#!/bin/bash
# km-sandbox 映像檢查：openspec sandbox-workload-image 各要求的代表性案例。
# 三個地方共用同一份：Dockerfile 的最後一步、deliver/test_offline.sh（斷網）、真的 OpenShell 沙盒內
# （code-executor-api 的 e2e 測試以 execute_bash 執行本檔，才驗得到沙盒政策之下的行為）。
# 以沙盒帳號、HOME=/work 執行，不需要網路；在 1 核的沙盒內要在 120 秒內跑完。
#
# 用法：check-image.sh [--licenses]
#   --licenses  另外比對三份授權清單是否涵蓋映像內所有已安裝的 pip、npm、apt 套件，以及每筆是否附授權全文、有沒有 AGPL 與不能商用的授權。
#               只能在沒有沙盒政策的環境用（直接 docker run，例如 deliver/test_offline.sh）：
#               沙盒內讀不到 dpkg 的資料庫（/var/lib/dpkg 不在政策的唯讀清單），apt 那一項會失敗
set -u

DOC=/usr/share/doc/km-sandbox
WITH_LICENSES=0
[ "${1:-}" = "--licenses" ] && WITH_LICENSES=1

# 直接 docker run 或在建置時執行，要自己載入設定檔；經 code-executor-api 執行時已載入過，重複載入結果相同
[ -r /etc/km-sandbox/env.sh ] && . /etc/km-sandbox/env.sh

W=$(mktemp -d /tmp/km-check.XXXXXX) || exit 1
cd "$W" || exit 1
trap 'rm -rf "$W"' EXIT

PASS=0
FAIL=0
START=$(date +%s)
ok() { PASS=$((PASS + 1)); echo "ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL  $1${2:+ — $2}"; }
# check <名稱> <指令…>：exit code 0 即通過；失敗時附上輸出的最後幾行
check() {
    local name="$1" out
    shift
    if out=$("$@" 2>&1); then ok "$name"; else bad "$name" "$(printf '%s' "$out" | tail -4 | tr '\n' ' ' | cut -c1-400)"; fi
}
# expect <名稱> <預期的 stdout> <指令…>
expect() {
    local name="$1" want="$2" got
    shift 2
    got=$("$@" 2>/dev/null)
    if [ "$got" = "$want" ]; then ok "$name"; else bad "$name" "預期「$want」，得到「$(printf '%s' "$got" | head -3 | tr '\n' ' ' | cut -c1-200)」"; fi
}
# 不帶入任何沙盒變數、重新載入設定檔後執行指令（驗證設定檔的換算）
with_limits() { # with_limits <cpu> <memory> <指令字串>
    env -i PATH="$PATH" HOME="$HOME" SANDBOX_CPU_LIMIT="$1" SANDBOX_MEMORY_LIMIT="$2" sh -c ". /etc/km-sandbox/env.sh; $3"
}

