"""產生系統套件的第三方授權清單（third_party_licenses_system.json，印到 stdout）。

建置映像時（連網的 Dockerfile 與離線的 deliver/Dockerfile 都是）在套件都裝好之後以 /usr/bin/python3 執行，清單與映像實際安裝的
套件、版本一致：apt 不鎖版，建置時以 apt-get upgrade 取當天的安全更新，從頭建置的映像版本會比先前產生的清單新，所以不放在
repo、每次建置重新產生（openspec: sandbox-image-license-review design D3）。pip 與 npm 兩份已鎖版，仍由
script/generate-third-party-licenses.sh 產生後放在 repo。

列出 dpkg 的所有套件與授權。授權取自 /usr/share/doc/<套件>/copyright 的 License: 欄位（Debian 的機器可讀格式），
讀不出來的標 UNKNOWN；全文附上 copyright 檔，同一份檔只放在第一筆，其他筆寫「同 <套件>」。
官方 LibreOffice 的 deb 沒有 copyright 檔，授權檔在安裝目錄。另加不經套件管理安裝的 Node.js、Chromium 無頭版與
Playwright 附帶的 ffmpeg。
"""

import glob
import json
import os
import re
import subprocess

# poppler-data 的 copyright 列有 AGPL-3+，只涵蓋 Identity-UTF16-H 這個檔，映像建置時已刪除（openspec: sandbox-image-license-review D2）。
# 以 dpkg -L 列出的每個位置（實體檔與兩個連結）判斷，套件改版換了位置時不會誤判為已刪除
AGPL_CMAP_PATHS = [
    p
    for p in subprocess.check_output(["dpkg", "-L", "poppler-data"], text=True).splitlines()
    if p.endswith("/Identity-UTF16-H")
]
AGPL_CMAP_REMOVED = bool(AGPL_CMAP_PATHS) and not any(os.path.lexists(p) for p in AGPL_CMAP_PATHS)


def license_names(path):
    names = []
    with open(path, encoding="utf-8", errors="replace") as fp:
        for line in fp:
            m = re.match(r"^License:\s*(\S.*?)\s*$", line)
            if m and m.group(1) not in names:
                names.append(m.group(1))
    return names


seen = {}


def license_text(name, path):
    """授權全文；同一份檔（實際路徑相同）只放在第一筆"""
    if not path:
        return "套件未附授權檔"
    real = os.path.realpath(path)
    if real in seen:
        return f"同 {seen[real]}"
    seen[real] = name
    with open(path, encoding="utf-8", errors="replace") as fp:
        return fp.read()


def item(name, version, license_name, path):
    return {
        "Name": name,
        "Version": version,
        "License": license_name,
        "LicenseFile": path,
        "LicenseText": license_text(name, path),
    }


libreoffice_license = (glob.glob("/opt/libreoffice*/LICENSE") or [""])[0]
entries = []
output = subprocess.check_output(["dpkg-query", "-W", "-f=${Package}\t${Version}\n"], text=True)
for line in output.splitlines():
    name, version = line.split("\t")
    copyright_file = f"/usr/share/doc/{name}/copyright"
    note = None
    if os.path.exists(copyright_file):
        names = license_names(copyright_file)
        if name == "poppler-data" and AGPL_CMAP_REMOVED:
            names = [n for n in names if "AGPL" not in n]
            note = (
                "copyright 檔中列為 AGPL-3+ 的 from-ghostscript/Resource/CMap/Identity-UTF16-H 已在建置映像時刪除，"
                "映像內沒有 AGPL 授權的檔案"
            )
        license_name = ", ".join(names) or "UNKNOWN"
    elif re.match(r"^(libobasis|libreoffice)\d", name) and libreoffice_license:
        license_name, copyright_file = "MPL-2.0", libreoffice_license
    else:
        license_name, copyright_file = "UNKNOWN", ""
    entry = item(name, version, license_name, copyright_file)
    if note:
        entry["Note"] = note
    entries.append(entry)

# 不經套件管理安裝的三項
node_version = subprocess.check_output(["node", "--version"], text=True).strip().lstrip("v")
browsers_file = "/opt/node-packages/node_modules/playwright-core/browsers.json"
browsers = {b["name"]: b for b in json.load(open(browsers_file))["browsers"]}
shell = browsers["chromium-headless-shell"]
entries.append(item("nodejs (official binary)", node_version, "MIT", "/usr/share/doc/km-sandbox/licenses/node-LICENSE"))
entries.append(
    item(
        "chromium-headless-shell (Playwright build)",
        f"{shell['browserVersion']} (revision {shell['revision']})",
        "BSD-3-Clause",
        glob.glob("/opt/pw-browsers/chromium_headless_shell-*/*/LICENSE.headless_shell")[0],
    )
)
entries.append(
    item(
        "ffmpeg (Playwright build)",
        f"revision {browsers['ffmpeg']['revision']}",
        "LGPL-2.1",
        glob.glob("/opt/pw-browsers/ffmpeg-*/COPYING.LGPLv2.1")[0],
    )
)
print(json.dumps(entries, ensure_ascii=False, indent=2))
