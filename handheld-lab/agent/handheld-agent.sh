#!/bin/sh
# INPUT:  POSIX sh、Linux 系统接口及探测到的输入/截图/调试 provider
# OUTPUT: 能力 TSV 与 snapshot/process/input/capture/scenario 所需命令结果
# POS:    为主机控制器提供低依赖的通用掌机探针与动作接口
# System-level Handheld DevTools Probe. Keep this POSIX sh and dependency-light.

set -eu

has() {
    command -v "$1" >/dev/null 2>&1
}

section() {
    printf '\n===== %s =====\n' "$1"
}

capability() {
    # Stable TSV: capability, available, provider, detail.
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"
}

input_helper() {
    if has handheld-input && [ -w /dev/uinput ] && handheld-input probe >/dev/null 2>&1; then
        command -v handheld-input
        return 0
    fi
    return 1
}

input_provider() {
    if [ -n "${HANDHELD_DEVTOOLS_INPUT_HELPER:-}" ] && [ -x "$HANDHELD_DEVTOOLS_INPUT_HELPER" ]; then
        printf '%s\n' configured-helper
    elif input_helper >/dev/null 2>&1; then
        printf '%s\n' uinput-helper
    elif has xdotool && [ -n "${DISPLAY:-}" ]; then
        printf '%s\n' xdotool
    elif has wtype && [ -n "${WAYLAND_DISPLAY:-}" ]; then
        printf '%s\n' wtype
    else
        return 1
    fi
}

input_state_dir() {
    printf '%s\n' "${HANDHELD_DEVTOOLS_STATE_DIR:-/tmp/handheld-devtools}"
}

capture_provider() {
    if [ -n "${HANDHELD_DEVTOOLS_CAPTURE_HELPER:-}" ] && [ -x "$HANDHELD_DEVTOOLS_CAPTURE_HELPER" ]; then
        printf '%s\n' configured-helper
    elif has grim && [ -n "${WAYLAND_DISPLAY:-}" ]; then
        printf '%s\n' grim
    elif has import && [ -n "${DISPLAY:-}" ]; then
        printf '%s\n' imagemagick
    elif has fbgrab && [ -r /dev/fb0 ]; then
        printf '%s\n' fbgrab
    elif has handheld-fbshot && [ -r /dev/fb0 ]; then
        printf '%s\n' handheld-fbshot
    elif has ffmpeg && [ -d /dev/dri ]; then
        for lab_card in /dev/dri/card*; do
            if [ -r "$lab_card" ]; then
                printf '%s\n' ffmpeg-kms
                return 0
            fi
        done
        return 1
    else
        return 1
    fi
}

core_provider() {
    if has gdb; then
        printf '%s\n' gdb
    elif has gcore; then
        printf '%s\n' gcore
    else
        return 1
    fi
}

render_provider() {
    if has drm_info; then
        printf '%s\n' drm_info
    elif has modetest; then
        printf '%s\n' modetest
    elif [ -d /sys/class/drm ]; then
        printf '%s\n' drm-sysfs
    elif has xrandr && [ -n "${DISPLAY:-}" ]; then
        printf '%s\n' xrandr
    elif has fbset && [ -r /dev/fb0 ]; then
        printf '%s\n' fbset
    else
        return 1
    fi
}

