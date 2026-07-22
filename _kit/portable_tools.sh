#!/usr/bin/env bash
# System/portable command adapter for self-contained aarch64 launchers.
#
# There are deliberately only two providers.  The system wins when every
# required applet exists and one representative capability suite passes.  Any
# failure switches the whole command set to the application-provided BusyBox,
# so an installation never mixes implementations.

PAM_TOOL_MODE="${PAM_TOOL_MODE:-auto}"
PAM_TOOL_SYSTEM_PATH="${PAM_TOOL_SYSTEM_PATH:-${PATH:-/usr/bin:/bin}}"
PAM_BUSYBOX_PORTABLE="${PAM_BUSYBOX_PORTABLE_OVERRIDE:-${PAM_BIN_DIR:-}/busybox-portable}"
PAM_TOOLBOX_DIR="${PAM_TOOLBOX_DIR_OVERRIDE:-${TMPDIR:-/tmp}/pam-tools.$$}"
# `true` is a shell builtin on every POSIX shell and cannot be shadowed by a
# PATH entry, so it is intentionally absent from this list.
PAM_TOOL_APPLETS="${PAM_TOOL_APPLETS:-awk basename cat cksum chmod cp date df dirname du env find grep head mkdir mv nice rm rmdir sed sleep sort stat sync tr uname wc}"
PAM_TOOL_PROVIDER="system"
PAM_TOOL_PROBE_FAILURE=""
PAM_PORTABLE_TOOLS=""
PAM_UNAVAILABLE_TOOLS=""
export PAM_BUSYBOX_PORTABLE

pam_tool_fail() {
  PAM_TOOL_PROBE_FAILURE="$1"
  return 1
}

pam_tool_forced_bad() {
  case ",${PAM_TOOL_TEST_FAIL:-}," in *,"$1",*) return 0 ;; *) return 1 ;; esac
}

pam_tool_smoke_test() {
  local root="${TMPDIR:-/tmp}/pam-tool-probe.$$" output tool
  for tool in $PAM_TOOL_APPLETS; do
    command -v "$tool" >/dev/null 2>&1 || { pam_tool_fail "$tool:missing"; return 1; }
    pam_tool_forced_bad "$tool" && { pam_tool_fail "$tool:probe"; return 1; }
  done

  mkdir -p "$root/nested" 2>/dev/null || { pam_tool_fail mkdir; return 1; }
  printf alpha > "$root/input"
  printf mode > "$root/mode"

  output=$(printf 'a\tb\n' | awk -F '\t' '$1 == "a" { print $2 }')
  [ "$output" = b ] || { pam_tool_fail awk; return 1; }
  [ "$(printf 'alpha\n' | sed -n 's/^alpha$/ok/p')" = ok ] || { pam_tool_fail sed; return 1; }
  printf 'alpha\n' | grep -Fqx alpha || { pam_tool_fail grep; return 1; }
  [ "$(find "$root" -maxdepth 1 -type f -name input -print -quit 2>/dev/null)" = "$root/input" ] || {
    pam_tool_fail find; return 1;
  }
  find "$root" -maxdepth 1 -type f -name mode -exec chmod +x {} + 2>/dev/null && [ -x "$root/mode" ] || {
    pam_tool_fail find-exec; return 1;
  }
  cp -a "$root/input" "$root/copied" 2>/dev/null && [ "$(cat "$root/copied")" = alpha ] || {
    pam_tool_fail cp; return 1;
  }
  mv -f -- "$root/copied" "$root/moved" 2>/dev/null && [ -f "$root/moved" ] || {
    pam_tool_fail mv; return 1;
  }
  printf 'b\na\n' > "$root/unsorted"
  sort -o "$root/sorted" "$root/unsorted" 2>/dev/null && [ "$(head -n 1 "$root/sorted")" = a ] || {
    pam_tool_fail sort; return 1;
  }
  df -Pk "$root" 2>/dev/null | awk 'END { exit !($4 ~ /^[0-9]+$/) }' || { pam_tool_fail df; return 1; }
  du -sk "$root" 2>/dev/null | awk 'NR == 1 { ok=($1 ~ /^[0-9]+$/) } END { exit !ok }' || {
    pam_tool_fail du; return 1;
  }
  [ "$(stat -c %s "$root/input" 2>/dev/null)" = 5 ] || { pam_tool_fail stat; return 1; }
  output=$(date +%s 2>/dev/null)
  case "$output" in ''|*[!0-9]*) pam_tool_fail date; return 1 ;; esac
  read -r output _ < <(printf alpha | cksum 2>/dev/null)
  case "$output" in ''|*[!0-9]*) pam_tool_fail cksum; return 1 ;; esac
  [ "$(dirname /a/b 2>/dev/null)" = /a ] && [ "$(basename /a/b 2>/dev/null)" = b ] || {
    pam_tool_fail path-tools; return 1;
  }
  [ "$(head -c 2 "$root/input" 2>/dev/null)" = al ] &&
    [ "$(tr '[:lower:]' '[:upper:]' < "$root/input")" = ALPHA ] || { pam_tool_fail text-tools; return 1; }
  output=$(wc -c < "$root/input" 2>/dev/null); output=${output//[[:space:]]/}
  [ "$output" = 5 ] || { pam_tool_fail wc; return 1; }
  env true >/dev/null 2>&1 && nice -n 19 true >/dev/null 2>&1 && sleep 0 >/dev/null 2>&1 &&
    [ -n "$(uname -m 2>/dev/null)" ] || { pam_tool_fail process-tools; return 1; }
  mkdir -p "$root/remove/child" && rm -rf -- "$root/remove" && [ ! -e "$root/remove" ] || {
    pam_tool_fail rm; return 1;
  }
  rm -rf -- "$root" 2>/dev/null || { pam_tool_fail rm; return 1; }
}

