#!/bin/bash
# INPUT:  Separate developer debug binary/checksum and explicit writable cache locations.
# OUTPUT: launcher_native_debug_prepare() sets PORTKIT_DEBUG_LAUNCHER_BIN to the verified native helper.
# POS:    Explicit remote-debug bootstrap; firmware menu entries never invoke it.

launcher_native_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1"
  elif command -v busybox >/dev/null 2>&1; then
    busybox sha256sum "$1"
  else
    printf 'PortKit debug bootstrap requires SHA-256 support.\n' >&2
    return 1
  fi
}

launcher_native_matches() {
  local actual rest
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  read -r actual rest < <(launcher_native_digest "$1")
  [ "$actual" = "$2" ]
}

launcher_native_cache() {
  local base="$1" suffix="$2" source="$3" expected="$4" directory target incoming
  [ -d "$base" ] && [ -w "$base" ] || return 1
  directory="$base/$suffix"
  # Predictable cache names are safe only inside our own non-symlink directory.
  [ ! -L "$directory" ] || return 1
  ( umask 077; mkdir -p -- "$directory" ) || return 1
  [ -O "$directory" ] && [ -d "$directory" ] && [ ! -L "$directory" ] || return 1
  chmod 700 "$directory" || return 1
  target="$directory/portkit-debug-launch-$expected"
  if launcher_native_matches "$target" "$expected" && "$target" version >/dev/null 2>&1; then
    PORTKIT_DEBUG_LAUNCHER_BIN="$target"
    return 0
  fi
  [ ! -L "$target" ] || return 1
  incoming="$(mktemp "$directory/.incoming.XXXXXXXX")" || return 1
  if cp -- "$source" "$incoming" && chmod 700 "$incoming" &&
     launcher_native_matches "$incoming" "$expected" && "$incoming" version >/dev/null 2>&1; then
    if mv -f -- "$incoming" "$target"; then
      PORTKIT_DEBUG_LAUNCHER_BIN="$target"
      return 0
    fi
  fi
  # This is the exact fresh file returned by mktemp in our owned cache.
  [ ! -f "$incoming" ] || unlink "$incoming"
  return 1
}

launcher_native_debug_prepare() {
  local source="${PORTKIT_DEBUG_LAUNCHER:?Set the separate developer debug binary}" expected uid base
  [ ! -L "$source.sha256" ] && [ -f "$source.sha256" ] || {
    printf 'PortKit debug helper checksum is missing.\n' >&2; return 1;
  }
  IFS= read -r expected < "$source.sha256" || return 1
  case "$expected" in ''|*[!0-9a-f]*) printf 'Invalid native helper checksum.\n' >&2; return 1;; esac
  [ "${#expected}" = 64 ] && launcher_native_matches "$source" "$expected" || {
    printf 'PortKit debug helper checksum mismatch.\n' >&2; return 1;
  }
  if "$source" version >/dev/null 2>&1; then
    export PORTKIT_DEBUG_LAUNCHER_BIN="$source"
    return 0
  fi
  uid="$(id -u)"
  if [ -n "${XDG_CACHE_HOME:-}" ]; then
    case "$XDG_CACHE_HOME" in
      /*) if launcher_native_cache "$XDG_CACHE_HOME" portkit-debug "$source" "$expected"; then
            export PORTKIT_DEBUG_LAUNCHER_BIN; return 0;
          fi ;;
    esac
  fi
  # Storage anchors are capabilities, not board identities. Never create a
  # missing volume path on the root filesystem just because /mnt is writable.
  for base in /userdata /mnt/UDISK "${TMPDIR:-/tmp}"; do
    if launcher_native_cache "$base" ".portkit-debug-$uid" "$source" "$expected"; then
      export PORTKIT_DEBUG_LAUNCHER_BIN
      return 0
    fi
  done
  printf 'No writable executable location for the debug PortKit helper.\n' >&2
  return 1
}

# MiniLoong's remote shell can lack the firmware menu's executable SD view.
# This wrapper is opt-in for debugging; it is never embedded in a player entry.
launcher_native_debug_exec() {
  local root="${1:?Expected game root}"
  shift
  [ "${1:-}" = -- ] && [ "$#" -gt 1 ] || {
    printf 'Usage: launcher_native_debug_exec GAME_ROOT -- COMMAND [ARG...]\n' >&2
    return 1
  }
  shift
  launcher_native_debug_prepare || return 1
  exec "$PORTKIT_DEBUG_LAUNCHER_BIN" --root "$root" -- "$@"
}
