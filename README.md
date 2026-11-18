# sandbox-universal

給 [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) 使用的通用開發型沙盒 workload 映像（約 6.4 GB）。
預裝 9 種程式語言、文件與圖片工具、無頭 Chromium 與中文字型，AI Agent 的技能腳本與單支程式不必臨時安裝套件，
就能在斷網的沙盒內執行。Anthropic 官方的 pptx、docx、xlsx、pdf 四個技能需要的依賴都在內（2026-11-13 以這四個技能的腳本流程實測通過）。

- Docker Hub：`t300/sandbox-universal`（目前版本 2.0.0，版號在 `version.py`）
- 映像內的路徑沿用開發時的名稱 `km-sandbox`，例如 `/etc/km-sandbox`、`/usr/share/doc/km-sandbox`。

## 使用方式

本映像不是服務：OpenShell gateway 建沙盒時以它起 workload 容器，映像的 CMD／ENTRYPOINT 不會被執行（OpenShell 以 supervisor 取代），
指令由呼叫端（以 OpenShell 建立與使用沙盒的服務）透過 exec 下達。

- 映像要放在 OpenShell gateway 所用的 Docker 主機上（`docker pull` 或自行建置），建沙盒時指定這個映像名稱。
- 指令以非 root 使用者 `sandbox`（uid／gid 1000）執行：OpenShell 政策的 `process.run_as_user` 以名稱綁定。
- OpenShell 執行指令時不帶映像的 ENV（只保留 PATH，HOME 為 `/work`）。呼叫端在執行腳本前先帶入沙盒的資源上限
  `SANDBOX_CPU_LIMIT`、`SANDBOX_MEMORY_LIMIT`，再載入環境設定檔 `/etc/km-sandbox/env.sh`（內容見「映像自帶的檔案」）。
- 沙盒的掛載、政策與資源上限由呼叫端決定。映像裝在 `/opt` 與 `/var/lib/texmf` 的內容，要靠沙盒政策放行唯讀才讀得到。
- 沙盒內執行 `sandbox-info` 會印出已安裝清單 `TOOLS.md`（各工具的版本與使用時的注意事項）。

映像內容隨版本調整，不提供個別部署加裝套件的機制；要新增工具請照「調整映像內容」的步驟自行建置。

## 映像內容

基底是 Docker 官方的 `ubuntu:24.04`（鎖 digest 以求可重現，建置時先 `apt-get upgrade` 補上安全更新），
配方沿 OpenShell 官方 `e2e/python/Dockerfile.workload`。不用 OpenShell 預設的 `nvcr.io/nvidia/base/ubuntu:24.04`：它是 NVIDIA 以
官方 Ubuntu 加上安全更新重新打包的映像，公開文件無法確認可以再散布以它為底的映像（見「授權」）。

| 類別 | 內容 | 位置 |
|---|---|---|
| 程式語言 | Python 3.12（含標頭檔 python3-dev）、Node.js LTS（含 TypeScript 的 `tsc`、`tsx`）、C／C++（gcc、g++、cmake、ninja；make 隨 build-essential 安裝，但沙盒內不能用）、Java 21（JDK）、Go、Rust 1.97（Ubuntu 的版本化套件，含 cargo、rustfmt、clippy）、R（含 ggplot2、dplyr、tidyr、readr、readxl、data.table）、Ruby、PHP（含 mbstring） | Node.js 在 `/usr/local`，其餘是 Ubuntu 的 apt 套件 |
| Python 套件 | 資料分析與繪圖、Office 與 PDF 的建立與讀取、markitdown、Playwright、測試與程式碼檢查（pytest、ruff）等，見 `requirements.txt` | venv `/sandbox/.venv` |
| Node.js 套件 | pptxgenjs、docx、pdf-lib、sharp、react、react-dom、react-icons、typescript、tsx、playwright，見 `node-packages/package.json` | `/opt/node-packages`；`/node_modules` 連到它的 `node_modules`，任何目錄的程式都能 `require` 或 `import`（對 npm 的影響見表格下方） |
| 文件與圖片工具 | LibreOffice（官方 deb）、poppler-utils、qpdf、pdftk、pandoc、tesseract（英文、繁體中文）、ImageMagick、TeX Live（xelatex、中文排版）；沒有 ffmpeg 等影音轉檔工具（見「授權」） | LibreOffice 在 `/opt/libreoffice<版號>`，其餘是 apt 套件 |
| 瀏覽器 | Chromium 無頭版（由 Playwright 下載，只裝 headless shell） | `/opt/pw-browsers` |
| 字型 | Noto Sans／Serif CJK、文泉驛微米黑（reportlab 需要 TrueType 外框）、文泉驛正黑、文鼎明體、Liberation、DejaVu、Noto Color Emoji | apt 套件 |
| 小工具 | git、ripgrep、sqlite3、7zip、zip／unzip、jq、bc、curl、file | apt 套件 |

