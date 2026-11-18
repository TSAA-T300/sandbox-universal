#!/bin/bash
# 對建好的映像產生 pip 與 npm 兩份第三方授權清單，放在 repo（套件異動後執行，步驟見 README「第三方授權清單」）：
#   third_party_licenses.json         pip：venv 內的套件（pip-licenses；這一步要連網安裝 pip-licenses）
#   third_party_licenses_npm.json     npm：預裝的 Node.js 套件（/opt/node-packages）與 Node.js 自帶的 npm、corepack
#                                     （/usr/local/lib/node_modules），都含巢狀相依
# 系統套件那份（third_party_licenses_system.json）不在這裡產生：apt 不鎖版，由映像建置時的
# rootfs/usr/share/doc/km-sandbox/gen-system-licenses.py 依實際安裝的套件產生。
# 每筆都有 LicenseFile（授權檔的位置）與 LicenseText（授權全文），格式比照 pip-licenses 的 JSON 輸出；
# 套件附了多個授權檔（含 NOTICE、內附元件的授權）時全部收齊，每段前標明檔名；多筆共用同一份授權檔時，全文只放在第一筆，
# 其他筆寫「同 <套件>」。套件沒有附授權檔時，依 license-texts/index.json 補上上游、套件 README 或 SPDX 的條文，並以 Note
# 註明來源；只有 CC0 的照實註明「套件未附授權檔」
# 用法：script/generate-third-party-licenses.sh [映像名稱]   （預設為 script/get-image-name.sh 的映像）
# 產生後重新建置映像，讓兩個檔進到 /usr/share/doc/km-sandbox/，再以 check-image.sh --licenses 比對有沒有缺漏。
# 任何一步失敗就停下來，不會動到 repo 內既有的清單
set -euo pipefail
PRJ_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/..
cd "${PRJ_DIR}"

IMAGE_NAME=${1:-$(bash script/get-image-name.sh)}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

echo "1/2 pip（$IMAGE_NAME）"
# 先記下映像原有的套件，裝上 pip-licenses 後只留原有的（pip-licenses 自己與它帶進來的相依不算）
docker run --rm -u sandbox "$IMAGE_NAME" bash -c '
set -e
/sandbox/.venv/bin/pip list --format=json > /tmp/before.json
/sandbox/.venv/bin/pip install -q pip-licenses > /dev/null
/sandbox/.venv/bin/pip-licenses --from=mixed --format=json --with-url --with-license-file > /tmp/all.json
/sandbox/.venv/bin/python - << "PY"
import importlib.metadata as metadata
import json
import re


