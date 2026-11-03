# Handheld DevTools

APP-independent observation/control for Linux handhelds and virtual targets.
`devtools` invokes the Python Controller; `agent/handheld-agent.sh` supplies a
bounded POSIX Probe through local, Docker, SSH or ADB transport.
Providers are discovered at runtime; unsupported capabilities are reported explicitly.

## Commands and targets

```sh
./handheld-lab/devtools --transport local probe
./handheld-lab/devtools --transport local snapshot
./handheld-lab/devtools --transport local process PID
./handheld-lab/devtools --transport local render-info
./handheld-lab/devtools --transport local diagnose --output artifacts
./handheld-lab/devtools --transport docker --endpoint handheld-target probe
./handheld-lab/devtools --transport ssh --endpoint 192.0.2.50 --user root probe
./handheld-lab/devtools --transport adb --endpoint SERIAL probe
```

SSH uses the installed client with local configuration, identity files and
known-host storage disabled. Password entry may be interactive; DevTools does
not read or persist credentials. Virtual evaluators normally own one disposable
`docker run --rm` target. Platform profiles are mounted data, not persistent
containers; idle DevTools needs no running container.

## Providers

| Capability | Provider order |
|---|---|
| Input | bundled `handheld-input`, configured helper, `xdotool`, `wtype` |
| Input observation | bundled `handheld-event`, Linux input inventory |
| Capture | configured helper, `grim`, ImageMagick `import`, `fbgrab`, FFmpeg KMS |
| Render information | `drm_info`, `modetest`, DRM sysfs/debugfs, `xrandr`, `fbset` |
| Process memory | `/proc/PID` status, maps, smaps and threads |
| Core dump | explicit `gcore` or GDB `generate-core-file` |
| System-call trace | explicit `strace` |

`HANDHELD_DEVTOOLS_INPUT_HELPER` / `HANDHELD_DEVTOOLS_CAPTURE_HELPER` accept
executable paths, not shell fragments. Build static amd64/arm64 helpers with:

```sh
sh handheld-lab/helpers/build-linux-helpers.sh
```

Deploy only the target architecture's `handheld-input`, `handheld-event` and
`handheld-fbshot`. Compilers stay in disposable build containers.

## Optional debugging toolbox

GDB, compilers, symbol servers and decompilers belong in an on-demand toolbox,
not the minimal Probe. Real handhelds normally run only a small tracing helper
or `gdbserver`, with heavy clients on the host. The default is one target and no
toolbox; routed targets/sidecars are an advanced fallback.

```sh
sh handheld-lab/toolbox/build.sh
sh handheld-lab/toolbox/start.sh handheld-target handheld-target-debug "$PWD/.handheld-devtools-work"
./handheld-lab/devtools --transport docker --endpoint handheld-target-debug trace PID 5 trace.txt
./handheld-lab/devtools --transport docker --endpoint handheld-target-debug core PID process.core
```

The sidecar shares target PID/network namespaces, uses `SYS_PTRACE`, and does
not replace the target filesystem or run privileged. Split I/O/debug routing:

```sh
./handheld-lab/devtools --transport docker --endpoint handheld-runtime --io-endpoint handheld-native-io --debug-endpoint handheld-runtime-debug probe
```

## Evidence and scenarios

`diagnose` writes a manifest and bounded observations. Kernel/journal logs require
`--include-logs`; a supplied PID adds memory accounting/maps, not a memory dump.
Core dumps are separate explicit operations and may contain sensitive runtime data.

Scenario steps use argument arrays. All steps are validated before the first
action; each records command, duration, status, stdout and stderr.

```json
{
  "name": "launch-and-observe",
  "steps": [
    {"action": "exec", "argv": ["/opt/game/launch.sh"]},
    {"action": "wait", "seconds": 2},
    {"action": "input", "button": "south"},
    {"action": "capture", "name": "after-confirm"}
  ]
}
```

Linux has no universal render-layer-tree API. Actual scanout/DRM planes depend
on available providers; X11, Wayland and framebuffer expose different evidence.
Missing information is reported unsupported, not synthesized from an APP's state.

## Verification

```sh
./handheld-lab/tests/run-self-test.sh
```

The advanced routed-target E2E requires explicitly prepared Docker targets:

```sh
sh handheld-lab/tests/run-docker-e2e.sh handheld-arm64-runtime handheld-native-io artifacts/handheld
```

It checks provider negotiation, process observations, uinput press/release,
framebuffer capture, evidence and scenario execution; it contains no APP actions.
Source navigation is in [AGENTS.md](AGENTS.md), terminology in [CONTEXT.md](CONTEXT.md).
