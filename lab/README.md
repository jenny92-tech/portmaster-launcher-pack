# APP Manager evaluation suite

APP-specific consumer of [Handheld DevTools](../handheld-lab/README.md).
Runs Rust service/Web, UI and Config contracts as ARM64 Linux processes under
Docker/binfmt/QEMU. Containers are disposable; profiles are userspace/config data.
Formal [Config](../config/README.md) remains the only platform-policy source.
The [MiniLoong execution contract](EXECUTION.md) describes firmware execution
windows, private mount views and the App Manager process handoff.

## Coverage and limits

| Check | Coverage |
|---|---|
| `smoke` | Real HTTP server, pairing/auth, snapshot and TrimUI filesystem fixture |
| `config` | Formal Config suite, including MiniLoong old/new layouts and ROCKNIX |
| `run-device-function-tests.sh` | Business/API/ZIP/file-management/UI tests under collected device loaders |
| `run-device-userspace.sh` | Exact device loader/libc/SDL closure, service-ready, Lua-ready and first frame |
| `device-probe.sh` | Bounded read-only device facts |

Base checks use Debian Bullseye ARM64/glibc 2.31. Userspace tests do not certify
physical GPU/DRM, controllers, audio, suspend, Wi-Fi or frontend restoration;
those require real-device evidence.

## Run evaluations

An ARM64-binfmt-capable Docker host is required. These commands execute tests;
`doctor` also starts a Docker ARM64 probe.

```sh
./lab/run-arm64-tests.sh smoke      # also: config, all, size
python3 lab/pam_lab.py doctor
python3 lab/pam_lab.py diagnose
./lab/run-device-function-tests.sh all
```

The full device-function runner requires `lupa` and fails if absent. If installed
outside system Python, expose its directory with process-local `PYTHONPATH`.
Each profile E2E uses a fresh ignored fixture and exact public APP paths; it
does not mutate a handheld or reuse real SD-card contents.

The repository is mounted read-only; Cargo data/builds use named volumes
`pam-lab-cargo-registry` / `pam-lab-target-arm64`. Reports go to
`.pam-lab/reports/<run>/`: `report.json`, `summary.md`, and per-check `logs/`.
Only checked-in probes run; Config/remote content cannot supply arbitrary commands.
Credentials, shell history and environment dumps are excluded.

## Device evidence and external userspace

Collect from an explicitly chosen target before its userspace smoke test:

```sh
python3 lab/collect_device_evidence.py --transport adb --endpoint DEVICE:5555 --profile miniloong --collect-runtime-libs
python3 lab/collect_device_evidence.py --transport ssh --endpoint DEVICE --profile trimui --collect-runtime-libs
./lab/run-device-userspace.sh all all
```

The SSH collector supports passwordless device SSH only, disabling local SSH
configuration, keys and known-host storage. It does not read/persist credentials.
Collection is limited to the observed runtime/helper dependency closure and
bounded metadata, without recursively scanning device storage.

Keep captured firmware rootfs/OCI layers outside the repository as read-only inputs.
Recognition fixtures derive from Config; launcher evidence comes from the device.

| Platform | Additional evidence |
|---|---|
| All | os-release, architecture/glibc/Python/imports, required commands, mounts, active PortMaster symlink metadata |
| TrimUI | Required `/usr/lib` / `/usr/trimui/lib` libraries and Config-used model values |
| MiniLoong 1.3 | `/loong/loong_version`, old system libraries and active PortMaster link/target |
| LoongOS 1.4+ | New libraries and `/roms/ports/PortMaster` link/target; retain legacy marker to test precedence |
| ROCKNIX | Firmware userspace, SDL/Python libraries and evidence for the configured ROM root |

## Browser fixture

```sh
python3 lab/serve-appmanager-web-fixture.py
```

Open `http://127.0.0.1:8766/`, pair with `123456`. Uses shipped HTML and stable
API data for pairing/layout/items/trash UI checks. Installation, uninstall,
restore and path association are validated by the native profile E2E instead.
