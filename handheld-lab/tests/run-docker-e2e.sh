#!/bin/sh
# INPUT:  运行态容器、I/O 容器、handheld_lab.py 与控制场景 JSON
# OUTPUT: 能力、事件、截图和诊断等端到端验证产物
# POS:    验证跨容器能力路由、持久输入与可见帧缓冲采集
set -eu

component_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
runtime=${1:-}
io=${2:-}
artifacts=${3:-"$component_root/artifacts/docker-e2e"}

[ -n "$runtime" ] && [ -n "$io" ] || {
    printf 'usage: %s RUNTIME_CONTAINER IO_CONTAINER [ARTIFACTS_DIR]\n' "$0" >&2
    exit 64
}

mkdir -p "$artifacts"

controller() {
    python3 "$component_root/handheld_lab.py" \
        --transport docker --endpoint "$runtime" --io-endpoint "$io" "$@"
}

io_controller() {
    python3 "$component_root/handheld_lab.py" \
        --transport docker --endpoint "$io" "$@"
}

cleanup_input() {
    io_controller input-stop >/dev/null 2>&1 || true
}
trap cleanup_input EXIT INT TERM

controller probe >"$artifacts/capabilities.json"
controller process 1 >"$artifacts/process-1.txt"
controller input-start --mode gamepad >"$artifacts/input-start.txt"

io_controller start --log /tmp/handheld-devtools-e2e-input.log -- \
    handheld-event "Handheld DevTools Virtual gamepad" 30000 4 \
    >"$artifacts/input-observer-pid.txt"
controller input south --hold-ms 120
sleep 1
io_controller exec -- grep -Fq "event type=1 code=304 value=1" \
    /tmp/handheld-devtools-e2e-input.log
io_controller exec -- grep -Fq "event type=1 code=304 value=0" \
    /tmp/handheld-devtools-e2e-input.log
io_controller exec -- sed -n 1,20p /tmp/handheld-devtools-e2e-input.log \
    >"$artifacts/input-events.txt"

controller capture "$artifacts/screen.png"
controller diagnose --output "$artifacts/evidence" --pid 1 \
    >"$artifacts/evidence-path.txt"
controller scenario "$component_root/scenarios/controller-smoke.json" \
    --artifacts "$artifacts/scenarios" >"$artifacts/scenario-path.txt"

cleanup_input
trap - EXIT INT TERM
printf 'PASS runtime=%s io=%s artifacts=%s\n' "$runtime" "$io" "$artifacts"
