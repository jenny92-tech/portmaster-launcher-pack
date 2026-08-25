#!/bin/sh
set -eu

binary=${1:?missing Cargo test executable}
shift
libs="/workspace/.pam-lab/userspace/${PAM_LAB_USERSPACE_PROFILE:?}/runtime-libs"
export PAM_LAB_TEST_EXECUTABLE="$binary"
exec "$libs/ld-linux-aarch64.so.1" --library-path "$libs" "$binary" "$@"
