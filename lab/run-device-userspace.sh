#!/usr/bin/env bash
# INPUT:  Docker、预置 App Manager、设备运行库与 prepare_device_fixture.py
# OUTPUT: verify/smoke/all 动态依赖与首帧验证结果
# POS:    用采集的固件用户态检查 App Manager 二进制启动兼容性
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${PAM_LAB_BASE_IMAGE:-debian:bullseye-slim}

usage() {
  echo "usage: $0 [verify|smoke|all] [trimui|miniloong|all]" >&2
  exit 64
}

run_profile() {
  local mode=$1
  local profile=$2
  local userspace="$REPO_ROOT/.pam-lab/userspace/$profile"
  local libs="$userspace/runtime-libs"
  local manifest="$userspace/runtime-libs.json"
  local binary="$REPO_ROOT/ports/appmanager/portable/runtime/love.aarch64"
  local fixture="$REPO_ROOT/.pam-lab/fixtures/$profile"
  local launcher

  [[ -x "$libs/ld-linux-aarch64.so.1" && -f "$manifest" ]] || {
    echo "missing collected userspace for $profile" >&2
    return 69
  }

  if [[ "$mode" == verify || "$mode" == all ]]; then
    docker run --rm --platform linux/arm64 \
      --volume "$REPO_ROOT:/repo:ro" \
      "$IMAGE" \
      "/repo/.pam-lab/userspace/$profile/runtime-libs/ld-linux-aarch64.so.1" \
      --library-path "/repo/.pam-lab/userspace/$profile/runtime-libs" \
      --list /repo/ports/appmanager/portable/runtime/love.aarch64
  fi

  if [[ "$mode" == smoke || "$mode" == all ]]; then
    launcher=$(python3 "$REPO_ROOT/lab/prepare_device_fixture.py" \
      --profile "$profile" \
      --output "$fixture" \
      --runtime-manifest "$manifest")
    docker run --rm --platform linux/arm64 --network none \
      --volume "$REPO_ROOT:/repo:ro" \
      --volume "$fixture:/device:ro" \
      --env "PAM_LAB_PROFILE=$profile" \
      --env "PAM_LAB_LAUNCHER=$launcher" \
      "$IMAGE" \
      sh /repo/lab/userspace-container-smoke.sh
  fi
}

command -v docker >/dev/null 2>&1 || {
  echo "docker is required" >&2
  exit 69
}

mode=${1:-all}
target=${2:-all}
[[ "$mode" == verify || "$mode" == smoke || "$mode" == all ]] || usage
[[ "$target" == trimui || "$target" == miniloong || "$target" == all ]] || usage

if [[ "$target" == all ]]; then
  run_profile "$mode" trimui
  run_profile "$mode" miniloong
else
  run_profile "$mode" "$target"
fi
