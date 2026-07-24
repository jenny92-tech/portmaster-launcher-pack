#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The shared layer must expose the components needed by both launcher pages and
# APP Manager's dynamic list/sidebar pages.
for symbol in \
  'function kit.picker' \
  'function kit.select' \
  'function kit.button' \
  'function kit.checkbox' \
  'function kit.switch' \
  'function kit.info' \
  'function kit.list_item' \
  'function kit.textview' \
  'function kit.section' \
  'function kit.badge' \
  'function kit.add_page' \
  'function kit.set_page' \
  'function kit.dialog' \
  'function kit.close_dialog' \
  'function kit.guide' \
  'function kit.close_guide' \
  'function kit.input' \
  'function kit.invalidate_layout' \
  'function kit.quit' \
  'function kit.set_busy' \
  'function kit.toast'; do
  grep -Fq "$symbol" "$ROOT/_kit/love/kit.lua" || {
    echo "kit.lua: missing shared component: $symbol" >&2
    exit 1
  }
done

grep -Fq 'function launcher.define' "$ROOT/_kit/love/launcher.lua"
grep -Fq 'function launcher.resolution' "$ROOT/_kit/love/launcher.lua"
grep -Fq 'function launcher.toggle' "$ROOT/_kit/love/launcher.lua"
grep -Fq 'function launcher.select' "$ROOT/_kit/love/launcher.lua"
grep -Fq 'k.switch(f.label_key' "$ROOT/_kit/love/launcher.lua"
grep -Fq 'k.select(f.label_key' "$ROOT/_kit/love/launcher.lua"

