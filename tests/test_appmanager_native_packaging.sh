#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${PAM_NATIVE_TARGET:-aarch64-unknown-linux-musl}"

if PAM_NATIVE_TARGET=aarch64-unknown-linux-gnu bash "$ROOT/_kit/build_appmanager_native.sh" >/dev/null 2>&1; then
  echo "native builder accepted a firmware-glibc target" >&2
  exit 1
fi

# The static HTTPS transport needs a musl C cross-compiler (ring). Skip the
# build on machines that do not have one; the structural glibc-rejection check
# above still runs unconditionally.
if [ -z "${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_CC:-}" ] &&
   [ -z "${CC_aarch64_unknown_linux_musl:-}" ] &&
   ! command -v aarch64-linux-musl-gcc >/dev/null 2>&1 &&
   ! command -v aarch64-unknown-linux-musl-gcc >/dev/null 2>&1; then
  echo "appmanager native packaging tests: SKIP (no aarch64 musl C cross-compiler)"
  exit 0
fi

bash "$ROOT/_kit/build_appmanager_native.sh" >/dev/null

for binary in portkit appmanager-cli; do
  path="$ROOT/ports/appmanager/portable/bin/$binary"
  [ -x "$path" ] || { echo "native helper is missing: $binary" >&2; exit 1; }
  file "$path" | grep -Fq 'ARM aarch64' || {
    echo "native helper is not an aarch64 executable: $binary" >&2
    exit 1
  }
done

expected_revision=$(python3 "$ROOT/_kit/appmanager_native_revision.py" "$ROOT")
[ "$(sed -n '1p' "$ROOT/ports/appmanager/native-revision.txt")" = "$expected_revision" ] || {
  echo "native helper revision does not match current sources" >&2
  exit 1
}

if file "$ROOT/ports/appmanager/portable/bin/portkit" | grep -Fq 'dynamically linked'; then
  echo "portkit must not depend on firmware glibc" >&2
  exit 1
fi
if file "$ROOT/ports/appmanager/portable/bin/appmanager-cli" | grep -Fq 'dynamically linked'; then
  echo "appmanager-cli must not depend on firmware glibc" >&2
  exit 1
fi

echo "appmanager native packaging tests: PASS"