S="沙盒測試：繁體中文"
# 這個環境實際可用的 CPU 數。OpenBLAS 與 joblib 會把設定的執行緒數再以它封頂，在核心數少的建置主機上預期值要跟著降
NCPU=$(env -u OMP_NUM_THREADS -u OMP_THREAD_LIMIT nproc)
capped() { if [ "$1" -lt "$NCPU" ]; then echo "$1"; else echo "$NCPU"; fi; }
# 這個環境的 CPU 配額（核心數，無條件進位）：讀得到 cgroup 而且有設配額時才有值。joblib 讀得到時會把它算進去；沙盒內讀不到。
# 與 joblib 相同的順序：先讀 cgroup v2 的 cpu.max，沒有這個檔才讀 v1 的兩個檔（v1 的環境沒有實測過）
CPU_QUOTA=$(
    if [ -e /sys/fs/cgroup/cpu.max ]; then
        awk '$1 != "max" && $1 > 0 && $2 > 0 { n = int($1 / $2); if ($1 / $2 > n) n++; print n }' /sys/fs/cgroup/cpu.max
    elif [ -e /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -e /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
        awk -v q="$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)" -v p="$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)" \
            'BEGIN { if (q > 0 && p > 0) { n = int(q / p); if (q / p > n) n++; print n } }'
    fi 2> /dev/null
)
joblib_capped() {
    local n
    n=$(capped "$1")
    if [ -n "$CPU_QUOTA" ] && [ "$CPU_QUOTA" -lt "$n" ]; then echo "$CPU_QUOTA"; else echo "$n"; fi
}

echo "== 執行身分、檔案權限、指令與預建快取 =="
if [ "$(id -u):$(id -g)" = "1000:1000" ] && [ "$(id -un)" = "sandbox" ]; then ok "執行身分是 sandbox（uid/gid 1000）"; else bad "執行身分" "$(id)"; fi
# 映像自帶的檔案與系統目錄的權限是建置時指定的，不跟著建置主機的 umask 走；沙盒帳號在這些位置沒有任何可寫的東西
BAD=$(
    stat -c '%U:%G %a %n' /etc/km-sandbox/env.sh 2>&1 | grep -vxF 'root:root 644 /etc/km-sandbox/env.sh'
    stat -c '%U:%G %a %n' /usr/local/bin/python /usr/local/bin/python3 /usr/local/bin/pip /usr/local/bin/pip3 \
        /usr/local/bin/java /usr/local/bin/javac /usr/local/bin/go /usr/local/bin/sandbox-info \
        /etc /etc/km-sandbox /usr /usr/local /usr/local/bin /usr/share /usr/share/doc /usr/share/doc/km-sandbox /opt 2>&1 \
        | grep -vE '^root:root 755 /'
)
if [ -z "$BAD" ]; then ok "設定檔 644、包裝腳本與系統目錄 755，擁有者都是 root"; else bad "擁有者或權限不對" "$(printf '%s' "$BAD" | tr '\n' ' ' | cut -c1-300)"; fi
BAD=$(find /etc/km-sandbox /usr/local /opt /usr/share/doc/km-sandbox \( -user sandbox -o \( ! -type l -perm -0002 \) \) -print 2> /dev/null | head -5)
if [ -z "$BAD" ]; then ok "/etc/km-sandbox、/usr/local、/opt 底下沒有沙盒帳號擁有或任何人可寫的檔案"; else bad "有沙盒帳號擁有或任何人可寫的檔案" "$(printf '%s' "$BAD" | tr '\n' ' ')"; fi
# 反過來，沙盒帳號自己的目錄裡不該有別人的檔案（建置時以 root 執行虛擬環境的 python 會留下 root 的 .pyc）
BAD=$(find /sandbox /work ! -user sandbox -print 2> /dev/null | head -5)
if [ -z "$BAD" ]; then ok "/sandbox、/work 底下的檔案都歸沙盒帳號"; else bad "/sandbox 或 /work 底下有不屬於沙盒帳號的檔案" "$(printf '%s' "$BAD" | tr '\n' ' ')"; fi
MISSING=""
for t in curl zip unzip jq bc ip file xz 7z git rg sqlite3 gcc g++ make cmake ninja java javac go Rscript ruby php node npm tsc tsx \
    soffice pdftoppm pdftotext pdfimages qpdf pdftk pandoc convert tesseract xelatex latexmk sandbox-info; do
    command -v "$t" > /dev/null || MISSING="$MISSING $t"
done
if [ -z "$MISSING" ]; then ok "指令都在 PATH"; else bad "缺少指令" "$MISSING"; fi
expect "python 導向 /sandbox/.venv" "/sandbox/.venv" python -c "import sys; print(sys.prefix)"
# 只有系統預設 PATH（沒有 venv 的 bin）時，不帶路徑的 python、pip 仍要由 /usr/local/bin 的包裝導向 venv
SYSTEM_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
expect "系統預設 PATH 下 python 是 /usr/local/bin 的包裝" "/usr/local/bin/python" env PATH="$SYSTEM_PATH" sh -c 'command -v python'
expect "系統預設 PATH 下 python3、pip 仍導向 /sandbox/.venv" "/sandbox/.venv /sandbox/.venv" env PATH="$SYSTEM_PATH" sh -c \
    'echo "$(python3 -c "import sys; print(sys.prefix)") $(pip --version | grep -o "/sandbox/.venv" | head -1)"'
if [ -d /work/.cache/matplotlib ]; then ok "預建的 matplotlib 字型快取"; else bad "缺少 /work/.cache/matplotlib"; fi
if [ -d /work/.cache/go-build ]; then ok "預建的 Go 編譯快取"; else bad "缺少 /work/.cache/go-build"; fi
expect "語系是 UTF-8" "C.UTF-8" sh -c 'echo "$LANG"'

echo "== 授權範圍（openspec: sandbox-image-license-review） =="
# 基底是 Docker 官方的 ubuntu:24.04，不是 NVIDIA 重新打包的版本（design D6）
OS=$(. /etc/os-release && echo "$ID $VERSION_ID")
if [ "$OS" = "ubuntu 24.04" ] && [ ! -e /opt/nvidia/ubuntu-base-image ]; then ok "基底是官方的 Ubuntu 24.04"
else bad "基底不是官方的 Ubuntu 24.04" "$OS；/opt/nvidia/ubuntu-base-image $([ -e /opt/nvidia/ubuntu-base-image ] && echo 存在 || echo 不存在)"; fi
# 不預裝 GPL 版的 ffmpeg 與影音編碼器（D1），也沒有 AGPL 的 Identity-UTF16-H（D2）：以檔名在整個系統目錄、/opt 與 venv 找
# （也涵蓋 pip、npm 套件自己附的 ffmpeg；套件改版換了位置也找得到），不查 dpkg：沙盒內讀不到 dpkg 的資料庫。
# Playwright 附帶的 LGPL 版 ffmpeg 在 /opt/pw-browsers，不在 PATH，排除。沙盒政策不放行 /var/lib/ghostscript，沙盒內只查得到其餘位置
FOUND=$(find /usr /opt /sandbox/.venv /var/lib/ghostscript \( -name 'Identity-UTF16-H*' -o -name 'libavcodec*' -o -name 'libpostproc*' \
    -o -name 'libx264*' -o -name 'libx265*' -o -name 'libxvidcore*' -o -iname '*ffmpeg*' \) -not -path '/opt/pw-browsers/*' 2> /dev/null)
GPL_AV=$(printf '%s\n' "$FOUND" | grep -v 'Identity-UTF16-H' | grep . | head -5 | tr '\n' ' ')
if ! command -v ffmpeg > /dev/null && [ -z "$GPL_AV" ]; then ok "沒有 GPL 版的 ffmpeg 與影音編碼器"
else bad "有 GPL 版的 ffmpeg 或影音編碼器" "${GPL_AV:-$(command -v ffmpeg)}"; fi
AGPL=$(printf '%s\n' "$FOUND" | grep 'Identity-UTF16-H' | head -5 | tr '\n' ' ')
if [ -z "$AGPL" ]; then ok "沒有 AGPL 的 Identity-UTF16-H"
else bad "有 AGPL 的 Identity-UTF16-H" "$AGPL"; fi
CMAP=/usr/share/poppler/cMap
if [ -d "$CMAP/Adobe-CNS1" ] && [ -e "$CMAP/Identity-H" ] && [ -e "$CMAP/Identity-V" ]; then ok "繁體中文 PDF 用的字元對應表都在（Adobe-CNS1、Identity-H、Identity-V）"
else bad "繁體中文 PDF 用的字元對應表不齊" "$(ls -d "$CMAP/Adobe-CNS1" "$CMAP/Identity-H" "$CMAP/Identity-V" 2>&1 | tr '\n' ' ')"; fi

echo "== 映像自我描述 =="
INFO=$(sandbox-info 2> /dev/null)
SIZE=$(printf '%s' "$INFO" | wc -c)
if [ "$SIZE" -gt 1000 ] && [ "$SIZE" -lt 65536 ]; then ok "sandbox-info 輸出 $SIZE bytes（小於 64 KiB）"; else bad "sandbox-info 輸出大小" "$SIZE bytes"; fi
MISSING=""
for w in Python Node.js TypeScript Java Go Ruby PHP LibreOffice Poppler pandoc tesseract ImageMagick "TeX Live" Chromium pandas pptxgenjs ggplot2 注意事項; do
    printf '%s' "$INFO" | grep -qF -- "$w" || MISSING="$MISSING $w"
done
if [ -z "$MISSING" ]; then ok "sandbox-info 列出語言、工具與套件"; else bad "sandbox-info 缺少項目" "$MISSING"; fi
MISMATCH=""
for pair in "python3 --version" "node --version" "tsc --version" "soffice --version" "pandoc --version" "go version"; do
    v=$($pair 2>&1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1)
    # 取不到版本（工具壞了）也算不符；空字串拿去比對會一律成立
    if [ -z "$v" ] || ! printf '%s' "$INFO" | grep -qF -- "$v"; then MISMATCH="$MISMATCH [$pair → ${v:-取不到版本}]"; fi
done
if [ -z "$MISMATCH" ]; then ok "sandbox-info 的版本與實際一致"; else bad "sandbox-info 的版本與實際不符" "$MISMATCH"; fi

echo "== Python 套件、matplotlib、reportlab、多行程 =="
# 虛擬環境裝到的每個套件與版本都要與鎖定檔相同：requirements.txt 加了套件卻沒有重新產生 constraints.txt 時，
# 新套件的間接相依不受鎖定檔限制，連網與離線建置會各自解析出不同的版本
DIFF=$(diff <(pip freeze 2> /dev/null | sort) <(grep -vE '^(#|$)' "$DOC/constraints.txt" | sort) | grep -E '^[<>]' | head -6 | tr '\n' ' ')
if [ -z "$DIFF" ]; then ok "虛擬環境的套件與版本和 constraints.txt 相同"; else bad "虛擬環境的套件與 constraints.txt 不同（< 是實際安裝的，> 是鎖定檔的）" "$DIFF"; fi
check "Python 套件可匯入，matplotlib 與 reportlab 的中文字型" python - << 'PY'
import concurrent.futures
import importlib
import multiprocessing

for name in (
    "pandas numpy scipy sklearn statsmodels sympy matplotlib seaborn pyarrow openpyxl xlsxwriter xlrd docx pptx "
    "reportlab pypdf pdfplumber pypdfium2 img2pdf chardet tabulate tqdm dateutil pytz joblib PIL "
    "markitdown defusedxml lxml pdf2image pytesseract playwright"
).split():
    importlib.import_module(name)

import matplotlib
import matplotlib.font_manager as fm
import matplotlib.pyplot as plt

assert matplotlib.get_backend().lower() == "agg", matplotlib.get_backend()
assert matplotlib.rcParams["font.sans-serif"][0] == "Noto Sans CJK TC", matplotlib.rcParams["font.sans-serif"]
assert any("CJK" in f.name for f in fm.fontManager.ttflist), "no CJK font"
import warnings

with warnings.catch_warnings():
    warnings.simplefilter("error")  # 缺字會發出 UserWarning
    plt.figure(); plt.title("繁體中文標題"); plt.plot([1, 2]); plt.savefig("mpl.png")

from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont

font = TTFont("WenQuanYiMicroHei", "/usr/share/fonts/truetype/wqy/wqy-microhei.ttc", subfontIndex=0)
pdfmetrics.registerFont(font)
assert all(ord(c) in font.face.charToGlyph for c in "繁體中文報表臺灣")

with multiprocessing.Pool(2) as pool:
    assert pool.map(abs, [-1, -2]) == [1, 2]
with concurrent.futures.ProcessPoolExecutor(2) as executor:
    assert list(executor.map(abs, [-3, -4])) == [3, 4]
PY
check "joblib 與 scikit-learn 的 n_jobs（多行程）" python - << 'PY'
import os

import joblib
from joblib import Parallel, delayed
from sklearn.datasets import make_classification
from sklearn.ensemble import RandomForestClassifier
from sklearn.model_selection import cross_val_score

assert 1 <= joblib.cpu_count() <= int(os.environ["SANDBOX_THREADS"]), joblib.cpu_count()
# 明確指定 2 個行程：不論配額多少都會真的開出工作行程
pids = Parallel(n_jobs=2)(delayed(os.getpid)() for _ in range(8))
assert os.getpid() not in pids, "沒有開出工作行程"
X, y = make_classification(n_samples=200, n_features=8, random_state=0)
model = RandomForestClassifier(n_estimators=10, n_jobs=-1, random_state=0)
assert cross_val_score(model, X, y, cv=2, n_jobs=-1).mean() > 0.5
PY
# joblib 算 CPU 數時會讀 /sys/fs/cgroup/cpu.max，沙盒政策不放行它，讀不到時要照常運作（靠 km_sandbox_hooks.py）。
# 建置與離線測試的環境讀得到這個檔，所以這裡讓「開啟 /sys/fs/cgroup 底下的檔案」一律被拒，模擬沙盒內的情況
check "joblib 讀不到 /sys/fs/cgroup 時照常運作" python - << 'PY'
import builtins
import os

real_open = builtins.open


def deny_cgroup(file, *args, **kwargs):
    if str(file).startswith("/sys/fs/cgroup"):
        raise PermissionError(13, "Permission denied", str(file))
    return real_open(file, *args, **kwargs)


builtins.open = deny_cgroup

import joblib
from joblib import Parallel, delayed

expected = min(int(os.environ["SANDBOX_THREADS"]), len(os.sched_getaffinity(0)))
assert joblib.cpu_count() == expected, (joblib.cpu_count(), expected)
assert Parallel(n_jobs=2)(delayed(abs)(-i) for i in range(4)) == [0, 1, 2, 3]
PY
# 預裝的測試與程式碼檢查工具：pytest 跑一個測試、ruff 檢查同一個檔。設定檔關掉兩者的快取，
# 不加參數執行也不在目前目錄留下 .pytest_cache、.ruff_cache（沙盒內的目前目錄是跨輪保留的 /working_dir）
printf 'def add(a, b):\n    return a + b\n\n\ndef test_add():\n    assert add(1, 2) == 3\n' > test_km_check.py
expect "pytest 與 ruff（不留快取目錄）" "1 passed|All checks passed!|" sh -c \
    'echo "$(python -m pytest -q test_km_check.py 2>&1 | grep -oE "[0-9]+ passed")|$(ruff check test_km_check.py 2>&1 | tail -1)|$(ls -d .pytest_cache .ruff_cache 2> /dev/null)"'

echo "== 各語言的單支程式（輸出含繁體中文） =="
cat > m.go << 'GO'
package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"sort"
)

