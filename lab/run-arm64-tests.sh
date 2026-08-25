#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RUST_IMAGE=${PAM_LAB_RUST_IMAGE:-rust:1.88-slim-bullseye}
CARGO_VOLUME=${PAM_LAB_CARGO_VOLUME:-pam-lab-cargo-registry}
TARGET_VOLUME=${PAM_LAB_TARGET_VOLUME:-pam-lab-target-arm64}

usage() {
  echo "usage: $0 [smoke|config|all|size]" >&2
  exit 64
}

run_cargo_test() {
  docker run --rm --platform linux/arm64 \
    --volume "$REPO_ROOT:/workspace:ro" \
    --volume "$TARGET_VOLUME:/workspace/target" \
    --volume "$CARGO_VOLUME:/usr/local/cargo/registry" \
    --workdir /workspace \
    "$RUST_IMAGE" \
    cargo test --locked -q "$@"
}

command -v docker >/dev/null 2>&1 || {
  echo "docker is required" >&2
  exit 69
}

mkdir -p "$REPO_ROOT/target"
docker volume create "$CARGO_VOLUME" >/dev/null
docker volume create "$TARGET_VOLUME" >/dev/null

case "${1:-smoke}" in
  smoke)
    run_cargo_test \
      -p appmanager-service \
      real_http_server_pairs_and_returns_an_authenticated_snapshot
    ;;
  config)
    run_cargo_test -p portkit-core --test config_contract
    ;;
  all)
    run_cargo_test \
      -p appmanager-service \
      real_http_server_pairs_and_returns_an_authenticated_snapshot
    run_cargo_test -p portkit-core --test config_contract
    ;;
  size)
    docker system df
    ;;
  *)
    usage
    ;;
esac
