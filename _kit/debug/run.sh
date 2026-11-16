#!/bin/bash
# INPUT: Explicit game root and command argv; separate developer debug kit.
# OUTPUT: Same-PID execution in an opt-in private executable view.
# POS: Remote developer entry; never distributed in a game Release package.
set -euo pipefail
DEBUG_KIT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export PORTKIT_DEBUG_LAUNCHER="${PORTKIT_DEBUG_LAUNCHER:-$DEBUG_KIT_DIR/runtime/portkit-debug-launch.aarch64}"
source "$DEBUG_KIT_DIR/launcher.sh"
launcher_native_debug_exec "$@"
