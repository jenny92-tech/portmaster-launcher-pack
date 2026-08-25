#!/bin/sh
set -eu

repo=/repo
app=/tmp/jenny92-appmanager
libs="$repo/.pam-lab/userspace/${PAM_LAB_PROFILE:?}/runtime-libs"
loader="$libs/ld-linux-aarch64.so.1"
log=/tmp/userspace-smoke.log

cp -a "$repo/ports/appmanager/dist/jenny92-appmanager" "$app"
mv "$app/bin/gptokeyb" "$app/bin/gptokeyb.real"
cp "$repo/lab/gptokeyb-loader-wrapper.sh" "$app/bin/gptokeyb"
chmod 755 "$app/bin/gptokeyb"

export PAM_APP_ROOT="$app"
export PAM_SOURCE_DIR="${PAM_LAB_LAUNCHER%/*}"
export PAM_LAUNCHER="$PAM_LAB_LAUNCHER"
export PAM_NATIVE_ROOT=/device
export PAM_LAB_DEVICE_LOADER="$loader"
export PAM_LAB_DEVICE_LIBS="$libs"
export PAM_LAB_GPTOKEYB_REAL="$app/bin/gptokeyb.real"
export LOVE_LITE_SOFTWARE=1
export SDL_AUDIODRIVER=dummy

set +e
timeout 8 "$loader" --library-path "$libs" \
    "$app/runtime/love.aarch64" "$app/love_ui" 960 720 >"$log" 2>&1
status=$?
set -e
cat "$log"

case $status in
    0|124|143) ;;
    *) exit "$status" ;;
esac
grep -q 'startup.phase=service-ready' "$log"
grep -q 'startup.phase=lua-ready' "$log"
grep -q 'startup.phase=first-frame' "$log"
grep -q "platform.id=$PAM_LAB_PROFILE" "$app/log.txt"
grep -E '^\[PAM\] (platform\.id|path\.launcher|path\.scripts|path\.game_data)=' \
    "$app/log.txt" || true
if grep -q 'start controller input helper:' "$log"; then
    exit 1
fi
