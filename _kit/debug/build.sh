#!/bin/sh
# INPUT: Existing project Rust builder.
# OUTPUT: Separate developer executable/checksum under this debug kit.
# POS: Explicit developer build; does not replace the Release helper.
set -eu
KIT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec "$KIT_DIR/build_portkit_launcher.sh" debug
