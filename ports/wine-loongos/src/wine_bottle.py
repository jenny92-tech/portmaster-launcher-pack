#!/usr/bin/env python3
# INPUT:  社区 bottle.json、可选 wine_runner 启动声明与游戏包目录
# OUTPUT: 已校验的运行器、依赖、环境和资源/输入路径声明
# POS:    把 ROCKNIX 社区游戏描述接入公共运行器，不执行第三方启动脚本
from wine_catalog import GAME_ENV, GRAPHICS_APIS, load_json, relative_path
from wine_game import game_path


def load_bottle(directory):
    data = load_json(game_path(directory, "bottle.json"))
    runner = data.get("runner", "default")
    if runner not in ("default", "wine-wow64"):
        raise ValueError("尚未提供此 Wine runner：" + str(runner))
    dependencies = data.get("deps", [])
    if not isinstance(dependencies, list) or not all(isinstance(value, str) for value in dependencies):
        raise ValueError("bottle.json 的 deps 应为依赖名称列表")
    unsupported = set(dependencies) - {"dxvk", "vkd3d-proton"}
    if unsupported:
        raise ValueError("尚未提供依赖组件：" + ", ".join(sorted(unsupported)))
    environment = data.get("env", {})
    if not isinstance(environment, dict) or not all(isinstance(value, str) and "\0" not in value for value in environment.values()):
        raise ValueError("bottle.json 的 env 应为字符串对象")
    if environment.get("WINEARCH", "win64") != "win64":
        raise ValueError("当前运行器仅提供 win64 Wine prefix")
    if environment.get("WINEDEBUG", "-all") != "-all":
        raise ValueError("当前 bottle 仅支持 WINEDEBUG=-all")
    if set(environment) - GAME_ENV - {"WINEARCH", "WINEDEBUG"}:
        raise ValueError("bottle.json 不能覆盖机型、驱动或运行器环境")
    configdirs = data.get("configdir", [])
    if not isinstance(configdirs, list):
        raise ValueError("configdir 应为 prefix 内的目录列表")
    for value in configdirs:
        path = relative_path(value)
        if not path.parts or path.parts[0] != "drive_c":
            raise ValueError("configdir 必须位于 prefix 的 drive_c 内")
    settings = data.get("wine_runner", {})
    if not isinstance(settings, dict):
        raise ValueError("wine_runner 应为启动声明对象")
    allowed = {"adapter", "executable", "graphics_api", "arguments", "input_mapping", "input_help", "borderless_fullscreen"}
    if set(settings) - allowed:
        raise ValueError("wine_runner 包含未支持的启动字段")
    if settings.get("adapter") and set(settings) - {"adapter", "input_mapping"}:
        raise ValueError("已有 adapter 时，EXE、图形接口和参数由 adapter.json 声明")
    if settings.get("graphics_api", "") not in ("", *GRAPHICS_APIS):
        raise ValueError("未知图形接口")
    mapping = None
    if settings.get("input_mapping"):
        mapping = game_path(directory, settings["input_mapping"])
        if mapping.suffix != ".gptk" or not mapping.is_file():
            raise ValueError("bottle 输入方案需要包目录内的 gptk 文件")
    attributes = data.get("attr", {})
    if not isinstance(attributes, dict) or not isinstance(attributes.get("title", ""), str):
        raise ValueError("bottle 的 attr.title 应为字符串")
    resources = game_path(directory, "data")
    return {"settings": settings, "dependencies": dependencies,
            "environment": {key: value for key, value in environment.items() if key in GAME_ENV},
            "title": attributes.get("title") or directory.name, "directory": resources,
            "input_mapping": mapping, "config_directories": configdirs}


def check_graphics_dependencies(dependencies, graphics_api):
    if "dxvk" in dependencies and graphics_api not in {"d3d9", "d3d10", "d3d11"}:
        raise ValueError("依赖 dxvk 时需在 wine_runner 或游戏适配中明确 D3D9/10/11 接口")
    if "vkd3d-proton" in dependencies and graphics_api != "d3d12":
        raise ValueError("依赖 vkd3d-proton 时需明确 D3D12 接口")