cmd_capabilities() {
    capability exec yes posix-sh "argument-vector command execution"
    capability file-transfer yes controller "transport-owned push and pull"
    if [ -r /proc/self/status ]; then
        capability process-observe yes procfs "status maps smaps threads"
        capability memory-observe yes procfs "bounded accounting and mappings"
    else
        capability process-observe no none "procfs unavailable"
        capability memory-observe no none "procfs unavailable"
    fi

    if has handheld-event && [ -r /proc/bus/input/devices ]; then
        capability input-observe yes handheld-event "bounded evdev event observation"
    elif [ -r /proc/bus/input/devices ]; then
        capability input-observe yes procfs "inventory only"
    else
        capability input-observe no none "input inventory unavailable"
    fi

    lab_provider=$(input_provider 2>/dev/null || true)
    if [ -n "$lab_provider" ]; then
        capability input yes "$lab_provider" "system input injection"
    else
        capability input no none "no input provider"
    fi

    lab_provider=$(capture_provider 2>/dev/null || true)
    if [ -n "$lab_provider" ]; then
        capability capture yes "$lab_provider" "actual target output"
    else
        capability capture no none "no readable capture provider"
    fi

    lab_provider=$(render_provider 2>/dev/null || true)
    if [ -n "$lab_provider" ]; then
        capability render-observe yes "$lab_provider" "display and plane facts"
    else
        capability render-observe no none "no render provider"
    fi

    lab_provider=$(core_provider 2>/dev/null || true)
    if [ -n "$lab_provider" ]; then
        capability core-dump yes "$lab_provider" "explicit process core dump"
    else
        capability core-dump no none "gcore and gdb unavailable"
    fi

    if has strace; then
        capability syscall-trace yes strace "explicit bounded attach"
    else
        capability syscall-trace no none "strace unavailable"
    fi

    lab_tools=""
    for lab_tool in cc gcc clang make cmake ninja cargo rustc python3; do
        if has "$lab_tool"; then
            lab_tools="${lab_tools}${lab_tools:+,}$lab_tool"
        fi
    done
    if [ -n "$lab_tools" ]; then
        capability toolchain yes inventory "$lab_tools"
    else
        capability toolchain no none "no compiler or build tool"
    fi
}

show_file() {
    lab_path=$1
    lab_lines=$2
    if [ -r "$lab_path" ]; then
        printf '\n--- %s ---\n' "$lab_path"
        sed -n "1,${lab_lines}p" "$lab_path"
    fi
}

cmd_snapshot() {
    section identity
    uname -a 2>&1 || true
    id 2>&1 || true
    show_file /etc/os-release 80
    if [ -r /proc/device-tree/model ]; then
        printf 'model='
        tr '\000' '\n' </proc/device-tree/model 2>/dev/null | sed -n '1p'
    fi

    section runtime
    show_file /proc/uptime 5
    show_file /proc/loadavg 5
    show_file /proc/meminfo 80

    section mounts
    if [ -r /proc/mounts ]; then
        awk '{print $1, $2, $3, $4}' /proc/mounts | sed -n '1,240p'
    fi

    section storage
    df -P 2>&1 | sed -n '1,160p' || true

    section network
    if has ip; then
        ip -brief address 2>&1 | sed -n '1,120p' || true
        ip route 2>&1 | sed -n '1,120p' || true
    elif has ifconfig; then
        ifconfig 2>&1 | sed -n '1,160p' || true
    else
        printf 'network inventory tool unavailable\n'
    fi

    section processes
    ps 2>&1 | sed -n '1,240p' || true

    section devices
    for lab_path in /dev/uinput /dev/input /dev/dri /dev/fb0 /dev/mali0 /dev/snd; do
        if [ -e "$lab_path" ]; then
            ls -ld "$lab_path" 2>&1 || true
        else
            printf 'missing %s\n' "$lab_path"
        fi
    done
    for lab_dir in /dev/input /dev/dri /dev/snd; do
        if [ -d "$lab_dir" ]; then
            ls -la "$lab_dir" 2>&1 | sed -n '1,100p'
        fi
    done

    section capabilities
    cmd_capabilities
}

cmd_input_info() {
    show_file /proc/bus/input/devices 1600
    if [ -d /sys/class/input ]; then
        for lab_input in /sys/class/input/input*; do
            [ -d "$lab_input" ] || continue
            printf '\n--- %s ---\n' "$lab_input"
            show_file "$lab_input/name" 5
            show_file "$lab_input/id/bustype" 5
            show_file "$lab_input/id/vendor" 5
            show_file "$lab_input/id/product" 5
        done
    fi
}

cmd_input_watch() {
    has handheld-event || {
        printf 'event observation requires handheld-event helper\n' >&2
        return 69
    }
    lab_name=${1:-}
    [ -n "$lab_name" ] || { printf 'input name required\n' >&2; return 64; }
    handheld-event "$lab_name" "${2:-5000}" "${3:-4}"
}

