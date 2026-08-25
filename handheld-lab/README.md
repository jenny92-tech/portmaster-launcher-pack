# Handheld DevTools

Handheld DevTools is an APP-independent observation and control component for real
and virtual Linux handhelds. It gives people, test runners, and AI agents the
same bounded interface for operating a target and collecting evidence.

The component has two core parts:

- `devtools`: stable command-line entry point.
- `handheld_lab.py`: host-side Controller with local, Docker, SSH, and ADB transports.
- `agent/handheld-agent.sh`: dependency-light POSIX shell Probe streamed to the Target.

The Probe never assumes a platform merely because a profile names one. It
discovers providers at runtime and reports unsupported capabilities explicitly.

Run the package self-test:

```sh
./handheld-lab/tests/run-self-test.sh
```

## Current commands

```sh
./handheld-lab/devtools --transport local probe
./handheld-lab/devtools --transport local snapshot
./handheld-lab/devtools --transport local process PID
./handheld-lab/devtools --transport local render-info
./handheld-lab/devtools --transport local diagnose --output artifacts
```

Use a Docker target:

```sh
./handheld-lab/devtools \
  --transport docker --endpoint handheld-target probe
```

Virtual evaluators should normally own one disposable target created with
`docker run --rm`. TrimUI, MiniLoong, and other Platform Profiles are mounted
userspace/configuration data, not long-running containers. Handheld DevTools
therefore needs no persistent container when it is idle.

Use a real target over SSH or ADB:

```sh
./handheld-lab/devtools \
  --transport ssh --endpoint 192.0.2.50 --user root probe

./handheld-lab/devtools \
  --transport adb --endpoint SERIAL probe
```

SSH authentication is delegated to the installed `ssh` command. Local SSH
configuration, identity files, and known-host storage are disabled; a password
may be entered interactively but is never read or persisted by Handheld DevTools.

## Capability providers

The first available provider is selected at runtime:

| Capability | Providers |
|---|---|
| Input | bundled `handheld-input`, configured helper, `xdotool`, `wtype` |
| Input observation | bundled `handheld-event`, Linux input inventory |
| Capture | configured helper, `grim`, ImageMagick `import`, `fbgrab`, FFmpeg KMS |
| Render information | `drm_info`, `modetest`, DRM sysfs/debugfs, `xrandr`, `fbset` |
| Process memory | Linux `/proc/PID` status, maps, smaps, threads |
| Core dump | `gcore`, or GDB `generate-core-file`; explicit command only |
| System-call trace | `strace`; explicit command only |

`HANDHELD_DEVTOOLS_INPUT_HELPER` and `HANDHELD_DEVTOOLS_CAPTURE_HELPER` may point to an
executable provider deployed with a platform image. They are executable paths,
not shell fragments.

Build the three small static Linux helpers without installing a compiler on the
VM or Target:

```sh
docker run --rm \
  --volume "$PWD/handheld-lab:/src" --workdir /src \
  alpine:3.22 sh helpers/build-in-alpine.sh /src/build
```

Build both VM (`amd64`) and handheld (`arm64`) helper sets:

```sh
sh handheld-lab/helpers/build-linux-helpers.sh
```

Each target needs only its architecture's `handheld-input`,
`handheld-event`, and `handheld-fbshot`. Compilers and package indexes remain
inside disposable build containers.

## Dev Toolbox boundary

Compilers, GDB, `gcore`, `strace`, symbol servers, and decompilers belong to an
on-demand Dev Toolbox, not the minimal Probe. A virtual Target can attach a
toolbox sidecar to its PID and mount namespaces. A real handheld normally runs
only a small `gdbserver` or static tracing helper while the heavy client stays
on the VM. The Controller exposes the same process, core, and trace operations
regardless of which provider supplies them.

The normal topology is one Target and no Toolbox. A persistent sidecar is an
advanced QEMU/debugging fallback, not the default execution model. When used,
the Controller may route process/filesystem work to the Target, native device
I/O to one provider, and explicit core/trace work to the Dev Toolbox:

```sh
./handheld-lab/devtools \
  --transport docker \
  --endpoint handheld-runtime \
  --io-endpoint handheld-native-io \
  --debug-endpoint handheld-runtime-debug \
  probe
```

For a Docker Target:

```sh
sh handheld-lab/toolbox/build.sh
sh handheld-lab/toolbox/start.sh handheld-target handheld-target-debug \
  "$PWD/.handheld-devtools-work"

./handheld-lab/devtools \
  --transport docker --endpoint handheld-target-debug process PID
./handheld-lab/devtools \
  --transport docker --endpoint handheld-target-debug trace PID 5 trace.txt
./handheld-lab/devtools \
  --transport docker --endpoint handheld-target-debug core PID process.core
```

The sidecar joins the Target's PID and network namespaces and receives only the
`SYS_PTRACE` capability needed for tracing. It is not privileged and it does
not replace the Target filesystem.

## Evidence and autonomous debugging

`diagnose` writes a machine-readable manifest plus bounded observations. Broad
kernel and journal logs are excluded by default and require `--include-logs`. A PID
adds process memory accounting and mappings. It does not dump process memory by
default. Core dumps are a separate explicit operation because they may be large
and may contain sensitive runtime data.

Scenarios are JSON documents whose steps use argument arrays rather than shell
strings:

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

Every step records its command, duration, exit status, stdout, and stderr. This
is the stable surface an AI uses for the observe/hypothesize/act/verify loop.
Every step is validated before the first action runs, so an invalid later step
cannot leave a partially executed scenario.

Run the advanced routed-target Docker E2E when validating that fallback:

```sh
sh handheld-lab/tests/run-docker-e2e.sh \
  handheld-arm64-runtime handheld-native-io artifacts/handheld
```

This verifies capability negotiation, `/proc` memory observations, persistent
uinput registration, consumer-visible press/release events, framebuffer capture,
evidence generation, and the generic scenario runner. It contains no APP
Manager actions.

## Honest platform boundary

There is no universal Linux API for a complete render-layer tree. Handheld DevTools
can capture the actual scanout and report DRM planes when the kernel/provider
exposes them. X11, Wayland, framebuffer, and application-instrumented targets
use different providers. Unsupported information is reported as unsupported;
it is never synthesized from an APP's internal state.
