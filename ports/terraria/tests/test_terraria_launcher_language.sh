#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ui="$ROOT/src/launcher_ui.gd"
shfile="$ROOT/src/launcher.sh"

grep -Fq 'const LANG_VALUES = ["1", "7", "12"]' "$ui"
grep -Fq '"language":       "7"' "$ui"
grep -Fq 'f.store_string("TER_LANGUAGE=%s' "$ui"

grep -Fq 'apply_terraria_language' "$shfile"
grep -Fq 'local lang="${TER_LANGUAGE:-7}"' "$shfile"
grep -Fq 'local cfg="$CONFDIR/config.json"' "$shfile"
! grep -Fq '/storage/emulated/0/Android/data/com.and.games505.TerrariaPaid/config.json' "$shfile"
grep -Fq '"Language": %s' "$shfile"
grep -Fq '#@KIT-BEGIN' "$shfile"
grep -Fq 'source "$KIT/portmaster_common.sh"' "$shfile"
grep -Fq 'source "$KIT/launcher_unity_common.sh"' "$shfile"
grep -Fq 'run_launcher_ui frt3 "$GAMEDIR/bootstrap.pck"' "$shfile"
grep -Fq 'run_unity_game wsm.toml' "$shfile"
grep -Fq 'apply_button_remap "$GAMEDIR/wsm.toml"' "$shfile"
! grep -Fq 'find_frt3()' "$shfile"
! grep -Fq 'run_launcher_ui()' "$shfile"
! grep -Fq 'run_unity_game()' "$shfile"
! grep -Fq 'apply_button_remap()' "$shfile"
bash -n "$shfile"
