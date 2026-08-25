#!/bin/sh
set -eu

helper_root=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
build_dir=${1:-"$helper_root/../build"}
compiler=${CC:-cc}
mkdir -p "$build_dir"

static_flag=""
if [ "${HANDHELD_DEVTOOLS_STATIC:-0}" = "1" ]; then
    static_flag="-static"
fi

"$compiler" -std=c11 -O2 -Wall -Wextra -Werror $static_flag \
    "$helper_root/handheld-input.c" -o "$build_dir/handheld-input"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror $static_flag \
    "$helper_root/handheld-fbshot.c" -o "$build_dir/handheld-fbshot"
"$compiler" -std=c11 -O2 -Wall -Wextra -Werror $static_flag \
    "$helper_root/handheld-event.c" -o "$build_dir/handheld-event"
strip "$build_dir/handheld-input" "$build_dir/handheld-fbshot" \
    "$build_dir/handheld-event" 2>/dev/null || true
printf '%s\n' "$build_dir/handheld-input" "$build_dir/handheld-fbshot" \
    "$build_dir/handheld-event"
