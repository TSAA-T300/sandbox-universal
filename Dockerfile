# sandbox-universal：OpenShell 的沙盒 workload 映像，由 OpenShell gateway 建沙盒時取用（映像內的路徑沿用舊名 km-sandbox）。
# 以 script/build-docker-image.sh 連網建置。套件與版本記在清單檔（apt-packages.txt、requirements.txt 與 constraints.txt、
# node-packages/、versions.env），映像自帶的設定檔與腳本在 rootfs/。
#
# 基底：Docker 官方的 ubuntu:24.04（極簡 Ubuntu，無 Python、無工具），以日期標籤 noble-20261110 加 digest 鎖定以求可重現
# （換版時取 Docker Hub 上最新的 noble 日期標籤與它的 digest）；安裝套件前以 apt-get upgrade 補上安全更新。
# 2026-11-17 由 nvcr.io/nvidia/base/ubuntu:24.04 換底：NGC 沒有指定它的授權條款，公開文件無法確認可以再散布，而本映像要
# 公開發佈；它的內容就是官方 Ubuntu 加上 apt 安全更新。更早（2026-10-02）由
# ghcr.io/nvidia/openshell-community/sandboxes/base 換底：該 community 倉庫已退役，且 3.4 GB 內容多為本功能用不到的
# Node 與 coding-agent CLI。
# 配方沿 OpenShell 官方 e2e/python/Dockerfile.workload 與 examples/bring-your-own-container：
# - 非 root 使用者 sandbox（政策 process.run_as_user 以名稱綁定）；venv 固定在 /sandbox/.venv，R 自行安裝的套件放在
#   /sandbox/R/library（/sandbox 在 Landlock 政策為可寫，開網模式下 LLM 才能 pip install、install.packages() 臨時套件；
#   R 只用已存在的目錄，所以在映像裡先建好，環境設定檔的 R_LIBS_USER 指向它）
# - 映像的 CMD/ENTRYPOINT 不會被執行，OpenShell 以 supervisor 取代；指令由呼叫端透過 exec 下達
#
# 2026-11-13 改為通用開發型：9 種語言（2026-11-16 加 Rust）、文件與媒體工具（2026-11-17 授權審查後拿掉 ffmpeg，
# 改稱文件與圖片工具）、Chromium、TeX Live。各部分的位置：
# Rust 在 /usr/lib/rust-<版號>（指令連到 /usr/local/bin）、
# LibreOffice 在 /opt/libreoffice<版號>、Chromium 無頭版在 /opt/pw-browsers、Node.js 在 /usr/local、預裝的 Node.js 套件在
# /opt/node-packages、映像自帶的設定檔與腳本在 rootfs/（放到 /etc/km-sandbox、/usr/local/bin、/usr/share/doc/km-sandbox）。
#
# build context 的檔案一律先 COPY 到 /tmp/km-build，再由 RUN 以 install 放到定位並指定權限，不直接 COPY 到最終位置：
# git 只記錄檔案可不可執行，其餘權限跟著建置主機的 umask 走；COPY 目錄時，連映像裡既有的 /etc、/usr 都會被改成來源目錄的
# 權限（2026-11-14 實測）。各清單檔在用到它的步驟前才 COPY，改其中一個不會讓前面的步驟重做。
#
# 分成三個階段：image 是映像的全部內容；check 在 image 之上執行檢查腳本；最後的階段是 image 加上 check 產生的通過標記。
# 檢查另開一個階段，檢查過程留下的暫存檔與快取（例如 onnxruntime 寫在家目錄的裝置識別碼）才不會進到映像，
# 而檢查沒通過時一樣建不出映像。
FROM ubuntu:noble-20261110@sha256:73b999393d07f2bf65a40373778a44dc9a6d54ad7718d29247d8ff9413c4d6a8 AS image