# Every game uses the same explicit Chinese wording for controller swaps.
for main in "$ROOT"/ports/*/love/main.lua; do
  if grep -Fq 'key = "swap_ab"' "$main"; then
    grep -Fq 'zh = "交换 A/B:"' "$main"
    grep -Fq 'zh = "交换 X/Y:"' "$main"
    ! grep -Fq 'zh = "换 A/B:"' "$main"
    ! grep -Fq 'zh = "换 X/Y:"' "$main"
  fi
done
# APP Manager must consume the same kit rather than carrying a second renderer.
app_lua="$ROOT/ports/appmanager/love"
grep -Fq 'require("kit")' "$app_lua/main.lua"
for module in app_model app_operations app_pages app_environment; do
  grep -Fq "require(\"$module\")" "$app_lua/main.lua"
done
grep -Fq 'kit=kit,native=native' "$app_lua/app_model.lua"
[ "$(wc -l < "$app_lua/main.lua")" -lt 220 ]
grep -Fq 'kit.checkbox' "$app_lua"/*.lua
grep -Fq 'kit.checkbox(model.display_name(script),{' "$app_lua/app_pages.lua"
grep -Fq 'on_change=' "$app_lua"/*.lua
grep -Fq 'kit.set_busy' "$app_lua"/*.lua
grep -Fq 'kit.toast' "$app_lua"/*.lua
grep -Fq 'type(busy_info.on_cancel)=="function"' "$ROOT/_kit/love/kit.lua"
grep -Fq 'busy_info.cancel_requested=true' "$ROOT/_kit/love/kit.lua"
! grep -Fq 'status_message' "$app_lua"/*.lua
grep -Fq 'theme={kind="app"' "$app_lua/main.lua"
grep -Fq 'sidebar_title=' "$app_lua"/*.lua
grep -Fq 'half=true' "$app_lua/app_pages.lua"
grep -Fq 'group="bottom"' "$app_lua"/*.lua
grep -Fq 'kit.dialog' "$app_lua"/*.lua
! grep -Fq 'CONFIRM' "$app_lua"/*.lua
grep -Fq 'checked=false,danger=true}' "$app_lua/app_pages.lua"
grep -Fq 'dialog_state._checkbox_checked=opts.checkbox and opts.checkbox.checked==true or false' "$ROOT/_kit/love/kit.lua"
grep -Fq 'function kit.debug_layout' "$ROOT/_kit/love/kit.lua"
grep -Fq 'function kit.debug_layout_cache' "$ROOT/_kit/love/kit.lua"
grep -Fq 'function kit.debug_dialog' "$ROOT/_kit/love/kit.lua"
grep -Fq 'function kit.debug_guide' "$ROOT/_kit/love/kit.lua"
grep -Fq 'love.graphics.stencil' "$ROOT/_kit/love/kit.lua"
grep -Fq 'local function coach_card_position' "$ROOT/_kit/love/kit.lua"
grep -Fq 'function kit.debug_focus' "$ROOT/_kit/love/kit.lua"
grep -Fq 'function kit.debug_page' "$ROOT/_kit/love/kit.lua"
grep -Fq 'preserve_focus=' "$app_lua/app_pages.lua"
grep -Fq 'function self.refresh_home()' "$app_lua/app_operations.lua"
grep -Fq 'rebuild_return_page(self.confirm_return)' "$app_lua/app_operations.lua"
[ "$(grep -Fc 'operations.refresh_home()' "$app_lua/main.lua")" -ge 3 ]
grep -Fq 'state.onboarding_seen~="1" and not preserve_focus' "$app_lua/app_pages.lua"
grep -Fq 'on_home_cancel=operations.show_exit_dialog' "$app_lua/main.lua"
grep -Fq 'onboarding_seen="0"' "$app_lua/main.lua"
grep -Fq 'kit.guide({' "$app_lua/app_pages.lua"
grep -Fq 'Port 游戏维护工具，可管理 PortMaster、Runtime、已安装游戏和回收站。' "$app_lua/app_pages.lua"
grep -Fq '开始使用' "$app_lua/app_pages.lua"
grep -Fq 'target="leftovers"' "$app_lua/app_pages.lua"
grep -Fq 'id="leftovers:rules"' "$app_lua/app_pages.lua"
grep -Fq '未配套的启动项和数据目录会默认选中' "$app_lua/app_pages.lua"
grep -Fq '重复目录引用' "$app_lua/app_pages.lua"
grep -Fq '只会把这个启动项移入回收站，共用目录会保留。' "$app_lua/app_pages.lua"
grep -Fq 'target="runtime-repair-entry"' "$app_lua/app_pages.lua"
grep -Fq 'state.onboarding_seen="1"' "$app_lua/app_pages.lua"
grep -Fq 'button(L("Quit","退出"),operations.show_exit_dialog' "$app_lua/app_pages.lua"
grep -Fq 'row_layout={mode="grid",columns=2}' "$app_lua"/*.lua
grep -Fq 'kit.textview' "$app_lua/app_pages.lua"
grep -Fq 'kit.list_item(name' "$app_lua/app_pages.lua"
grep -Fq 'Installed Runtimes (%d)' "$app_lua/app_pages.lua"
grep -Fq '已安装 Runtime（%d）' "$app_lua/app_pages.lua"
grep -Fq 'INSTALL_RUNTIME' "$app_lua/app_pages.lua"
launcher="$ROOT/ports/appmanager/src/launcher.sh"
runner="$ROOT/crates/appmanager-service/src/launcher.rs"
[ ! -e "$ROOT/ports/appmanager/love/runtime_catalog.tsv" ]
grep -Fq 'runtime_metadata_url' "$runner"
grep -Fq 'refresh_runtime_metadata' "$runner"
grep -Fq 'RuntimeMetadata::parse' "$runner"
grep -Fq 'digest_file(&image, DigestAlgorithm::Md5)' "$runner"
! grep -Fq 'RUNTIME_SOURCE_REF' "$runner"
grep -Fq 'runtime/love.aarch64' "$launcher"
! grep -Fq 'launcher-session' "$launcher"
! grep -Fq '"Runtime "..index.."/"..#runtimes' "$app_lua"/*.lua
grep -Fq 'mode=="flow"' "$ROOT/_kit/love/kit.lua"
grep -Fq 'font:getWidth(title)>title_w' "$ROOT/_kit/love/kit.lua"
! grep -Fq 'local title_px=#title' "$ROOT/_kit/love/kit.lua"

# APP Manager is a LÖVE package now; none of the retired Godot/FRT smoke-test
# payload may reappear in its distribution.
bash "$ROOT/_kit/dist_port.sh" appmanager >/dev/null
for retired in bootstrap.pck appmanager.gptk runtime hacksdl; do
  [ ! -e "$ROOT/ports/appmanager/dist/$retired" ] || {
    echo "appmanager dist: retired payload returned: $retired" >&2
    exit 1
  }
done
for current in love_ui/kit.lua love_ui/main.lua love_ui/app_model.lua love_ui/app_operations.lua \
  love_ui/app_pages.lua love_ui/app_environment.lua love_ui/app_native.lua love_ui/ui.gptk; do
  [ -f "$ROOT/ports/appmanager/dist/jenny92-appmanager/$current" ] || {
    echo "appmanager dist: missing $current" >&2
    exit 1
  }
done
[ ! -e "$ROOT/ports/appmanager/dist/jenny92-appmanager/love_ui/runtime_catalog.tsv" ]

# Ordinary launchers accept either primary face button as confirm.
for mapping in 'a = enter' 'b = enter' 'x = esc' 'y = esc'; do
  grep -Fxq "$mapping" "$ROOT/_kit/love/ui.gptk"
done
# APP Manager also makes both face-button conventions activate the focused
# explicit choice, avoiding firmware-specific physical A/B label swaps.
for mapping in 'a = enter' 'b = enter' 'x = esc' 'y = esc'; do
  grep -Fxq "$mapping" "$ROOT/ports/appmanager/dist/jenny92-appmanager/love_ui/ui.gptk"
done
for ignored_mapping in 'start = f10' 'back = f10'; do
  grep -Fxq "$ignored_mapping" "$ROOT/ports/appmanager/dist/jenny92-appmanager/love_ui/ui.gptk"
done
! grep -Eq '^(start|back) = (enter|esc)$' "$ROOT/ports/appmanager/dist/jenny92-appmanager/love_ui/ui.gptk"
for repeat_mapping in 'up = repeat' 'down = repeat' 'left_analog_up = repeat' \
  'left_analog_down = repeat' 'repeat_delay = 360' 'repeat_interval = 90'; do
  grep -Fxq "$repeat_mapping" "$ROOT/_kit/love/ui.gptk"
  grep -Fxq "$repeat_mapping" "$ROOT/ports/appmanager/dist/jenny92-appmanager/love_ui/ui.gptk"
done
if cmp -s "$ROOT/_kit/love/ui.gptk" "$ROOT/ports/appmanager/dist/jenny92-appmanager/love_ui/ui.gptk"; then
  echo "appmanager dist: expected its explicit navigation mapping" >&2
  exit 1
fi

echo "love shared component contract: PASS"
