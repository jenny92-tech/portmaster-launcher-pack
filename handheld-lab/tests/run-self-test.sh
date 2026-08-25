#!/bin/sh
set -eu

component_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)

python3 -m unittest discover -s "$component_root/tests" -v
python3 -m py_compile "$component_root/handheld_lab.py"

for script in \
    "$component_root/devtools" \
    "$component_root/agent/handheld-agent.sh" \
    "$component_root/helpers/"*.sh \
    "$component_root/toolbox/"*.sh \
    "$component_root/tests/"*.sh; do
    [ "$script" = "$component_root/tests/run-self-test.sh" ] || sh -n "$script"
done

"$component_root/devtools" --transport local probe >/dev/null
printf 'Handheld DevTools self-test: PASS\n'