func main() {
	xs := []int{3, 1, 2}
	sort.Ints(xs)
	b, _ := json.Marshal(xs)
	fmt.Println("沙盒測試：繁體中文", string(b), http.StatusOK)
}
GO
# go 每次建置結束時會刪掉 5 天沒用到的快取項目（一天最多一次），而預建的快取在使用時一定超過 5 天。
# 先放一個 10 天前的快取項目，並把「上次清理時間」改成很久以前：/usr/local/bin/go 的包裝有作用的話，建置後它還在
GO_CACHE=/work/.cache/go-build
GO_OLD_ENTRY=$GO_CACHE/00/km-sandbox-check-d
touch -d '10 days ago' "$GO_OLD_ENTRY" 2> /dev/null && echo 1 > "$GO_CACHE/trim.txt"
T0=$(date +%s.%N)
GOT=$(go run m.go 2>&1)
GO_SEC=$(echo "$(date +%s.%N) - $T0" | bc)
if [ "$GOT" = "$S [1,2,3] 200" ]; then ok "Go"; else bad "Go" "$(printf '%s' "$GOT" | tail -2 | tr '\n' ' ')"; fi
if awk -v s="$GO_SEC" 'BEGIN { exit !(s <= 5) }'; then ok "Go 第一次執行 ${GO_SEC} 秒（不超過 5 秒）"; else bad "Go 第一次執行太慢" "${GO_SEC} 秒"; fi
if [ -e "$GO_OLD_ENTRY" ]; then ok "Go 建置後沒有清掉超過 5 天的預建快取"; else bad "Go 清掉了超過 5 天的快取項目" "/usr/local/bin/go 的包裝沒有作用"; fi
rm -f "$GO_OLD_ENTRY"
expect "Python" "$S" python3 -c "print('$S')"
expect "Node.js" "$S" node -e "console.log('$S')"
printf "const s: string = '%s';\nconsole.log(s);\n" "$S" > t.ts
expect "TypeScript（tsx 直接執行）" "$S" tsx t.ts
check "TypeScript（tsc 編譯）" tsc t.ts
expect "TypeScript（執行 tsc 編譯出的 JavaScript）" "$S" node t.js
printf '#include <stdio.h>\nint main(void) { puts("%s"); return 0; }\n' "$S" > t.c
check "C 編譯" gcc t.c -o t_c
expect "C" "$S" ./t_c
printf '#include <iostream>\n#include <string>\nint main() { std::string s = "%s"; std::cout << s << std::endl; }\n' "$S" > t.cpp
check "C++ 編譯" g++ -std=c++20 t.cpp -o t_cpp
expect "C++" "$S" ./t_cpp
# 沙盒內 make 不能執行指令，cmake 預設的 Unix Makefiles 產生器也就不能用；設定檔把預設改為 Ninja，不帶 -G 也要能建置。
# 建置與離線測試時沒有沙盒的限制，make 可以用，所以另外確認產生的是 Ninja 的建置檔
mkdir -p cm && cp t.c cm/main.c && printf 'cmake_minimum_required(VERSION 3.20)\nproject(km_check C)\nadd_executable(km_check main.c)\n' > cm/CMakeLists.txt
expect "cmake 不指定產生器也能建置（預設 Ninja）" "$S" sh -c 'cmake -S cm -B cm/build > /dev/null && [ -f cm/build/build.ninja ] && cmake --build cm/build > /dev/null && ./cm/build/km_check'
printf 'fn main() {\n    let s = "%s";\n    println!("{}", s);\n}\n' "$S" > t.rs
expect "Rust（rustc）" "$S" sh -c 'rustc -O t.rs -o t_rs 2> /dev/null && ./t_rs'
# cargo 建專案、建置與執行（沒有相依，不需要網路），再以 rustfmt、clippy 檢查同一個專案
expect "Rust（cargo 建置與執行、rustfmt、clippy）" "Hello, world! ok" sh -c \
    'cargo new --vcs none rs-demo -q && cd rs-demo && echo "$(cargo run -q 2> /dev/null) $(cargo fmt --check && cargo clippy -q 2> /dev/null && echo ok)"'
