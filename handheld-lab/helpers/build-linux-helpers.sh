#!/bin/sh
set -eu

component_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
image=${HANDHELD_DEVTOOLS_BUILD_IMAGE:-alpine:3.22}

for architecture in amd64 arm64; do
    docker run --rm --platform "linux/$architecture" \
        --volume "$component_root:/src" --workdir /src \
        "$image" sh helpers/build-in-alpine.sh "/src/build/$architecture"
done