pam_portable_has_all() {
  local list tool
  [ -x "$PAM_BUSYBOX_PORTABLE" ] && "$PAM_BUSYBOX_PORTABLE" true >/dev/null 2>&1 || return 1
  list=$'\n'"$("$PAM_BUSYBOX_PORTABLE" --list 2>/dev/null)"$'\n'
  for tool in $PAM_TOOL_APPLETS; do
    case "$list" in *$'\n'"$tool"$'\n'*) ;; *) pam_tool_fail "portable-$tool:missing"; return 1 ;; esac
  done
}

pam_toolbox_write() {
  local directory="$1" tool wrapper
  "$PAM_BUSYBOX_PORTABLE" rm -rf -- "$directory" 2>/dev/null || true
  "$PAM_BUSYBOX_PORTABLE" mkdir -p "$directory" 2>/dev/null || return 1
  for tool in $PAM_TOOL_APPLETS; do
    wrapper="$directory/$tool"
    {
      printf '%s\n' '#!/bin/sh'
      printf 'exec "$PAM_BUSYBOX_PORTABLE" %s "$@"\n' "$tool"
    } > "$wrapper" || return 1
    "$PAM_BUSYBOX_PORTABLE" chmod 0755 "$wrapper" || return 1
  done
  PAM_BUSYBOX_PORTABLE="$PAM_BUSYBOX_PORTABLE" "$directory/awk" 'BEGIN { exit 0 }' >/dev/null 2>&1
}

pam_tools_use_portable() {
  local failed_toolbox=""
  pam_portable_has_all || return 1
  if ! pam_toolbox_write "$PAM_TOOLBOX_DIR"; then
    failed_toolbox="$PAM_TOOLBOX_DIR"
    PAM_TOOLBOX_DIR="${PAM_APP_ROOT:-${HOME:-/tmp}}/state/.tools.$$"
    pam_toolbox_write "$PAM_TOOLBOX_DIR" || return 1
    "$PAM_BUSYBOX_PORTABLE" rm -rf -- "$failed_toolbox" 2>/dev/null || true
  fi
  PATH="$PAM_TOOLBOX_DIR:$PAM_TOOL_SYSTEM_PATH"
  PAM_TOOL_PROVIDER=portable
  PAM_PORTABLE_TOOLS="$PAM_TOOL_APPLETS"
  export PATH PAM_TOOLBOX_DIR PAM_TOOL_PROVIDER PAM_PORTABLE_TOOLS
  PAM_TOOL_TEST_FAIL="" pam_tool_smoke_test || return 1
}

pam_tools_cleanup() {
  [ "$PAM_TOOL_PROVIDER" = portable ] || return 0
  "$PAM_BUSYBOX_PORTABLE" rm -rf -- "$PAM_TOOLBOX_DIR" 2>/dev/null || true
}

pam_tools_init() {
  case "$PAM_TOOL_MODE" in auto|system|portable) ;; *) PAM_TOOL_MODE=auto ;; esac
  PATH="$PAM_TOOL_SYSTEM_PATH"
  export PATH
  case "$PAM_TOOL_MODE" in
    system)
      PAM_TOOL_PROVIDER=system
      ;;
    portable)
      pam_tools_use_portable || PAM_UNAVAILABLE_TOOLS="${PAM_TOOL_PROBE_FAILURE:-portable}"
      ;;
    auto)
      if pam_tool_smoke_test; then
        PAM_TOOL_PROVIDER=system
      else
        pam_tools_use_portable || PAM_UNAVAILABLE_TOOLS="${PAM_TOOL_PROBE_FAILURE:-portable}"
      fi
      ;;
  esac
  export PAM_TOOL_PROVIDER PAM_PORTABLE_TOOLS PAM_TOOL_PROBE_FAILURE PAM_UNAVAILABLE_TOOLS
  if [ -n "$PAM_UNAVAILABLE_TOOLS" ]; then
    pam_tools_cleanup
    PAM_TOOL_PROVIDER=unavailable
    export PAM_TOOL_PROVIDER
    return 1
  fi
}