根目錄的 `/node_modules` 連結對 npm 有一個副作用：npm 會從目前目錄往上找第一個有 `package.json` 或 `node_modules` 的目錄當專案，
所以在沒有 `package.json` 的目錄執行 `npm install <套件>` 時，它會把根目錄當成專案並試著刪掉這個連結。沙盒帳號沒有權限，
指令以權限錯誤失敗（已安裝清單的注意事項寫了做法：先 `npm init -y`）；**以 root 執行時連結會被刪掉**，預裝的套件就載不到了。
以本映像為底另外疊映像時，`npm install` 前一定要先切到有 `package.json` 的目錄。

沙盒可以連網時（由 OpenShell 的網路政策決定），各語言以自己的工具從官方套件庫安裝，不必加參數：pip 裝進 venv、
R 的 `install.packages()` 裝進 `/sandbox/R/library`、`gem install` 裝進家目錄、npm 裝進 `/work` 底下的專案目錄（先 `npm init -y`）、
cargo 下載的 crate 放在家目錄的快取（cargo 另由設定檔指定信任 OpenShell 的憑證），都隨沙盒刪除。
Go 不下載模組：設定檔把 `GOPROXY` 設為 `off`（Go 的模組代理會依模組路徑替請求去連任意網站，不適合放進網路政策的白名單）。
要從原始碼編譯 C／C++ 的 R、Ruby 與 Node.js 套件裝不起來（沙盒內 make 不能用；Node.js 另外要從 nodejs.org 下載標頭檔）；
Python 的可以。pytest、ruff 的快取由設定檔關掉，不在工作目錄留下 `.pytest_cache`、`.ruff_cache`。

## 映像自帶的檔案

映像自帶的檔案放在 `rootfs/`，建置時放到映像的同一個路徑。擁有者與權限由 Dockerfile 指定（root；`etc/km-sandbox` 與
`usr/share/doc/km-sandbox` 的檔案 644、`usr/local/bin` 的檔案 755），不跟著建置主機的 umask 走：

