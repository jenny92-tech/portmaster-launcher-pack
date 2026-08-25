#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RUST_IMAGE=${PAM_LAB_RUST_IMAGE:-rust:1.88-slim-bullseye}
CARGO_VOLUME=${PAM_LAB_CARGO_VOLUME:-pam-lab-cargo-registry}
TARGET_VOLUME=${PAM_LAB_TARGET_VOLUME:-pam-lab-target-arm64}

usage() {
  echo "usage: $0 [trimui|miniloong|all] [all|suite|e2e|ui]" >&2
  exit 64
}

run_profile() {
  local profile=$1
  local userspace="$REPO_ROOT/.pam-lab/userspace/$profile"
  local libs="$userspace/runtime-libs"
  local manifest="$userspace/runtime-libs.json"
  local fixture="$REPO_ROOT/.pam-lab/function-fixtures/${profile}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  local card_root device_card_root launcher runner

  [[ -x "$libs/ld-linux-aarch64.so.1" && -f "$manifest" ]] || {
    echo "missing collected userspace for $profile" >&2
    return 69
  }
  case "$profile" in
    trimui) device_card_root=/mnt/SDCARD ;;
    miniloong) device_card_root=/mnt/sdcard ;;
    *) usage ;;
  esac
  card_root="/device${device_card_root}"

  launcher=$(python3 "$REPO_ROOT/lab/prepare_device_fixture.py" \
    --profile "$profile" \
    --output "$fixture" \
    --runtime-manifest "$manifest" \
    --card-root "$device_card_root")
  runner=/workspace/lab/device-cargo-runner.sh

  if [[ "$scope" == all || "$scope" == suite ]]; then
    echo "=== $profile: complete Rust business-logic suite under collected loader/libc ==="
    docker run --rm --platform linux/arm64 --shm-size 256m \
      --volume "$REPO_ROOT:/workspace:ro" \
      --volume "$TARGET_VOLUME:/workspace/target" \
      --volume "$CARGO_VOLUME:/usr/local/cargo/registry" \
      --workdir /workspace \
      --env "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUNNER=$runner" \
      --env "PAM_LAB_USERSPACE_PROFILE=$profile" \
      "$RUST_IMAGE" \
      cargo test --locked --target aarch64-unknown-linux-gnu \
        -p appmanager-core -p appmanager-service -p portkit-core
  fi

  if [[ "$scope" == all || "$scope" == e2e ]]; then
    echo "=== $profile: Config-resolved public service, ZIP, file, launch, and HTTP E2E ==="
    docker run --rm --platform linux/arm64 --network bridge --shm-size 256m \
      --volume "$REPO_ROOT:/workspace:ro" \
      --volume "$TARGET_VOLUME:/workspace/target" \
      --volume "$CARGO_VOLUME:/usr/local/cargo/registry" \
      --volume "$fixture:/device" \
      --workdir /workspace \
      --env "CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_RUNNER=$runner" \
      --env "PAM_LAB_USERSPACE_PROFILE=$profile" \
      --env "PAM_LAB_PROFILE=$profile" \
      --env "PAM_NATIVE_ROOT=/device" \
      --env "PAM_LAB_LAUNCHER=$launcher" \
      --env "PAM_LAB_CARD_ROOT=$card_root" \
      "$RUST_IMAGE" \
      cargo test --locked --target aarch64-unknown-linux-gnu \
        -p appmanager-service --test device_profile_e2e -- --nocapture
  fi

  if [[ "$scope" == all || "$scope" == ui ]]; then
    echo "=== $profile: full UI process reaches first rendered frame ==="
    "$REPO_ROOT/lab/run-device-userspace.sh" smoke "$profile"
  fi
}

command -v docker >/dev/null 2>&1 || {
  echo "docker is required" >&2
  exit 69
}

target=${1:-all}
scope=${2:-all}
[[ "$target" == trimui || "$target" == miniloong || "$target" == all ]] || usage
[[ "$scope" == all || "$scope" == suite || "$scope" == e2e || "$scope" == ui ]] || usage
mkdir -p "$REPO_ROOT/.pam-lab/function-fixtures" "$REPO_ROOT/target"
docker volume create "$CARGO_VOLUME" >/dev/null
docker volume create "$TARGET_VOLUME" >/dev/null

if [[ "$scope" == all || "$scope" == ui ]]; then
  echo "=== shared APP Manager Lua/UI contracts ==="
  PAM_REQUIRE_LUPA=1 python3 "$REPO_ROOT/tests/test_appmanager_environment_ui.py"
  "$REPO_ROOT/tests/test_appmanager_ui_runtime_scope.sh"
  bash "$REPO_ROOT/_kit/dist_port.sh" appmanager >/dev/null
fi

if [[ "$target" == all ]]; then
  run_profile trimui
  run_profile miniloong
else
  run_profile "$target"
fi
