#!/usr/bin/env python3
# INPUT:  公共组件目录、机型定义、机型环境定义和游戏的图形接口声明
# OUTPUT: 机型识别、环境依赖解析和缺少能力的明确错误
# POS:    将游戏需求与硬件环境、共享实现分离，在启动前组合三者
from __future__ import annotations

import hashlib
import json
import os
import platform
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent
GAME_ENV = {"SteamAppId", "SteamGameId", "DXVK_HUD", "DXVK_FRAME_RATE"}
GRAPHICS_APIS = {"d3d9", "d3d10", "d3d11", "d3d12", "vulkan"}


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", value):
        raise ValueError("无效配置标识")
    return value


def load_json(path):
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("配置应为对象：" + str(path))
    return data


def load_definition(path, boundary=None, chain=()):
    path = Path(path).resolve()
    boundary = Path(boundary).resolve() if boundary else path.parent
    path.relative_to(boundary)
    if path in chain or len(chain) >= 8:
        raise ValueError("配置继承存在循环或层级过深")
    data = load_json(path)
    parent = data.pop("extends", None)
    if parent is None:
        return data
    base = load_definition(boundary / relative_path(parent), boundary, (*chain, path))

    def merge(left, right):
        result = dict(left)
        for key, value in right.items():
            result[key] = merge(result[key], value) if isinstance(value, dict) and isinstance(result.get(key), dict) else value
        return result

    return merge(base, data)


def relative_path(value):
    if not isinstance(value, str):
        raise ValueError("需要目录内的相对路径")
    path = Path(value)
    if not value or path.is_absolute() or ".." in path.parts or "\\" in value or "\0" in value:
        raise ValueError("需要目录内的相对路径")
    return path


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def detect_device(root=ROOT, system_root=Path("/"), machine=None):
    machine = machine or platform.machine()
    os_release = {}
    release = Path(system_root) / "etc/os-release"
    if release.is_file():
        for line in release.read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                key, value = line.split("=", 1)
                os_release[key] = value.strip().strip('"').strip("'")
    compatible_file = Path(system_root) / "proc/device-tree/compatible"
    compatible = compatible_file.read_bytes().decode(errors="replace").split("\0") if compatible_file.is_file() else []
    matches = []
    for path in sorted((Path(root) / "devices").glob("*.json")):
        device = load_definition(path, Path(root) / "devices")
        rule = device["detect"]
        if (machine == rule["machine"] and os_release.get("ID") == rule["os_id"]
                and os_release.get("VERSION_ID") == rule["os_version"] and rule["compatible"] in compatible
                and all((Path(system_root) / name.lstrip("/")).exists() for name in rule.get("required_files", []))):
            matches.append(device)
    if len(matches) != 1:
        raise RuntimeError("尚无匹配此机型与固件的 Wine 环境；不会按相似芯片猜测安装")
    return matches[0]


def load_environment(device, root=ROOT):
    environment = load_definition(Path(root) / "environments" / (identifier(device["environment"]) + ".json"), Path(root) / "environments")
    if environment["machine"] != device["machine"]:
        raise ValueError("机型与环境架构不一致")
    return environment


def resolve_components(environment, graphics_api="", root=ROOT):
    catalog = load_json(Path(root) / "components/catalog.json")["components"]
    selected = list(environment["base_components"]) + list(environment.get("additional_components", []))
    graphics = None
    if graphics_api:
        if graphics_api not in GRAPHICS_APIS:
            raise ValueError("未知图形接口：" + graphics_api)
        graphics = environment.get("graphics", {}).get(graphics_api)
        if graphics is None:
            reason = environment.get("unsupported_graphics", {}).get(graphics_api, "未提供实现")
            raise RuntimeError(environment["label"] + " 不支持 " + graphics_api.upper() + "：" + reason)
        selected += graphics["components"]
        provider = catalog[graphics["provider"]]
        graphics = dict(graphics, directory=provider.get("runtime_path", ""))
        relative_path(graphics["directory"])
        for name in graphics["dlls"]:
            if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_]+\.dll", name):
                raise ValueError("图形组件 DLL 名称无效")
            if graphics["directory"] + "/" + name not in provider["files"]:
                raise ValueError("提供者缺少声明的 DLL：" + name)
        if graphics_api not in provider.get("provides", []):
            raise ValueError("环境选择的组件未提供所需图形接口")
    result, visiting = [], set()

    def include(name):
        identifier(name)
        if name in visiting:
            raise ValueError("运行组件依赖存在循环")
        if name in [item["id"] for item in result]:
            return
        visiting.add(name)
        component = catalog[name]
        for dependency in component.get("requires", []):
            include(dependency)
        visiting.remove(name)
        result.append(dict(component, id=name))

    for name in selected:
        include(name)
    return result, graphics


def host_requirements(device, environment, system_root=Path("/")):
    paths = environment.get("required_host_files", []) + [device["controller_device"]]
    return [path for path in paths if not (Path(system_root) / path.lstrip("/")).exists()]


def launcher_asset(path, app_root=ROOT):
    return Path(os.environ.get("WINE_RUNNER_BOOTSTRAP", app_root)) / path
