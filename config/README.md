# Port App Manager configuration contract

`config.json` is the canonical root: global policy plus thin platform detection
entries. Each entry names one `platforms/<id>.json` detail. Details repeat the
format/schema/config-version identity,
contain models under their parent platform, and omit root-only priority and
recognition. The engine embeds only the root and loads exactly the detected
detail; packaged local details provide the offline fallback. Generated files
are one-line minified UTF-8 JSON with a trailing newline; do not edit them.

The human-maintained inputs live in `src/`. Top-level keys may appear in only
one fragment, which keeps the merge deterministic and prevents silent
overrides. After changing a fragment, run:

```sh
python3 config/scripts/generate.py
python3 config/scripts/validate.py config/config.json
python3 config/scripts/validate.py config/platforms/trimui.json
python3 -m unittest -v config.tests.test_config_contract
```

CI and packaging should use `generate.py --check`. A release author updates
`metadata.generated_at` and `metadata.source_revision` in `src/00-contract.json`
when the generated contract changes.

## Current contract and safety

Shell analysis receives `directory` from the profile's explicit
`paths.shell_directory`, not by inspecting a folder name. This legacy Shell
value is separate from `launcher_directory` and the managed Port data location.
`controlfolder` comes from resolved `portmaster_core`; downloadable images are
its `libs/*.squashfs`. An absent Shell path input remains unknown rather than
becoming a guessed card root. All bundled profiles declare `shell_directory`;
the declaration does not imply complete Shell or real-device compatibility.

The engine first checks `format` and `schema_version`, compares root
`config_version` without downgrading, detects from the root, then verifies and
loads one detail. The detail must match the root's format, schema version,
config version and platform ID. Each root detail descriptor also binds the
exact byte length and SHA-256 digest, so a mutable branch cannot combine a root
with a different same-version detail.

Models provide recognition, display facts, and narrow display/input overrides;
containment defines their parent platform. Models are an ordered array with a
stable id and explicit priority. Matching more than one model at the highest
priority is an error instead of depending on object-key ordering.

Managed storage is expressed as `locations[]`. Every location has a stable id,
typed kind, named path reference, roles, accepted bundle formats and priority.
Array order is never used as persistent identity or an implicit install
destination. Port script/data targets are selected only after filtering for all
roles required by the enabled capabilities; an inventory-only root can never
become an install or management destination. A highest-priority tie is invalid,
including ties among eligible targets. An APP bundle must resolve to exactly
one location with both the `install` role and `trimui_app` format. Trash
manifests retain the location id, so reordering the array cannot restore an APP
to another card. Linux storage card discovery is deliberately not configurable
per platform: ZIP scanning uses the system mount table, while install
destinations remain typed Config locations.

Config v1 is strict for contract objects: unknown platform, model, location and
power fields are rejected. Model display metadata, the baseline capability set,
and at least one Port script plus one Port data location are explicit rather
than supplied by runtime defaults. The schema's `x-appmanager-*` annotations
name cross-item priority/role invariants that JSON Schema Draft 2020-12 cannot
compare natively; both the source validator and Rust loader enforce them.

Power retention is `power { mode, strategies[] }`. `any` means one successful
strategy is sufficient; `all` requires every configured strategy. Runtime
architecture aliases are likewise an ordered array under
`sources.runtime.architectures`, so a new architecture is enabled by Config
instead of a compiled three-name whitelist.

Adapter definitions are an extension point. An engine may retain an unknown
adapter used only by an unrelated device. It must reject the current resolved
device closure if any referenced adapter kind or contract version is unknown.

Objects remain where they are stable-id registries referenced by name
(`adapters`, source routes, named paths and environment profiles). Arrays are
used where order, priority, multiple instances or future additional roots are
part of behavior (`models`, `locations`, power strategies and Runtime
architecture mappings). Object key order is never a business rule.

Predicates, path strategies, health checks, and environment operations are
finite declarative vocabularies. There is no shell,
evaluation, or arbitrary-code operation. Environment values are copied
literally. Inheritance is default-open and blocks exactly the names and prefix
listed in `environment`; each platform explicitly references the `love_ui`
execution scope.

`literal` and `relative_to` may opt into `canonicalize_existing: true` for a firmware-owned
alias such as LoongOS `/roms/ports/PortMaster`. Only an already existing path is
canonicalized; a missing install target remains the derived child. The resolved
target still passes the native managed-root, protected-namespace and overlap
checks, so the option cannot authorize a symlink into a system directory.

Each platform frontend also carries the normalized installer policy consumed
by native plan validation. Optional shell `-` values are represented as JSON
`null`, and mutation flags are booleans. `support.target_confirmation` controls
when a resolved core is safe to modify. Generic discovery requires an existing
core or an explicit override; exhausting its candidates leaves the path
unresolved and never promotes the first nonexistent candidate.

`frontend.transforms` is a small, finite post-staging vocabulary for firmware
facts that must be written into an installed frontend. The current
`export_library_group` transform selects the first candidate containing every
required SONAME in the named library group and replaces one explicit `export`
line. It does not execute config text or introduce a platform-specific code
branch; fixture roots affect probing only, while the rendered value remains the
device path.

TrimUI delegates PortMaster core maintenance to the firmware or environment
provider: `frontend.management` and `source_route` are `system`, and
`manage_portmaster`, `install_portmaster`, `update_portmaster`, and
`manage_frontend` are disabled. This covers stock, custom-firmware, and external
userland setups without replacing their core or launcher. Existing path and
health detection, Port/APP management, and the separate `repair_runtimes`
capability remain enabled; it does not imply support for running every setup.

Parser limits cover nesting, paths, strings, and collection counts. There is
deliberately no total config file-size limit, so future unrelated device
entries do not make an otherwise usable config invalid solely because it grew.
Detail references must remain relative children of the selected configuration
directory; absolute paths, traversal and symlink escape are rejected.
