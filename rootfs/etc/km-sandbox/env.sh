# km-sandbox 映像自帶的環境設定（openspec: sandbox-workload-image「環境設定檔與 runtime 上限」）。
# OpenShell 執行指令時不帶映像的 ENV（只保留 PATH，HOME 為 /work），需要環境變數的工具靠這個檔。
# code-executor-api 在執行腳本前載入它，並先帶入 SANDBOX_CPU_LIMIT（核心數，可為小數）與 SANDBOX_MEMORY_LIMIT（例如 1Gi、512M）。
# 只用 POSIX sh 的語法；載入時不輸出任何文字，也不讀寫任何檔案。
# code-executor-api 在子 shell 內載入本檔，只把 export 的變數帶給腳本：umask、ulimit、cd、函式與沒有 export 的變數都不會生效。

export LANG=C.UTF-8
export LC_ALL=C.UTF-8
# fontconfig 的預設語言：沒有指定字型或找不到指定的字型時，替代字型選繁體中文（台灣）的字形。
# 不設的話，LibreOffice 轉檔與 Chromium 會用到文泉驛正黑或其他地區的字形（2026-11-13 實測）。只影響字型的挑選，語系不變。
export FC_LANG=zh-TW
export PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
# Go 固定用映像內的工具鏈，不嘗試下載新版
export GOTOOLCHAIN=local
# Go 只能用標準函式庫：開網白名單不放行 Go 的模組代理（它會依模組路徑替請求去連任意網站，見 code-executor-api 的
# allowlist.yaml），go get 直接失敗，不嘗試連線
export GOPROXY=off
# 時區：台灣時間。date 與 Python、Node.js、Java、Go、R、Ruby 的本地時間都跟著 TZ；PHP 不看 TZ，
# 改由 /etc/km-sandbox/php-timezone.ini 沿用同一個值（PHP_INI_SCAN_DIR 開頭的空白段代表仍讀 PHP 預設的設定目錄）
export TZ=Asia/Taipei
export PHP_INI_SCAN_DIR=":/etc/km-sandbox"
# make 在沙盒內不能執行指令：沙盒禁止更改程式身分的系統呼叫，make 4.3 每執行一行指令都會這麼做（2026-11-14 實測）。
# cmake 預設改用 Ninja 產生建置檔，不帶 -G 也能建置
export CMAKE_GENERATOR=Ninja
# npm 連不上套件庫時不重試：預設的重試要約 70 秒才失敗（2026-11-14 實測，斷網時），會吃掉大半的逾時
export npm_config_fetch_retries=0
# npm install 預設另以 POST 送出 audit；開網白名單只准讀取，這個請求一定被擋（安裝照樣成功），關掉以免每次都留下一筆被擋的紀錄
export npm_config_audit=false
# pytest、ruff 不寫快取：腳本的工作目錄是跨輪保留、有容量上限的 /working_dir，快取目錄（.pytest_cache、.ruff_cache）會一直留在那裡；
# 每次呼叫都是新沙盒，快取也用不到
export PYTEST_ADDOPTS="-p no:cacheprovider"
export RUFF_NO_CACHE=true
# 開網時自行安裝的套件要放在可寫的位置（系統目錄唯讀）。R：使用者的套件目錄在映像裡已建好，R 啟動時把它排在
# 套件目錄的第一個，install.packages() 不指定 lib 就裝進去（目錄不存在時 R 不會用它，install.packages() 會以目錄不可寫失敗）
export R_LIBS_USER=/sandbox/R/library
# Ruby：gem install 預設加上 --user-install（裝進家目錄），說明見該檔
export GEMRC=/etc/km-sandbox/gemrc
# Rust：cargo（Ubuntu 的版本以 GnuTLS 連線）不看 SSL_CERT_FILE，開網時要另外指定憑證，才信任 OpenShell 解開 TLS 用的憑證；
# 沒有 SSL_CERT_FILE（斷網或不在沙盒內）時不設定，cargo 用系統預設
if [ -n "${SSL_CERT_FILE:-}" ]; then
    export CARGO_HTTP_CAINFO="$SSL_CERT_FILE"
fi

# 執行緒數＝CPU 上限無條件進位，至少 1；未傳入、不是數字或換算失敗時為 1。
# 沙盒內看得到主機全部的 CPU（配額以 CFS quota 實作），各 runtime 不設限會照主機核心數開執行緒而互搶。
_km_threads=$(awk -v c="${SANDBOX_CPU_LIMIT:-}" 'BEGIN {
    if (c !~ /^[0-9]+(\.[0-9]+)?$/) { print 1; exit }
    n = int(c); if (c + 0 > n) n++; if (n < 1) n = 1; print n
}')
case "$_km_threads" in
    '' | *[!0-9]* | 0) _km_threads=1 ;;
esac
export SANDBOX_THREADS="$_km_threads"
export OPENBLAS_NUM_THREADS="$_km_threads"
export OMP_NUM_THREADS="$_km_threads"
export MKL_NUM_THREADS="$_km_threads"
export NUMEXPR_NUM_THREADS="$_km_threads"
export GOMAXPROCS="$_km_threads"
# cmake --build（預設以 Ninja）的平行數。make 在沙盒內不能用，不設 MAKEFLAGS
export CMAKE_BUILD_PARALLEL_LEVEL="$_km_threads"
# cargo 同時編譯幾個 crate：預設照主機的 CPU 數（沙盒內是 128）。6 個 crate 的專案在 1 核／1 GiB 下，預設時記憶體峰值
# 686 MB、設為 1 時 202 MB（2026-11-16 實測），相依多的專案會超過記憶體上限
export CARGO_BUILD_JOBS="$_km_threads"
# joblib（scikit-learn 的 n_jobs 靠它）認定的 CPU 數：n_jobs=-1 時開幾個行程由它決定
export LOKY_MAX_CPU_COUNT="$_km_threads"

# 記憶體上限換算成位元組：K／M／G 以 1000 進位，Ki／Mi／Gi 以 1024 進位（與 OpenShell 對同一個字串的解讀一致）。
# 未傳入、無法解析或為 0（不限制）時不設定任何記憶體上限。
_km_mem=$(awk -v m="${SANDBOX_MEMORY_LIMIT:-}" 'BEGIN {
    if (m !~ /^[0-9]+(\.[0-9]+)?(K|M|G|Ki|Mi|Gi)?$/) exit
    u = m; sub(/^[0-9.]+/, "", u)
    v = m; sub(/[A-Za-z]+$/, "", v)
    f = 1
    if (u == "K") f = 1000; else if (u == "M") f = 1000 * 1000; else if (u == "G") f = 1000 * 1000 * 1000
    else if (u == "Ki") f = 1024; else if (u == "Mi") f = 1024 * 1024; else if (u == "Gi") f = 1024 * 1024 * 1024
    if (v * f < 1) exit
    printf "%.0f", v * f
}')
if [ -n "$_km_mem" ]; then
    # java、javac 的包裝腳本讀這個值
    export SANDBOX_MEMORY_LIMIT_BYTES="$_km_mem"
    # Node.js 的 heap 上限預設依主機記憶體決定；設為上限的 75%
    export NODE_OPTIONS="--max-old-space-size=$((_km_mem * 3 / 4 / 1048576))"
fi
unset _km_threads _km_mem
