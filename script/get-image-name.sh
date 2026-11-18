PRJ_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/..
cd ${PRJ_DIR}

# 沙盒（workload）映像：OpenShell gateway 建沙盒時取用。版號在 version.py
DOCKER_IMAGE_NAME="t300/sandbox-universal"
VERSION=`grep -Po "(?<=['\"])[0-9a-zA-Z\.\-]+" version.py`

echo "${DOCKER_IMAGE_NAME}:${VERSION}"
