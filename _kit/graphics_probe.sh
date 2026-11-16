#!/bin/bash
# INPUT: Audited native probe, optional engine probe argv, child-only graphics plan.
# OUTPUT: Actual SDL output geometry and success only after all supplied probes pass.
# POS: Adapter between shared environment selection and an engine's own validation.
set -eu
probe="${1:?native graphics probe is required}"
shift
if [ -n "${RUDROID_VULKAN_WSI_LIBRARY:-}" ]; then
    "$probe" --wsi "$RUDROID_VULKAN_WSI_LIBRARY" --layer VK_LAYER_RUDROID_wayland
else
    "$probe"
fi
if [ "$#" -gt 0 ]; then
    [ "$1" = --engine ] && [ "$#" -gt 1 ] || exit 64
    shift
    exec "$@"
fi
