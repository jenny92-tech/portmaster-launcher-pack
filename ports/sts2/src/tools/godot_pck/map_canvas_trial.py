#!/usr/bin/env python3
# INPUT:  Fixed 9caf parent PCK and its unchanged native map-drawing scene
# OUTPUT: Separate one-scene delta, merged main, source identities and fixture inputs
# POS:    Offline half-resolution map canvas experiment; no device or player data
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile

import low_texture_overlay as low
import merge_texture_pck as merge

PARENT = "9caf3fa8448a7729dc11fa4897b9756e30fcdeadb56acbdb1cba9acc3e7b6fad"
TARGET = "scenes/screens/map/map_drawing.tscn"
SCENE = "9ff9034b3a24ea7e120cdd0ee790a516d7c2022e812e7739673d95ef8ea4e649"
ANCHOR = b"size = Vector2i(960, 1620)\n"
REPLACEMENT = (b"size = Vector2i(480, 810)\n"
               b"size_2d_override = Vector2i(960, 1620)\n"
               b"size_2d_override_stretch = true\n")


def patch_scene(data):
    if hashlib.sha256(data).hexdigest() != SCENE or data.count(ANCHOR) != 1:
        raise ValueError("unexpected map scene")
    if b"size_2d_override" in data or b'type="Script"' in data:
        raise ValueError("unexpected map canvas configuration")
    return data.replace(ANCHOR, REPLACEMENT, 1)


def build(parent, work):
    parent, work = Path(parent), Path(work)
    if parent.is_symlink() or not parent.is_file() or work.exists() or work.is_symlink():
        raise ValueError("regular parent and fresh output directory required")
    parent = parent.resolve(strict=True)
    work = work.parent.resolve(strict=True) / work.name
    if work == parent or work in parent.parents:
        raise ValueError("output overlaps parent")
    if merge.sha256_file(parent) != PARENT:
        raise ValueError("parent identity mismatch")
    before = merge.identity(parent)
    entries = merge.read_pack(parent)
    with parent.open("rb") as stream:
        offset, size, _ = entries[TARGET]
        stream.seek(offset)
        original = stream.read(size)
    changed = patch_scene(original)
    work.mkdir()
    project = work / "project"
    project.mkdir()
    (project / "project.godot").write_text('[application]\nconfig/name="Map canvas fixture"\n')
    (project / ".godot").mkdir()
    (project / ".godot/global_script_class_cache.cfg").write_text("list=[]\n")
    (project / "original.tscn").write_bytes(original)
    (project / "candidate.tscn").write_bytes(changed)
    fixture = Path(__file__).with_name("map_canvas_fixture.gd")
    (project / "test.gd").write_bytes(fixture.read_bytes())
    delta = work / "map-canvas.pck"
    low.write_pack([(TARGET, project / "candidate.tscn")], delta)
    patch = merge.read_pack(delta)
    if set(patch) != {TARGET}:
        raise ValueError("replacement closed set mismatch")
    packs = work / "packs"
    packs.mkdir()
    fd, name = tempfile.mkstemp(prefix=".map-canvas-", suffix=".incoming", dir=packs)
    temporary = Path(name)
    try:
        directory = []
        with os.fdopen(fd, "w+b") as out, parent.open("rb") as source, delta.open("rb") as overlay:
            out.write(struct.pack("<6I2Q", *merge.HEADER, 2, 112, 0) + bytes(72))
            for key in sorted(entries):
                entry = patch[key] if key in patch else entries[key]
                position = out.tell() - 112
                if key in patch:
                    merge.transfer(source, entries[key])
                merge.transfer(overlay if key in patch else source, entry, out)
                directory.append((key, position, entry[1], entry[2]))
                out.write(bytes((-out.tell()) % 16))
            position = out.tell()
            out.write(struct.pack("<I", len(directory)))
            for key, offset, length, md5 in directory:
                raw = ("res://" + key).encode()
                raw += bytes((-len(raw)) % 4)
                out.write(struct.pack("<I", len(raw)) + raw + struct.pack("<QQ16sI", offset, length, md5, 0))
            out.seek(32)
            out.write(struct.pack("<Q", position))
            out.flush()
            os.fsync(out.fileno())
        if merge.identity(parent) != before:
            raise ValueError("parent changed")
        result = merge.read_pack(temporary)
        if {k: v[1:] for k, v in result.items()} != {k: patch.get(k, v)[1:] for k, v in entries.items()}:
            raise ValueError("merged inventory differs")
        with temporary.open("rb") as stream:
            for entry in result.values():
                merge.transfer(stream, entry)
        merged_sha = merge.sha256_file(temporary)
        main = packs / (merged_sha + ".pck")
        temporary.rename(main)
        delta_sha = merge.sha256_file(delta)
        st = merge.identity(main)
        sidecar = {"source_sha256": PARENT, "overlay_sha256": delta_sha, "merged_sha256": merged_sha,
                   "source_stat": {k: before[k] for k in ("size", "mtime_ns")},
                   "merged_stat": {k: st[k] for k in ("size", "mtime_ns")}}
        main.with_suffix(".json").write_text(json.dumps(sidecar, sort_keys=True) + "\n")
        report = {"base_main_sha256": PARENT, "delta_sha256": delta_sha, "merged_sha256": merged_sha,
                  "target": TARGET, "before_sha256": SCENE, "after_sha256": hashlib.sha256(changed).hexdigest(),
                  "builder_sha256": merge.sha256_file(Path(__file__)), "fixture_sha256": merge.sha256_file(fixture),
                  "physical_size": [[960, 1620], [480, 810]], "logical_size": [960, 1620],
                  "unchanged_entries": len(entries) - 1,
                  "limitations": ["Fixture must be run separately before a device trial.",
                    "RGBA8 base-layer reduction is nominal, not measured allocation or RSS.",
                    "Lower raster resolution may soften ink; input, erase, reopening and LAN still need validation."]}
        (work / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps({"main": str(main), "sha256": merged_sha, "delta_sha256": delta_sha}))
    finally:
        if temporary.exists():
            temporary.unlink()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-main", type=Path, required=True)
    parser.add_argument("--work-dir", type=Path, required=True)
    args = parser.parse_args()
    build(args.base_main, args.work_dir)