| 路徑 | 用途 |
|---|---|
| `/etc/km-sandbox/env.sh` | 環境設定檔。OpenShell 執行指令時不帶映像的 ENV（只保留 PATH，HOME 為 `/work`），呼叫端在執行腳本前先帶入 `SANDBOX_CPU_LIMIT`／`SANDBOX_MEMORY_LIMIT` 再載入它：設定 UTF-8 語系、`FC_LANG=zh-TW`（沒指定字型時用繁體字形）、`PLAYWRIGHT_BROWSERS_PATH`、`JAVA_HOME`、時區 `TZ=Asia/Taipei`、cmake 的預設產生器 Ninja（沙盒內 make 不能執行指令）、npm 連不上套件庫時不重試也不送 audit（網路政策只准讀取時，audit 的 POST 會被擋）、Go 不連模組代理（`GOPROXY=off`）、pytest 與 ruff 不寫快取（`PYTEST_ADDOPTS`、`RUFF_NO_CACHE`）、R 自行安裝套件的目錄（`R_LIBS_USER`＝`/sandbox/R/library`，映像裡已建好）、gem 的預設參數（`GEMRC`）、cargo 信任 OpenShell 憑證的設定（沙盒帶入 `SSL_CERT_FILE` 時設 `CARGO_HTTP_CAINFO`），並依 CPU 上限設定各 runtime 的執行緒數（含 cargo 的 `CARGO_BUILD_JOBS`）（`SANDBOX_THREADS`＝上限無條件進位，至少 1）、依記憶體上限設定 Java 與 Node.js 的 heap |
| `/etc/km-sandbox/php-timezone.ini` | PHP 不看 `TZ`：`env.sh` 以 `PHP_INI_SCAN_DIR` 讓 PHP 另外讀這個檔，時區沿用 `TZ` 的值 |
| `/etc/km-sandbox/gemrc` | gem 的預設參數：`--user-install`（系統的 gem 目錄在沙盒內唯讀，改裝進家目錄）與 `--no-document`；`env.sh` 以 `GEMRC` 指到它 |
| `/usr/local/bin/python`、`python3`、`pip`、`pip3` | 導向 venv 的包裝：只有系統預設 PATH 時，不帶路徑的 `python` 仍然進 venv |
| `/usr/local/bin/java`、`javac` | 依 `SANDBOX_THREADS` 與記憶體上限帶上 `-XX:ActiveProcessorCount`、`-XX:MaxRAM`；沒有載入設定檔時不加參數 |
| `/usr/local/bin/go` | 執行前把編譯快取的「上次清理時間」記為現在：go 會清掉 5 天沒用到的快取項目，不處理的話預建的標準函式庫快取在每個沙盒第一次建置後就少掉沒用到的部分 |
| `/usr/local/bin/sandbox-info` | 印出已安裝清單 `TOOLS.md` |
| `/usr/share/doc/km-sandbox/check-image.sh` | 映像檢查腳本，見「映像檢查」 |
| `/usr/share/doc/km-sandbox/gen-system-licenses.py` | 建置時依實際安裝的套件產生系統套件的授權清單 `third_party_licenses_system.json`（apt 不鎖版，所以每次建置重新產生，見「第三方授權清單」） |
| `/usr/share/doc/km-sandbox/gen-tools.sh`、`TOOLS-notes.md` | 建置的最後依實際安裝的版本產生 `TOOLS.md`（任何一個版本取不到就建置失敗）；手寫的只有 `TOOLS-notes.md` 的注意事項 |
| `/usr/share/doc/km-sandbox/wrap-chromium.sh` | 建置時驗證 `/opt/pw-browsers` 整個目錄的 sha256 與 Chromium 需要的系統函式庫，並把執行檔換成自動帶 `--no-zygote` 的包裝（沙盒內不加就開不了頁面） |
| `/usr/share/doc/km-sandbox/km_sandbox_hooks.py` | 建置時複製到 venv，並以 `.pth` 檔在直譯器啟動時載入。沙盒內讀不到自己的 CPU 配額，兩個沒有環境變數可設的套件在被匯入後調整：沒有指定執行緒數的 onnxruntime session 改用 `SANDBOX_THREADS`（markitdown 的檔案類型偵測會用到）；joblib 讀不到 `/sys/fs/cgroup` 時不再失敗（scikit-learn 的 `n_jobs` 會用到），CPU 數由設定檔匯出的 `LOKY_MAX_CPU_COUNT` 決定 |
| `/usr/share/doc/km-sandbox/libreoffice-defaults.xcd` | 建置時複製到 LibreOffice 的設定目錄：中日韓文字的預設文件語言設為繁體中文，沒指定字型的文件轉檔時用繁體字形 |

建置時另外產生或放進 `/usr/share/doc/km-sandbox/` 的檔案：`TOOLS.md`（已安裝清單）、`check-passed`（檢查通過的時間）、
清單檔（`apt-packages.txt`、`requirements.txt`、`constraints.txt`、`versions.env`）與 `version.py`、三份授權清單（pip、npm 兩份來自 repo，
系統套件那份建置時產生）、`licenses/node-LICENSE`。

其他設定：matplotlib 預設 Agg 後端與中文字型（Noto Sans CJK TC）；以 OpenShell exec 的 `HOME=/work` 預建 matplotlib 字型快取
與 Go 標準函式庫的編譯快取（`/work/.cache`），全新的沙盒第一次出圖與第一次 `go run` 不必重建。

## 清單檔

套件與版本只改這裡：

