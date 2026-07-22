#!/bin/bash
# Terraria first-launch gamedata setup. Idempotent.
#
# Invoked under PortMaster's patcher UI (stdout → full-screen progress) at
# two points in the launcher:
#   • stage-0: first launch, before the settings UI
#   • final check: just before run_unity_game, as defence in depth
#
# Cases (checked in order):
#   1. sentinel exists          → already ready, exit 0
#   2. core files all present   → self-heal sentinel, exit 0
#   3. APK in gamedata/         → extract → verify → sentinel → delete APK
#   4. no APK, no core files    → friendly "buy & place APK" message, exit 1
#
# Zero compression, zero transcoding — pure file move. The APK is a standard
# zip; only the two trees UnityLoader needs are pulled, landing at:
#   $GAMEDIR/lib/arm64-v8a/*.so
#   $GAMEDIR/assets/bin/Data/...
# which are the relative paths UnityLoader loads from its cwd.
#
# Output is English on purpose: the patcher UI uses a Latin-only font
# (PeaberryBase). Chinese player instructions live in the port README.
#
# Environment (set by the launcher preamble):
#   GAMEDIR       absolute port directory (UnityLoader cwd)
#   controlfolder PortMaster root (for the 7z fallback)

set -u

GAMEDIR="${GAMEDIR:-$(pwd)}"
GAMEDATA="$GAMEDIR/gamedata"
SENTINEL="$GAMEDIR/.gamedata_ready"

# Core files UnityLoader needs at runtime. config.toml's
# game_files="./gamedata/" points the loader at the gamedata/ subtree, so
# every path below is relative to $GAMEDATA (== $GAMEDIR/gamedata).
CORE_FILES="lib/arm64-v8a/libil2cpp.so
assets/bin/Data/Managed/Metadata/global-metadata.dat
assets/bin/Data/data.unity3d"

have_core_files() {
  local f
  for f in $CORE_FILES; do [ -f "$GAMEDATA/$f" ] || return 1; done
  return 0
}

# ── case 1 & 2: already ready (sentinel or self-heal) ─────────────────────
if [ -f "$SENTINEL" ] || have_core_files; then
  [ -f "$SENTINEL" ] || touch "$SENTINEL"
  echo "Game data ready."
  exit 0
fi

mkdir -p "$GAMEDATA"

# ── locate the player-supplied APK ────────────────────────────────────────
APK=""
for f in "$GAMEDATA"/*.apk; do
  [ -f "$f" ] || continue
  if [ -n "$APK" ]; then
    echo "[!] Multiple APKs in gamedata/:"
    echo "    $(basename "$APK")"
    echo "    $(basename "$f")"
    echo "Keep only one Terraria APK and restart."
    exit 1
  fi
  APK="$f"
done

# ── case 4: no APK and no core files ──────────────────────────────────────
if [ -z "$APK" ]; then
  echo "============================================"
  echo " Terraria game data not found"
  echo "============================================"
  echo ""
  echo "This port ships no game content."
  echo "Please buy Terraria (Android version)"
  echo "and place the APK into:"
  echo ""
  echo "  $GAMEDATA/"
  echo ""
  echo "Then restart the game."
  echo "============================================"
  exit 1
fi

# ── case 3: extract the APK ───────────────────────────────────────────────
echo "Found APK: $(basename "$APK")"
echo "Extracting (under a minute)..."

if command -v unzip >/dev/null 2>&1; then
  unzip -o -q "$APK" 'lib/arm64-v8a/*' 'assets/*' -d "$GAMEDATA" || {
    echo "[!] unzip failed. The APK may be corrupted."
    exit 1
  }
else
  SEVENZ=""
  for c in \
    "${controlfolder:-}/tools/7zzs.aarch64" \
    "${controlfolder:-}/tools/7zzs" \
    /usr/bin/7z /usr/bin/7za
  do
    [ -x "$c" ] && { SEVENZ="$c"; break; }
  done
  if [ -z "$SEVENZ" ]; then
    echo "[!] No unzip or 7z found on this device."
    echo "    Install 'unzip' via your CFW package manager."
    exit 1
  fi
  "$SEVENZ" x -y -bd -o"$GAMEDATA" "$APK" \
    'lib/arm64-v8a/*' 'assets/*' >/dev/null 2>&1 || {
    echo "[!] 7z extraction failed. The APK may be corrupted."
    exit 1
  }
fi

# ── verify the minimum IL2CPP/Unity boot set ──────────────────────────────
echo "Verifying..."
if ! have_core_files; then
  echo "[!] Extraction incomplete — core files missing."
  echo "The APK may not be Terraria, or is a wrong variant."
  echo "Original APK kept for retry."
  exit 1
fi

# ── commit: sentinel + free the APK's space ───────────────────────────────
touch "$SENTINEL"
rm -f "$APK"

echo ""
echo "============================================"
echo " Setup complete!"
echo "============================================"
