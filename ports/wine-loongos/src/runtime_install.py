#!/usr/bin/env python3
# INPUT:  固定校验值的共享组件、机型环境、私有 ext4 映像和标准 ZIP/展开的离线组件
# OUTPUT: 可重试的组件安装、原子运行库切换及独立保留的玩家数据
# POS:    为所有游戏共用的 Wine 环境提供一键安装，不导入游戏文件
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import posixpath
import shutil
import subprocess
import tarfile
import tempfile
from urllib.parse import urlparse
from urllib.request import urlopen

from runtime_mount import verify_mount
from wine_catalog import ROOT, detect_device, digest, host_requirements, load_environment, load_json, load_definition, relative_path, resolve_components
from wine_layout import resolve_library, offline_directory
from wine_package import import_runtime_packages


IMAGE_BYTES = 2 * 1024 ** 3


def mounted_runtime(base, mount, create=False):
    base, mount = Path(base).resolve(), Path(mount).resolve()
    base.mkdir(parents=True, exist_ok=True)
    image = base / "runtime.ext4"
    if image.is_symlink():
        raise RuntimeError("运行映像不能是符号链接")
    if not image.exists():
        if not create:
            raise RuntimeError("运行环境未安装，请选择安装环境")
        mkfs = shutil.which("mke2fs")
        if not mkfs:
            raise RuntimeError("固件缺少 mke2fs，无法创建私有运行映像")
        if shutil.disk_usage(base).free < IMAGE_BYTES + 128 * 1024 ** 2:
            raise RuntimeError("安装环境至少需要 2 GiB 加下载缓存的可用空间")
        with tempfile.NamedTemporaryFile(dir=base, prefix=".runtime-", suffix=".ext4", delete=False) as stream:
            temporary = Path(stream.name)
            stream.truncate(IMAGE_BYTES)
        try:
            subprocess.run([mkfs, "-q", "-t", "ext4", "-F", str(temporary)], check=True)
            temporary.rename(image)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    if not image.is_file():
        raise RuntimeError("运行映像必须为普通文件")
    if not os.path.ismount(mount):
        mount.mkdir(parents=True, exist_ok=True)
        subprocess.run(["mount", "-o", "loop,rw,exec,nosuid,nodev,noatime", str(image), str(mount)], check=True)
    verify_mount(mount, image)
    return mount


def copy_download(source, target, component):
    total = 0
    expected = component["bytes"]
    while True:
        block = source.read(1024 * 1024)
        if not block:
            break
        total += len(block)
        if total > expected:
            raise RuntimeError("组件校验失败：下载大小超出目录记录")
        target.write(block)
    if total != expected:
        raise RuntimeError("组件校验失败：下载不完整")


def acquire(component, cache, offline=None, progress=print):
    cache = Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    filename = relative_path(component["archive"])
    if len(filename.parts) != 1:
        raise ValueError("组件包名不能包含目录")
    destination = cache / filename
    expected = component["sha256"]
    if destination.is_file() and not destination.is_symlink() and digest(destination) == expected:
        return destination
    source = Path(offline) / filename if offline else None
    progress("准备组件：" + component["id"])
    if not (source is not None and source.is_file()) and urlparse(component.get("url", "")).scheme != "https":
        raise RuntimeError("缺少离线组件 " + str(filename) + "；此构建尚未配置 HTTPS 发布地址")
    with tempfile.NamedTemporaryFile(dir=cache, prefix=".download-", delete=False) as target:
        temporary = Path(target.name)
        if source is not None and source.is_file():
            with source.open("rb") as stream:
                copy_download(stream, target, component)
        else:
            url = component.get("url", "")
            if urlparse(url).scheme != "https":
                raise RuntimeError("缺少离线组件 " + str(filename) + "；此构建尚未配置 HTTPS 发布地址")
            with urlopen(url, timeout=30) as stream:
                if urlparse(stream.geturl()).scheme != "https":
                    raise RuntimeError("组件下载不能降级到非 HTTPS")
                copy_download(stream, target, component)
        target.flush()
        os.fsync(target.fileno())
    if digest(temporary) != expected:
        raise RuntimeError("组件校验失败，保留现有环境：" + component["id"])
    temporary.replace(destination)
    return destination


def extract_component(archive, target, component):
    target = Path(target)
    allowed = {str(relative_path(name)) for name in component["files"]}
    seen = set()
    with tarfile.open(archive, "r:*") as package:
        for entry in package:
            path = relative_path(entry.name.rstrip("/"))
            if str(path) not in allowed or str(path) in seen or not (entry.isfile() or entry.issym()):
                raise ValueError("组件包含未声明或不支持的文件：" + entry.name)
            seen.add(str(path))
            destination = target / path
            if destination.exists() or destination.is_symlink():
                raise ValueError("组件之间存在路径冲突：" + str(path))
            for parent in path.parents:
                if parent != Path(".") and (target / parent).is_symlink():
                    raise ValueError("组件写入路径包含符号链接")
            destination.parent.mkdir(parents=True, exist_ok=True)
            if entry.issym():
                resolved = posixpath.normpath(posixpath.join(str(path.parent), entry.linkname))
                if entry.linkname.startswith("/") or resolved == ".." or resolved.startswith("../"):
                    raise ValueError("组件链接越过运行库边界")
                destination.symlink_to(entry.linkname)
            else:
                with package.extractfile(entry) as source, destination.open("xb") as output:
                    shutil.copyfileobj(source, output)
                destination.chmod(0o755 if entry.mode & 0o111 else 0o644)
    if seen != allowed:
        raise ValueError("组件文件清单不完整")


