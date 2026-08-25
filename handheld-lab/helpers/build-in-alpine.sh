#!/bin/sh
set -eu

component_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
apk add --no-cache build-base linux-headers >/dev/null
HANDHELD_DEVTOOLS_STATIC=1 sh "$component_root/helpers/build-input-helper.sh" \
    "${1:-$component_root/build}"
