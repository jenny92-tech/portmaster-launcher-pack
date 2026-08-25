#!/bin/sh
set -eu

component_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
image=${HANDHELD_DEVTOOLS_TOOLBOX_IMAGE:-handheld-devtools-toolbox}
docker build --tag "$image" --file "$component_root/toolbox/Dockerfile" "$component_root"
