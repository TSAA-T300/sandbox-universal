#!/bin/bash
# 建置映像的最後以沙盒帳號執行一次：依實際安裝的內容產生已安裝清單，輸出到 stdout（Dockerfile 導向 TOOLS.md，sandbox-info 印出它）。
# 版本一律來自實際執行各工具，不手寫；手寫的只有 TOOLS-notes.md 的注意事項。任何一個版本取不到就以非 0 結束，建置跟著失敗。
set -uo pipefail

DOC=/usr/share/doc/km-sandbox
NODE_PACKAGES=/opt/node-packages
[ -r /etc/km-sandbox/env.sh ] && . /etc/km-sandbox/env.sh

# 取不到的項目記在這個檔：下面的函式都在 $( ) 的子行程內執行，改不到這支腳本的變數
MISSING=$(mktemp)
trap 'rm -f "$MISSING"' EXIT

# need <說明> <值>：印出值；值是空的就把說明記下來
need() {
    [ -n "$2" ] || echo "$1" >> "$MISSING"
    printf '%s' "$2"
}
# ver <指令…>：執行指令，取輸出中第一個像版本號的字串（例如 3.12.3、24.22.3、26.2.6.3）
ver() { need "$*" "$("$@" 2>&1 | grep -oE '[0-9]+(\.[0-9]+)+([._-][0-9A-Za-z]+)*' | head -1)"; }
# 把「名稱 版本」逐行的輸入排成一行，以頓號分隔
join_lines() { awk '{printf "%s%s %s", (NR > 1 ? "、" : ""), $1, $2} END {print ""}'; }

CHROMIUM=$(find "${PLAYWRIGHT_BROWSERS_PATH:-/opt/pw-browsers}" -maxdepth 3 -type f -name 'chrome-headless-shell.real' | head -1)

echo "# 沙盒已安裝內容（km-sandbox $(ver cat "$DOC/version.py")）"
echo
echo "清單在建置映像時依實際安裝的內容產生。作業系統：$(. /etc/os-release && echo "$PRETTY_NAME")。"
echo
echo "## 程式語言"
echo
echo "| 語言 | 版本 | 指令 |"
echo "|---|---|---|"
echo "| Python | $(ver python3 --version) | \`python3\`、\`pip\`（虛擬環境 /sandbox/.venv） |"
echo "| Node.js | $(ver node --version) | \`node\`、\`npm\` |"
echo "| TypeScript | $(ver tsc --version) | \`tsc\` 編譯、\`tsx file.ts\` 直接執行 |"
echo "| C／C++ | gcc $(ver gcc --version) | \`gcc\`、\`g++\`、\`cmake\` $(ver cmake --version)（預設以 Ninja 建置）、\`ninja\` $(ver ninja --version)；\`make\` 在沙盒內不能用（見注意事項） |"
echo "| Java | $(ver java -version) | \`java\`、\`javac\`（JDK，無 Maven） |"
echo "| Go | $(ver go version) | \`go run\`、\`go build\`（預裝的只有標準函式庫） |"
echo "| Rust | $(ver rustc --version) | \`rustc\`、\`cargo\`、\`rustfmt\`、\`cargo clippy\`（預裝的只有標準函式庫） |"
echo "| R | $(ver Rscript --version) | \`Rscript\` |"
echo "| Ruby | $(ver ruby --version) | \`ruby\` |"
echo "| PHP | $(ver php --version) | \`php\`（含 mbstring） |"
echo
echo "## 文件與圖片工具"
echo
echo "| 工具 | 版本 | 指令 |"
echo "|---|---|---|"
echo "| LibreOffice | $(ver soffice --version) | \`soffice --headless --convert-to pdf\` |"
echo "| Poppler | $(ver pdftoppm -v) | \`pdftoppm\`、\`pdftotext\`、\`pdfimages\`、\`pdfinfo\`、\`pdffonts\` |"
echo "| qpdf | $(ver qpdf --version) | \`qpdf\` |"
echo "| pdftk | $(ver pdftk --version) | \`pdftk\` |"
echo "| pandoc | $(ver pandoc --version) | \`pandoc\` |"
echo "| tesseract | $(ver tesseract --version) | \`tesseract\`；語言檔：$(need "tesseract 的語言檔" "$(tesseract --list-langs 2>/dev/null | tail -n +2 | tr '\n' ' ')") |"
echo "| ImageMagick | $(ver convert --version) | \`convert\`、\`identify\` |"
echo "| TeX Live | $(need "TeX Live" "$(xelatex --version 2>&1 | grep -oE 'TeX Live [0-9]{4}' | head -1 | sed 's/TeX Live //')") | \`xelatex\`、\`latexmk\` |"
echo "| Chromium（無頭版） | $(ver "${CHROMIUM:-chrome-headless-shell.real}" --version) | 以 Playwright 啟動 |"
echo "| git | $(ver git --version) | \`git\` |"
echo "| 其他 | | \`rg\` $(ver rg --version)、\`sqlite3\` $(ver sqlite3 --version)、\`7z\`、\`zip\`、\`unzip\`、\`jq\`、\`bc\`、\`curl\`、\`file\` |"
echo
echo "## Python 套件"
echo
need "pip list" "$(/sandbox/.venv/bin/pip list --format=freeze 2>/dev/null | grep -viE '^(pip|setuptools|wheel)==' | sed 's/==/ /' | join_lines)"
echo
echo
echo "## Node.js 套件"
echo
# package.json 列出的套件；它們帶進來的間接相依不列
jq -r '.dependencies | keys[]' "$NODE_PACKAGES/package.json" | while read -r p; do
    printf '%s %s\n' "$p" "$(ver node -p "require('$NODE_PACKAGES/node_modules/$p/package.json').version")"
done | join_lines
echo
echo "## R 套件"
echo
for p in ggplot2 dplyr tidyr readr readxl data.table; do
    printf '%s %s\n' "$p" "$(ver Rscript -e "cat(as.character(packageVersion('$p')))")"
done | join_lines
echo
cat "$DOC/TOOLS-notes.md"

if [ -s "$MISSING" ]; then
    echo "gen-tools.sh：下列項目取不到，已安裝清單不完整：" >&2
    sed 's/^/  /' "$MISSING" >&2
    exit 1
fi