| 檔案 | 內容 |
|---|---|
| `apt-packages.txt` | apt 套件（一行一個）。LibreOffice 官方 deb 與 Chromium 需要的系統函式庫也列在這裡 |
| `requirements.txt` | venv 要裝的 Python 套件，鎖版 |
| `constraints.txt` | venv 內所有 Python 套件（含間接相依）的版本。由 `script/update-lock-files.sh` 產生，安裝時以 `-c` 帶入 |
| `node-packages/package.json` | 要裝的 Node.js 套件，鎖版 |
| `node-packages/package-lock.json` | 所有 Node.js 套件（含間接相依）的版本與完整性雜湊。由 `script/update-lock-files.sh` 產生，以 `npm ci` 安裝 |
| `versions.env` | 從官方來源下載的工具：LibreOffice 與 Node.js 的版本、網址、sha256，以及 Playwright 下載的瀏覽器目錄（Chromium 無頭版與 ffmpeg）整棵樹的 sha256；每個值怎麼核對過寫在檔內 |

兩份鎖定檔（`constraints.txt`、`package-lock.json`）讓每次建置裝到相同的版本；apt 套件的版本跟著建置當下 Ubuntu 套件庫的內容。

Playwright 的 Python 套件（`requirements.txt`）與 Node.js 套件（`node-packages/package.json`）要鎖同一版，兩者才對應同一個 Chromium；
檢查腳本會比對。

## 映像檢查

`rootfs/usr/share/doc/km-sandbox/check-image.sh` 檢查各語言、工具、字型、Chromium、環境設定檔的換算等代表性案例：

1. 建置的最後一個階段會執行它，沒通過就建不出映像。檢查另開一個建置階段，過程中產生的暫存檔與快取不會留在映像裡。
2. 加上 `--licenses` 時，另外比對三份授權清單是否涵蓋所有已安裝的套件，並檢查清單的授權全文與授權欄（見「第三方授權清單」）。
3. 在真的 OpenShell 沙盒內執行，才驗得到沙盒政策與資源上限之下的行為（2026-11-17 實測：121 項，1 核／1 GiB 的沙盒內 45 秒跑完）。

手動執行：

```bash
docker run --rm --network none -u sandbox -e HOME=/work -e SANDBOX_CPU_LIMIT=1 -e SANDBOX_MEMORY_LIMIT=1Gi \
  $(bash script/get-image-name.sh) bash /usr/share/doc/km-sandbox/check-image.sh --licenses
```

## 建置

```bash
bash script/build-docker-image.sh
```

映像名由 `script/get-image-name.sh` 依 `version.py` 決定（`t300/sandbox-universal:2.0.0`）。
建置主機需能連 Docker Hub、Ubuntu apt、PyPI、npm、LibreOffice 與 Node.js 的官方下載站，以及 Playwright 的瀏覽器下載站。

## 調整映像內容

1. 改清單檔：apt 套件加在 `apt-packages.txt`，Python 套件加在 `requirements.txt`（鎖版），Node.js 套件加在 `node-packages/package.json`（鎖版）。
   新增的套件要符合「授權」一節的條件。
   - 改了 `requirements.txt` 或 `package.json` 之後執行 `bash script/update-lock-files.sh`，重新產生 `constraints.txt` 與 `package-lock.json`
     （在現有的映像內解析，要能連 PyPI 與 npm；主機要有 docker 與 jq）。
   - 換 Playwright 的版本時，`requirements.txt` 與 `package.json` 一起改。`update-lock-files.sh` 的最後一步會印出 `versions.env` 的
     `PLAYWRIGHT_BROWSERS_SHA256` 應有的值：它依新的鎖定檔，以開啟憑證檢查的連線從官方來源重新下載 Chromium 無頭版與 ffmpeg 後計算
     （要能連 Google 的儲存區與 Playwright 的 Microsoft 下載站，連線被 TLS 檢查換過憑證時這一步會失敗，前兩份鎖定檔仍會寫回）。
     建置時 sha256 不符會印出實際值，但那一次下載沒有經過憑證檢查，不要直接拿來填。
   - 換 LibreOffice 或 Node.js 的版本改 `versions.env`（版本、網址、sha256 一起改）。sha256 要以官方的 PGP 簽章核對過再填，
     做法寫在 `versions.env` 各項的註解。