valid_pid() {
    case ${1:-} in
        ''|*[!0-9]*) return 1 ;;
        *) [ "$1" -gt 0 ] 2>/dev/null ;;
    esac
}

cmd_process() {
    lab_pid=${1:-}
    valid_pid "$lab_pid" || {
        printf 'invalid PID\n' >&2
        return 64
    }
    [ -d "/proc/$lab_pid" ] || {
        printf 'PID not found: %s\n' "$lab_pid" >&2
        return 66
    }
    section status
    show_file "/proc/$lab_pid/status" 240
    section stat
    show_file "/proc/$lab_pid/stat" 10
    section memory-accounting
    show_file "/proc/$lab_pid/smaps_rollup" 240
    section memory-map
    show_file "/proc/$lab_pid/maps" 1200
    section threads
    if [ -d "/proc/$lab_pid/task" ]; then
        for lab_task in "/proc/$lab_pid/task"/*; do
            [ -d "$lab_task" ] || continue
            lab_tid=${lab_task##*/}
            lab_name=$(sed -n 's/^Name:[[:space:]]*//p' "$lab_task/status" 2>/dev/null | sed -n '1p')
            lab_state=$(sed -n 's/^State:[[:space:]]*//p' "$lab_task/status" 2>/dev/null | sed -n '1p')
            printf 'tid=%s name=%s state=%s\n' "$lab_tid" "$lab_name" "$lab_state"
        done | sed -n '1,1000p'
    fi
}

cmd_render_info() {
    lab_provider=$(render_provider 2>/dev/null || true)
    case $lab_provider in
        drm_info)
            drm_info 2>&1 | sed -n '1,2400p'
            ;;
        modetest)
            modetest -p 2>&1 | sed -n '1,2400p'
            ;;
        drm-sysfs)
            for lab_entry in /sys/class/drm/*; do
                [ -e "$lab_entry" ] || continue
                printf '\n--- %s ---\n' "$lab_entry"
                for lab_fact in status enabled modes mode dpms; do
                    show_file "$lab_entry/$lab_fact" 120
                done
            done
            for lab_state in /sys/kernel/debug/dri/*/state; do
                [ -r "$lab_state" ] || continue
                show_file "$lab_state" 2400
            done
            ;;
        xrandr)
            xrandr --verbose 2>&1 | sed -n '1,2400p'
            ;;
        fbset)
            fbset -i 2>&1 | sed -n '1,400p'
            ;;
        *)
            printf 'render observation unsupported\n' >&2
            return 69
            ;;
    esac
}

normalized_button() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '-' '_'
}

xdotool_key() {
    case $1 in
        dpad_up|up) printf '%s\n' Up ;;
        dpad_down|down) printf '%s\n' Down ;;
        dpad_left|left) printf '%s\n' Left ;;
        dpad_right|right) printf '%s\n' Right ;;
        south|confirm) printf '%s\n' Return ;;
        east|cancel) printf '%s\n' Escape ;;
        start) printf '%s\n' Return ;;
        select) printf '%s\n' space ;;
        *) return 1 ;;
    esac
}

