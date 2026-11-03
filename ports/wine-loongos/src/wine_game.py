#!/usr/bin/env python3
# INPUT:  不含游戏内容的适配定义、玩家完整游戏目录及可选已处理入口
# OUTPUT: 文件/版本检查、准备状态与仅位于玩家目录内的启动副本
# POS:    管理游戏自己的资源要求和准备规则，不选择机型或图形实现
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

from wine_catalog import ROOT, GAME_ENV, GRAPHICS_APIS, digest, identifier, load_json, relative_path


ADAPTER_FIELDS = {"id", "title", "executable", "graphics_api", "architecture", "required_files", "arguments",
                  "borderless_fullscreen", "screen_arguments", "environment", "input_mapping", "input_help", "preparation", "status", "patches", "file_hashes"}


def game_path(directory, name):
    directory = Path(directory).resolve()
    path = directory / relative_path(name)
    path.resolve().relative_to(directory)
    return path


def adapter_directory(name, root=ROOT):
    name = identifier(name)
    root = Path(root)
    library = root.parent.parent if root.parent.name == ".winecellar" else root.parent
    installed = library / name
    return installed if (installed / "adapter.json").is_file() else root / "adapters" / name


def load_adapter(name, root=ROOT, directory=None):
    identifier(name)
    directory = Path(directory) if directory is not None else adapter_directory(name, root)
    adapter = load_json(game_path(directory, "adapter.json"))
    if set(adapter) - ADAPTER_FIELDS:
        raise ValueError("游戏适配包混入未允许字段：" + ",".join(sorted(set(adapter) - ADAPTER_FIELDS)))
    if adapter["id"] != name or adapter["graphics_api"] not in GRAPHICS_APIS or adapter["architecture"] != "x86_64":
        raise ValueError("游戏适配标识、图形接口或架构无效")
    if not isinstance(adapter["arguments"], list) or not all(isinstance(value, str) and "\0" not in value for value in adapter["arguments"]):
        raise ValueError("游戏参数必须为字符串列表")
    if not isinstance(adapter["environment"], dict) or not set(adapter["environment"]).issubset(GAME_ENV) or not all(isinstance(value, str) and "\0" not in value for value in adapter["environment"].values()):
        raise ValueError("游戏适配不能改写机型进程环境")
    for filename in [adapter["executable"], *adapter["required_files"]]:
        relative_path(filename)
    if adapter.get("input_mapping"):
        mapping = game_path(directory, adapter["input_mapping"])
        if mapping.suffix != ".gptk" or not mapping.is_file():
            raise ValueError("游戏输入方案需要适配目录内的 gptk 文件")
    return adapter


def inspect_game(directory, adapter):
    result = inspect_executable(directory, adapter)
    if result["state"] != "ready":
        return result
    options = game_path(directory, ".wine/patch-options.json")
    enabled = load_json(options).get("enabled", []) if options.is_file() else []
    overrides = {}
    for patch in adapter.get("patches", []):
        if patch.get("optional", False) and patch["id"] not in enabled:
            continue
        if digest(game_path(directory, patch["file"])) != patch["input_sha256"]:
            return dict(result, state="unsupported-version", message="游戏资源版本不匹配：" + patch["file"])
        target = game_path(directory, ".wine/patched/" + patch["file"])
        if not target.is_file() or digest(target) != patch["output_sha256"]:
            return dict(result, state="needs-resource-preparation", message="需要准备游戏资源补丁：" + patch["id"])
        overrides[patch["file"]] = str(target.relative_to(Path(directory).resolve()))
    return dict(result, resource_overrides=overrides)


def prepare_resources(directory, adapter, enabled=()):
    known = {patch["id"] for patch in adapter.get("patches", [])}
    if set(enabled) - known:
        raise ValueError("未知可选游戏补丁")
    files = set()
    for patch in adapter.get("patches", []):
        identifier(patch["id"])
        if patch.get("optional", False) and patch["id"] not in enabled:
            continue
        if patch["file"] in files:
            raise ValueError("同一文件的修改必须合并成一个已校验补丁")
        files.add(patch["file"])
        original = game_path(directory, patch["file"])
        if digest(original) != patch["input_sha256"]:
            raise ValueError("游戏资源版本不匹配：" + patch["file"])
        target = game_path(directory, ".wine/patched/" + patch["file"])
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.is_file() and digest(target) == patch["output_sha256"]:
            continue
        temporary = target.with_name(target.name + ".preparing")
        with original.open("rb") as source, temporary.open("xb") as output:
            shutil.copyfileobj(source, output)
            for edit in patch["writes"]:
                offset, replacement = edit["offset"], bytes.fromhex(edit["hex"])
                if type(offset) is not int or offset < 0 or offset + len(replacement) > original.stat().st_size:
                    raise ValueError("游戏补丁写入越过文件边界")
                output.seek(offset)
                output.write(replacement)
        if digest(temporary) != patch["output_sha256"]:
            raise ValueError("游戏补丁结果校验失败，原文件未改动")
        temporary.replace(target)
    if adapter.get("patches"):
        options = game_path(directory, ".wine/patch-options.json")
        options.parent.mkdir(parents=True, exist_ok=True)
        options.write_text(json.dumps({"enabled": sorted(enabled)}))