printf 'public class Hello { public static void main(String[] a) { System.out.println("%s"); } }\n' "$S" > Hello.java
check "Java 編譯" javac Hello.java
expect "Java" "$S" java -cp . Hello
expect "R" "$S" Rscript -e "cat('$S\n')"
expect "Ruby" "$S" ruby -e "puts '$S'"
expect "PHP" "$S" php -r "echo '$S', PHP_EOL;"
expect "Ruby 的字串長度" "4" ruby -e 'puts "中文字串".length'
expect "R 的字串長度" "4" Rscript -e 'cat(nchar("中文字串"))'
expect "PHP 的 mb_strlen" "4" php -r 'echo mb_strlen("中文字串");'
# 設定檔把時區設為台灣時間；PHP 不看 TZ，靠 /etc/km-sandbox/php-timezone.ini
expect "本地時間是台灣時間（date、Python、PHP）" "+0800 +0800 Asia/Taipei" sh -c \
    'echo "$(date +%z) $(python3 -c "import datetime; print(datetime.datetime.now().astimezone().strftime(\"%z\"))") $(php -r "echo date_default_timezone_get();")"'
cat > plot.R << 'R'
suppressMessages(library(ggplot2))
df <- data.frame(x = 1:20, y = cumsum(rep(c(1, -0.5), 10)))
p <- ggplot(df, aes(x, y)) + geom_line() + ggtitle("繁體中文標題")
ggsave("r_plot.png", p, width = 5, height = 3, dpi = 80)
R
Rscript plot.R > r.out 2> r.err
if [ -s r_plot.png ] && ! grep -qiE 'warning|警告|font' r.err; then ok "R 以 ggplot2 繪圖（中文標題、沒有字型警告）"; else bad "R 繪圖" "$(tail -3 r.err | tr '\n' ' ')"; fi
check "R 的常用套件" Rscript -e 'for (p in c("ggplot2", "dplyr", "tidyr", "readr", "readxl", "data.table")) suppressMessages(library(p, character.only = TRUE))'

echo "== 自行安裝套件：預設的安裝位置與套件庫（以本機的套件驗證，不需要網路） =="
# 有 Python 的標頭檔（python3-dev），pip 才能從原始碼安裝含 C 程式碼的套件。這裡不經 pip（setuptools 沒有預裝，
# pip 會從 PyPI 下載），直接以 gcc 編譯一個 C 擴充再載入
printf '#include <Python.h>\nstatic PyObject *hi(PyObject *self, PyObject *args) { return PyUnicode_FromString("%s"); }\nstatic PyMethodDef methods[] = {{"hi", hi, METH_NOARGS, NULL}, {NULL, NULL, 0, NULL}};\nstatic struct PyModuleDef module = {PyModuleDef_HEAD_INIT, "km_ext", NULL, -1, methods};\nPyMODINIT_FUNC PyInit_km_ext(void) { return PyModule_Create(&module); }\n' "$S" > km_ext.c
expect "Python 的 C 擴充可以編譯（有 Python 標頭檔）" "$S" sh -c \
    'gcc -shared -fPIC $(python3-config --includes) km_ext.c -o "km_ext$(python3-config --extension-suffix)" && python3 -c "import km_ext; print(km_ext.hi())"'
# 系統的套件目錄在沙盒內唯讀：install.packages() 不指定 lib 時要裝進使用者的套件目錄（設定檔的 R_LIBS_USER，映像裡已建好）
mkdir -p rpkg/R
printf 'Package: kmcheck\nVersion: 0.1\nTitle: Check\nDescription: Check.\nLicense: MIT\nEncoding: UTF-8\nAuthor: km\nMaintainer: km <km@example.com>\n' > rpkg/DESCRIPTION
echo 'export(hi)' > rpkg/NAMESPACE
printf 'hi <- function() "%s"\n' "$S" > rpkg/R/hi.R
expect "R 的 install.packages() 不指定 lib 就裝進使用者的套件目錄" "$S /sandbox/R/library" sh -c \
    'Rscript -e "install.packages(\"rpkg\", repos = NULL, type = \"source\")" > /dev/null 2>&1 && Rscript -e "cat(kmcheck::hi(), dirname(find.package(\"kmcheck\")))"'