2. 需要環境變數或啟動參數才能在沙盒內使用的工具，設定寫在 `rootfs/etc/km-sandbox/env.sh` 或 `/usr/local/bin` 的包裝。
   `env.sh` 由呼叫端在子 shell 內載入，只有 export 的變數會帶給腳本，`umask`、`ulimit`、`cd` 與函式都不會生效；
   `env.sh` 不輸出任何文字，載入時有輸出、語法錯誤或 `exit` 都代表沒有正常載入。使用時要注意的事寫在
   `rootfs/usr/share/doc/km-sandbox/TOOLS-notes.md`。`rootfs/` 只有三個目錄（`etc/km-sandbox`、`usr/local/bin`、
   `usr/share/doc/km-sandbox`），Dockerfile 逐一以指定的權限安裝；要放到別的目錄時，Dockerfile 要補上對應的 `install`。
3. 在 `rootfs/usr/share/doc/km-sandbox/check-image.sh` 補上新工具的檢查。只在沙盒政策下才會出現的問題，另外補一個不靠沙盒也驗得到的案例。
4. `bash script/build-docker-image.sh` 建置，再重新產生 pip、npm 兩份授權清單（見「第三方授權清單」）並重建一次；系統套件那份建置時自動產生。
5. 在真的 OpenShell 沙盒內執行 `check-image.sh` 驗證。
6. 改 `version.py` 的版號。

## 授權

本 repo 自己的檔案（Dockerfile、腳本、設定檔與說明）以 MIT 授權釋出，見 [LICENSE](LICENSE)；
`license-texts/` 與三份授權清單收錄的是各套件自己的授權條文。

映像的基底與預裝的內容都要能依各自的授權公開再散布，檢查腳本會守住：

- 沒有 AGPL 與不能商用的內容。poppler-data 唯一的 AGPL-3+ 檔案 `Identity-UTF16-H`（來自 Ghostscript 的字元對應表）與指向它的
  兩個連結，在安裝 apt 套件的同一步刪除（分開刪的話，檔案仍留在下層）；同一個套件的其他對應表（繁體中文 PDF 需要的 Adobe-CNS1 等）不受影響。
- 不預裝 Ubuntu 的 ffmpeg：它以 GPL 建置並連結 x264、x265、xvid 編碼器，另有 H.264／H.265 的專利議題。
  Playwright 附帶的 ffmpeg 是 LGPL 版，只供 Playwright 錄影，不在 `PATH` 上，保留。
- GPL 的工具（例如 poppler-utils、pandoc、git、gcc、R）保留，散布映像時要依 GPL 提供原始碼。
- react-icons 收錄的部分圖示集是 CC BY 或 CC BY-SA，用進產出的文件時要標示出處或不能使用，規則寫在注意事項 `TOOLS-notes.md`。

各套件的授權以三份授權清單的全文為準；套件本身沒有附授權檔的，清單補上上游或 SPDX 的條文並註明來源（見下方「套件沒有附授權檔時」）。

## 第三方授權清單

映像內有三份授權清單，都在 `/usr/share/doc/km-sandbox/`：

- pip、npm 兩份：版本由鎖定檔固定，放在 repo。套件異動後，對建好的映像執行下面的腳本重新產生（pip 那一步要連網安裝
  pip-licenses），再重新建置映像讓它們進到映像內：

  ```bash
  bash script/generate-third-party-licenses.sh            # 預設對 script/get-image-name.sh 的映像；也可以帶映像名稱
  ```

- 系統套件那份：apt 不鎖版，建置時以 `apt-get upgrade` 取當天的安全更新，從頭建置的版本會比先前產生的清單新，所以不放在 repo，
  每次建置由 `gen-system-licenses.py` 依實際安裝的套件產生。從映像取出：

  ```bash
  docker run --rm <映像> cat /usr/share/doc/km-sandbox/third_party_licenses_system.json > third_party_licenses_system.json
  ```

格式比照 pip-licenses 的 JSON 輸出：每筆都有
`LicenseFile`（主要授權檔在映像內的位置）與 `LicenseText`（授權全文）。套件附了多個授權檔（含 NOTICE 與內附元件的授權）時全部收齊，
每段前以 `==> 檔名 <==` 標明來源。多筆共用同一份授權檔時（例如官方 LibreOffice 的 deb），全文只放在第一筆，其他筆寫「同 <套件>」。
套件本身沒有附授權檔時，從 `license-texts/` 補上全文，並以 `Note` 註明全文從哪裡來（見下方「套件沒有附授權檔時」）；
只有 CC0（放棄著作權）的照實寫「套件未附授權檔」。產生 pip、npm 兩份的腳本最後會列出「同 …」、照實註明與補上全文的筆數與名單。