def norm(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def dist_license_files(name):
    """套件 dist-info 內所有的授權檔：licenses/ 底下的檔（含內附元件的授權）與頂層的 LICENSE、COPYING、NOTICE。
    pip-licenses 每個套件只讀一個檔，主檔只寫「見 LICENSE.APACHE 或 LICENSE.BSD」的套件（例如 cryptography）就缺了條文"""
    try:
        dist = metadata.distribution(name)
    except metadata.PackageNotFoundError:
        return []
    pattern = re.compile(r"\.dist-info/(licenses/.+|(licen[cs]e|copying|notice)[^/]*)$", re.IGNORECASE)
    files = [f for f in (dist.files or []) if pattern.search(str(f))]
    # 主檔在前：目錄層數少的先，同層依檔名
    return [(str(f), dist.locate_file(f)) for f in sorted(files, key=lambda f: (str(f).count("/"), str(f).lower()))]


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fp:
        return fp.read()


before = {norm(e["name"]) for e in json.load(open("/tmp/before.json"))}
entries = [e for e in json.load(open("/tmp/all.json")) if norm(e["Name"]) in before]
for entry in entries:
    files = dist_license_files(entry["Name"])
    if files:
        # 全文收齊每一個授權檔（design D3）；不只一個檔時，每段前標明來自哪個檔
        entry["LicenseFile"] = str(files[0][1])
        if len(files) == 1:
            entry["LicenseText"] = read(files[0][1])
        else:
            entry["LicenseText"] = "\n\n".join(f"==> {rel} <==\n{read(path)}" for rel, path in files)
    elif (entry.get("LicenseText") or "").strip() in ("", "UNKNOWN"):
        # 套件的 wheel 沒有附授權檔：先註明，最後一步再依 license-texts/ 補上全文
        entry["LicenseText"] = "套件未附授權檔（授權名稱取自套件的 metadata）"
print(json.dumps(entries, ensure_ascii=False, indent=2))
PY
' > "$OUT/pip.json"

echo "2/2 npm"
docker run --rm -i --network=none -u sandbox "$IMAGE_NAME" node - > "$OUT/npm.json" << 'JS'
// 走訪兩個 node_modules（含巢狀相依），列出每個套件的名稱、版本、授權與網址；走訪方式與 check-image.sh 的比對相同
const fs = require('fs');
const path = require('path');

function licenseOf(pkg) {
  const value = pkg.license || pkg.licenses;
  if (!value) return 'UNKNOWN';
  if (typeof value === 'string') return value;
  if (Array.isArray(value)) {
    return value.map((item) => (typeof item === 'string' ? item : item && item.type)).filter(Boolean).join(' OR ') || 'UNKNOWN';
  }
  return value.type || 'UNKNOWN';
}

function urlOf(pkg) {
  const repository = typeof pkg.repository === 'string' ? pkg.repository : pkg.repository && pkg.repository.url;
  return pkg.homepage || repository || '';
}

// 授權檔：套件目錄下的 LICENSE、LICENCE、COPYING、NOTICE、ThirdPartyNotices（不分大小寫，可帶副檔名或 -MIT 這類後綴）；
// 全文收齊每一個檔，不只一個檔時每段前標明檔名；同一份檔（實際路徑相同）只在第一筆放全文（design D3）
const LICENSE_FILE = /^(licen[cs]e|copying|notice|thirdpartynotices?)([-._].*)?$/i;
const seenFiles = new Map();
function licenseFileOf(dir, key) {
  const files = fs
    .readdirSync(dir)
    .filter((name) => LICENSE_FILE.test(name) && fs.statSync(path.join(dir, name)).isFile())
    .sort();
  // 沒有授權檔：先註明，最後一步再依 license-texts/ 補上全文
  if (!files.length) return { LicenseFile: '', LicenseText: '套件未附授權檔（授權名稱取自 package.json 的 license 欄位）' };
  const first = fs.realpathSync(path.join(dir, files[0]));
  if (seenFiles.has(first)) return { LicenseFile: first, LicenseText: '同 ' + seenFiles.get(first) };
  seenFiles.set(first, key);
  const read = (name) => fs.readFileSync(path.join(dir, name), 'utf8');
  const text = files.length === 1 ? read(files[0]) : files.map((name) => '==> ' + name + ' <==\n' + read(name)).join('\n\n');
  return { LicenseFile: first, LicenseText: text };
}

const found = new Map();
function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const full = path.join(dir, entry.name);
    if (entry.name.startsWith('@')) {
      walk(full);
      continue;
    }
    const pkgFile = path.join(full, 'package.json');
    if (fs.existsSync(pkgFile)) {
      const pkg = JSON.parse(fs.readFileSync(pkgFile, 'utf8'));
      const key = pkg.name + '@' + pkg.version;
      if (pkg.name && pkg.version && !found.has(key)) {
        found.set(key, { Name: pkg.name, Version: pkg.version, License: licenseOf(pkg), URL: urlOf(pkg), ...licenseFileOf(full, key) });
      }
    }
    const nested = path.join(full, 'node_modules');
    if (fs.existsSync(nested)) walk(nested);
  }
}
walk('/opt/node-packages/node_modules');
walk('/usr/local/lib/node_modules');
const list = [...found.values()].sort((a, b) => (a.Name + '@' + a.Version).localeCompare(b.Name + '@' + b.Version, 'en'));
console.log(JSON.stringify(list, null, 2));
JS

# 兩份都是非空的 JSON 陣列才往下做
for f in pip npm; do
    jq -e 'type == "array" and length > 0' "$OUT/$f.json" > /dev/null
done

# 套件沒有附授權檔時，依 license-texts/index.json 補上全文與 Note。
# 索引的鍵是「pip 或 npm／名稱@版本」，files 依序組成全文（多個檔時每段前以 ==> 檔名 <== 標明），note 寫進 Note。
# 只有 CC0（放棄著作權）的照實註明；其他沒附授權檔、索引也沒有的套件，或索引有用不到的鍵（套件改版後），
# 列出名單後失敗，repo 內的清單不動
TEXTS=license-texts
echo '{}' > "$OUT/texts.json"
while IFS= read -r key; do
    mapfile -t files < <(jq -r --arg k "$key" '.[$k].files[]' "$TEXTS/index.json")
    if [ "${#files[@]}" -eq 0 ]; then
        echo "$TEXTS/index.json 的 $key 沒有列條文檔" >&2
        exit 1
    fi
    : > "$OUT/text"
    for f in "${files[@]}"; do
        if [ ! -f "$TEXTS/$f" ]; then
            echo "$TEXTS/index.json 的 $key 列了不存在的檔：$TEXTS/$f" >&2
            exit 1
        fi
        if [ "${#files[@]}" -gt 1 ]; then
            if [ -s "$OUT/text" ]; then printf '\n\n' >> "$OUT/text"; fi
            printf '==> %s <==\n' "$(basename "$f")" >> "$OUT/text"
        fi
        cat "$TEXTS/$f" >> "$OUT/text"
    done
    jq --arg k "$key" --rawfile t "$OUT/text" --slurpfile idx "$TEXTS/index.json" \
        '.[$k] = {text: $t, note: $idx[0][$k].note}' "$OUT/texts.json" > "$OUT/texts.next"
    mv "$OUT/texts.next" "$OUT/texts.json"
