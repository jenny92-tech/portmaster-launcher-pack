# Port App Manager configuration contract

Edit `src/` fragments; generate `config.json` and `platforms/<id>.json`.
Top-level fragment keys must be unique. Outputs are deterministic, minified UTF-8
JSON with a trailing newline; generated files are not edited by hand.

```sh
python3 config/scripts/generate.py
python3 config/scripts/validate.py config/config.json
python3 config/scripts/validate.py config/platforms/trimui.json
python3 -m unittest -v config.tests.test_config_contract
```

CI/packaging uses `generate.py --check`. When the generated contract changes,
update `metadata.generated_at` and `metadata.source_revision` in `src/00-contract.json`.
Format and package versions follow the root repository rules.

## Resolution and identity

- The root owns global policy, platform priority/recognition and detail references.
  The engine embeds the root and loads one detected detail, using packaged details
  offline. A detail contains its models, not root-only recognition/priority fields.
- Validate format/schema, reject config downgrades, detect from the root, then
  verify the selected detail's format, schema/config version, platform ID, exact
  byte length and SHA-256. A root cannot be paired with a different same-version detail.
- Models have stable IDs and explicit priorities, with narrow display/input
  overrides. A highest-priority recognition tie is an error.
- Unknown platform/model/location/power fields are rejected. Display metadata,
  baseline capabilities and Port script/data locations are explicit, not defaults.
  Source validation and Rust enforce cross-item `x-appmanager-*` invariants that
  JSON Schema Draft 2020-12 cannot compare.
- Unknown adapters for unrelated devices may be retained; an unknown kind/version
  in the resolved device closure is rejected.

## Paths and storage

- Shell analysis gets `directory` from `paths.shell_directory`, independently of
  `launcher_directory` and Port data. An absent input stays unknown.
  `controlfolder` comes from resolved `portmaster_core`; runtime images are its
  `libs/*.squashfs`. Declared paths do not prove real-device Shell compatibility.
- `locations[]` use stable IDs, typed kinds, named paths, roles, bundle formats and
  priority. All roles required by enabled capabilities must match before choosing
  a script/data target; inventory-only locations cannot become mutation targets.
  Highest-priority ties are invalid, including ties among eligible destinations.
- An APP install requires exactly one location with `install` and `trimui_app`.
  Trash records the location ID, so reordering cannot restore to another card.
  ZIP discovery uses Linux mount information; install destinations remain Config locations.
- `literal` / `relative_to` may use `canonicalize_existing: true` for firmware aliases
  such as LoongOS `/roms/ports/PortMaster`. Only existing paths are canonicalized;
  missing targets retain the derived child. Managed-root, protected-namespace and
  overlap checks still apply.
- Detail references must remain relative children of the Config directory;
  absolute paths, traversal and symlink escape are rejected.

## Declarative policy

- Device-specific facts belong in Config; protected namespaces, official archive
  rules and application transaction safety stay in native code. Add vocabulary
  together with its consumer, schema, parser and contract tests; keep unused
  placeholder fields out of the format.
- Predicates, paths, health checks and environment operations use finite vocabularies.
  Config text is never executed. Environment values are literal; inheritance is
  default-open and blocks exactly configured names/prefixes. Platforms explicitly
  reference the `love_ui` scope.
- Stable-name registries use objects: adapters, source routes, paths and environment
  profiles. Ordered/priority/multi-instance rules use arrays: models, locations,
  power strategies and Runtime architecture aliases. Object-key order has no semantics.
- `power { mode, strategies[] }` uses `any` for one successful strategy or `all` for
  every strategy. `sources.runtime.architectures` declares architecture aliases.
- Frontend installer policy is normalized for native plan validation: Shell `-`
  becomes JSON `null`, mutation flags are booleans. `support.target_confirmation`
  gates writes. Generic detection requires an existing core or explicit override;
  exhausted candidates leave the path unresolved.
- `frontend.transforms` is finite. `export_library_group` finds the first candidate
  with all required SONAMEs and replaces one explicit export line. Fixture roots
  affect probing only; rendered paths remain device paths.
- Parser limits cover nesting, paths, strings and collection counts, not total
  config bytes; unrelated device additions must not invalidate a usable config.

TrimUI delegates PortMaster core/frontend maintenance to its environment provider:
`frontend.management` / `source_route` are `system`; `manage_portmaster`,
`install_portmaster`, `update_portmaster`, `manage_frontend` are disabled.
Path/health detection, Port/APP management and `repair_runtimes` remain available.
This policy does not certify every stock, custom-firmware or external userland setup.
