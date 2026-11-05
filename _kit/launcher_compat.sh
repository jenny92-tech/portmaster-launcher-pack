#!/bin/bash
# INPUT:  launcher_platform.sh、端口/固件身份、真实显示 socket 与选定运行目录的私有库
# OUTPUT: launcher_compat_plan()、launcher_compat_exec()、launcher_compat_describe() 的启动适配计划
# POS:    集中匹配已支持的引擎/设备组合，仅在目标子进程应用所选补丁
# SPDX-License-Identifier: CC-BY-NC-SA-4.0
# Copyright (c) 2025-2026 jenny92-tech

# Function library: sourcing, matching and planning never start a game or
# modify the caller's graphics environment. Engine-owned native preflights
# remain mandatory; matching a profile is not evidence of working gameplay.
launcher_compat_accepts() {
  case "$1:$2" in
    unity-rudroid:gles|godot-sdl2:gles) return 0 ;;
    unity-rudroid:vulkan)
      case "${PORT_NAME:-}:${CFW_NAME:-}" in
        silksong:TrimUI|vampiresurvivors114:TrimUI)
          launcher_platform_matches_compatible allwinner,a523 ;;
        silksong:Loong|vampiresurvivors114:Loong)
          launcher_platform_matches_compatible rockchip,rk3566-rk817-tablet ;;
        *) return 1 ;;
      esac ;;
    unity-rudroid:malisx2)
      case "${PORT_NAME:-}:${CFW_NAME:-}" in
        silksong:Loong|vampiresurvivors114:Loong)
          launcher_platform_matches_compatible rockchip,rk3566-rk817-tablet ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

# Check the optional Linux build without loading it. Android release packs use
# Bionic and cannot serve as a Linux ICD, even though both are AArch64 ELF.
launcher_compat_malisx2() {
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$1" <<'PY'
import hashlib,json,struct,sys
from pathlib import Path
try:
    root=Path(sys.argv[1])
    if not root.is_absolute() or ':' in str(root) or '\n' in str(root):
        raise ValueError('driver directory must be an absolute single-ICD path')
    if root.is_symlink() or not root.is_dir(): raise ValueError('driver directory must be local')
    for name in ('mali_icd.json','sources.json','libvulkan_malisx2.so'):
        p=root/name
        if p.is_symlink() or not p.is_file(): raise ValueError('missing regular Linux driver file')
    source=json.loads((root/'sources.json').read_text())
    if (source.get('platform'),source.get('profile'),source.get('source_revision')) != (
        'linux-aarch64','Release','d0422ed5eb5d8971f118f14d2550ce04aa1a0a5a'):
        raise ValueError('driver source/platform/Release identity mismatch')
    manifest=json.loads((root/'mali_icd.json').read_text())
    if manifest.get('ICD',{}).get('library_path')!='./libvulkan_malisx2.so':
        raise ValueError('driver manifest must select its local library')
    data=(root/'libvulkan_malisx2.so').read_bytes()
    if len(data)<64 or data[:6]!=b'\x7fELF\x02\x01' or struct.unpack_from('<HH',data,16)!=(3,183):
        raise ValueError('driver requires an AArch64 Linux shared library')
    phoff=struct.unpack_from('<Q',data,32)[0]
    ehsize,phsize,phnum=struct.unpack_from('<HHH',data,52)
    if ehsize!=64 or phsize!=56 or not 1<=phnum<=256 or phoff+phnum*56>len(data):
        raise ValueError('incomplete driver ELF headers')
    programs=[struct.unpack_from('<IIQQQQQQ',data,phoff+i*56) for i in range(phnum)]
    if any(p[2]+p[5]>len(data) or p[5]>p[6] for p in programs):
        raise ValueError('truncated driver ELF segment')
    if not any(p[0]==1 and p[1]&1 and p[5] for p in programs):
        raise ValueError('driver has no executable load segment')
    dynamic=[p for p in programs if p[0]==2]
    if len(dynamic)!=1 or dynamic[0][5]%16: raise ValueError('invalid driver dynamic table')
    entries=[]
    for off in range(dynamic[0][2],dynamic[0][2]+dynamic[0][5],16):
        key,value=struct.unpack_from('<QQ',data,off)
        if key==0: break
        entries.append((key,value))
    else: raise ValueError('unterminated driver dynamic table')
    tags=dict(entries);address=tags.get(5,0);size=tags.get(10,0)
    loads=[p for p in programs if p[0]==1 and p[3]<=address and address+size<=p[3]+p[5]]
    if not size or len(loads)!=1: raise ValueError('invalid driver dynamic strings')
    start=loads[0][2]+address-loads[0][3];strings=data[start:start+size];needed=[]
    for key,value in entries:
        if key!=1: continue
        end=strings.find(b'\0',value)
        if value>=len(strings) or end<0: raise ValueError('invalid driver import name')
        needed.append(strings[value:end])
    if b'libc.so.6' not in needed or any(n in needed for n in (b'liblog.so',b'libc.so')):
        raise ValueError('Android/Bionic driver is not a Linux build')
    if hashlib.sha256(data).hexdigest()!=source.get('library_sha256'):
        raise ValueError('driver checksum mismatch')
except (OSError,ValueError,KeyError,TypeError,AttributeError,struct.error) as error:
    print('malisx2: '+str(error),file=sys.stderr);sys.exit(1)
PY
}

