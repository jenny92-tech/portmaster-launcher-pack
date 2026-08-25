# APP Manager evaluation suite

This is the APP Manager-specific evaluator and the first consumer of Handheld
DevTools. It runs the real Rust service, Web API, UI contracts, and Config
contracts as ARM64 Linux processes on an x86 Docker host through
`binfmt_misc`/QEMU. Its containers are disposable; Platform Profiles are
mounted userspace/configuration data rather than persistent containers.

The checked-in files under `config/` remain the only source of truth for
TrimUI, MiniLoong 1.3, LoongOS 1.4+, and ROCKNIX. The lab does not copy their
paths or detection rules into another profile format.

## Current coverage

- `smoke`: real HTTP server, pairing, authentication, snapshot, and a TrimUI
  filesystem fixture.
- `config`: the complete Config contract suite, including TrimUI, MiniLoong's
  old layout, LoongOS's new `/roms` layout, and ROCKNIX resolution.
- Both commands run in Debian Bullseye ARM64 with glibc 2.31.
- `device-probe.sh` records bounded, read-only evidence from a handheld without
  recursively scanning its storage or dumping its environment.
- `run-device-userspace.sh` loads the current APP Manager with the exact
  dynamic loader, libc, SDL2, and controller-helper libraries observed on a
  real device. Its smoke check must reach service-ready, Lua-ready, and the
  first rendered frame with the expected Config platform selected.

This layer validates userspace behavior. GPU/DRM, physical controllers, audio
devices, suspend, firmware Wi-Fi behavior, and frontend recovery still require
real-device tests.

## Usage

On a Docker host with ARM64 `binfmt_misc` support:

```sh
./lab/run-arm64-tests.sh smoke
./lab/run-arm64-tests.sh config
./lab/run-arm64-tests.sh all
./lab/run-arm64-tests.sh size
```

For an AI-readable full evaluation with isolated logs:

```sh
python3 lab/pam_lab.py doctor
python3 lab/pam_lab.py diagnose
```

Run the complete APP Manager business suite once under each collected device
loader/libc, followed by the Config-resolved service/Web/ZIP/file-management
E2E and the full UI first-frame smoke:

```sh
./lab/run-device-function-tests.sh all
```

The complete runner requires Python `lupa` for controller-driven Lua UI tests
and fails instead of silently skipping them. When `lupa` lives outside the
system Python installation, expose that directory with `PYTHONPATH` for the
runner process.

The profile E2E uses a new ignored fixture for every run. It exercises public
APP Manager entry points and exact selected paths; it never mutates a mounted
handheld or reuses its real SD-card contents.

Collect a real device profile before running its userspace smoke test:

```sh
python3 lab/collect_device_evidence.py \
  --transport adb --endpoint DEVICE:5555 --profile miniloong \
  --collect-runtime-libs

python3 lab/collect_device_evidence.py \
  --transport ssh --endpoint DEVICE --profile trimui \
  --collect-runtime-libs

./lab/run-device-userspace.sh all all
```

The SSH collector explicitly disables local SSH configuration, keys, and
known-host storage. It supports passwordless device SSH only; it does not read
or persist credentials.

Each run writes a self-contained directory below `.pam-lab/reports/`:

- `report.json`: machine-readable host, Config, artifact, userspace, and check
  results.
- `summary.md`: short pass/fail summary and the next missing evidence.
- `logs/`: exact output for every check, kept out of the summary so failures
  are easy to inspect without flooding the AI context.

The evaluation runner executes only its checked-in probes. It does not read
environment dumps, credentials, shell history, or arbitrary commands supplied
by Config or remote content.

The repository is mounted read-only. Cargo downloads and ARM64 build products
live in the named volumes `pam-lab-cargo-registry` and
`pam-lab-target-arm64`, so repeated runs are fast and do not populate the host
checkout's `target/` directory.

Exact firmware userspace layers are intentionally not checked in. Add them as
external, read-only inputs after they have been collected from a firmware image
or a device; do not encode a second copy of the platform Config in this lab.
Recognition fixtures are generated from the checked-in Config at run time. The
observed APP Manager launcher comes from the device evidence, not a second
hand-maintained profile.

## Browser fixture

Use the real shipped HTML with deterministic API data when evaluating pairing,
responsive layout, installed items, and trash states:

```sh
python3 lab/serve-appmanager-web-fixture.py
```

Open `http://127.0.0.1:8766/` and pair with `123456`. The fixture is deliberately
UI-only: install, uninstall, restore, and path-association semantics remain the
responsibility of the Rust device-profile E2E suite.

The collected closure is intentionally small: it includes only the loader and
libraries resolved for the APP Manager runtime and `gptokeyb`. It is enough to
catch libc/SDL ABI failures and to run a headless full-UI startup. It is not a
firmware emulator: DRM/GLES output, controller events through `/dev/uinput`,
audio hardware, suspend, Wi-Fi, and frontend restoration still require a real
handheld.

## External userspace inputs

Collect evidence before creating an exact userspace layer. Keep the captured
rootfs or OCI layer outside this repository.

- All systems: `/etc/os-release`, architecture and glibc versions, Python
  version/import availability, required command inventory, filesystem mount
  types, and symlink metadata for the active PortMaster installation.
- TrimUI: the required libraries from `/usr/lib` and `/usr/trimui/lib`, plus
  the model environment values used by the checked-in Config.
- MiniLoong 1.3: `/loong/loong_version`, the old system library set, and the
  active PortMaster link/target metadata.
- LoongOS 1.4+: the new system library set and `/roms/ports/PortMaster`
  link/target metadata. Retain any legacy marker in the fixture so detection
  precedence is tested.
- ROCKNIX: the official firmware userspace image, its system SDL/Python
  libraries, and evidence showing which configured ROM root exists on the
  selected release/device.
