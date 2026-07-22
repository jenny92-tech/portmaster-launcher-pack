#!/usr/bin/env python3
"""Print the source revision of the APP Manager LOVE-lite runtime."""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    crate = root / "crates" / "love-lite"
    files = [
        root / "Cargo.toml",
        root / "Cargo.lock",
        root / "_kit" / "build_appmanager_love_lite.sh",
        root / "_kit" / "love_lite_revision.py",
        crate / "Cargo.toml",
    ]
    for source_dir in (crate / "src", crate / "vendor"):
        files.extend(sorted(path for path in source_dir.rglob("*") if path.is_file()))
    digest = hashlib.sha256()
    for path in files:
        if not path.is_file():
            raise SystemExit(f"missing LOVE-lite source: {path}")
        relative = path.relative_to(root).as_posix().encode("utf-8")
        payload = path.read_bytes()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    print(digest.hexdigest())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
