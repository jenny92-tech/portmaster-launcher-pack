#!/usr/bin/env python3
"""Print the content revision that must match packaged App Manager helpers."""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    files = [root / "Cargo.toml", root / "Cargo.lock"]
    files.extend(sorted((root / "crates").rglob("*.toml")))
    files.extend(sorted((root / "crates").rglob("*.rs")))
    files.append(root / "config" / "config.json")
    files.extend(sorted((root / "config" / "platforms").glob("*.json")))
    digest = hashlib.sha256()
    for path in files:
        if not path.is_file():
            raise SystemExit(f"missing native source: {path}")
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
