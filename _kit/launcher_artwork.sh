#!/usr/bin/env bash
# Shared launcher artwork adapter for tested handheld frontends.

# Resolve the frontend-owned Port image directory once for both launchers and
# APP Manager. Only verified MiniLoong and TrimUI layouts are supported here;
# unknown devices are deliberately left untouched until tested.
portmaster_resolve_launcher_image_dir() {
  local script_dir="$1" card_root
  PORTMASTER_LAUNCHER_IMAGE_DIR=""
  PORTMASTER_LAUNCHER_IMAGE_DIR_KNOWN=0

  if [ -f "${PORTMASTER_LOONG_VERSION_FILE:-/loong/loong_version}" ]; then
    PORTMASTER_LAUNCHER_IMAGE_DIR="$script_dir/images"
    PORTMASTER_LAUNCHER_IMAGE_DIR_KNOWN=1
    return 0
  fi
  case "$script_dir" in
    */Roms/PORTS|*/Roms/Ports|*/ROMS/PORTS|*/ROMS/Ports)
      card_root=${script_dir%/*/*}
      if [ -d "/usr/trimui" ] || [ -f "$card_root/Emus/PORTS/config.json" ]; then
        PORTMASTER_LAUNCHER_IMAGE_DIR="$card_root/Imgs/PORTS"
        PORTMASTER_LAUNCHER_IMAGE_DIR_KNOWN=1
        return 0
      fi
      ;;
  esac
}

# Make package-owned artwork visible in the device-specific image folder.
# The optional third argument is the installed game/app directory. The source
# image must match the launcher's stem exactly; no fuzzy or generic fallback is
# used, so one package cannot accidentally publish another launcher's artwork.
# Existing frontend artwork is never overwritten.
portmaster_sync_launcher_artwork() {
  local script_dir="${1:-$(cd "$(dirname "$0")" && pwd)}"
  local launcher="${2:-$0}" source_dir="${3:-$script_dir}"
  local stem source="" ext source_ext image_dir target
  stem=$(basename "$launcher")
  case "$stem" in *.sh) stem=${stem%.sh} ;; *) stem="" ;; esac
  case "$stem" in ""|.port) stem="" ;; esac
  [ -n "$stem" ] || return 0
  for ext in png PNG jpg JPG jpeg JPEG webp WEBP; do
    if [ -f "$source_dir/$stem.$ext" ] && [ ! -L "$source_dir/$stem.$ext" ]; then
      source="$source_dir/$stem.$ext"; source_ext="$ext"; break
    fi
  done
  [ -n "$source" ] || return 0

  portmaster_resolve_launcher_image_dir "$script_dir"
  image_dir="$PORTMASTER_LAUNCHER_IMAGE_DIR"
  [ -n "$image_dir" ] || return 0
  if [ ! -d "$image_dir" ]; then
    [ "$PORTMASTER_LAUNCHER_IMAGE_DIR_KNOWN" = "1" ] || return 0
    mkdir -p "$image_dir" 2>/dev/null || return 0
  fi
  [ ! -L "$image_dir" ] || return 0
  target="$image_dir/$stem.$source_ext"
  [ ! -e "$target" ] && [ ! -L "$target" ] || return 0
  cp "$source" "$target" 2>/dev/null || true
}
