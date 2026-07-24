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

The engine first checks `format` and `schema_version`, compares root
`config_version` without downgrading, detects from the root, then verifies and
loads one detail. The detail must match the root's format, schema version,
config version and platform ID.
Models provide recognition, display facts, and narrow display/input overrides;
containment defines their parent platform.

Adapter definitions are an extension point. An engine may retain an unknown
adapter used only by an unrelated device. It must reject the current resolved
device closure if any referenced adapter kind or contract version is unknown.

Predicates, path strategies, health checks, and environment operations are
finite declarative vocabularies. There is no shell,
evaluation, or arbitrary-code operation. Environment values are copied
literally. Inheritance is default-open and blocks exactly the names and prefix
listed in `environment`; each platform explicitly references the `love_ui`
execution scope.

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

Parser limits cover nesting, paths, strings, and collection counts. There is
deliberately no total config file-size limit, so future unrelated device
entries do not make an otherwise usable config invalid solely because it grew.
Detail references must remain relative children of the selected configuration
directory; absolute paths, traversal and symlink escape are rejected.