Rscript -e 'remove.packages("kmcheck")' > /dev/null 2>&1
# 系統的 gem 目錄在沙盒內唯讀：gem install 不加參數時要裝進家目錄（設定檔以 GEMRC 帶入 --user-install）
mkdir -p gempkg/lib
printf 'def km_check_hi = "%s"\n' "$S" > gempkg/lib/km_check.rb
printf 'Gem::Specification.new do |s|\n  s.name = "km_check"\n  s.version = "0.1.0"\n  s.summary = "check"\n  s.authors = ["km"]\n  s.license = "MIT"\n  s.files = ["lib/km_check.rb"]\nend\n' > gempkg/km_check.gemspec
expect "gem install 不加參數就裝進家目錄" "$S" sh -c \
    '(cd gempkg && gem build km_check.gemspec) > /dev/null 2>&1 && gem install --local gempkg/km_check-0.1.0.gem > /dev/null 2>&1 && ruby -e "require \"km_check\"; puts km_check_hi"'
gem uninstall --executables km_check > /dev/null 2>&1
# 各工具預設連的套件庫要和 code-executor-api 開網白名單（conf/policies/allowlist.yaml）列的網站相同，改一邊另一邊要跟著改；
# 白名單不放行 Go 的模組代理，GOPROXY 是 off
expect "npm、R、gem 預設連的套件庫與開網白名單一致，Go 不連模組代理" \
    "https://registry.npmjs.org/ https://cloud.r-project.org https://rubygems.org/ off" sh -c \
    'echo $(npm config get registry) $(Rscript -e "cat(getOption(\"repos\")[[\"CRAN\"]])") $(gem sources | grep "^https") $(go env GOPROXY)'
# 開網白名單以程式的真實路徑放行（allowlist.yaml 的 binaries；symlink 不算）。換語言版本時路徑會變，例如 Rust 的
# /usr/lib/rust-1.97，白名單沒跟著改的話該語言默默連不出去，所以在這裡比對，兩邊要一起改
expect "開網白名單列的程式路徑與映像一致" \
    "/usr/bin/curl /usr/bin/python3.12 /usr/local/bin/node /usr/lib/R/bin/exec/R /usr/bin/ruby3.2 /usr/lib/rust-1.97/bin/cargo" sh -c \
    'echo $(readlink -f "$(command -v curl)") $(readlink -f /sandbox/.venv/bin/python3) $(readlink -f "$(command -v node)") $(ls /usr/lib/R/bin/exec/R) $(readlink -f "$(command -v ruby)") $(readlink -f "$(command -v cargo)")'

echo "== Node.js 預裝套件 =="
mkdir -p sub/dir
check "任意目錄可用 require 載入預裝套件" sh -c "cd sub/dir && node -e \"for (const m of ['pptxgenjs', 'docx', 'pdf-lib', 'sharp', 'react', 'react-dom/server', 'react-icons/fa', 'typescript', 'playwright']) require(m)\""
cat > sub/dir/esm.mjs << 'JS'
import PptxGenJS from 'pptxgenjs';
import { Document } from 'docx';
import { PDFDocument } from 'pdf-lib';
import sharp from 'sharp';
import React from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { FaHome } from 'react-icons/fa';
import { chromium } from 'playwright';

// react 與 react-dom 要是同一份：元件用到 hook 時，兩份不同的 react 會讓渲染失敗
function Icon() {
  const [size] = React.useState(24);
  return React.createElement(FaHome, { size });
}
const svg = renderToStaticMarkup(React.createElement(Icon));
const loaded = [PptxGenJS, Document, PDFDocument, sharp, chromium].every((m) => m);
console.log(loaded && svg.startsWith('<svg') ? 'ok' : 'failed');
JS
expect "任意目錄可用 import 載入預裝套件（含以 react 渲染圖示）" "ok" sh -c "cd sub/dir && node esm.mjs"
printf "import PptxGenJS from 'pptxgenjs';\nconst deck: PptxGenJS = new PptxGenJS();\nconsole.log(typeof deck.addSlide);\n" > sub/dir/typed.ts
check "tsc 找得到預裝套件的型別" sh -c "cd sub/dir && tsc --noEmit typed.ts"
expect "tsx 執行 import 預裝套件的 TypeScript" "function" sh -c "cd sub/dir && tsx typed.ts"
printf "import fs from 'node:fs';\nconsole.log(fs.existsSync('/'), process.argv.length > 0);\n" > sub/dir/nodeapi.ts
check "tsc 加 --types node 可編譯用到 Node.js 內建模組的程式" sh -c "cd sub/dir && tsc --noEmit --types node nodeapi.ts"
# 根目錄有 /node_modules，npm 在沒有 package.json 的目錄會把根目錄當成專案（npm install 會以權限錯誤失敗）；
# 注意事項寫的做法是先 npm init -y，這裡確認之後 npm 就以該目錄為專案，預裝的套件也還載得到
mkdir -p npm-project
expect "npm init -y 之後 npm 以該目錄為專案，預裝套件仍可載入" "$W/npm-project ok" sh -c \
    "cd npm-project && npm init -y > /dev/null 2>&1 && echo \"\$(npm prefix 2> /dev/null) \$(node -e \"require('pptxgenjs'); console.log('ok')\")\""
# 斷網時 npm 預設要重試約 70 秒才失敗；設定檔關掉重試。開網白名單只准讀取，audit 的 POST 一定被擋，設定檔也關掉
expect "npm 連不上套件庫時不重試、不送 audit" "0 false" sh -c 'echo $(npm config get fetch-retries) $(npm config get audit)'
PW_PY=$(python -c "import importlib.metadata as m; print(m.version('playwright'))" 2> /dev/null)
PW_NODE=$(node -p "require('playwright/package.json').version" 2> /dev/null)
if [ -n "$PW_PY" ] && [ "$PW_PY" = "$PW_NODE" ]; then ok "Playwright 的 Python 與 Node.js 套件同版（$PW_PY）"; else bad "Playwright 版本不一致" "pip=$PW_PY npm=$PW_NODE"; fi

echo "== Office 轉檔、PDF 工具 =="
check "以 python 建立 pptx、docx、xlsx" python - << 'PY'
import openpyxl
from docx import Document
from pptx import Presentation

deck = Presentation()
for i in range(5):
    slide = deck.slides.add_slide(deck.slide_layouts[1])
    slide.shapes.title.text = f"第 {i + 1} 頁：季度營運報告"
    slide.placeholders[1].text = "重點一：營收成長\n重點二：新客戶"
deck.save("deck.pptx")
doc = Document()
doc.add_heading("測試文件", 0)
for i in range(10):
    doc.add_paragraph(f"第 {i + 1} 段：這是一段繁體中文測試內容。")
doc.save("doc.docx")
book = openpyxl.Workbook()
sheet = book.active
for r in range(1, 201):
    sheet.append([r, r * 2, f"=A{r}+B{r}"])
