#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SYSTEM_PATH=$PATH

cat > "$TMP/fake-busybox" <<'EOF'
#!/usr/bin/env bash
set -e
applet=${1:-}
shift || true
if [ "$applet" = --list ]; then
  printf '%s\n' awk basename cat cksum chmod cp date df dirname du env find grep head mkdir mv nice rm rmdir sed sleep sort stat sync tr true uname wc
  exit 0
fi
if [ "$applet" = stat ] && [ "${1:-}" = -c ] && [ "${2:-}" = %s ] && [ "$#" = 3 ]; then
  wc -c < "$3" | tr -d '[:space:]'
  exit 0
fi
PATH=$PAM_TEST_REAL_PATH
export PATH
exec "$applet" "$@"
EOF
chmod +x "$TMP/fake-busybox"

run_auto_probe() (
  export PAM_TEST_REAL_PATH="$SYSTEM_PATH"
  export PAM_BIN_DIR="$TMP/unused"
  export PAM_BUSYBOX_PORTABLE_OVERRIDE="$TMP/fake-busybox"
  export PAM_TOOLBOX_DIR_OVERRIDE="$TMP/auto-tools"
  export PAM_TOOL_TEST_FAIL=awk,find
  source "$ROOT/_kit/portable_tools.sh"
  pam_tools_init
  trap pam_tools_cleanup EXIT

  [ "$PAM_TOOL_PROVIDER" = portable ]
  [ "$PAM_TOOL_PROBE_FAILURE" = "awk:probe" ]
  for tool in awk find sed grep cp mv rm rmdir; do
    case "$(command -v "$tool")" in "$PAM_TOOLBOX_DIR"/*) ;; *) exit 1 ;; esac
  done
  [ "$(printf 'a\tb\n' | awk -F '\t' '$1 == "a" { print $2 }')" = b ]
  probe="$TMP/find-probe"
  mkdir -p "$probe"
  printf x > "$probe/file"
  [ "$(find "$probe" -type f -print -quit)" = "$probe/file" ]
)

run_portable_mode() (
  export PAM_TEST_REAL_PATH="$SYSTEM_PATH"
  export PAM_BIN_DIR="$TMP/unused"
  export PAM_BUSYBOX_PORTABLE_OVERRIDE="$TMP/fake-busybox"
  export PAM_TOOLBOX_DIR_OVERRIDE="$TMP/portable-tools"
  export PAM_TOOL_MODE=portable
  source "$ROOT/_kit/portable_tools.sh"
  pam_tools_init
  trap pam_tools_cleanup EXIT

  [ "$PAM_TOOL_PROVIDER" = portable ]
  for tool in awk sed grep find cp mv rm rmdir; do
    case "$(command -v "$tool")" in "$PAM_TOOLBOX_DIR"/*) ;; *) exit 1 ;; esac
  done
)

run_auto_probe
[ ! -e "$TMP/auto-tools" ]
run_portable_mode
[ ! -e "$TMP/portable-tools" ]

echo "portable tool adapter tests: PASS"
