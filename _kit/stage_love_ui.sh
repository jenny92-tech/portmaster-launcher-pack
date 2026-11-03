#!/usr/bin/env bash
# INPUT:  Shared _kit/love source and an explicit UI destination
# OUTPUT: Shared Lua, pinned LUIS/Fluent resources and their legal notices
# POS:    Common UI payload staging for generic and STS2 launcher builds
set -euo pipefail
KIT_ROOT="$(cd "$(dirname "$0")" && pwd)"
DESTINATION="${1:?usage: stage_love_ui.sh DESTINATION}"
mkdir -p "$DESTINATION"
cp "$KIT_ROOT/love/"*.lua "$DESTINATION/"
cp "$KIT_ROOT/love/ui.gptk" "$DESTINATION/"
mkdir -p "$DESTINATION/icons"
for file in atlas.png layout.lua LICENSE upstream.json; do
  cp "$KIT_ROOT/love/icons/$file" "$DESTINATION/icons/"
done
if [ -f "$KIT_ROOT/love/launcher_bg.png" ]; then
  cp "$KIT_ROOT/love/launcher_bg.png" "$DESTINATION/"
fi
# Explicit files keep docs, editor metadata and unused upstream widgets out.
mkdir -p "$DESTINATION/luis/widgets" "$DESTINATION/luis/3rdparty"
for file in LICENSE LICENSE-flux.txt upstream.json; do
  cp "$KIT_ROOT/love/luis/$file" "$DESTINATION/luis/"
done
for file in button checkBox switch; do
  cp "$KIT_ROOT/love/luis/widgets/$file.lua" "$DESTINATION/luis/widgets/"
done
for file in utils vector decorators flux; do
  cp "$KIT_ROOT/love/luis/3rdparty/$file.lua" "$DESTINATION/luis/3rdparty/"
done

mkdir -p "$DESTINATION/qrcode"
for file in encode.lua LICENSE upstream.json; do
  cp "$KIT_ROOT/love/qrcode/$file" "$DESTINATION/qrcode/"
done