sheet["E1"] = "=SUM(C1:C200)"
book.save("book.xlsx")
PY
LO="soffice --headless -env:UserInstallation=file://$W/lo_profile"
mkdir -p out
check "LibreOffice：pptx 轉 PDF" $LO --convert-to pdf --outdir out deck.pptx
check "LibreOffice：docx 轉 PDF" $LO --convert-to pdf --outdir out doc.docx
check "LibreOffice：重算 xlsx" $LO --convert-to xlsx --outdir out book.xlsx
expect "pptx 轉出的 PDF 是 5 頁" "5" sh -c "pdfinfo out/deck.pdf | awk '/^Pages:/ {print \$2}'"
# 兩份文件都沒有指定中日韓字型：pptx 的字形由 LibreOffice 的預設文件語言決定，docx（範本指定了映像沒有的字型）由 fontconfig
# 挑替代字型；兩者都要是繁體（TC）字形
for f in deck doc; do
    FONTS=$(pdffonts "out/$f.pdf" 2> /dev/null | tail -n +3 | awk '{print $1}' | sed 's/^[A-Z]*+//' | sort -u | tr '\n' ' ')
    if printf '%s' "$FONTS" | grep -q 'CJKtc' && ! printf '%s' "$FONTS" | grep -qE 'CJK(sc|jp|kr|hk)|WenQuanYi'; then
        ok "$f.pdf 內嵌繁體字形的中文字型"
    else
        bad "$f.pdf 的中文字型不是繁體字形" "$FONTS"
    fi
done
expect "重算後讀得到公式的計算值" "60300" python -c "import openpyxl; print(openpyxl.load_workbook('out/book.xlsx', data_only=True).active['E1'].value)"
check "pdftoppm：PDF 轉圖" pdftoppm -jpeg -r 50 out/deck.pdf out/slide
expect "PDF 轉出 5 張圖" "5" sh -c "ls out/slide-*.jpg | wc -l"
check "qpdf：合併" qpdf --empty --pages out/deck.pdf out/doc.pdf -- out/merged.pdf
check "pdftk：擷取頁面" pdftk out/deck.pdf cat 1-2 output out/p12.pdf
expect "pdftk 擷取出 2 頁" "2" sh -c "pdfinfo out/p12.pdf | awk '/^Pages:/ {print \$2}'"
check "ImageMagick：產生與縮放" sh -c "convert -size 400x300 gradient:blue-white g.png && convert g.png -resize 50% g.jpg && identify g.jpg | grep -q '200x150'"

echo "== 中文 PDF 排版 =="
cat > t.tex << 'TEX'
\documentclass{article}
\usepackage{xeCJK}
\setCJKmainfont{Noto Serif CJK TC}
\begin{document}
\section{測試}
繁體中文排版測試：$E=mc^2$，$\int_0^1 x^2\,dx=\frac{1}{3}$。
\end{document}
TEX
check "xelatex 編譯含中文與數學式的文件" xelatex -interaction=nonstopmode -halt-on-error t.tex
if pdftotext t.pdf - 2> /dev/null | grep -q '繁體中文排版測試'; then ok "xelatex 的 PDF 內文是中文"; else bad "xelatex 的 PDF 內文" "找不到中文"; fi
printf '# 標題\n\n這是 **pandoc** 測試。\n\n| 項目 | 數值 |\n|---|---|\n| 甲 | 1 |\n' > a.md
check "pandoc：Markdown 轉 PDF" pandoc a.md -o a.pdf --pdf-engine=xelatex -V CJKmainfont="Noto Serif CJK TC"
if pdftotext a.pdf - 2> /dev/null | grep -q '標題'; then ok "pandoc 的 PDF 內文是中文"; else bad "pandoc 的 PDF 內文" "找不到中文"; fi
check "pandoc：Markdown 轉 docx 再讀回" sh -c "pandoc a.md -o a.docx && pandoc a.docx -t markdown | grep -q '標題'"

echo "== OCR =="
check "產生含中文的圖片" python - << 'PY'
from PIL import Image, ImageDraw, ImageFont

font = ImageFont.truetype("/usr/share/fonts/truetype/wqy/wqy-microhei.ttc", 44)
image = Image.new("RGB", (1000, 120), "white")
ImageDraw.Draw(image).text((20, 30), "沙盒文字辨識測試 OCR 2026", font=font, fill="black")
image.save("ocr.png")
PY
# 圖片只有一行字，用單行模式（--psm 7）；預設的版面分析（--psm 3）對單行圖片會漏掉開頭幾個字
OCR=$(tesseract ocr.png stdout -l chi_tra+eng --psm 7 2> /dev/null | tr -d ' \n')
if printf '%s' "$OCR" | grep -q '文字辨識' && printf '%s' "$OCR" | grep -q 'OCR2026'; then ok "tesseract 辨識繁體中文與英數字"; else bad "tesseract 辨識結果" "$OCR"; fi

echo "== Chromium（以 Playwright 的一般寫法啟動，不帶額外參數） =="
check "Python 的 Playwright：截圖與輸出 PDF，瀏覽器帶著 --no-zygote 啟動" python - << 'PY'
import glob

from playwright.sync_api import sync_playwright


def browser_main_processes():
    """正在執行的 Chromium 主行程的參數（子行程帶 --type=，不算）。"""
    found = []
    for path in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            with open(path, "rb") as fp:
                # 子行程會把整串參數改寫成以空白分隔的一個字串，所以不能只靠 NUL 切開
                args = fp.read().replace(b"\0", b" ").decode(errors="replace").split()
        except OSError:
            continue
        if args and "chrome-headless-shell" in args[0] and not any(a.startswith("--type=") for a in args):
            found.append(args)
    return found


with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page()
    # 不指定字型與語言，中文要以繁體字形呈現
    page.set_content("<html><body><h1>沙盒瀏覽器測試</h1></body></html>")
    page.screenshot(path="shot.png")
    page.pdf(path="shot.pdf")
    # 沙盒內不加 --no-zygote 就開不了頁面，沒有沙盒政策的環境（建置、離線測試）不加也能開；
    # 直接看行程的參數，包裝腳本沒有作用時在任何環境都驗得到
    processes = browser_main_processes()
    browser.close()
assert processes, "找不到 Chromium 的主行程"
assert all("--no-zygote" in args for args in processes), [args[:3] for args in processes]
PY
if [ -s shot.png ] && pdftotext shot.pdf - 2> /dev/null | grep -q '沙盒瀏覽器測試'; then ok "Chromium 的截圖與 PDF（中文正確）"; else bad "Chromium 的輸出" "shot.png 或 shot.pdf 不正確"; fi
FONTS=$(pdffonts shot.pdf 2> /dev/null | tail -n +3 | awk '{print $1}' | sed 's/^[A-Z]*+//' | sort -u | tr '\n' ' ')
if printf '%s' "$FONTS" | grep -q 'CJKtc'; then ok "Chromium 沒指定字型時用繁體字形的中文字型"; else bad "Chromium 的中文字型不是繁體字形" "$FONTS"; fi
check "Node.js 的 Playwright：截圖與輸出 PDF" node -e "
const { chromium } = require('playwright');
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  await page.setContent('<h1>沙盒瀏覽器測試</h1>');
  await page.screenshot({ path: 'shot_node.png' });
  await page.pdf({ path: 'shot_node.pdf' });
  await browser.close();
})().catch((e) => { console.error(String(e).split('\n')[0]); process.exit(1); });
"
if [ -s shot_node.png ] && pdftotext shot_node.pdf - 2> /dev/null | grep -q '沙盒瀏覽器測試' && pdffonts shot_node.pdf 2> /dev/null | grep -q 'CJKtc'; then
    ok "Node.js 的截圖與 PDF（中文正確、繁體字形）"
