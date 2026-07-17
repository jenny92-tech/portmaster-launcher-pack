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
  'function kit.textview' \
  'function kit.section' \
  'function kit.badge' \
  'function kit.add_page' \
  'function kit.set_page' \
  'function kit.dialog' \
  'function kit.close_dialog' \
  'function kit.input' \
  'function kit.invalidate_layout' \
  'function kit.quit' \
  'function kit.set_busy'; do
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
grep -Fq '"zh": "交换 A/B:"' "$ROOT/_kit/launcher_base.gd"
grep -Fq '"zh": "交换 X/Y:"' "$ROOT/_kit/launcher_base.gd"

# APP Manager must consume the same kit rather than carrying a second renderer.
grep -Fq 'require("kit")' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'kit.checkbox' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'kit.checkbox(display_name(script),{' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'on_change=' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'kit.set_busy' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'theme={kind="app"' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'sidebar_title=' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'half=true' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'group="bottom"' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'kit.dialog' "$ROOT/ports/appmanager/love/main.lua"
! grep -Fq 'CONFIRM' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'function kit.debug_layout' "$ROOT/_kit/love/kit.lua"
grep -Fq 'function kit.debug_layout_cache' "$ROOT/_kit/love/kit.lua"
grep -Fq 'function kit.debug_dialog' "$ROOT/_kit/love/kit.lua"
grep -Fq 'function kit.debug_focus' "$ROOT/_kit/love/kit.lua"
grep -Fq 'function kit.debug_page' "$ROOT/_kit/love/kit.lua"
grep -Fq 'preserve_focus=' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'on_home_cancel=show_exit_dialog' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'button(L("Quit","退出"),show_exit_dialog' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'row_layout={mode="grid",columns=2}' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'kit.textview' "$ROOT/ports/appmanager/love/main.lua"
grep -Fq 'mode=="flow"' "$ROOT/_kit/love/kit.lua"
grep -Fq 'font:getWidth(title)>title_w' "$ROOT/_kit/love/kit.lua"
! grep -Fq 'local title_px=#title' "$ROOT/_kit/love/kit.lua"

# APP Manager is a LÖVE package now; none of the retired Godot/FRT smoke-test
# payload may reappear in its distribution.
"$ROOT/_kit/dist_port.sh" appmanager >/dev/null
for retired in bootstrap.pck appmanager.gptk runtime hacksdl; do
  [ ! -e "$ROOT/ports/appmanager/dist/$retired" ] || {
    echo "appmanager dist: retired payload returned: $retired" >&2
    exit 1
  }
done
for current in love_ui/kit.lua love_ui/main.lua love_ui/scan.lua love_ui/ui.gptk; do
  [ -f "$ROOT/ports/appmanager/dist/$current" ] || {
    echo "appmanager dist: missing $current" >&2
    exit 1
  }
done

# Ordinary launchers accept either primary face button as confirm.
for mapping in 'a = enter' 'b = enter' 'x = esc' 'y = esc'; do
  grep -Fxq "$mapping" "$ROOT/_kit/love/ui.gptk"
done
# The target firmwares expose gptokeyb a/b opposite to their printed labels.
# These raw values make physical A confirm and physical B cancel.
for mapping in 'a = esc' 'b = enter' 'x = esc' 'y = esc'; do
  grep -Fxq "$mapping" "$ROOT/ports/appmanager/dist/love_ui/ui.gptk"
done
for repeat_mapping in 'up = repeat' 'down = repeat' 'left_analog_up = repeat' \
  'left_analog_down = repeat' 'repeat_delay = 360' 'repeat_interval = 90'; do
  grep -Fxq "$repeat_mapping" "$ROOT/_kit/love/ui.gptk"
  grep -Fxq "$repeat_mapping" "$ROOT/ports/appmanager/dist/love_ui/ui.gptk"
done
if cmp -s "$ROOT/_kit/love/ui.gptk" "$ROOT/ports/appmanager/dist/love_ui/ui.gptk"; then
  echo "appmanager dist: expected its explicit A-confirm/B-cancel mapping" >&2
  exit 1
fi

echo "love shared component contract: PASS"