cmd_input() {
    lab_button=$(normalized_button "${1:-}")
    lab_hold=${2:-80}
    case $lab_hold in
        ''|*[!0-9]*) printf 'invalid hold time\n' >&2; return 64 ;;
    esac
    [ "$lab_hold" -le 10000 ] || { printf 'hold time exceeds 10000 ms\n' >&2; return 64; }
    lab_provider=$(input_provider 2>/dev/null || true)
    case $lab_provider in
        configured-helper)
            "$HANDHELD_DEVTOOLS_INPUT_HELPER" tap "$lab_button" "$lab_hold"
            ;;
        uinput-helper)
            lab_helper=$(input_helper)
            lab_state=$(input_state_dir)
            lab_fifo="$lab_state/input.fifo"
            lab_pid_file="$lab_state/input.pid"
            lab_pid=""
            [ -r "$lab_pid_file" ] && lab_pid=$(sed -n '1p' "$lab_pid_file")
            if [ -n "$lab_pid" ] && kill -0 "$lab_pid" 2>/dev/null && [ -p "$lab_fifo" ]; then
                printf '%s %s\n' "$lab_button" "$lab_hold" >"$lab_fifo"
            else
                "$lab_helper" tap "$lab_button" "$lab_hold" "${HANDHELD_DEVTOOLS_INPUT_MODE:-gamepad}"
            fi
            ;;
        xdotool)
            lab_key=$(xdotool_key "$lab_button") || {
                printf 'button not mapped by xdotool provider: %s\n' "$lab_button" >&2
                return 65
            }
            xdotool key --clearmodifiers "$lab_key"
            ;;
        wtype)
            lab_key=$(xdotool_key "$lab_button") || {
                printf 'button not mapped by wtype provider: %s\n' "$lab_button" >&2
                return 65
            }
            wtype -k "$lab_key"
            ;;
        *)
            printf 'input injection unsupported\n' >&2
            return 69
            ;;
    esac
}

cmd_input_start() {
    lab_provider=$(input_provider 2>/dev/null || true)
    [ "$lab_provider" = uinput-helper ] || {
        printf 'persistent input requires writable uinput and handheld-input helper\n' >&2
        return 69
    }
    lab_helper=$(input_helper 2>/dev/null || true)
    [ -n "$lab_helper" ] || {
        printf 'persistent input requires handheld-input helper\n' >&2
        return 69
    }
    lab_mode=${1:-${HANDHELD_DEVTOOLS_INPUT_MODE:-gamepad}}
    case $lab_mode in gamepad|keyboard) ;; *) printf 'invalid input mode\n' >&2; return 64 ;; esac
    lab_state=$(input_state_dir)
    lab_fifo="$lab_state/input.fifo"
    lab_pid_file="$lab_state/input.pid"
    lab_log="$lab_state/input.log"
    mkdir -p "$lab_state"
    lab_pid=""
    [ -r "$lab_pid_file" ] && lab_pid=$(sed -n '1p' "$lab_pid_file")
    if [ -n "$lab_pid" ] && kill -0 "$lab_pid" 2>/dev/null && [ -p "$lab_fifo" ]; then
        printf 'ready pid=%s mode=%s fifo=%s\n' "$lab_pid" "$lab_mode" "$lab_fifo"
        return 0
    fi
    rm -f "$lab_fifo" "$lab_pid_file"
    if has setsid; then
        nohup setsid "$lab_helper" serve "$lab_fifo" "$lab_mode" >"$lab_log" 2>&1 </dev/null &
    else
        nohup "$lab_helper" serve "$lab_fifo" "$lab_mode" >"$lab_log" 2>&1 </dev/null &
    fi
    lab_pid=$!
    printf '%s\n' "$lab_pid" >"$lab_pid_file"
    lab_attempt=0
    while [ "$lab_attempt" -lt 50 ]; do
        if [ -p "$lab_fifo" ] && kill -0 "$lab_pid" 2>/dev/null; then
            printf 'ready pid=%s mode=%s fifo=%s\n' "$lab_pid" "$lab_mode" "$lab_fifo"
            return 0
        fi
        sleep 0.1
        lab_attempt=$((lab_attempt + 1))
    done
    printf 'input helper did not become ready\n' >&2
    sed -n '1,80p' "$lab_log" >&2 2>/dev/null || true
    return 70
}

cmd_input_stop() {
    lab_state=$(input_state_dir)
    lab_fifo="$lab_state/input.fifo"
    lab_pid_file="$lab_state/input.pid"
    lab_pid=""
    [ -r "$lab_pid_file" ] && lab_pid=$(sed -n '1p' "$lab_pid_file")
    if [ -n "$lab_pid" ] && kill -0 "$lab_pid" 2>/dev/null; then
        if [ -p "$lab_fifo" ]; then printf 'QUIT\n' >"$lab_fifo"; fi
        lab_attempt=0
        while kill -0 "$lab_pid" 2>/dev/null && [ "$lab_attempt" -lt 30 ]; do
            sleep 0.1
            lab_attempt=$((lab_attempt + 1))
        done
        if kill -0 "$lab_pid" 2>/dev/null; then kill "$lab_pid" 2>/dev/null || true; fi
    fi
    rm -f "$lab_fifo" "$lab_pid_file"
    printf 'stopped\n'
}

