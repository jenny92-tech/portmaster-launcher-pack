#!/bin/sh
# Read-only, bounded evidence probe for APP Manager handheld targets.

set -u

section() {
    printf '\n===== %s =====\n' "$1"
}

show_text_file() {
    probe_file=$1
    probe_lines=$2
    if [ -r "$probe_file" ]; then
        printf '\n--- %s ---\n' "$probe_file"
        sed -n "1,${probe_lines}p" "$probe_file"
    fi
}

show_path() {
    probe_path=$1
    if [ -e "$probe_path" ] || [ -L "$probe_path" ]; then
        ls -ld "$probe_path" 2>&1
        if [ -L "$probe_path" ]; then
            printf 'symlink-target: '
            readlink "$probe_path" 2>&1 || true
        fi
    else
        printf 'missing %s\n' "$probe_path"
    fi
}

directory_counts() {
    probe_dir=$1
    if [ ! -d "$probe_dir" ]; then
        printf 'missing %s\n' "$probe_dir"
        return
    fi

    probe_files=0
    probe_dirs=0
    probe_scripts=0
    for probe_entry in "$probe_dir"/*; do
        [ -e "$probe_entry" ] || [ -L "$probe_entry" ] || continue
        if [ -d "$probe_entry" ] && [ ! -L "$probe_entry" ]; then
            probe_dirs=$((probe_dirs + 1))
        elif [ -f "$probe_entry" ] && [ ! -L "$probe_entry" ]; then
            probe_files=$((probe_files + 1))
            case $probe_entry in
                *.sh) probe_scripts=$((probe_scripts + 1)) ;;
            esac
        fi
    done
    printf '%s files=%s directories=%s shell_scripts=%s\n' \
        "$probe_dir" "$probe_files" "$probe_dirs" "$probe_scripts"
}

show_command() {
    probe_command=$1
    probe_location=$(command -v "$probe_command" 2>/dev/null || true)
    if [ -n "$probe_location" ]; then
        printf '%s=%s\n' "$probe_command" "$probe_location"
        show_path "$probe_location"
    else
        printf '%s=missing\n' "$probe_command"
    fi
}

show_library_glob() {
    for probe_library in $1; do
        [ -e "$probe_library" ] || [ -L "$probe_library" ] || continue
        show_path "$probe_library"
    done
}

show_elf() {
    probe_elf=$1
    [ -f "$probe_elf" ] || return
    printf '\n--- ELF %s ---\n' "$probe_elf"
    if command -v file >/dev/null 2>&1; then
        file "$probe_elf" 2>&1 || true
    fi
    if command -v readelf >/dev/null 2>&1; then
        readelf -h "$probe_elf" 2>&1 | sed -n '1,24p'
        readelf -d "$probe_elf" 2>&1 | grep 'NEEDED' || true
    elif command -v objdump >/dev/null 2>&1; then
        objdump -p "$probe_elf" 2>&1 | grep 'NEEDED' || true
    else
        printf 'ELF metadata tool unavailable\n'
    fi
}

section identity
uname -a 2>&1 || true
printf 'machine='
uname -m 2>&1 || true
printf 'user='
id 2>&1 || true
if [ -r /proc/device-tree/model ]; then
    printf 'device-tree-model='
    tr '\000' '\n' </proc/device-tree/model 2>/dev/null || true
fi
show_text_file /etc/os-release 40
show_text_file /loong/loong_version 20

section runtime
if command -v getconf >/dev/null 2>&1; then
    getconf GNU_LIBC_VERSION 2>&1 || true
fi
if command -v ldd >/dev/null 2>&1; then
    ldd --version 2>&1 | sed -n '1,4p'
fi
if command -v python3 >/dev/null 2>&1; then
    python3 --version 2>&1 || true
    python3 -c 'import encodings, hashlib, sys, zipfile; print("python-required-imports=ok")' 2>&1 || true
    python3 -c 'import importlib.util; modules=("ctypes", "ssl", "lzma", "sqlite3"); [(print("python-optional-%s=ok" % name) if importlib.util.find_spec(name) else print("python-optional-%s=missing" % name)) for name in modules]' 2>&1 || true
else
    printf 'python3=missing\n'
fi
for probe_libc in /lib/libc.so.6 /usr/lib/libc.so.6; do
    show_path "$probe_libc"
    if [ -x "$probe_libc" ]; then
        "$probe_libc" 2>&1 | sed -n '1,4p' || true
    fi
done

section command-inventory
for probe_command_name in \
    sh sed find grep xargs tar awk unzip zip curl wget rsync python3 \
    file readelf objdump mount readlink realpath sha256sum flock setsid chrt taskset; do
    show_command "$probe_command_name"
done

section launcher-environment-whitelist
printf 'CFW_NAME=%s\n' "${CFW_NAME-}"
printf 'DEVICE=%s\n' "${DEVICE-}"
printf 'DISPLAY_WIDTH=%s\n' "${DISPLAY_WIDTH-}"
printf 'DISPLAY_HEIGHT=%s\n' "${DISPLAY_HEIGHT-}"
printf 'SDL_VIDEODRIVER=%s\n' "${SDL_VIDEODRIVER-}"
printf 'SDL_AUDIODRIVER=%s\n' "${SDL_AUDIODRIVER-}"
printf 'PYSDL2_DLL_PATH=%s\n' "${PYSDL2_DLL_PATH-}"
printf 'LD_LIBRARY_PATH=%s\n' "${LD_LIBRARY_PATH-}"
printf 'XDG_DATA_HOME=%s\n' "${XDG_DATA_HOME-}"

section mounts
if [ -r /proc/mounts ]; then
    awk '{print $1, $2, $3}' /proc/mounts | sed -n '1,200p'
fi

section configured-paths
for probe_configured_path in \
    /usr/trimui \
    /usr/trimui/lib \
    /mnt/SDCARD \
    /mnt/SDCARD/Data \
    /mnt/SDCARD/Data/ports \
    /mnt/SDCARD/Roms/PORTS \
    /mnt/SDCARD/Imgs/PORTS \
    /mnt/SDCARD/Apps \
    /mnt/SDCARD/Apps/PortMaster \
    /mnt/SDCARD/Apps/PortMaster/PortMaster \
    '/mnt/SDCARD/Roms/PORTS/APP Manager.sh' \
    /mnt/SDCARD/Roms/PORTS/jenny92-appmanager \
    '/mnt/SDCARD/Apps/jenny92-appmanager/APP Manager.sh' \
    /mnt/SDCARD/Apps/jenny92-appmanager/launch.sh \
    /mnt/SDCARD/Apps/jenny92-appmanager/jenny92-appmanager \
    /loong \
    /loong/loong_version \
    /mnt/sdcard \
    /mnt/sdcard/roms \
    '/mnt/sdcard/roms/ports/APP Manager.sh' \
    /mnt/sdcard/roms/ports/jenny92-appmanager \
    /mnt/sdcard/roms/ports \
    /mnt/sdcard/roms/ports/PortMaster \
    /roms \
    /roms/ports \
    /roms/ports/PortMaster \
    /storage/roms \
    /storage/roms/ports \
    /storage/roms/ports/PortMaster; do
    show_path "$probe_configured_path"
done

section bounded-directory-counts
for probe_count_path in \
    /mnt/SDCARD/Data \
    /mnt/SDCARD/Data/ports \
    /mnt/SDCARD/Apps \
    /mnt/SDCARD/Roms/PORTS/jenny92-appmanager \
    /mnt/SDCARD/Apps/jenny92-appmanager/jenny92-appmanager \
    /mnt/sdcard/roms \
    /mnt/sdcard/roms/ports \
    /mnt/sdcard/roms/ports/jenny92-appmanager \
    /roms \
    /roms/ports \
    /storage/roms \
    /storage/roms/ports; do
    directory_counts "$probe_count_path"
done

section appmanager-files
for probe_app_root in \
    /mnt/SDCARD/Roms/PORTS/jenny92-appmanager \
    /mnt/SDCARD/Apps/jenny92-appmanager/jenny92-appmanager \
    /mnt/sdcard/roms/ports/jenny92-appmanager \
    /roms/ports/jenny92-appmanager \
    /storage/roms/ports/jenny92-appmanager; do
    [ -d "$probe_app_root" ] || continue
    printf '\n--- app-root %s ---\n' "$probe_app_root"
    for probe_app_name in LICENSE README.md bin config licenses love_ui runtime share state trash; do
        show_path "$probe_app_root/$probe_app_name"
    done
    show_path "$probe_app_root/runtime/love.aarch64"
    if command -v sha256sum >/dev/null 2>&1 && \
        [ -f "$probe_app_root/runtime/love.aarch64" ]; then
        sha256sum "$probe_app_root/runtime/love.aarch64" 2>&1 || true
    fi
done

section appmanager-launchers
show_text_file '/mnt/SDCARD/Roms/PORTS/APP Manager.sh' 180
show_text_file '/mnt/SDCARD/Apps/jenny92-appmanager/APP Manager.sh' 180
show_text_file /mnt/SDCARD/Apps/jenny92-appmanager/launch.sh 180
show_text_file '/mnt/sdcard/roms/ports/APP Manager.sh' 180
show_text_file '/roms/ports/APP Manager.sh' 180
show_text_file '/storage/roms/ports/APP Manager.sh' 180

section static-launch-environment
for probe_launch_config in \
    /mnt/SDCARD/System/etc/ex_config \
    /mnt/SDCARD/Apps/PortMaster/PortMaster/control.txt \
    /mnt/SDCARD/Apps/PortMaster/PortMaster/device_info.txt \
    /mnt/sdcard/roms/ports/PortMaster/control.txt \
    /mnt/sdcard/roms/ports/PortMaster/device_info.txt \
    /roms/ports/PortMaster/control.txt \
    /roms/ports/PortMaster/device_info.txt; do
    [ -r "$probe_launch_config" ] || continue
    printf '\n--- selected assignments %s ---\n' "$probe_launch_config"
    grep -nE '^(export[[:space:]]+)?(CFW_NAME|DEVICE|DEVICE_ARCH|directory|ESUDO|DISPLAY_WIDTH|DISPLAY_HEIGHT|SDL_[A-Za-z0-9_]*|PYSDL2_DLL_PATH|LD_LIBRARY_PATH|XDG_DATA_HOME)=' \
        "$probe_launch_config" 2>&1 || true
done

section portmaster-core-files
for probe_core in \
    /mnt/SDCARD/Apps/PortMaster/PortMaster \
    /mnt/sdcard/roms/ports/PortMaster \
    /roms/ports/PortMaster \
    /storage/roms/ports/PortMaster; do
    [ -d "$probe_core" ] || [ -L "$probe_core" ] || continue
    printf '\n--- core %s ---\n' "$probe_core"
    for probe_core_name in \
        PortMaster.sh control.txt device_info.txt funcs.txt harbourmaster pugwash \
        pylibs.zip pylibs love.aarch64; do
        show_path "$probe_core/$probe_core_name"
    done
done

section frontend-launchers
show_text_file /mnt/SDCARD/Apps/PortMaster/launch.sh 300
show_text_file /mnt/sdcard/roms/PortMaster.sh 300
show_text_file /roms/PortMaster.sh 300
show_text_file /storage/roms/PortMaster.sh 300
show_text_file /mnt/sdcard/roms/ports/PortMaster/PortMaster.sh 300
show_text_file /roms/ports/PortMaster/PortMaster.sh 300
show_text_file /storage/roms/ports/PortMaster/PortMaster.sh 300

section required-libraries
for probe_library_pattern in \
    '/usr/lib/libSDL2*.so*' \
    '/usr/trimui/lib/libSDL2*.so*' \
    '/lib/libSDL2*.so*' \
    '/lib64/libSDL2*.so*' \
    '/usr/lib64/libSDL2*.so*' \
    '/lib/aarch64-linux-gnu/libSDL2*.so*' \
    '/usr/lib/aarch64-linux-gnu/libSDL2*.so*' \
    '/usr/lib/libGLES*.so*' \
    '/usr/lib/libEGL*.so*' \
    '/usr/trimui/lib/libGLES*.so*' \
    '/usr/trimui/lib/libEGL*.so*'; do
    show_library_glob "$probe_library_pattern"
done

section appmanager-elf
for probe_binary in \
    /mnt/SDCARD/Apps/PortMaster/PortMaster/love.aarch64 \
    /mnt/SDCARD/Roms/PORTS/jenny92-appmanager/runtime/love.aarch64 \
    /mnt/SDCARD/Apps/jenny92-appmanager/jenny92-appmanager/runtime/love.aarch64 \
    /mnt/sdcard/roms/ports/PortMaster/love.aarch64 \
    /mnt/sdcard/roms/ports/jenny92-appmanager/runtime/love.aarch64 \
    /roms/ports/PortMaster/love.aarch64 \
    /storage/roms/ports/PortMaster/love.aarch64; do
    show_elf "$probe_binary"
done

section appmanager-loader-resolution
for probe_binary in \
    /mnt/SDCARD/Roms/PORTS/jenny92-appmanager/runtime/love.aarch64 \
    /mnt/SDCARD/Roms/PORTS/jenny92-appmanager/bin/gptokeyb \
    /mnt/SDCARD/Apps/jenny92-appmanager/jenny92-appmanager/runtime/love.aarch64 \
    /mnt/SDCARD/Apps/jenny92-appmanager/jenny92-appmanager/bin/gptokeyb \
    /mnt/sdcard/roms/ports/jenny92-appmanager/runtime/love.aarch64 \
    /mnt/sdcard/roms/ports/jenny92-appmanager/bin/gptokeyb \
    /roms/ports/jenny92-appmanager/runtime/love.aarch64 \
    /roms/ports/jenny92-appmanager/bin/gptokeyb \
    /storage/roms/ports/jenny92-appmanager/runtime/love.aarch64; do
    [ -f "$probe_binary" ] || continue
    printf '\n--- loader %s ---\n' "$probe_binary"
    /lib/ld-linux-aarch64.so.1 --list "$probe_binary" 2>&1 || true
done

section hardware-interfaces
for probe_device_path in \
    /dev/dri /dev/fb0 /dev/input /dev/mali0 /dev/snd /dev/tty0; do
    show_path "$probe_device_path"
done
for probe_device_dir in /dev/dri /dev/input /dev/snd; do
    if [ -d "$probe_device_dir" ]; then
        ls -la "$probe_device_dir" 2>&1 | sed -n '1,120p'
    fi
done
