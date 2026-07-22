#!/usr/bin/env bash
# Build the self-contained native helpers shipped by Port App Manager.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${PAM_NATIVE_TARGET:-aarch64-unknown-linux-musl}"
OUT="$ROOT/ports/appmanager/portable/bin"
REVISION_FILE="$ROOT/ports/appmanager/native-revision.txt"

case "$TARGET" in
  aarch64-unknown-linux-musl) ;;
  *)
    echo "unsupported Port App Manager target: $TARGET" >&2
    exit 64
    ;;
esac

rustup target list --installed | grep -Fxq "$TARGET" || {
  echo "Rust target is not installed: $TARGET" >&2
  echo "Install it with: rustup target add $TARGET" >&2
  exit 69
}

# macOS `cc` invokes the Mach-O linker even for a Linux Rust target. Rust ships
# an ELF-capable lld beside the active toolchain, so use it directly when the
# caller has not supplied a cross linker. Linux builders keep their normal
# target linker.
if [ "$(uname -s)" = "Darwin" ] &&
   [ -z "${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER:-}" ] &&
   [ "$TARGET" = "aarch64-unknown-linux-musl" ]; then
  RUST_LLD="$(rustc --print sysroot)/lib/rustlib/aarch64-apple-darwin/bin/rust-lld"
  [ -x "$RUST_LLD" ] || { echo "Rust ELF linker is unavailable: $RUST_LLD" >&2; exit 69; }
  export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_LINKER="$RUST_LLD"
fi

# The static HTTPS transport (ureq + rustls) pulls in `ring`, which builds
# C/asm and therefore needs a musl C cross-compiler for this target. Detect a
# standard one or honor an explicit override; cc-rs reads the CARGO_TARGET_
# CC/AR passthroughs set below.
MUSL_CC="${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_CC:-${CC_aarch64_unknown_linux_musl:-}}"
MUSL_AR="${CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_AR:-${AR_aarch64_unknown_linux_musl:-}}"
if [ -z "$MUSL_CC" ]; then
  for candidate in aarch64-linux-musl-gcc aarch64-unknown-linux-musl-gcc aarch64-linux-musl-cc; do
    command -v "$candidate" >/dev/null 2>&1 && { MUSL_CC="$candidate"; break; }
  done
fi
if [ -z "$MUSL_AR" ]; then
  for candidate in aarch64-linux-musl-ar aarch64-unknown-linux-musl-ar llvm-ar; do
    command -v "$candidate" >/dev/null 2>&1 && { MUSL_AR="$candidate"; break; }
  done
fi
[ -n "$MUSL_CC" ] || {
  echo "Native HTTPS (rustls/ring) needs a musl C cross-compiler for $TARGET." >&2
  echo "Install one, e.g. on macOS: brew install messense/macos-cross-toolchains/aarch64-unknown-linux-musl" >&2
  echo "or set CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_CC / _AR." >&2
  exit 69
}
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_CC="$MUSL_CC"
[ -z "$MUSL_AR" ] || export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_AR="$MUSL_AR"

cargo build \
  --manifest-path "$ROOT/Cargo.toml" \
  --locked \
  --release \
  --target "$TARGET" \
  -p portkit-cli \
  -p appmanager-cli

mkdir -p "$OUT"
install -m 0755 "$ROOT/target/$TARGET/release/portkit" "$OUT/portkit"
install -m 0755 "$ROOT/target/$TARGET/release/appmanager-cli" "$OUT/appmanager-cli"
python3 "$ROOT/_kit/appmanager_native_revision.py" "$ROOT" > "$REVISION_FILE"

for binary in "$OUT/portkit" "$OUT/appmanager-cli"; do
  description=$(file "$binary")
  case "$description" in
    *ELF*ARM\ aarch64*statically\ linked*) ;;
    *) echo "native helper is not a static aarch64 ELF: $description" >&2; exit 65 ;;
  esac
done
file "$OUT/portkit" "$OUT/appmanager-cli"
