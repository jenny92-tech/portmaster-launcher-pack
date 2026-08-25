#!/bin/sh
set -eu

exec "${PAM_LAB_DEVICE_LOADER:?}" \
    --library-path "${PAM_LAB_DEVICE_LIBS:?}" \
    "${PAM_LAB_GPTOKEYB_REAL:?}" "$@"
