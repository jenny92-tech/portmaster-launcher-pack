#!/usr/bin/env python3
"""Print the source revision of the APP Manager LOVE-lite runtime."""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

from cargo_revision import update_lock_closure, update_paths


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    crate = root / "crates" / "love-lite"
    files = [
        root / "_kit" / "build_appmanager_love_lite.sh",
        root / "_kit" / "cargo_revision.py",
        root / "_kit" / "love_lite_revision.py",
        crate / "Cargo.toml",
    ]
    for source_dir in (crate / "src", crate / "vendor"):
        files.extend(sorted(path for path in source_dir.rglob("*") if path.is_file()))
    digest = hashlib.sha256()
    update_paths(digest, root, files)
    update_lock_closure(digest, root / "Cargo.lock", ["love-lite"], "love-lite")
    print(digest.hexdigest())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