def inspect_executable(directory, adapter):
    missing = [name for name in adapter["required_files"] if not game_path(directory, name).is_file()]
    if missing:
        return {"state": "missing-files", "missing": missing, "message": "待补游戏文件（" + str(len(missing)) + "项），例如：" + missing[0], "override": None}
    for name, expected in adapter.get("file_hashes", {}).items():
        if digest(game_path(directory, name)) != expected:
            return {"state": "unsupported-version", "message": "游戏文件版本不匹配：" + name, "override": None}
    recipe = adapter.get("preparation")
    if not recipe:
        return {"state": "ready", "message": adapter["status"], "override": None}
    if recipe["kind"] != "verified-executable":
        raise ValueError("未知游戏准备规则")
    source = game_path(directory, adapter["executable"])
    checksum = digest(source)
    if checksum == recipe["output_sha256"]:
        return {"state": "ready", "message": adapter["status"], "override": None}
    if checksum != recipe["source_sha256"]:
        return {"state": "unsupported-version", "message": "游戏入口版本不匹配；请使用适配包支持的版本", "override": None}
    prepared = game_path(directory, recipe["output"])
    if prepared.is_file() and digest(prepared) == recipe["output_sha256"]:
        return {"state": "ready", "message": adapter["status"], "override": prepared}
    return {"state": "needs-preparation", "message": "需在电脑运行准备工具，再复制完整目录到掌机", "override": None}


def prepare_executable(directory, adapter, tool_directory, docker_image):
    state = inspect_executable(directory, adapter)
    if state["state"] == "ready":
        return state
    if state["state"] != "needs-preparation":
        raise ValueError(state["message"])
    recipe = adapter["preparation"]
    tools = Path(tool_directory).resolve()
    contract = load_json(tools / "tool.json")
    if contract["id"] != recipe["tool"]:
        raise ValueError("准备工具与游戏规则不匹配")
    for name, expected in contract["files"].items():
        if digest(game_path(tools, name)) != expected:
            raise ValueError("准备工具校验失败")
    if not docker_image.startswith("sha256:") or len(docker_image) != 71:
        raise ValueError("准备工具必须使用显式的本地 Docker 镜像完整 ID")
    # Only the one input executable and a private output directory enter Docker.
    # No game code is executed, no host home/auth stores/network are exposed.
    with tempfile.TemporaryDirectory(prefix="wine-game-prepare-") as temporary:
        work = Path(temporary)
        source = game_path(directory, adapter["executable"])
        shutil.copyfile(source, work / "input.exe")
        command = ["docker", "run", "--pull", "never", "--rm", "--network", "none", "--read-only", "--cap-drop", "ALL",
                   "--security-opt", "no-new-privileges", "--pids-limit", "128", "--memory", "512m",
                   "--tmpfs", "/tmp:rw,nosuid,nodev,noexec,size=64m", "--mount", "type=bind,src=" + str(tools) + ",dst=/tools,readonly",
                   "--mount", "type=bind,src=" + str(work) + ",dst=/work", "--workdir", "/work",
                   "--env", "MONO_ENV_OPTIONS=--interpreter", docker_image, "mono", "/tools/Steamless.CLI.exe", "/work/input.exe"]
        subprocess.run(command, check=True)
        result = work / "input.exe.unpacked.exe"
        if not result.is_file() or digest(result) != recipe["output_sha256"]:
            raise RuntimeError("处理结果校验不匹配；未改动原游戏")
        output = game_path(directory, recipe["output"])
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary_output = output.with_name(output.name + ".preparing")
        if temporary_output.exists() or temporary_output.is_symlink():
            raise ValueError("准备输出临时文件已存在")
        with result.open("rb") as source_file, temporary_output.open("xb") as target:
            shutil.copyfileobj(source_file, target)
        temporary_output.replace(output)
    return inspect_game(directory, adapter)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Check/prepare user-supplied Windows game files on a computer")
    parser.add_argument("--adapter", required=True)
    parser.add_argument("--game", required=True, type=Path)
    parser.add_argument("--root", default=ROOT, type=Path)
    parser.add_argument("--adapter-directory", type=Path, help="Windows 库中包含 adapter.json 的游戏包目录")
    parser.add_argument("--tools", type=Path)
    parser.add_argument("--docker-image")
    parser.add_argument("--apply-patches", action="store_true")
    parser.add_argument("--patch", action="append", default=[])
    args = parser.parse_args(argv)
    adapter = load_adapter(args.adapter, args.root, args.adapter_directory)
    state = prepare_executable(args.game, adapter, args.tools, args.docker_image) if args.tools else inspect_game(args.game, adapter)
    if args.apply_patches or args.patch:
        if state["state"] not in {"ready", "needs-resource-preparation"}:
            raise ValueError(state["message"])
        prepare_resources(args.game, adapter, args.patch)
        state = inspect_game(args.game, adapter)
    print(json.dumps(state, ensure_ascii=False, default=str, indent=2))
    return 0 if state["state"] == "ready" else 2


if __name__ == "__main__":
    raise SystemExit(main())
