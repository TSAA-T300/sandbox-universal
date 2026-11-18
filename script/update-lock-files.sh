#!/bin/bash
# 重新產生兩份鎖定檔，並算出 Playwright 瀏覽器目錄的 sha256。改了 requirements.txt 或 node-packages/package.json 之後執行
# （步驟見 README「調整映像內容」）；連網與離線建置都依這些檔安裝，兩邊裝到的內容才會相同。
#   1. constraints.txt                  pip：requirements.txt 解析出的所有套件與版本（含間接相依）
#   2. node-packages/package-lock.json  npm：package.json 解析出的所有套件、版本與完整性雜湊
#   3. versions.env 的 PLAYWRIGHT_BROWSERS_SHA256 應有的值：依 package-lock.json 鎖定的 Playwright 版本，以開啟憑證檢查的連線
#      從官方來源下載 Chromium 無頭版與 ffmpeg 後計算。只印出來，不改檔；與 versions.env 不同時請手動更新
# 三個步驟都在現有的 km-sandbox 映像內執行（同一版 Python 與 Node.js）：前兩步要能連 PyPI 與 npm，第三步另外要能連
# Google 的儲存區與 Microsoft 的下載站，而且連線不能被 TLS 檢查換過憑證。前兩步成功就先寫回 repo，第三步失敗不影響鎖定檔。
# 主機要有 docker 與 jq。
# 用法：script/update-lock-files.sh [映像名稱]   （預設為 script/get-image-name.sh 的映像）
set -euo pipefail
PRJ_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/..
cd "${PRJ_DIR}"

IMAGE_NAME=${1:-$(bash script/get-image-name.sh)}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

echo "1/3 pip（$IMAGE_NAME）"
# 在全新的虛擬環境安裝 requirements.txt，再列出裝到的所有套件
docker run --rm -i --network=host -u sandbox "$IMAGE_NAME" bash -c '
set -euo pipefail
cat > /tmp/requirements.txt
/usr/bin/python3 -m venv /tmp/lock
/tmp/lock/bin/pip install -q --no-cache-dir -r /tmp/requirements.txt >&2
/tmp/lock/bin/pip freeze' < requirements.txt > "$OUT/freeze.txt"
grep -qE '^[A-Za-z0-9._-]+==' "$OUT/freeze.txt"
{
    echo "# km-sandbox 的 /sandbox/.venv 內所有 Python 套件的版本（含 requirements.txt 帶進來的間接相依）。"
    echo "# 由 script/update-lock-files.sh 產生，不要手動修改。Dockerfile 與 deliver/ 在安裝與下載時以 -c 帶入，"
    echo "# 連網與離線建置才會裝到相同的版本。"
    cat "$OUT/freeze.txt"
} > "$OUT/constraints.txt"

echo "2/3 npm"
docker run --rm -i --network=host -u sandbox "$IMAGE_NAME" bash -c '
set -euo pipefail
mkdir /tmp/lock && cd /tmp/lock
cat > package.json
npm install --package-lock-only --no-audit --no-fund >&2
cat package-lock.json' < node-packages/package.json > "$OUT/package-lock.json"
jq -e '.lockfileVersion >= 2 and (.packages | length > 1)' "$OUT/package-lock.json" > /dev/null

mv "$OUT/constraints.txt" constraints.txt
mv "$OUT/package-lock.json" node-packages/package-lock.json
echo "constraints.txt：$(grep -cE '^[A-Za-z0-9._-]+==' constraints.txt) 個套件"
echo "node-packages/package-lock.json：$(jq '.packages | length - 1' node-packages/package-lock.json) 個套件"

echo "3/3 Playwright 的瀏覽器目錄"
PLAYWRIGHT_VERSION=$(jq -r '.packages["node_modules/playwright-core"].version' node-packages/package-lock.json)
# 該版 Playwright 對應的瀏覽器版本與修訂號記在它的 browsers.json。Playwright 安裝時下載的兩包，這裡改從官方來源直接下載：
# Chromium 無頭版在 Google 的 Chrome for Testing 儲存區（Playwright 的下載網址就是轉址到這裡），ffmpeg 在 Playwright 的
# Microsoft 下載站。npm 與 curl 都開著憑證檢查，連線被 TLS 檢查換過憑證時會直接失敗，不會拿到未經驗證的內容。
# 解開成與 /opt/pw-browsers 相同的目錄佈局後，以映像建置時用的同一支腳本計算整棵樹的 sha256
docker run --rm -i --network=host -u sandbox -e PLAYWRIGHT_VERSION="$PLAYWRIGHT_VERSION" "$IMAGE_NAME" bash -c '
set -euo pipefail
mkdir -p /tmp/browsers/tree && cd /tmp/browsers
cat > wrap-chromium.sh
npm pack --silent "playwright-core@$PLAYWRIGHT_VERSION" > /dev/null
tar -xzf "playwright-core-$PLAYWRIGHT_VERSION.tgz" package/browsers.json
field() { jq -r --arg name "$1" --arg field "$2" ".browsers[] | select(.name == \$name) | .[\$field]" package/browsers.json; }
CHROME_VERSION=$(field chromium-headless-shell browserVersion)
SHELL_REVISION=$(field chromium-headless-shell revision)
FFMPEG_REVISION=$(field ffmpeg revision)
curl -fsS -o shell.zip "https://storage.googleapis.com/chrome-for-testing-public/$CHROME_VERSION/linux64/chrome-headless-shell-linux64.zip"
curl -fsS -o ffmpeg.zip "https://playwright.download.prss.microsoft.com/dbazure/download/playwright/builds/ffmpeg/$FFMPEG_REVISION/ffmpeg-linux.zip"
unzip -q shell.zip -d "tree/chromium_headless_shell-$SHELL_REVISION"
unzip -q ffmpeg.zip -d "tree/ffmpeg-$FFMPEG_REVISION"
bash wrap-chromium.sh --sha256 tree' < rootfs/usr/share/doc/km-sandbox/wrap-chromium.sh > "$OUT/browsers.sha256"
BROWSERS_SHA256=$(cat "$OUT/browsers.sha256")
if ! [[ "$BROWSERS_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "算不出瀏覽器目錄的 sha256" >&2
    exit 1
fi

if [ "$BROWSERS_SHA256" = "$(. ./versions.env && echo "$PLAYWRIGHT_BROWSERS_SHA256")" ]; then
    echo "Playwright $PLAYWRIGHT_VERSION 的瀏覽器目錄：sha256 與 versions.env 相同"
else
    echo "Playwright $PLAYWRIGHT_VERSION 的瀏覽器目錄與 versions.env 不同，請把 versions.env 的這一行改成："
    echo "PLAYWRIGHT_BROWSERS_SHA256=$BROWSERS_SHA256"
fi
