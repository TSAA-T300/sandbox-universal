#!/bin/bash -e
PRJ_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"/..
cd ${PRJ_DIR}

export DOCKER_BUILDKIT=1

IMAGE_NAME=$(bash script/get-image-name.sh)

echo "building $IMAGE_NAME..."

# 映像須存在於 OpenShell gateway 所在主機的 Docker（gateway 以 if_not_present 取用）
docker build \
    --network=host \
    --force-rm \
    --tag $IMAGE_NAME \
    -f Dockerfile \
    .
