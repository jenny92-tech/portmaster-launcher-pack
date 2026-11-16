#!/bin/bash
# INPUT: Selected native GLES environment and the installed title runtime.
# OUTPUT: Real GLES 3.2 display/present and logical output markers, without guest execution.
# POS: Title adapter; shared compatibility code owns display acquisition and deadline.
set -eu
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
result=$(mktemp "${TMPDIR:-/tmp}/soulknight-gles-probe.XXXXXX")
trap 'rm -f "$result"' EXIT
export DM_SHADER_ROOT="$ROOT/shaders-gles" DM_GLES_FILTER_UNSUPPORTED=0
unset LD_LIBRARY_PATH LD_PRELOAD
"$ROOT/runtime/soulknight-ns-gles" --display-probe "$result"
