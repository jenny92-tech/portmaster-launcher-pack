#!/usr/bin/env bash
# INPUT:  启动脚本位置、包内图片目录与 portkit-launcher artwork sync
# OUTPUT: portmaster_sync_launcher_artwork()
# POS:    以不阻塞启动的方式同步受支持前端的同名封面图
# Shared launcher artwork adapter. The device-layout knowledge lives in
# portkit-launcher (`artwork sync`, unit-tested in crates/portkit-launcher);
# this wrapper only locates the helper next to the installed package. Artwork
# is cosmetic, so every failure — helper missing, helper too old to know the
# subcommand, unwritable image dir — degrades to a silent skip and must never
# block a launch.
portmaster_sync_launcher_artwork() {
  local script_dir="${1:-$(cd "$(dirname "$0")" && pwd)}"
  local launcher="${2:-$0}" source_dir="${3:-$script_dir}"
  local helper="${PORTKIT_LAUNCHER_BIN_OVERRIDE:-$source_dir/bin/portkit-launcher}"
  [ -x "$helper" ] || return 0
  "$helper" artwork sync --script-dir "$script_dir" \
    --launcher "$launcher" --source-dir "$source_dir" >/dev/null 2>&1 || true
}
