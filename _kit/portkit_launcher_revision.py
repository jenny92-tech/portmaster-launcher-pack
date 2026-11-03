#!/usr/bin/env python3
# INPUT:  hashlib, sys, pathlib, cargo_revision；portkit-launcher 源码与构建脚本
# OUTPUT: main()；标准输出 PortKit 启动辅助程序的 SHA-256 revision
# POS:    为普通游戏携带的静态辅助二进制建立独立源码身份
"""Print the source revision of the portable PortKit launcher helper."""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path

from cargo_revision import update_lock_closure, update_paths


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    files = [
        root / "_kit" / "build_portkit_launcher.sh",
        root / "_kit" / "cargo_revision.py",
        root / "_kit" / "portkit_launcher_revision.py",
        root / "crates" / "portkit-launcher" / "Cargo.toml",
    ]
    for source_dir in (root / "crates" / "portkit-launcher" / "src",):
        files.extend(sorted(path for path in source_dir.rglob("*") if path.is_file()))
    digest = hashlib.sha256()
    update_paths(digest, root, files)
    update_lock_closure(
        digest, root / "Cargo.lock", ["portkit-launcher"], "portkit-launcher"
    )
    print(digest.hexdigest())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