else
    bad "Node.js 的 Playwright 輸出" "shot_node.png 或 shot_node.pdf 不正確"
fi

echo "== markitdown =="
T0=$(date +%s.%N)
MD=$(markitdown out/book.xlsx 2> md.err)
MD_SEC=$(echo "$(date +%s.%N) - $T0" | bc)
if printf '%s' "$MD" | grep -q '60300'; then ok "markitdown 讀取 xlsx"; else bad "markitdown 讀取 xlsx" "$(tail -2 md.err | tr '\n' ' ' | cut -c1-200)"; fi
if awk -v s="$MD_SEC" 'BEGIN { exit !(s <= 10) }'; then ok "markitdown ${MD_SEC} 秒（不超過 10 秒）"; else bad "markitdown 太慢" "${MD_SEC} 秒"; fi
if grep -q 'pthread_setaffinity_np' md.err; then bad "markitdown 的錯誤輸出有執行緒親和性錯誤" "$(grep -c pthread_setaffinity_np md.err) 行"; else ok "markitdown 的錯誤輸出沒有執行緒親和性錯誤"; fi

echo "== 環境設定檔：執行緒數與記憶體上限 =="
GOT=""
for c in 0.5 1 1.5 4; do GOT="$GOT$(with_limits "$c" "" 'echo "$SANDBOX_THREADS"') "; done
if [ "$GOT" = "1 1 2 4 " ]; then ok "CPU 上限 0.5／1／1.5／4 換算成 1／1／2／4 條執行緒"; else bad "執行緒數換算" "$GOT"; fi
GOT=""
for c in 0.5 1 1.5 4; do GOT="$GOT$(with_limits "$c" "" 'echo "$CARGO_BUILD_JOBS"') "; done
if [ "$GOT" = "1 1 2 4 " ]; then ok "cargo 同時編譯的 crate 數跟著 CPU 上限（1／1／2／4）"; else bad "cargo 的平行數" "$GOT"; fi
# OpenShell 解開 TLS 時以 SSL_CERT_FILE 帶入它的憑證；cargo 不看這個變數，設定檔要轉給 CARGO_HTTP_CAINFO
expect "有 SSL_CERT_FILE 時 cargo 用同一份憑證" "/tmp/km-check-ca.pem" env -i PATH="$PATH" HOME="$HOME" SSL_CERT_FILE=/tmp/km-check-ca.pem \
    sh -c '. /etc/km-sandbox/env.sh; echo "$CARGO_HTTP_CAINFO"'
cat > Procs.java << 'JAVA'
public class Procs {
    public static void main(String[] a) {
        System.out.println(Runtime.getRuntime().availableProcessors() + " " + Runtime.getRuntime().maxMemory());
    }
}
JAVA
printf 'package main\n\nimport (\n\t"fmt"\n\t"runtime"\n)\n\nfunc main() { fmt.Println(runtime.GOMAXPROCS(0)) }\n' > gomax.go
# onnxruntime：不指定執行緒數建立 session（用 magika 自帶的模型），讀回實際生效的設定。
# 匯入前先查詢一次套件在不在（很多函式庫會這樣探測）：查詢不可以讓執行緒數的調整失效
cat > ort_threads.py << 'PY'
import glob
import importlib.util
import os

assert importlib.util.find_spec("onnxruntime") is not None

import magika
import onnxruntime

