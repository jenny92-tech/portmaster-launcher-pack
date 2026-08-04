#!/usr/bin/env bash
# Prepare Bogodroid's Android-style data tree from a player-owned Windows copy.
# The input under GameData/ is read-only and is never renamed or deleted.

set -euo pipefail

GAMEDIR="${GAMEDIR:-$(cd "$(dirname "$0")/.." && pwd)}"
case "$GAMEDIR" in
  ""|"/"|"/mnt"|"/mnt/SDCARD"|"/mnt/SDCARD/Data"|"/mnt/SDCARD/Data/ports")
    echo "unsafe GAMEDIR: $GAMEDIR" >&2
    exit 1
    ;;
esac

INPUT="$GAMEDIR/GameData"
RUNTIME_DATA="$GAMEDIR/gamefiles/assets/bin/Data"
LIBDIR="$GAMEDIR/gamefiles/lib/arm64-v8a"
READY="$GAMEDIR/gamefiles/.gamedata_ready"
EXTRACTED_IL2CPP="$GAMEDIR/conf/il2cpp"

core_files_ok() {
  [ -s "$LIBDIR/libil2cpp.so" ] &&
    [ -s "$LIBDIR/libunity.so" ] &&
    [ -s "$LIBDIR/libmain.so" ] &&
    [ -s "$RUNTIME_DATA/Managed/Metadata/global-metadata.dat" ] &&
    [ -s "$RUNTIME_DATA/globalgamemanagers" ] &&
    [ -s "$EXTRACTED_IL2CPP/Metadata/global-metadata.dat" ] &&
    [ -s "$EXTRACTED_IL2CPP/unity.ver" ] &&
    [ -s "$READY" ]
}

core_files_ok && {
  echo "GameData already prepared"
  exit 0
}

GAME_ROOT=""
if [ -d "$INPUT/Sunken Dragon_Data" ]; then
  GAME_ROOT="$INPUT"
