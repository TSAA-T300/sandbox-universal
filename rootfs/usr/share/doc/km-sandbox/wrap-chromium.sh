#!/bin/bash
# 建置映像時以 root 執行一次：驗證 Playwright 下載的瀏覽器目錄（Chromium 無頭版與錄影用的 ffmpeg），
# 並把 Chromium 的執行檔換成自動帶 --no-zygote 的包裝腳本。
# OpenShell 沙盒內 Chromium 的 zygote 行程無法 fork，開頁面時渲染行程會當掉（Target crashed）；
# 加 --no-zygote 才能用（2026-11-13 實測）。包在執行檔這一層，模型照一般的 Playwright 寫法就能啟動。
#
# 用法：
#   wrap-chromium.sh                 驗證 PLAYWRIGHT_BROWSERS_PATH（預設 /opt/pw-browsers）並換上包裝
#   wrap-chromium.sh --sha256 <目錄>  只印出該目錄整棵樹的 sha256（script/update-lock-files.sh 取得新值時用）
set -euo pipefail

# 整棵樹的 sha256：每個檔案的 sha256 與相對路徑，依路徑排序後再取一次 sha256。
# Playwright 安裝時自己寫的標記檔（INSTALLATION_COMPLETE、DEPENDENCIES_VALIDATED、.links/）不是下載來的內容，不算在內
tree_sha256() {
    if [ -n "$(find "$1" -type l -print -quit)" ]; then
        echo "$1 底下有符號連結，整棵樹的 sha256 不涵蓋連結指向的內容；請確認後調整本腳本" >&2
        return 1
    fi
    (cd "$1" && find . -type f ! -name INSTALLATION_COMPLETE ! -name DEPENDENCIES_VALIDATED ! -path './.links/*' -print0 \
        | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
}

if [ "${1:-}" = "--sha256" ]; then
    tree_sha256 "$2"
    exit 0
fi

. /usr/share/doc/km-sandbox/versions.env
ROOT="${PLAYWRIGHT_BROWSERS_PATH:-/opt/pw-browsers}"

# 下載時跳過了憑證檢查（見 versions.env），所以下載到的每一個檔都要對得上：只驗主程式的話，
# 同一包裡的 .so、資源檔與另外下載的 ffmpeg 被換掉也不會發現
ACTUAL=$(tree_sha256 "$ROOT")
if [ "$ACTUAL" != "$PLAYWRIGHT_BROWSERS_SHA256" ]; then
    echo "$ROOT 的 sha256 不符：預期 $PLAYWRIGHT_BROWSERS_SHA256，實際 $ACTUAL" >&2
    echo "換了 Playwright 的版本時，以 script/update-lock-files.sh 取得新值再更新 versions.env；" >&2
    echo "不要直接填上面的實際值：這次下載沒有經過憑證檢查。" >&2
    exit 1
fi

BIN=$(find "$ROOT" -maxdepth 3 -type f -name chrome-headless-shell | head -1)
if [ -z "$BIN" ]; then
    echo "找不到 Chromium 無頭版的執行檔（Playwright 的目錄佈局可能變了）" >&2
    exit 1
fi

MISSING=$(ldd "$BIN" | grep 'not found' || true)
if [ -n "$MISSING" ]; then
    echo "Chromium 缺少系統函式庫，請把對應的套件補進 apt-packages.txt：" >&2
    echo "$MISSING" >&2
    exit 1
fi

mv "$BIN" "$BIN.real"
cat > "$BIN" <<'WRAPPER'
#!/bin/sh
# Chromium 無頭版的包裝：OpenShell 沙盒內 zygote 行程無法 fork，固定加上 --no-zygote
exec "$0.real" --no-zygote "$@"
WRAPPER
chmod 755 "$BIN"
echo "wrapped $BIN"