def release_installed(release, components):
    receipt = Path(release) / ".components.json"
    if not receipt.is_file():
        return False
    actual = load_json(receipt).get("components", {})
    return all(actual.get(item["id"]) == item["sha256"]
               and all((Path(release) / name).exists() for name in item["files"])
               for item in components)


def installed(runtime, components):
    return release_installed(Path(runtime) / "runtime", components)


def reuse_component(current, staging, component):
    for name in component["files"]:
        path = relative_path(name)
        source, target = current / path, staging / path
        if target.exists() or target.is_symlink():
            raise ValueError("组件之间存在路径冲突：" + name)
        if any((staging / parent).is_symlink() for parent in path.parents if parent != Path(".")):
            raise ValueError("组件写入路径包含符号链接")
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.is_symlink():
            target.symlink_to(source.readlink())
        else:
            os.link(source, target, follow_symlinks=False)


def install_components(runtime, components, cache, offline=None, progress=print):
    runtime = Path(runtime)
    runtime.mkdir(parents=True, exist_ok=True)
    with (runtime / "environment.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        current = runtime / "runtime"
        if current.exists() and not current.is_symlink():
            raise RuntimeError("检测到手工准备的旧环境；请使用新的数据目录，保留原目录中的玩家数据")
        if installed(runtime, components):
            progress("所需运行组件已安装")
            return
        # Keep previously installed providers when adding another game's needs.
        receipt = runtime / "runtime/.components.json"
        previous = load_json(receipt).get("components", {}) if receipt.is_file() else {}
        if previous:
            catalog = load_json(ROOT / "components/catalog.json")["components"]
            requested = {item["id"]: item for item in components}
            for name in previous:
                if name not in requested:
                    requested[name] = dict(catalog[name], id=name)
            components = list(requested.values())
        archives = [(item, acquire(item, cache, offline, progress)) for item in components]
        reusable = {item["id"] for item in components if previous.get(item["id"]) == item["sha256"]
                    and all((runtime / "runtime" / name).exists() for name in item["files"])}
        needed = sum(item["unpacked_bytes"] for item in components if item["id"] not in reusable) + 64 * 1024 ** 2
        if shutil.disk_usage(runtime).free < needed:
            raise RuntimeError("运行映像空间不足；现有运行库和存档保持不变")
        releases = runtime / "releases"
        releases.mkdir(exist_ok=True)
        identity = hashlib.sha256(json.dumps({x["id"]: x["sha256"] for x in components}, sort_keys=True).encode()).hexdigest()[:16]
        destination = releases / identity
        if destination.exists() and not release_installed(destination, components):
            destination = Path(tempfile.mkdtemp(prefix=identity + "-repair-", dir=releases)) / "runtime"
        if not destination.exists():
            staging = Path(tempfile.mkdtemp(prefix=".install-", dir=releases))
            try:
                for item, archive in archives:
                    progress("安装组件：" + item["id"])
                    if item["id"] in reusable:
                        reuse_component(runtime / "runtime", staging, item)
                    else:
                        extract_component(archive, staging, item)
            except BaseException:
                shutil.rmtree(staging)
                raise
            (staging / ".components.json").write_text(json.dumps({"components": {x["id"]: x["sha256"] for x in components}}, sort_keys=True))
            staging.rename(destination)
        pointer = runtime / ".runtime-next"
        if pointer.is_symlink():
            pointer.unlink()
        pointer.symlink_to(destination.relative_to(runtime))
        pointer.replace(current)
        for directory in ("prefixes/default", "sessions", "logs", "input"):
            (runtime / directory).mkdir(parents=True, exist_ok=True)
        progress("环境安装完成；玩家数据未参与运行库替换")


def install(base, device, graphics_apis=(), root=ROOT, offline=None, progress=print):
    base = Path(base)
    base.mkdir(parents=True, exist_ok=True)
    with (base / "installation.lock").open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RuntimeError("另一个环境安装任务正在进行") from exc
        environment = load_environment(device, root)
        missing = host_requirements(device, environment)
        if missing:
            raise RuntimeError("固件或 PortMaster 缺少：" + "、".join(missing))
        components = {}
        for api in ["", *graphics_apis]:
            for item in resolve_components(environment, api, root)[0]:
                components[item["id"]] = item
        cache = Path(base) / "downloads"
        library = resolve_library(device)
        offline = offline if offline is not None else offline_directory(library)
        import_runtime_packages(library, list(components.values()), cache, environment,
                                offline=offline, root=root, progress=progress)
        # Download before creating/mounting an image, so unavailable sources change no runtime.
        for item in components.values():
            acquire(item, cache, offline, progress)
        runtime = mounted_runtime(base, device["runtime_mount"], create=True)
        install_components(runtime, list(components.values()), cache, offline, progress)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Install shared Wine components for a supported device")
    parser.add_argument("--base", required=True, type=Path)
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--offline", type=Path, help="离线组件目录或带身份清单的标准 ZIP，可使用任意文件名")
    parser.add_argument("--graphics", action="append", default=[])
    parser.add_argument("--mount-existing", type=Path)
    args = parser.parse_args(argv)
    if args.mount_existing:
        mounted_runtime(args.base, args.mount_existing)
    else:
        device = load_definition(args.profile, args.profile.parent) if args.profile else detect_device()
        install(args.base, device, args.graphics, offline=args.offline or offline_directory(resolve_library(device)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