launcher_compat_fail() {
  LAUNCHER_COMPAT_READY=0
  LAUNCHER_COMPAT_REASON="$1"
  printf '[compat] %s\n' "$1" >&2
  return 1
}

launcher_compat_wayland_socket() {
  local display="${WAYLAND_DISPLAY:-wayland-0}" dir candidate
  case "$display" in
    /*)
      if [ -S "$display" ]; then
        LAUNCHER_COMPAT_SOCKET="$display"
        return 0
      fi
      display=wayland-0 ;;
  esac
  for dir in "${XDG_RUNTIME_DIR:-}" /run "/run/user/$(id -u)" /var/run; do
    [ -n "$dir" ] || continue
    for candidate in "$display" wayland-0; do
      if [ -S "$dir/$candidate" ]; then
        LAUNCHER_COMPAT_SOCKET="$dir/$candidate"
        return 0
      fi
    done
  done
  return 1
}

launcher_compat_system_sdl() {
  local dir remaining="${LD_LIBRARY_PATH:-}:/usr/lib:/usr/lib64"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      *:*) dir="${remaining%%:*}"; remaining="${remaining#*:}" ;;
      *) dir="$remaining"; remaining="" ;;
    esac
    [ -n "$dir" ] || continue
    if [ -r "$dir/libSDL2-2.0.so.0" ]; then
      printf '%s\n' "$dir/libSDL2-2.0.so.0"
      return 0
    fi
  done
  return 1
}

launcher_compat_sdl_has_driver() {
  # Match a whole NUL-terminated driver name. A substring like "mali" also
  # occurs in ordinary strings such as "normalization" in unrelated builds.
  LC_ALL=C tr '\000' '\n' < "$1" | LC_ALL=C grep -Fxi -- "$2" >/dev/null
}

# The SDL string scan preserves the existing port's selection heuristic. The
# selected SDL/runtime must still initialize successfully; this is not a GPU
# capability or firmware acceptance probe. Native Wayland always wins.
launcher_compat_godot_sdl() {
  local bundled="$1" system_sdl
  if launcher_compat_wayland_socket; then
    LAUNCHER_COMPAT_PROFILE=godot-sdl2-wayland
    LAUNCHER_COMPAT_SDL_DRIVER=wayland
    return 0
  fi
  LAUNCHER_COMPAT_ALSA=1
  case "${SDL_VIDEODRIVER:-}" in
    dummy) launcher_compat_fail 'Godot SDL2 requires a video driver with GL support, not dummy'; return 1 ;;
    ''|wayland) ;;
    *)
      LAUNCHER_COMPAT_PROFILE=godot-sdl2-firmware
      LAUNCHER_COMPAT_SDL_DRIVER="$SDL_VIDEODRIVER"
      return 0 ;;
  esac
  system_sdl="$(launcher_compat_system_sdl)" || system_sdl=""
  if [ -n "$system_sdl" ] && launcher_compat_sdl_has_driver "$system_sdl" mali; then
    LAUNCHER_COMPAT_PROFILE=godot-sdl2-mali
    LAUNCHER_COMPAT_SDL_DRIVER=mali
  elif [ -n "$bundled" ] && [ -r "$bundled/libSDL2-2.0.so.0" ] &&
       launcher_compat_sdl_has_driver "$bundled/libSDL2-2.0.so.0" kmsdrm; then
    LAUNCHER_COMPAT_PROFILE=godot-sdl2-bundled-kmsdrm
    LAUNCHER_COMPAT_SDL_DRIVER=kmsdrm
    LAUNCHER_COMPAT_LIBRARY_DIR="$bundled"
    LAUNCHER_COMPAT_PATCHES=bundled-sdl2
  else
    launcher_compat_fail 'Godot SDL2 has no selected GL video driver or usable bundled KMSDRM SDL2'
    return 1
  fi
}

# Interface: STACK BACKEND RUNTIME_DIR [BUNDLED_SDL_DIR]. All outputs are owned
# LAUNCHER_COMPAT_* values. A failed/new selection invalidates the old plan.
# Keep concrete rules here; ports never assemble generic shell command strings.
launcher_compat_plan() {
  LAUNCHER_COMPAT_READY=0
  LAUNCHER_COMPAT_STACK="$1"
  LAUNCHER_COMPAT_BACKEND="$2"
  LAUNCHER_COMPAT_PROFILE=""
  LAUNCHER_COMPAT_PATCHES=""
  LAUNCHER_COMPAT_REASON=""
  LAUNCHER_COMPAT_LIBRARY_DIR=""
  LAUNCHER_COMPAT_WSI_DIR=""
  LAUNCHER_COMPAT_ICD_FILE=""
  LAUNCHER_COMPAT_SDL_DRIVER=""
  LAUNCHER_COMPAT_SOCKET=""
  LAUNCHER_COMPAT_ALSA=0
  local runtime="$3" bundled="${4:-}"
  case "$runtime" in /*) ;; *) launcher_compat_fail 'runtime directory must be absolute'; return 1 ;; esac
  case "$runtime:$bundled" in
    *'
'*) launcher_compat_fail 'runtime/library paths must not contain newlines'; return 1 ;;
  esac
  case "$runtime" in *:*) launcher_compat_fail 'runtime directory must not contain a library-path separator'; return 1 ;; esac
  if [ -n "$bundled" ]; then
    case "$bundled" in /*) ;; *) launcher_compat_fail 'bundled SDL directory must be absolute'; return 1 ;; esac
    case "$bundled" in *:*) launcher_compat_fail 'bundled SDL directory must not contain a library-path separator'; return 1 ;; esac
  fi
  launcher_compat_accepts "$1" "$2" || {
    launcher_compat_fail "unsupported stack/backend or unaccepted title/device: $1/$2"
    return 1
  }
  case "$1:$2" in
    unity-rudroid:gles) LAUNCHER_COMPAT_PROFILE=unity-system-gles ;;
    unity-rudroid:vulkan|unity-rudroid:malisx2)
      LAUNCHER_COMPAT_PROFILE="unity-${CFW_NAME}-$2"
      LAUNCHER_COMPAT_WSI_DIR="$runtime/vulkan-wsi"
      local file
      for file in libVkLayer_window_system_integration.so VkLayer_window_system_integration.json; do
        [ -s "$LAUNCHER_COMPAT_WSI_DIR/$file" ] || {
          launcher_compat_fail "missing private WSI file: $file"
          return 1
        }
      done
      LAUNCHER_COMPAT_PATCHES=private-wayland-wsi
      if [ "$2" = malisx2 ]; then
        local driver="${LAUNCHER_MALISX2_DIR:-$runtime/vulkan-malisx2}"
        launcher_compat_malisx2 "$driver" || {
          launcher_compat_fail 'missing or invalid malisx2 Linux driver'
          return 1
        }
        LAUNCHER_COMPAT_ICD_FILE="$driver/mali_icd.json"
        LAUNCHER_COMPAT_PATCHES=private-wayland-wsi,malisx2
      fi ;;
    godot-sdl2:gles) launcher_compat_godot_sdl "$bundled" || return 1 ;;
  esac
  LAUNCHER_COMPAT_READY=1
}

launcher_compat_describe() {
  [ "${LAUNCHER_COMPAT_READY:-0}" = 1 ] || return 1
  printf '[compat] stack=%s backend=%s profile=%s patches=%s\n' \
    "$LAUNCHER_COMPAT_STACK" "$LAUNCHER_COMPAT_BACKEND" "$LAUNCHER_COMPAT_PROFILE" "${LAUNCHER_COMPAT_PATCHES:-none}"
  printf '[compat] sdl=%s library=%s wsi=%s\n' \
    "${LAUNCHER_COMPAT_SDL_DRIVER:-system}" "${LAUNCHER_COMPAT_LIBRARY_DIR:-system}" "${LAUNCHER_COMPAT_WSI_DIR:-system}"
}

# Call only in the game's existing subshell/background job or a disposable
# command substitution. Apply the plan, then replace that child through the
# platform's exec hook: no extra supervisor, PID change or parent env leakage.
# Arguments stay quoted positional values, never generated shell source.
launcher_compat_exec() {
  [ "${LAUNCHER_COMPAT_READY:-0}" = 1 ] && [ "$#" -gt 0 ] || return 1
  # Selection applies only in this disposable child. Reselecting system Vulkan
  # must also clear an ICD override inherited from a prior launch environment.
  unset VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES RUDROID_WSI_HEADLESS_SURFACE
  if [ -n "$LAUNCHER_COMPAT_ICD_FILE" ]; then
    export VK_DRIVER_FILES="$LAUNCHER_COMPAT_ICD_FILE" VK_ICD_FILENAMES="$LAUNCHER_COMPAT_ICD_FILE"
    export RUDROID_WSI_HEADLESS_SURFACE=1
  fi
  if [ -n "$LAUNCHER_COMPAT_WSI_DIR" ]; then
    export DISABLE_WSI_LAYER=1
    export VK_LAYER_PATH="$LAUNCHER_COMPAT_WSI_DIR${VK_LAYER_PATH:+:$VK_LAYER_PATH}"
    export RUDROID_VULKAN_WSI_LIBRARY="$LAUNCHER_COMPAT_WSI_DIR/libVkLayer_window_system_integration.so"
  fi
  if [ -n "$LAUNCHER_COMPAT_LIBRARY_DIR" ]; then
    export LD_LIBRARY_PATH="$LAUNCHER_COMPAT_LIBRARY_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  fi
  if [ -n "$LAUNCHER_COMPAT_SDL_DRIVER" ]; then
    export SDL_VIDEODRIVER="$LAUNCHER_COMPAT_SDL_DRIVER"
  fi
  if [ -n "$LAUNCHER_COMPAT_SOCKET" ]; then
    export XDG_RUNTIME_DIR="${LAUNCHER_COMPAT_SOCKET%/*}" WAYLAND_DISPLAY="${LAUNCHER_COMPAT_SOCKET##*/}"
    unset LIBGL_FB
  fi
  # audio_setup may have selected PulseAudio or an ALSA mixing route after
  # planning. Preserve that choice; ALSA is only the old no-compositor default.
  if [ "$LAUNCHER_COMPAT_ALSA" = 1 ] && [ -z "${SDL_AUDIODRIVER:-}" ]; then
    export SDL_AUDIODRIVER=alsa
  fi
  launcher_platform_exec "$@"
}