| 檔案 | 範圍 | 授權名稱與全文的來源 |
|---|---|---|
| `third_party_licenses.json` | venv 內的 Python 套件 | 名稱、授權、網址取自 pip-licenses（`--from=mixed --with-url --with-license-file`），不含 pip-licenses 自己與它帶進來的相依；全文取自套件 dist-info 內所有的授權檔（`licenses/` 底下與頂層的 LICENSE、COPYING、NOTICE），pip-licenses 每個套件只讀一個檔；沒有授權檔時取自 `license-texts/` |
| `third_party_licenses_npm.json` | 預裝的 Node.js 套件（`/opt/node-packages`）與 Node.js 自帶的 npm、corepack（`/usr/local/lib/node_modules`），都含巢狀相依 | 名稱、版本、授權取自各套件的 `package.json`；全文取自套件目錄下的 LICENSE、LICENCE、COPYING、NOTICE、ThirdPartyNotices，沒有授權檔時取自 `license-texts/` |
| `third_party_licenses_system.json`（建置時產生，不在 repo） | dpkg 列出的所有套件（含官方 LibreOffice 的 deb），加上不經套件管理安裝的 Node.js、Chromium 無頭版與 Playwright 附帶的 ffmpeg | 授權名稱取自 `/usr/share/doc/<套件>/copyright` 的 `License:` 欄位，全文是整個 copyright 檔；官方 LibreOffice 的 deb 與另外三項讀各自的授權檔 |

- pip 清單中授權為 `UNKNOWN` 的項目要人工補上。
- 系統套件的 copyright 檔不是機器可讀格式時，授權名稱標為 `UNKNOWN`（2026-11-17：555 筆中 145 筆），
  要看授權請讀 `LicenseText` 的全文；不以關鍵字推測，以免把帶例外條款的授權標錯。
- poppler-data 那一筆的授權名稱不列 AGPL-3+，另以 `Note` 註明該檔已在建置時刪除。
- `check-image.sh --licenses` 會比對三份清單與映像內實際安裝的套件，有缺漏就失敗；也檢查每筆都有授權全文
  （「同 X」的 X 要是同一份清單內有全文的那一筆；只有 CC0 的可以寫「套件未附授權檔」，而且不能列授權檔），授權欄沒有 AGPL、
  不能商用與 npm 的 `UNLICENSED`，全文含 AGPL 條文的只有 poppler-data 而且有 `Note`。

### 套件沒有附授權檔時

有些 pip、npm 套件本身沒有附授權檔（2026-11-17：pip 4 筆、npm 8 筆）。除了 CC0 的以外，要附上的條文放在 `license-texts/`，
產生清單的腳本依 `license-texts/index.json` 補進清單，`Note` 寫明全文的來源：

| 位置 | 內容 |
|---|---|
| `upstream/<名稱>@<版本>/` | 上游 repo 在該版本 tag 的授權檔，檔名照上游 |
| `readme/<名稱>@<版本>/` | 從套件 README 摘出的授權段落（條文寫在 README、沒有另外的授權檔） |
| `spdx-3.29.0/` | SPDX License List 3.29.0 的標準條文，原樣附上（不填 `<year>`、`<owner>`），版權人依套件 metadata 寫在 `Note` |
| `index.json` | 鍵是 `pip/<名稱>@<版本>` 或 `npm/<名稱>@<版本>`；`files` 依序組成全文（多個檔時每段前以 `==> 檔名 <==` 標明），`note` 寫進 `Note` |

條文依序找：上游 repo 在該版本 tag 的授權檔 → 套件 README 的授權段落 → 上游完全沒有時，用 SPDX 的標準條文。

套件改版（`script/update-lock-files.sh`）後，索引的鍵帶的版本會對不上，產生清單的腳本列出要補的套件與用不到的鍵後失敗，
repo 內的清單不動。先看新版本有沒有附授權檔：有就拿掉那個鍵；沒有就依上面的順序放進新版本的條文、改索引的鍵，再重跑腳本。
