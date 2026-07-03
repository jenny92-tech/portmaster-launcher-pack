#!/usr/bin/env python3
import json
import os
import sys


def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def image_value(value, fallback):
    if isinstance(value, dict):
        image = dict(fallback or {})
        image.update(value)
        image.setdefault("covers", [])
        image.setdefault("thumbnail", None)
        image.setdefault("video", None)
        return image
    if value is None:
        return fallback
    return value


def main():
    if len(sys.argv) != 4:
        sys.exit("usage: port_json.py <manifest.json> <dist-dir> <port-folder>")

    manifest_path, dist_dir, port_folder = sys.argv[1:4]
    with open(manifest_path, "r", encoding="utf-8") as fh:
        manifest = json.load(fh)

    pm = manifest.get("portmaster", {})
    port_dir = manifest.get("port_dir") or pm.get("port_dir") or manifest.get("id") or port_folder
    script = manifest.get("script") or manifest.get("dist", {}).get("script") or f"{port_folder}.sh"
    title = manifest.get("title") or manifest.get("name") or port_dir
    porter = as_list(pm.get("porter") or manifest.get("porter") or "jenny92-tech")

    screenshot_path = os.path.join(os.path.dirname(manifest_path), "screenshot.png")
    default_image = (
        {
            "screenshot": "screenshot.png",
            "covers": [],
            "thumbnail": None,
            "video": None,
        }
        if os.path.exists(screenshot_path)
        else None
    )

    attr_defaults = {
        "title": title,
        "porter": porter,
        "desc": pm.get("desc") or manifest.get("notes") or "",
        "desc_md": pm.get("desc_md"),
        "inst": pm.get("inst") or "",
        "inst_md": pm.get("inst_md"),
        "genres": as_list(pm.get("genres")),
        "image": image_value(pm.get("image"), default_image),
        "rtr": bool(pm.get("rtr", False)),
        "exp": bool(pm.get("exp", True)),
        "runtime": as_list(pm.get("runtime")),
        "store": as_list(pm.get("store")),
        "availability": pm.get("availability") or "paid",
        "reqs": as_list(pm.get("reqs")),
        "arch": as_list(pm.get("arch") or "aarch64"),
        "min_glibc": pm.get("min_glibc") or "",
    }
    attr_defaults.update(pm.get("attr", {}))

    port_json = {
        "version": int(pm.get("version", 4)),
        "name": pm.get("zip_name") or f"{port_dir}.zip",
        "items": as_list(pm.get("items") or [script, port_dir]),
        "items_opt": as_list(pm.get("items_opt")),
        "attr": attr_defaults,
    }

    os.makedirs(dist_dir, exist_ok=True)
    with open(os.path.join(dist_dir, "port.json"), "w", encoding="utf-8") as fh:
        json.dump(port_json, fh, ensure_ascii=False, indent=2)
        fh.write("\n")


if __name__ == "__main__":
    main()
