#!/usr/bin/env python3
"""Build launcher CJK font subsets from the bundled OFL source font."""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE_FONT = ROOT / "_kit/fonts/LXGWWenKaiLite-Regular.ttf"
CONTACT_TEXT = "QQ 群 1047158975"

TARGETS = [
    ROOT / "ports/heishenhua/src/assets/launcher_font_zh.ttf",
    ROOT / "ports/hk/src/assets/launcher_font_zh.ttf",
    ROOT / "ports/terraria/src/assets/launcher_font_zh.ttf",
    ROOT / "ports/vampiresurvivors114/src/assets/launcher_font_zh.ttf",
    ROOT / "ports/sts2/src/linux/assets/launcher_font_zh.ttf",
]

SOURCE_TEXT_FILES = [
    ROOT / "_kit/launcher_base.gd",
    ROOT / "ports/heishenhua/src/launcher_ui.gd",
    ROOT / "ports/hk/src/launcher_ui.gd",
    ROOT / "ports/terraria/src/launcher_ui.gd",
    ROOT / "ports/vampiresurvivors114/src/launcher_ui.gd",
    ROOT / "ports/sts2/src/linux/launcher_ui.gd",
]


def collect_text() -> str:
    text = CONTACT_TEXT + "\n"
    for path in SOURCE_TEXT_FILES:
        text += path.read_text(encoding="utf-8") + "\n"
    # Add ASCII explicitly for labels, digits, punctuation, env names, and
    # fallback UI text. pyftsubset deduplicates codepoints.
    text += "".join(chr(i) for i in range(0x20, 0x7F))
    # Drop control characters except newlines before passing to pyftsubset.
    text = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", text)
    return text


def main() -> int:
    if not SOURCE_FONT.is_file():
        print(f"missing source font: {SOURCE_FONT}", file=sys.stderr)
        return 1

    text = collect_text()
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as fh:
        fh.write(text)
        text_file = Path(fh.name)

    try:
        for target in TARGETS:
            target.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                [
                    "pyftsubset",
                    str(SOURCE_FONT),
                    f"--text-file={text_file}",
                    "--layout-features=*",
                    "--name-IDs=*",
                    "--name-legacy",
                    "--name-languages=*",
                    "--symbol-cmap",
                    "--legacy-cmap",
                    "--notdef-glyph",
                    "--notdef-outline",
                    "--recommended-glyphs",
                    f"--output-file={target}",
                ],
                check=True,
            )
            print(f"wrote {target.relative_to(ROOT)} ({target.stat().st_size} bytes)")
    finally:
        text_file.unlink(missing_ok=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
