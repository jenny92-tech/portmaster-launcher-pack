#!/usr/bin/env python3
# INPUT:  选定运行目录/映像、Linux mountinfo 和 sysfs loop backing_file
# OUTPUT: verify_mount() 与已挂载 Wine 映像身份校验命令
# POS:    防止切换 Wine 数据目录时复用另一个仍挂载的 prefix
from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys


def decode_path(value: str) -> str:
    return re.sub(r"\\([0-7]{3})", lambda match: chr(int(match[1], 8)), value)


def verify_mount(root: Path, image: Path, mountinfo: Path = Path("/proc/self/mountinfo"),
                 sys_dev_block: Path = Path("/sys/dev/block")) -> None:
    if not image.is_file():
        raise ValueError(f"Missing Wine filesystem: {image}")
    selected = image.resolve()
    target = root.resolve()
    for line in mountinfo.read_text().splitlines():
        fields = line.split()
        if len(fields) < 7 or Path(decode_path(fields[4])).resolve() != target:
            continue
        device = fields[2]
        if not re.fullmatch(r"[0-9]+:[0-9]+", device):
            raise ValueError("Invalid mounted runtime device")
        backing_file = sys_dev_block / device / "loop/backing_file"
        if not backing_file.is_file():
            raise ValueError(f"Wine runtime is not mounted from a loop image: {root}")
        backing = decode_path(backing_file.read_text().rstrip("\n"))
        mounted = Path("/" + backing.lstrip("/")).resolve()
        if mounted != selected:
            raise ValueError(f"Another Wine image is mounted at {root}: {mounted}; selected {selected}")
        return
    raise ValueError(f"Wine runtime mount is missing: {root}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify the selected Wine loop image")
    parser.add_argument("root", type=Path)
    parser.add_argument("image", type=Path)
    args = parser.parse_args()
    try:
        verify_mount(args.root, args.image)
    except (OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 78
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