model = glob.glob(os.path.join(os.path.dirname(magika.__file__), "models", "*", "model.onnx"))[0]
print(onnxruntime.InferenceSession(model).get_session_options().intra_op_num_threads)
PY
if javac Procs.java 2> /dev/null && go build -o gomax gomax.go 2> /dev/null; then
    # 每一組是「CPU 上限:預期的執行緒數」。numpy（OpenBLAS）與 joblib 另外受這個環境實際可用的 CPU 數限制
    for pair in 0.5:1 1:1 1.5:2 4:4; do
        c=${pair%%:*}
        n=${pair##*:}
        expect "CPU 上限 $c：numpy 的 BLAS 執行緒數" "$(capped "$n")" with_limits "$c" "" "python3 -c \"from threadpoolctl import threadpool_info; import numpy; print(max(d['num_threads'] for d in threadpool_info()))\""
        expect "CPU 上限 $c：joblib 的 n_jobs=-1 用的 CPU 數" "$(joblib_capped "$n")" with_limits "$c" "" "python3 -c \"import joblib; print(joblib.effective_n_jobs(-1))\""
        expect "CPU 上限 $c：onnxruntime 沒指定時的執行緒數" "$n" with_limits "$c" "" "python3 ort_threads.py"
        expect "CPU 上限 $c：Go 的 GOMAXPROCS" "$n" with_limits "$c" "" "./gomax"
        expect "CPU 上限 $c：Java 的可用處理器數" "$n" with_limits "$c" "" "java -cp . Procs | cut -d' ' -f1"
    done
else
    bad "無法編譯執行緒數的測試程式"
fi
HEAP=$(with_limits 1 1Gi "java -cp . Procs" 2> /dev/null | cut -d' ' -f2)
if [ -n "$HEAP" ] && [ "$HEAP" -le 1073741824 ]; then ok "記憶體上限 1Gi：Java 的最大 heap $HEAP bytes（不超過 1 GiB）"; else bad "Java 的最大 heap" "$HEAP"; fi
expect "記憶體上限 512M 換算成位元組" "512000000" with_limits 1 512M 'echo "$SANDBOX_MEMORY_LIMIT_BYTES"'
expect "記憶體上限 1Gi 換算成位元組" "1073741824" with_limits 1 1Gi 'echo "$SANDBOX_MEMORY_LIMIT_BYTES"'
expect "記憶體上限 0（不限制）：不設記憶體上限，Java 仍可執行" "unset unset ok" with_limits 1 0 'echo "${SANDBOX_MEMORY_LIMIT_BYTES:-unset} ${NODE_OPTIONS:-unset} $(java -cp . Procs > /dev/null 2>&1 && echo ok)"'
expect "未傳入上限：1 條執行緒、不設記憶體上限" "1 unset unset" env -i PATH="$PATH" HOME="$HOME" sh -c '. /etc/km-sandbox/env.sh; echo "$SANDBOX_THREADS ${SANDBOX_MEMORY_LIMIT_BYTES:-unset} ${NODE_OPTIONS:-unset}"'
expect "未傳入上限：Python、Node.js、Java、Go 仍可執行" "ok ok ok ok" env -i PATH="$PATH" HOME="$HOME" sh -c ". /etc/km-sandbox/env.sh; echo \"\$(python3 -c 'print(\"ok\")') \$(node -e 'console.log(\"ok\")') \$(java -cp . Procs > /dev/null && echo ok) \$(./gomax > /dev/null && echo ok)\""
if java -version 2>&1 | grep -q 'Picked up'; then bad "java 的 stderr 多了提示行"; else ok "java 的 stderr 沒有多出提示行"; fi

if [ "$WITH_LICENSES" = 1 ]; then
    echo "== 第三方授權清單 =="
    check "pip 授權清單涵蓋所有已安裝的套件" python - << 'PY'
import json
import re
import subprocess

def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()

listed = {norm(e["Name"]) for e in json.load(open("/usr/share/doc/km-sandbox/third_party_licenses.json"))}
installed = {norm(e["name"]) for e in json.loads(subprocess.check_output(["/sandbox/.venv/bin/pip", "list", "--format=json"]))}
missing = sorted(installed - listed - {"pip", "setuptools", "wheel"})
assert not missing, f"授權清單缺少：{missing}"
PY
    check "apt 授權清單涵蓋所有已安裝的套件" python - << 'PY'
import json
import subprocess

listed = {e["Name"] for e in json.load(open("/usr/share/doc/km-sandbox/third_party_licenses_system.json"))}
installed = set(subprocess.check_output(["dpkg-query", "-W", "-f=${Package}\n"], text=True).split())
missing = sorted(installed - listed)
assert not missing, f"授權清單缺少：{missing[:20]}（共 {len(missing)} 個）"
PY
    # 兩個目錄：預裝套件（/opt/node-packages）與 Node.js 自帶的 npm、corepack（/usr/local/lib）
    check "npm 授權清單涵蓋所有已安裝的套件" node -e "
const fs = require('fs'), path = require('path');
const listed = new Set(JSON.parse(fs.readFileSync('$DOC/third_party_licenses_npm.json', 'utf8')).map((e) => e.Name + '@' + e.Version));
const missing = [];
function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const full = path.join(dir, entry.name);
    if (entry.name.startsWith('@')) { walk(full); continue; }
    const pkgFile = path.join(full, 'package.json');
    if (fs.existsSync(pkgFile)) {
      const pkg = JSON.parse(fs.readFileSync(pkgFile, 'utf8'));
      if (pkg.name && pkg.version && !listed.has(pkg.name + '@' + pkg.version)) missing.push(pkg.name + '@' + pkg.version);
    }
    const nested = path.join(full, 'node_modules');
    if (fs.existsSync(nested)) walk(nested);
  }
}
walk('/opt/node-packages/node_modules');
walk('/usr/local/lib/node_modules');
if (missing.length) { console.error('授權清單缺少：' + missing.slice(0, 20).join(' ') + '（共 ' + missing.length + ' 個）'); process.exit(1); }
"
    # 每筆的 LicenseText 是下列之一（openspec: sandbox-image-license-review design D3、D5；sandbox-license-missing-texts design D4）：
    #   全文（至少 100 字，擋掉「N/A」這類字串；套件沒附授權檔時由 license-texts/ 補上）；「同 X」且 X 是同一份清單內有全文的
    #   那一筆（npm 以「名稱@版本」標示，其他以名稱）；「套件未附授權檔…」只限授權是 CC0（放棄著作權）的套件，且 LicenseFile 是空的或 UNKNOWN
    check "三份授權清單每筆都有授權全文（「同 …」指到有全文的那一筆，只有 CC0 可註明未附授權檔）" python - << 'PY'
import json
import re

MIN_TEXT = 100
problems = []
for name in ("third_party_licenses.json", "third_party_licenses_npm.json", "third_party_licenses_system.json"):
    entries = json.load(open(f"/usr/share/doc/km-sandbox/{name}"))
    full = set()
    for entry in entries:
        text = (entry.get("LicenseText") or "").strip()
        if not text.startswith(("同 ", "套件未附授權檔")) and len(text) >= MIN_TEXT:
            full.update({entry["Name"], f"{entry['Name']}@{entry['Version']}"})
    for entry in entries:
        text = (entry.get("LicenseText") or "").strip()
        if text.startswith("同 "):
            if text[2:] not in full:
                problems.append(f"{name}：{entry['Name']} 寫「{text}」，清單內沒有那一筆的全文")
        elif text.startswith("套件未附授權檔"):
            if not re.search(r"CC0[- ]1\.0", entry.get("License") or ""):
                problems.append(f"{name}：{entry['Name']} 註明未附授權檔，只有 CC0 可以這樣註明（其他要依 README 補上全文）")
            if (entry.get("LicenseFile") or "") not in ("", "UNKNOWN"):
                problems.append(f"{name}：{entry['Name']} 註明未附授權檔，卻列了授權檔 {entry['LicenseFile']}")
        elif len(text) < MIN_TEXT:
            problems.append(f"{name}：{entry['Name']} 沒有授權全文")
assert not problems, "；".join(problems[:20]) + f"（共 {len(problems)} 筆）"
PY
    # 授權欄沒有 AGPL、不能商用（CC BY-NC 等）與 npm 的專有授權標記 UNLICENSED（區分大小寫，不是 Unlicense）；
    # 授權欄讀不出名稱（UNKNOWN）的系統套件另看全文：含 AGPL 全文標題的只能是 poppler-data，且要註明 AGPL 的檔案已刪除（D2）
    check "三份授權清單沒有 AGPL 與不能商用的授權" python - << 'PY'
import json
import re

problems = []
for name in ("third_party_licenses.json", "third_party_licenses_npm.json", "third_party_licenses_system.json"):
    for entry in json.load(open(f"/usr/share/doc/km-sandbox/{name}")):
        license_name = entry.get("License") or ""
        if re.search(r"AGPL|Affero|NonCommercial|non-commercial|CC-BY-NC", license_name, re.IGNORECASE) or re.search(r"\bUNLICENSED\b", license_name):
            problems.append(f"{name}：{entry['Name']} 的授權是 {license_name}")
        if "GNU AFFERO GENERAL PUBLIC LICENSE" in (entry.get("LicenseText") or ""):
            if entry["Name"] != "poppler-data" or not entry.get("Note"):
                problems.append(f"{name}：{entry['Name']} 的授權全文含 AGPL")
assert not problems, "；".join(problems[:20]) + f"（共 {len(problems)} 筆）"
PY
fi

echo
echo "通過 $PASS 項，失敗 $FAIL 項，耗時 $(($(date +%s) - START)) 秒"
[ "$FAIL" -eq 0 ]
