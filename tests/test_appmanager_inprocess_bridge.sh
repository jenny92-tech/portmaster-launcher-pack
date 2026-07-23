#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LOVE="$ROOT/ports/appmanager/love"
RUST="$ROOT/crates/love-lite/src"

for file in main.lua app_operations.lua app_environment.lua app_model.lua; do
  if grep -Eq 'os\.execute|io\.popen' "$LOVE/$file"; then
    echo "$file still starts an external process" >&2
    exit 1
  fi
done

if grep -Eq 'plan_file|result_file|progress_file|validation_result_file|config_refresh_result' \
  "$LOVE/main.lua" "$LOVE/app_operations.lua" "$LOVE/app_environment.lua"; then
  echo "Lua still uses files as an APP Manager task bus" >&2
  exit 1
fi

grep -Fq 'model.native.start' "$LOVE/app_operations.lua"
grep -Fq 'model.native.poll' "$LOVE/main.lua"
grep -Fq 'appmanager.start' "$LOVE/app_native.lua"
grep -Fq 'appmanager.poll' "$LOVE/app_native.lua"
grep -Fq 'install_appmanager_api' "$RUST/lib.rs"
grep -Fq 'CancellationToken' "$ROOT/crates/appmanager-cli/src/launcher.rs"
grep -Fq 'ProgressChannel' "$ROOT/crates/appmanager-cli/src/launcher.rs"
! sed -n '/pub fn cancel/,/^    }/p' "$ROOT/crates/appmanager-cli/src/launcher.rs" | grep -Fq 'write_text'

echo "APP Manager Lua/Rust in-process bridge contract passed"
