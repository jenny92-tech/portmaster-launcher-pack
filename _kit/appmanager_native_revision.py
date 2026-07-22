#!/usr/bin/env python3
"""Print the content revision that must match packaged App Manager helpers."""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

from cargo_revision import update_lock_closure, update_paths, update_toml_section


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    files = [
        root / "_kit" / "appmanager_native_revision.py",
        root / "_kit" / "build_appmanager_native.sh",
        root / "_kit" / "cargo_revision.py",
    ]
    native_crates = (
        "appmanager-cli",
        "appmanager-core",
        "portkit-cli",
        "portkit-core",
    )
    for name in native_crates:
        crate = root / "crates" / name
        files.extend(sorted(crate.rglob("*.toml")))
        files.extend(sorted(crate.rglob("*.rs")))
    files.append(root / "config" / "config.json")
    files.extend(sorted((root / "config" / "platforms").glob("*.json")))
    digest = hashlib.sha256()
    update_paths(digest, root, files)
    update_toml_section(digest, root / "Cargo.toml", ("workspace", "package"), "workspace.package")
    update_lock_closure(
        digest,
        root / "Cargo.lock",
        ["appmanager-cli", "portkit-cli"],
        "appmanager-native",
    )
    print(digest.hexdigest())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