done < <(jq -r 'keys[]' "$TEXTS/index.json")

# 對一份清單補條文，輸出 {list: 補好的清單, filled: 補上的鍵, missing: 缺條文的鍵}
merge() {
    jq --arg eco "$1" --slurpfile texts "$OUT/texts.json" '
        def key: $eco + "/" + .Name + "@" + .Version;
        def no_file: (.LicenseText // "") | startswith("套件未附授權檔");
        def cc0: (.License // "") | test("CC0[- ]1\\.0");
        $texts[0] as $t
        | {list: map(if no_file and $t[key] != null then key as $k | .LicenseText = $t[$k].text | .Note = $t[$k].note else . end),
           filled: [.[] | select(no_file and $t[key] != null) | key],
           missing: [.[] | select(no_file and $t[key] == null and (cc0 | not)) | key]}' "$2"
}
merge pip "$OUT/pip.json" > "$OUT/pip.merged.json"
merge npm "$OUT/npm.json" > "$OUT/npm.merged.json"
MERGED=("$OUT/pip.merged.json" "$OUT/npm.merged.json")
missing=$(jq -rs '[.[].missing[]] | join("、")' "${MERGED[@]}")
unused=$(jq -rs --slurpfile texts "$OUT/texts.json" \
    '[.[].filled[]] as $used | [$texts[0] | keys[] | select(. as $k | any($used[]; . == $k) | not)] | join("、")' \
    "${MERGED[@]}")
if [ -n "$missing" ] || [ -n "$unused" ]; then
    if [ -n "$missing" ]; then echo "沒有附授權檔、$TEXTS/index.json 也沒有條文的套件：$missing" >&2; fi
    if [ -n "$unused" ]; then echo "$TEXTS/index.json 有用不到的鍵（套件已不在清單、已自帶授權檔或版本改了）：$unused" >&2; fi
    echo "依 README「生成第三方授權清單」補上條文或拿掉用不到的鍵後重跑；repo 內的清單沒有更動" >&2
    exit 1
fi
jq '.list' "$OUT/pip.merged.json" > "$OUT/pip.json"
jq '.list' "$OUT/npm.merged.json" > "$OUT/npm.json"
mv "$OUT/pip.json" third_party_licenses.json
mv "$OUT/npm.json" third_party_licenses_npm.json

# 摘要：「同 …」與「套件未附授權檔」（只剩 CC0）分開計數並列出名單，空白或 UNKNOWN 的全文另外列出
# （check-image.sh --licenses 會擋）；最後列出依 license-texts/ 補上全文的套件
for f in third_party_licenses.json third_party_licenses_npm.json; do
    jq -r --arg f "$f" '
        [.[] | select((.LicenseText // "") | startswith("套件未附授權檔")) | .Name] as $none
        | [.[] | select((.LicenseText // "") | startswith("同 "))] as $same
        | [.[] | select((.LicenseText // "") == "" or .LicenseText == "UNKNOWN") | .Name] as $empty
        | "\($f)：\(length) 筆；授權名稱為 UNKNOWN 的 \([.[] | select(.License == "UNKNOWN")] | length) 筆；"
          + "全文寫「同 …」的 \($same | length) 筆；套件未附授權檔（CC0）的 \($none | length) 筆"
          + (if ($none | length) > 0 then "（\($none | join("、"))）" else "" end)
          + (if ($empty | length) > 0 then "；沒有全文也沒有註明的 \($empty | length) 筆（\($empty | join("、"))）" else "" end)' "$f"
done
echo "依 $TEXTS/ 補上全文的 $(jq -rs '[.[].filled[]] | length' "${MERGED[@]}") 筆：$(jq -rs '[.[].filled[]] | join("、")' "${MERGED[@]}")"
echo "pip 清單中 UNKNOWN 的項目請人工補上；接著重新建置映像，並執行 check-image.sh --licenses 確認沒有缺漏"
