# Repository agent rules

## Version discipline before the first public release

This repository has not made its first public release. Evolving internal data
formats are the current baseline, not a sequence of supported public versions.

- Never increment a Schema, Config, API, manifest, or package version unless
  the user explicitly authorizes that exact version change.
- A struct or JSON shape change alone is not permission to bump a version.
  Update the format, every in-tree consumer, and its tests in place.
- Do not add backward-compatibility readers or migrations for unpublished
  formats unless the user explicitly requests them.
- Before proposing a version bump, identify the released external consumer or
  persisted compatibility boundary that requires it. If none exists, keep the
  current version.
- Source revision hashes and rebuilt binary checksums are build identities, not
  semantic format versions; they may change when their inputs are rebuilt.

## What counts as an incompatible change

A version number identifies a compatibility contract. It may change only when
an old and a new independently deployed or persisted participant cannot safely
interoperate. Examples are:

- an old persisted document must survive an upgrade, but the new reader cannot
  safely interpret it without migration;
- old and new frontend/backend binaries can run together, but one side cannot
  parse the other side's message;
- a required field is removed or renamed, or an existing field changes type,
  units, or meaning in a way that an old participant would misinterpret.

These are not incompatible changes and must not bump a version:

- internal refactors or implementation changes;
- adding an optional/defaulted field that old readers can ignore;
- making an internal fact more precise while updating all in-tree consumers;
- changing a producer and consumer that are built and shipped together;
- changing any format that has never been publicly released or persisted as a
  supported upgrade boundary.

Incompatibility does not automatically authorize a bump. Before changing any
version, an agent must:

1. obtain explicit user approval for the exact old and new version;
2. document which old/new producer-reader combinations must work or fail;
3. implement migration, compatibility reading, or explicit version negotiation
   with a fail-closed error for unsupported combinations;
4. add tests for every supported old/new combination and the unsupported case;
5. update all producers, consumers, schemas, generated files, and release
   artifacts atomically.

If those conditions are not met, keep the current version. Never use a version
bump as a substitute for updating all in-tree consumers correctly.