else
  for candidate in "$INPUT"/*; do
    [ -d "$candidate/Sunken Dragon_Data" ] || continue
    GAME_ROOT="$candidate"
    break
  done
fi

[ -n "$GAME_ROOT" ] || {
  echo "Windows game not found under $INPUT" >&2
  exit 2
}

DATA_ROOT="$GAME_ROOT/Sunken Dragon_Data"
for required in \
  "$GAME_ROOT/Sunken Dragon.exe" \
  "$GAME_ROOT/GameAssembly.dll" \
  "$GAME_ROOT/UnityPlayer.dll" \
  "$DATA_ROOT/app.info" \
  "$DATA_ROOT/globalgamemanagers" \
  "$DATA_ROOT/level0" \
  "$DATA_ROOT/resources.assets" \
  "$DATA_ROOT/ScriptingAssemblies.json" \
  "$DATA_ROOT/il2cpp_data/Metadata/global-metadata.dat"
do
  [ -s "$required" ] || {
    echo "incomplete Windows game; missing: $required" >&2
    exit 3
  }
done

grep -Fxq "Sunken Dragon" "$DATA_ROOT/app.info" || {
  echo "GameData is not the supported Sunken Dragon Windows build" >&2
  exit 4
}

for required in \
  "$LIBDIR/libil2cpp.so" \
  "$LIBDIR/libunity.so" \
  "$LIBDIR/libmain.so" \
  "$RUNTIME_DATA/Managed/Metadata/global-metadata.dat" \
  "$RUNTIME_DATA/ScriptingAssemblies.json" \
  "$RUNTIME_DATA/RuntimeInitializeOnLoads.json" \
  "$RUNTIME_DATA/unity_app_guid"
do
  [ -s "$required" ] || {
    echo "minimal ARM64 runtime is incomplete: $required" >&2
    exit 5
  }
done

STAGE="$GAMEDIR/.sunkendragon-assets-staging.$$"
PREVIOUS="$GAMEDIR/.sunkendragon-assets-previous"
case "$STAGE:$PREVIOUS" in
  "$GAMEDIR"/*:"$GAMEDIR"/*) ;;
  *) echo "unsafe staging paths" >&2; exit 1 ;;
esac
cleanup() {
  rm -rf "$STAGE"
}
trap cleanup EXIT INT TERM

mkdir -p "$STAGE/bin/Data/Managed/Metadata" "$STAGE/bin/Data/Managed/Resources"

# Copy only reusable Windows game resources. Windows executables, DLL plugins,
# Steam binaries and the original metadata remain in GameData/ as ownership
# input and are never put into the ARM64 runtime tree.
for source_file in \
  "$DATA_ROOT"/globalgamemanagers* \
  "$DATA_ROOT"/level* \
  "$DATA_ROOT"/resources.* \
  "$DATA_ROOT"/sharedassets*
do
  [ -f "$source_file" ] || continue
  cp "$source_file" "$STAGE/bin/Data/"
done
[ -d "$DATA_ROOT/Resources" ] && cp -R "$DATA_ROOT/Resources" "$STAGE/bin/Data/"
[ -s "$DATA_ROOT/il2cpp_data/Resources/mscorlib.dll-resources.dat" ] && \
  cp "$DATA_ROOT/il2cpp_data/Resources/mscorlib.dll-resources.dat" \
    "$STAGE/bin/Data/Managed/Resources/"

# These three generated files must match the supplied ARM64 libil2cpp.so.
cp "$RUNTIME_DATA/Managed/Metadata/global-metadata.dat" \
  "$STAGE/bin/Data/Managed/Metadata/global-metadata.dat"
cp "$RUNTIME_DATA/ScriptingAssemblies.json" "$STAGE/bin/Data/ScriptingAssemblies.json"
cp "$RUNTIME_DATA/RuntimeInitializeOnLoads.json" "$STAGE/bin/Data/RuntimeInitializeOnLoads.json"
cp "$RUNTIME_DATA/unity_app_guid" "$STAGE/bin/Data/unity_app_guid"

# Use the official Windows boot settings, adding only Android display flags.
cp "$DATA_ROOT/boot.config" "$STAGE/bin/Data/boot.config"
sed '/^single-instance=/d; /^nolog=/d' "$STAGE/bin/Data/boot.config" \
  > "$STAGE/bin/Data/boot.config.filtered"
mv "$STAGE/bin/Data/boot.config.filtered" "$STAGE/bin/Data/boot.config"
printf '%s\n' \
  'androidStartInFullscreen=1' \
  'androidRenderOutsideSafeArea=1' >> "$STAGE/bin/Data/boot.config"

rm -rf "$PREVIOUS"
if [ -d "$GAMEDIR/gamefiles/assets" ]; then
  mv "$GAMEDIR/gamefiles/assets" "$PREVIOUS"
fi
if ! mv "$STAGE" "$GAMEDIR/gamefiles/assets"; then
  [ -d "$PREVIOUS" ] && mv "$PREVIOUS" "$GAMEDIR/gamefiles/assets"
  exit 6
fi
rm -rf "$PREVIOUS"
trap - EXIT INT TERM

# Unity's Android bootstrap expects its IL2CPP resources in external files.
# Pre-populate the same conf/il2cpp layout used by the verified heishenhua port
# so Unity does not enter its generic "not enough storage" extraction failure.
mkdir -p "$EXTRACTED_IL2CPP/Metadata" "$EXTRACTED_IL2CPP/Resources"
cp "$RUNTIME_DATA/Managed/Metadata/global-metadata.dat" \
  "$EXTRACTED_IL2CPP/Metadata/global-metadata.dat"
if [ -s "$RUNTIME_DATA/Managed/Resources/mscorlib.dll-resources.dat" ]; then
  cp "$RUNTIME_DATA/Managed/Resources/mscorlib.dll-resources.dat" \
    "$EXTRACTED_IL2CPP/Resources/mscorlib.dll-resources.dat"
fi
cp "$RUNTIME_DATA/unity_app_guid" "$EXTRACTED_IL2CPP/unity.ver"

{
  echo "source=Windows official GameData"
  echo "title=Sunken Dragon"
  echo "prepared_by=龙沉异世录 launcher"
} > "$READY"

core_files_ok || {
  echo "prepared data failed final validation" >&2
  exit 7
}
echo "GameData prepared successfully from $GAME_ROOT"