cmd_capture() {
    lab_output=${1:-}
    [ -n "$lab_output" ] || {
        printf 'capture output path required\n' >&2
        return 64
    }
    lab_provider=$(capture_provider 2>/dev/null || true)
    case $lab_provider in
        configured-helper)
            "$HANDHELD_DEVTOOLS_CAPTURE_HELPER" "$lab_output"
            ;;
        grim)
            grim "$lab_output"
            ;;
        imagemagick)
            import -window root "$lab_output"
            ;;
        fbgrab)
            fbgrab "$lab_output"
            ;;
        handheld-fbshot)
            handheld-fbshot "$lab_output"
            ;;
        ffmpeg-kms)
            lab_card=${HANDHELD_DEVTOOLS_DRM_DEVICE:-}
            if [ -z "$lab_card" ]; then
                for lab_candidate in /dev/dri/card*; do
                    if [ -r "$lab_candidate" ]; then lab_card=$lab_candidate; break; fi
                done
            fi
            [ -n "$lab_card" ] || return 69
            ffmpeg -hide_banner -loglevel warning -y \
                -f kmsgrab -i "$lab_card" \
                -vf "hwdownload,format=${HANDHELD_DEVTOOLS_DRM_FORMAT:-bgr0}" \
                -frames:v 1 "$lab_output"
            ;;
        *)
            printf 'capture unsupported\n' >&2
            return 69
            ;;
    esac
    [ -s "$lab_output" ] || {
        printf 'capture provider produced no image: %s\n' "$lab_output" >&2
        return 70
    }
    printf '%s\n' "$lab_output"
}

cmd_core() {
    lab_pid=${1:-}
    lab_output=${2:-}
    valid_pid "$lab_pid" || { printf 'invalid PID\n' >&2; return 64; }
    [ -n "$lab_output" ] || { printf 'core output path required\n' >&2; return 64; }
    lab_provider=$(core_provider 2>/dev/null || true)
    case $lab_provider in
        gcore)
            gcore -o "$lab_output" "$lab_pid" >/dev/null
            lab_actual="${lab_output}.${lab_pid}"
            ;;
        gdb)
            gdb -q -n -batch \
                -ex "set sysroot /proc/$lab_pid/root" \
                -ex "file /proc/$lab_pid/exe" \
                -ex "attach $lab_pid" \
                -ex "generate-core-file $lab_output" \
                -ex detach -ex quit >/dev/null
            lab_actual=$lab_output
            ;;
        *)
            printf 'core dump unsupported\n' >&2
            return 69
            ;;
    esac
    [ -s "$lab_actual" ] || { printf 'core dump not created\n' >&2; return 70; }
    printf '%s\n' "$lab_actual"
}

cmd_trace() {
    lab_pid=${1:-}
    lab_seconds=${2:-5}
    lab_output=${3:-}
    valid_pid "$lab_pid" || { printf 'invalid PID\n' >&2; return 64; }
    case $lab_seconds in
        ''|*[!0-9]*) printf 'invalid trace duration\n' >&2; return 64 ;;
    esac
    [ "$lab_seconds" -ge 1 ] && [ "$lab_seconds" -le 300 ] || {
        printf 'trace duration must be between 1 and 300 seconds\n' >&2
        return 64
    }
    [ -n "$lab_output" ] || { printf 'trace output path required\n' >&2; return 64; }
    has strace || { printf 'syscall trace unsupported\n' >&2; return 69; }
    if has timeout; then
        timeout "$lab_seconds" strace -f -tt -T -p "$lab_pid" -o "$lab_output" 2>&1 || {
            lab_status=$?
            case $lab_status in
                124|137|143) ;;
                *) return "$lab_status" ;;
            esac
        }
    else
        printf 'bounded tracing requires timeout\n' >&2
        return 69
    fi
    printf '%s\n' "$lab_output"
}