ENV DEBIAN_FRONTEND=noninteractive
COPY apt-packages.txt /tmp/km-build/
# poppler-data 唯一的 AGPL-3+ 檔案（Ghostscript 的字元對應表 Identity-UTF16-H，以及兩個指向它的連結）在安裝的同一步刪除：
# 放到之後的步驟再刪，檔案仍留在這一層，照樣隨映像散布。其餘對應表（繁體中文的 Adobe-CNS1 等）保留
RUN install -d -m 755 /etc/km-sandbox /usr/share/doc/km-sandbox /usr/share/doc/km-sandbox/licenses \
 && install -m 644 /tmp/km-build/apt-packages.txt /usr/share/doc/km-sandbox/ \
 && apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends $(grep -v '^#' /usr/share/doc/km-sandbox/apt-packages.txt) \
 && rm -f /usr/share/poppler/cMap/Identity-UTF16-H /usr/share/fonts/cMap/Identity-UTF16-H /var/lib/ghostscript/CMap/Identity-UTF16-H \
 && rm -rf /var/lib/apt/lists/* \
 && if getent passwd ubuntu >/dev/null; then userdel --remove ubuntu; fi \
 && if getent group ubuntu >/dev/null; then groupdel ubuntu; fi \
 && groupadd --gid 1000 sandbox \
 && useradd --uid 1000 --gid sandbox --create-home --home-dir /sandbox --shell /bin/bash sandbox \
 && mkdir -p /work /sandbox/R/library \
 && chown -R sandbox:sandbox /work /sandbox

# Rust：Ubuntu 的版本化套件把 rustc、cargo、rustfmt、cargo-clippy 等指令裝在 /usr/lib/rust-<版本>/bin，連到 /usr/local/bin
# 才能以原名執行（只裝一個版本，有兩個版本時 ln 會失敗）
RUN ln -s /usr/lib/rust-*/bin/* /usr/local/bin/ \
 && rustc --version && cargo --version

# LibreOffice：官方 deb，安裝全部套件到 /opt。
# 下載時跳過憑證檢查（有些建置環境的網路會以 TLS 檢查換掉憑證），完整性以 versions.env 的 sha256 驗證
COPY versions.env /tmp/km-build/
RUN install -m 644 /tmp/km-build/versions.env /usr/share/doc/km-sandbox/ \
 && . /usr/share/doc/km-sandbox/versions.env \
 && curl -fsSLk -o /tmp/libreoffice.tar.gz "$LIBREOFFICE_URL" \
 && echo "$LIBREOFFICE_SHA256  /tmp/libreoffice.tar.gz" | sha256sum -c - \
 && mkdir /tmp/libreoffice \
 && tar -xzf /tmp/libreoffice.tar.gz -C /tmp/libreoffice --no-same-owner --strip-components=1 \
 && dpkg -i /tmp/libreoffice/DEBS/*.deb \
 && rm -rf /tmp/libreoffice.tar.gz /tmp/libreoffice \
 && ln -s "/opt/libreoffice${LIBREOFFICE_VERSION%.*.*}/program/soffice" /usr/local/bin/soffice

# Node.js：官方 tarball，只解出 bin 與 lib（不放標頭檔與文件），授權檔另存。封存檔裡的擁有者是 uid 1000（與 sandbox 同號），
# 解開時加 --no-same-owner，檔案才歸 root。
# 預裝的 Node.js 套件：依 node-packages/ 的 package.json 與 package-lock.json 以 npm ci 裝在 /opt/node-packages（鎖定檔記了
# 每個套件的版本與完整性雜湊，連網與離線建置裝到的內容相同）；裝完清掉 npm 快取。
# /node_modules 連到它：Node.js 找套件時會從程式所在的目錄一路往上找 node_modules 直到根目錄，所以任何目錄的程式都能以
# require 或 import 載入，tsc 也找得到型別。tsc、tsx、playwright 三個指令連到 /usr/local/bin
COPY node-packages/ /tmp/km-build/node-packages/
RUN . /usr/share/doc/km-sandbox/versions.env \
 && curl -fsSLk -o /tmp/node.tar.xz "$NODE_URL" \
 && echo "$NODE_SHA256  /tmp/node.tar.xz" | sha256sum -c - \
 && tar -xJf /tmp/node.tar.xz -C /usr/local --no-same-owner --strip-components=1 \
        "node-${NODE_VERSION}-linux-x64/bin" "node-${NODE_VERSION}-linux-x64/lib" \
 && tar -xJf /tmp/node.tar.xz -O "node-${NODE_VERSION}-linux-x64/LICENSE" > /usr/share/doc/km-sandbox/licenses/node-LICENSE \
 && rm -f /tmp/node.tar.xz \
 && install -d -m 755 /opt/node-packages \
 && install -m 644 /tmp/km-build/node-packages/package.json /tmp/km-build/node-packages/package-lock.json /opt/node-packages/ \
 && cd /opt/node-packages \
 && npm ci --no-audit --no-fund \
 && npm cache clean --force \
 && rm -rf /root/.npm /tmp/node-compile-cache \
 && ln -s /opt/node-packages/node_modules /node_modules \
 && for b in tsc tsx playwright; do ln -s "/opt/node-packages/node_modules/.bin/$b" "/usr/local/bin/$b"; done

# Chromium 無頭版：由上一步裝好的 Playwright 下載到 /opt/pw-browsers，只裝 headless shell（沙盒沒有畫面，完整版用不到）。
# 它需要的系統函式庫列在 apt-packages.txt（離線建置不能用 --with-deps）。
# 下載後在同一步驗證整個目錄的 sha256 與系統函式庫，並把執行檔換成自動帶 --no-zygote 的包裝（沙盒內不加就無法開頁面）；
# 分成兩步的話，改名會讓 217 MB 的執行檔在兩層各存一份
COPY rootfs/usr/share/doc/km-sandbox/wrap-chromium.sh /tmp/km-build/
RUN PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers NODE_TLS_REJECT_UNAUTHORIZED=0 playwright install --only-shell chromium \
 && chmod -R u=rwX,go=rX /opt/pw-browsers \
 && PLAYWRIGHT_BROWSERS_PATH=/opt/pw-browsers bash /tmp/km-build/wrap-chromium.sh

# Python 套件：requirements.txt 是要裝的套件，constraints.txt 鎖住所有套件（含間接相依）的版本
COPY requirements.txt constraints.txt /tmp/km-build/
RUN install -m 644 /tmp/km-build/requirements.txt /tmp/km-build/constraints.txt /usr/share/doc/km-sandbox/
USER sandbox
RUN /usr/bin/python3 -m venv /sandbox/.venv \
 && /sandbox/.venv/bin/pip install --no-cache-dir -r /usr/share/doc/km-sandbox/requirements.txt -c /usr/share/doc/km-sandbox/constraints.txt
# matplotlib：Agg 後端、預設中文字型（Noto Sans CJK TC）。直接改 venv 內建 mpl-data/matplotlibrc 的樣板原行
# （不依賴 HOME 或 MPLCONFIGDIR 是否被帶進 exec 環境；用 sed 改原行而非附加，附加會造成重複 key 警告）
RUN MPLRC=$(/sandbox/.venv/bin/python -c "import matplotlib; print(matplotlib.matplotlib_fname())") \
 && sed -i -E 's|^#font\.family: .*|font.family: sans-serif|; s|^#font\.sans-serif: .*|font.sans-serif: Noto Sans CJK TC, DejaVu Sans, Bitstream Vera Sans, Arial, Helvetica, sans-serif|; s|^#axes\.unicode_minus: True(.*)|axes.unicode_minus: False\1|' "$MPLRC" \
 && sed -i '1i backend: Agg' "$MPLRC"
# 預建快取。OpenShell exec 時 HOME=/work 且不帶映像 ENV，matplotlib 的字型快取在 /work/.cache/matplotlib、
# Go 的編譯快取在 /work/.cache/go-build；以同樣的 HOME 預建一份放進映像（呼叫端不清空 /work 時，沙盒就會沿用）。
# 沒有預建時，每個全新的沙盒第一次出圖要多等數秒、第一次 go run 要先編譯標準函式庫（1 核下 20 秒以上）
RUN HOME=/work /sandbox/.venv/bin/python -c "import matplotlib.pyplot as plt, matplotlib.font_manager as fm; fm.fontManager" \
 && HOME=/work go build std \
 && ls -d /work/.cache/matplotlib /work/.cache/go-build

USER root
# 映像自帶的檔案：環境設定檔（/etc/km-sandbox/env.sh）、/usr/local/bin 的包裝腳本
# （python、pip 導向 venv；java、javac 帶入配額；go 保住預建的快取；sandbox-info）、/usr/share/doc/km-sandbox 的腳本與注意事項。
# 放在套件安裝之後：改這些檔案時不必重裝套件。
# LibreOffice 的預設值（中日韓文字的預設文件語言，說明見該檔）放進它的設定目錄
COPY rootfs/ /tmp/km-build/rootfs/
RUN . /usr/share/doc/km-sandbox/versions.env \
 && install -m 644 /tmp/km-build/rootfs/etc/km-sandbox/* /etc/km-sandbox/ \
 && install -m 755 /tmp/km-build/rootfs/usr/local/bin/* /usr/local/bin/ \
 && install -m 644 /tmp/km-build/rootfs/usr/share/doc/km-sandbox/* /usr/share/doc/km-sandbox/ \
 && install -m 644 /usr/share/doc/km-sandbox/libreoffice-defaults.xcd \
        "/opt/libreoffice${LIBREOFFICE_VERSION%.*.*}/share/registry/km-sandbox.xcd"
# 匯入掛鉤放進 venv，並以 .pth 檔在直譯器啟動時載入（說明見 km_sandbox_hooks.py）。以 sandbox 身分做，檔案與直譯器
# 第一次啟動時產生的 .pyc 才歸 sandbox
USER sandbox
RUN PURELIB=$(/sandbox/.venv/bin/python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])') \
 && install -m 644 /usr/share/doc/km-sandbox/km_sandbox_hooks.py "$PURELIB/" \
 && echo 'import km_sandbox_hooks' > "$PURELIB/km_sandbox_hooks.pth" \
 && /sandbox/.venv/bin/python -c 'import sys; assert "km_sandbox_hooks" in sys.modules'

USER root
# 版號（已安裝清單的標題會用到）與第三方授權清單：pip、npm 兩份已鎖版，由 script/generate-third-party-licenses.sh 對建好的映像
# 產生後放在 repo（見 README）；系統套件那份在這裡依實際安裝的套件產生（apt 不鎖版，從頭建置會取到當天的安全更新）。
# 放在套件安裝之後：壓版號或重新產生授權清單時不必重裝套件。
# 已安裝清單：以 sandbox 身分依實際安裝的內容產生（家目錄指到暫存目錄，不在映像留下各工具的設定檔），sandbox-info 印出它。
# 最後清掉前面各步驟留在 /tmp 的暫存檔
COPY version.py third_party_licenses.json third_party_licenses_npm.json /tmp/km-build/
RUN /usr/bin/python3 /usr/share/doc/km-sandbox/gen-system-licenses.py > /tmp/km-build/third_party_licenses_system.json \
 && install -m 644 /tmp/km-build/version.py /tmp/km-build/third_party_licenses*.json /usr/share/doc/km-sandbox/ \
 && install -d -o sandbox -g sandbox /tmp/km-gen-home \
 && runuser -u sandbox -- env HOME=/tmp/km-gen-home bash /usr/share/doc/km-sandbox/gen-tools.sh > /usr/share/doc/km-sandbox/TOOLS.md \
 && find /tmp -mindepth 1 -delete

# 注意：OpenShell exec 只沿用這裡的 PATH（HOME 被設為 /work），其他環境變數靠 /etc/km-sandbox/env.sh
ENV VIRTUAL_ENV=/sandbox/.venv PATH="/sandbox/.venv/bin:/usr/local/bin:/usr/bin:/bin"
WORKDIR /work
USER sandbox

# 映像檢查：以 OpenShell exec 的條件（沙盒帳號、HOME=/work、上面的 PATH）執行，沒通過就建置失敗
FROM image AS check
RUN HOME=/work SANDBOX_CPU_LIMIT=1 SANDBOX_MEMORY_LIMIT=1Gi bash /usr/share/doc/km-sandbox/check-image.sh \
 && date -u '+%Y-%m-%dT%H:%M:%SZ' > /tmp/check-passed

FROM image
COPY --from=check --chown=root:root /tmp/check-passed /usr/share/doc/km-sandbox/check-passed