cmd_start() {
    lab_log=${1:-}
    [ -n "$lab_log" ] || { printf 'start log path required\n' >&2; return 64; }
    shift
    [ "${1:-}" = "--" ] && shift
    [ "$#" -gt 0 ] || { printf 'start command required\n' >&2; return 64; }
    lab_log_dir=${lab_log%/*}
    [ "$lab_log_dir" = "$lab_log" ] || mkdir -p "$lab_log_dir"
    if has setsid; then
        nohup setsid "$@" >"$lab_log" 2>&1 </dev/null &
    else
        nohup "$@" >"$lab_log" 2>&1 </dev/null &
    fi
    lab_pid=$!
    sleep 0.1
    if ! kill -0 "$lab_pid" 2>/dev/null; then
        printf 'process exited during startup; log=%s\n' "$lab_log" >&2
        sed -n '1,120p' "$lab_log" >&2 2>/dev/null || true
        return 70
    fi
    printf '%s\n' "$lab_pid"
}

cmd_signal() {
    lab_pid=${1:-}
    lab_signal=${2:-TERM}
    valid_pid "$lab_pid" || { printf 'invalid PID\n' >&2; return 64; }
    case $lab_signal in
        TERM|INT|HUP|USR1|USR2|CONT|STOP|KILL) ;;
        *) printf 'unsupported signal: %s\n' "$lab_signal" >&2; return 64 ;;
    esac
    kill -s "$lab_signal" "$lab_pid"
}

cmd_logs() {
    section kernel
    if has dmesg; then
        dmesg 2>&1 | tail -n 400 || true
    fi
    section journal
    if has journalctl; then
        journalctl --no-pager -n 400 2>&1 || true
    else
        printf 'journalctl unavailable\n'
    fi
}

cmd_cleanup_temp() {
    lab_path=${1:-}
    case $lab_path in
        /tmp/handheld-devtools-*/*|'')
            printf 'invalid Handheld DevTools temporary path\n' >&2
            return 64
            ;;
        /tmp/handheld-devtools-*) ;;
        *)
            printf 'refusing to remove non-Handheld-DevTools path: %s\n' "$lab_path" >&2
            return 64
            ;;
    esac
    [ ! -d "$lab_path" ] || {
        printf 'refusing to remove directory: %s\n' "$lab_path" >&2
        return 64
    }
    rm -f "$lab_path"
}

usage() {
    printf '%s\n' 'usage: handheld-agent.sh {capabilities|snapshot|process PID|render-info|input-info|input-watch NAME [TIMEOUT_MS] [COUNT]|input-start [MODE]|input BUTTON [HOLD_MS]|input-stop|capture PATH|core PID PATH|trace PID SECONDS PATH|start LOG -- COMMAND...|signal PID [SIGNAL]|logs|exec -- COMMAND...}' >&2
    return 64
}

lab_command=${1:-}
[ "$#" -gt 0 ] && shift || true
case $lab_command in
    capabilities) cmd_capabilities "$@" ;;
    snapshot) cmd_snapshot "$@" ;;
    process) cmd_process "$@" ;;
    render-info) cmd_render_info "$@" ;;
    input-info) cmd_input_info "$@" ;;
    input-watch) cmd_input_watch "$@" ;;
    input-start) cmd_input_start "$@" ;;
    input) cmd_input "$@" ;;
    input-stop) cmd_input_stop "$@" ;;
    capture) cmd_capture "$@" ;;
    core) cmd_core "$@" ;;
    trace) cmd_trace "$@" ;;
    start) cmd_start "$@" ;;
    signal) cmd_signal "$@" ;;
    logs) cmd_logs "$@" ;;
    cleanup-temp) cmd_cleanup_temp "$@" ;;
    exec)
        [ "${1:-}" = "--" ] && shift
        [ "$#" -gt 0 ] || usage
        exec "$@"
        ;;
    *) usage ;;
esac
