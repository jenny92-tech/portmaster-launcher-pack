#!/usr/bin/env python3
"""Dependency-free structural and semantic validator for the config contract."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


PLATFORMS = {
    "miniloong",
    "trimui",
    "muos",
    "rocknix",
    "jelos",
    "unofficialos",
    "knulli",
    "batocera",
    "miyoo",
    "generic",
}
PREDICATES = {
    "always",
    "all",
    "any",
    "directory_exists",
    "env_equals",
    "file_exists",
    "launcher_path_prefix",
    "os_release_equals",
}
PATH_STRATEGIES = {
    "first_existing",
    "launcher_dir",
    "literal",
    "literal_by_launcher_prefix",
    "parent",
    "platform_core",
    "relative_to",
    "rom_root_from_launcher",
    "xdg_data_home",
}
SUPPORTED_ADAPTER_KINDS = {"predicate", "path", "frontend", "library", "python"}
HEALTH_RULES = {
    "archive_or_nonempty_directory",
    "executable_file",
    "one_of_files",
    "python_imports_or_runtime",
    "required_file",
}
FORBIDDEN_KEYS = {"run_shell", "eval", "exec", "command", "shell"}
SAFE_ID = re.compile(r"^[a-z][a-z0-9_.-]{0,127}$")
SAFE_ENV_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")

# Top-level keys that live in the root config.json; per-platform detail is split
# into platforms/<id>.json.
ROOT_KEYS = {
    "format",
    "schema_version",
    "config_version",
    "metadata",
    "parser_limits",
    "bootstrap",
    "sources",
    "environment",
    "adapters",
    "platforms",
}
RFC3339_UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


class ConfigError(ValueError):
    pass


def fail(path: str, message: str) -> None:
    raise ConfigError(f"{path}: {message}")


def require_type(value: Any, expected: type, path: str) -> None:
    if not isinstance(value, expected) or (expected is int and isinstance(value, bool)):
        fail(path, f"expected {expected.__name__}")


def require_keys(value: dict, keys: set[str], path: str) -> None:
    missing = keys.difference(value)
    if missing:
        fail(path, f"missing keys {sorted(missing)}")


def allow_keys(value: dict, keys: set[str], path: str) -> None:
    extra = set(value).difference(keys)
    if extra:
        fail(path, f"unsupported keys {sorted(extra)}")


def walk_no_code(value: Any, path: str = "$") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key.lower() in FORBIDDEN_KEYS:
                fail(f"{path}.{key}", "executable escape hatch is forbidden")
            walk_no_code(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            walk_no_code(child, f"{path}[{index}]")


def validate_predicate(value: Any, path: str) -> None:
    require_type(value, dict, path)
    kind = value.get("kind")
    if kind not in PREDICATES:
        fail(f"{path}.kind", f"unsupported predicate {kind!r}")
    if kind in {"all", "any"}:
        allow_keys(value, {"kind", "predicates"}, path)
        children = value.get("predicates")
        require_type(children, list, f"{path}.predicates")
        if not children:
            fail(f"{path}.predicates", "must not be empty")
        for index, child in enumerate(children):
            validate_predicate(child, f"{path}.predicates[{index}]")
    elif kind in {"file_exists", "directory_exists"}:
        allow_keys(value, {"kind", "path"}, path)
        validate_absolute_path(value.get("path"), f"{path}.path")
    elif kind == "os_release_equals":
        allow_keys(value, {"kind", "field", "value", "case_insensitive"}, path)
        require_type(value.get("field"), str, f"{path}.field")
        require_type(value.get("value"), str, f"{path}.value")
    elif kind == "env_equals":
        allow_keys(value, {"kind", "name", "value", "case_insensitive"}, path)
        require_type(value.get("name"), str, f"{path}.name")
        require_type(value.get("value"), str, f"{path}.value")
    elif kind == "launcher_path_prefix":
        allow_keys(value, {"kind", "prefix"}, path)
        validate_absolute_path(value.get("prefix"), f"{path}.prefix")
    else:
        allow_keys(value, {"kind"}, path)


def validate_absolute_path(value: Any, path: str) -> None:
    require_type(value, str, path)
    if not value.startswith("/") or "\x00" in value or "\n" in value or "\r" in value:
        fail(path, "must be an absolute, single-line path")
    if any(part in {"", ".", ".."} for part in value.split("/")[1:]):
        fail(path, "must be normalized")


def validate_path_strategy(value: Any, path: str) -> None:
    require_type(value, dict, path)
    strategy = value.get("strategy")
    if strategy not in PATH_STRATEGIES:
        fail(f"{path}.strategy", f"unsupported path strategy {strategy!r}")
    allowed = {
        "literal": {"strategy", "value"},
        "first_existing": {"strategy", "candidates", "on_missing"},
        "launcher_dir": {"strategy"},
        "literal_by_launcher_prefix": {"strategy", "prefix", "matched", "fallback"},
        "parent": {"strategy", "of"},
        "platform_core": {"strategy"},
        "relative_to": {"strategy", "base", "suffix"},
        "rom_root_from_launcher": {"strategy", "suffix"},
        "xdg_data_home": {"strategy", "suffix"},
    }[strategy]
    allow_keys(value, allowed, path)
    if strategy == "literal":
        validate_absolute_path(value.get("value"), f"{path}.value")
    for key in ("candidates", "fallback"):
        if key in value:
            require_type(value[key], list, f"{path}.{key}")
            for index, candidate in enumerate(value[key]):
                validate_absolute_path(candidate, f"{path}.{key}[{index}]")
            if not value[key]:
                fail(f"{path}.{key}", "must not be empty")
    for key in ("prefix", "matched"):
        if key in value:
            validate_absolute_path(value[key], f"{path}.{key}")
    for key in ("base", "of"):
        if key in value and (not isinstance(value[key], str) or not SAFE_ID.fullmatch(value[key])):
            fail(f"{path}.{key}", "must reference a named resolved path")
    if "suffix" in value:
        suffix = value["suffix"]
        if not isinstance(suffix, str) or not suffix or suffix.startswith("/") or any(
            part in {"", ".", ".."} for part in suffix.split("/")
        ):
            fail(f"{path}.suffix", "must be a normalized relative path")
    if "on_missing" in value and value["on_missing"] != "unresolved":
        fail(f"{path}.on_missing", "must leave the path unresolved")


def validate_environment(environment: dict) -> None:
    scopes = environment.get("scopes")
    require_type(scopes, dict, "$.environment.scopes")
    expected_scopes = {"love_ui"}
    if set(scopes) != expected_scopes:
        fail("$.environment.scopes", f"must contain exactly {sorted(expected_scopes)}")
    profiles = environment.get("profiles")
    require_type(profiles, dict, "$.environment.profiles")
    operation_kinds = environment.get("operation_kinds")
    if operation_kinds != ["set", "prepend", "append", "unset"]:
        fail("$.environment.operation_kinds", "unexpected operation contract")

    def validate_operations(operations: Any, path: str) -> None:
        require_type(operations, list, path)
        for index, operation in enumerate(operations):
            item_path = f"{path}[{index}]"
            require_type(operation, dict, item_path)
            allow_keys(operation, {"operation", "name", "value", "separator"}, item_path)
            op = operation.get("operation")
            if op not in operation_kinds:
                fail(f"{item_path}.operation", "unsupported environment operation")
            name = operation.get("name")
            if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name):
                fail(f"{item_path}.name", "invalid environment name")
            if op == "unset":
                if "value" in operation or "separator" in operation:
                    fail(item_path, "unset does not accept a value or separator")
            elif not isinstance(operation.get("value"), str):
                fail(f"{item_path}.value", "must be a literal string")

    for profile_name, operations in profiles.items():
        if not SAFE_ID.fullmatch(profile_name):
            fail(f"$.environment.profiles.{profile_name}", "invalid profile id")
        validate_operations(operations, f"$.environment.profiles.{profile_name}")
    for scope_name, scope in scopes.items():
        scope_path = f"$.environment.scopes.{scope_name}"
        require_type(scope, dict, scope_path)
        require_keys(scope, {"profiles", "operations"}, scope_path)
        allow_keys(scope, {"profiles", "operations"}, scope_path)
        require_type(scope["profiles"], list, f"{scope_path}.profiles")
        for profile in scope["profiles"]:
            if profile not in profiles:
                fail(f"{scope_path}.profiles", f"undefined profile {profile!r}")
        validate_operations(scope["operations"], f"{scope_path}.operations")


def validate_platform(platform: Any, path: str) -> None:
    require_type(platform, dict, path)
    require_keys(
        platform,
        {
            "display_name",
            "priority",
            "support",
            "recognition",
            "required_adapters",
            "paths",
            "source_route",
            "frontend",
            "libraries",
            "python",
            "health",
            "preserved_dirs",
            "capabilities",
            "environment_scopes",
            "display",
            "input",
        },
        path,
    )
    if "device_manufacturer" in platform and (
        not isinstance(platform["device_manufacturer"], str) or not platform["device_manufacturer"]
    ):
        fail(f"{path}.device_manufacturer", "must be a non-empty string")
    validate_predicate(platform["recognition"], f"{path}.recognition")
    support = platform["support"]
    require_type(support, dict, f"{path}.support")
    require_keys(support, {"device_class", "target_confirmation"}, f"{path}.support")
    allow_keys(support, {"device_class", "target_confirmation"}, f"{path}.support")
    if support["device_class"] not in {"tested", "official-untested", "unsupported-known"}:
        fail(f"{path}.support.device_class", "unsupported device class")
    if support["target_confirmation"] not in {"detected", "existing_core_or_override"}:
        fail(f"{path}.support.target_confirmation", "unsupported target confirmation policy")
    require_type(platform["required_adapters"], list, f"{path}.required_adapters")
    for index, adapter in enumerate(platform["required_adapters"]):
        if not isinstance(adapter, str) or not SAFE_ID.fullmatch(adapter):
            fail(f"{path}.required_adapters[{index}]", "invalid adapter id")
    require_type(platform["paths"], dict, f"{path}.paths")
    if "launcher_directory" not in platform["paths"]:
        fail(f"{path}.paths", "missing launcher_directory")
    for name, strategy in platform["paths"].items():
        validate_path_strategy(strategy, f"{path}.paths.{name}")
    require_type(platform["health"], list, f"{path}.health")
    for index, rule in enumerate(platform["health"]):
        require_type(rule, dict, f"{path}.health[{index}]")
        if rule.get("kind") not in HEALTH_RULES:
            fail(f"{path}.health[{index}].kind", "unsupported health rule")
    entrypoint_rules = [rule for rule in platform["health"] if rule.get("kind") == "one_of_files"]
    expected_entrypoints = ["{portmaster_core}/pugwash", "{portmaster_core}/harbourmaster"]
    if len(entrypoint_rules) != 1 or entrypoint_rules[0].get("paths") != expected_entrypoints:
        fail(f"{path}.health", "must require pugwash or harbourmaster")
    for key in ("preserved_dirs", "environment_scopes"):
        require_type(platform[key], list, f"{path}.{key}")
    for key in ("frontend", "libraries", "python", "capabilities", "display", "input"):
        require_type(platform[key], dict, f"{path}.{key}")
    frontend = platform["frontend"]
    frontend_keys = {
        "management",
        "kind",
        "names",
        "primary",
        "control_source",
        "core_launcher_source",
        "remove_core_launcher",
        "empty_tasksetter",
        "core_executable",
        "frontend_executable",
        "install_map",
    }
    require_keys(frontend, frontend_keys, f"{path}.frontend")
    allow_keys(frontend, frontend_keys | {"transforms"}, f"{path}.frontend")
    for key in ("remove_core_launcher", "empty_tasksetter"):
        if not isinstance(frontend[key], bool):
            fail(f"{path}.frontend.{key}", "must be boolean")
    for key in ("control_source", "core_launcher_source", "core_executable", "frontend_executable"):
        if frontend[key] is not None and not isinstance(frontend[key], str):
            fail(f"{path}.frontend.{key}", "must be string or null")
    transforms = frontend.get("transforms", [])
    require_type(transforms, list, f"{path}.frontend.transforms")
    mapped_targets = {item.get("target") for item in frontend["install_map"]}
    for index, transform in enumerate(transforms):
        transform_path = f"{path}.frontend.transforms[{index}]"
        require_type(transform, dict, transform_path)
        require_keys(transform, {"kind", "target", "variable", "library_group"}, transform_path)
        allow_keys(transform, {"kind", "target", "variable", "library_group"}, transform_path)
        if transform["kind"] != "export_library_group":
            fail(f"{transform_path}.kind", "unsupported frontend transform")
        if transform["target"] not in mapped_targets:
            fail(f"{transform_path}.target", "must reference an installed frontend target")
        if not isinstance(transform["variable"], str) or not SAFE_ENV_NAME.fullmatch(transform["variable"]):
            fail(f"{transform_path}.variable", "invalid environment variable name")
    capability_names = {
        "install_portmaster",
        "update_portmaster",
        "repair_runtimes",
        "manage_ports",
        "manage_artwork",
        "trash",
        "leftovers",
        "cleanup_appledouble",
        "scan_script_images",
    }
    missing_capabilities = capability_names.difference(platform["capabilities"])
    if missing_capabilities:
        fail(f"{path}.capabilities", f"missing explicit capabilities {sorted(missing_capabilities)}")
    libraries = platform["libraries"]
    groups = libraries.get("groups")
    require_type(groups, dict, f"{path}.libraries.groups")
    if not groups:
        fail(f"{path}.libraries.groups", "must not be empty")
    for group_name, group in groups.items():
        group_path = f"{path}.libraries.groups.{group_name}"
        require_type(group, dict, group_path)
        require_type(group.get("required_sonames"), list, f"{group_path}.required_sonames")
        require_type(group.get("candidates"), list, f"{group_path}.candidates")
        if not group["required_sonames"] or not group["candidates"]:
            fail(group_path, "SONAMEs and candidates must not be empty")
    for index, transform in enumerate(transforms):
        if transform["library_group"] not in groups:
            fail(f"{path}.frontend.transforms[{index}].library_group", "undefined library group")
    if set(platform["environment_scopes"]) != {"love_ui"}:
        fail(f"{path}.environment_scopes", "must name every concrete execution scope")


def validate(config: Any) -> None:
    require_type(config, dict, "$")
    require_keys(
        config,
        {
            "format",
            "schema_version",
            "config_version",
            "metadata",
            "parser_limits",
            "bootstrap",
            "sources",
            "environment",
            "adapters",
            "platforms",
        },
        "$",
    )
    if config["format"] != "jenny92.appmanager-config":
        fail("$.format", "unsupported format")
    if config["schema_version"] != 1:
        fail("$.schema_version", "unsupported schema version")
    if not isinstance(config["config_version"], str) or not SEMVER.fullmatch(config["config_version"]):
        fail("$.config_version", "must be semantic version")
    metadata = config["metadata"]
    require_type(metadata, dict, "$.metadata")
    require_keys(metadata, {"generated_at", "source_revision"}, "$.metadata")
    if not isinstance(metadata["generated_at"], str) or not RFC3339_UTC.fullmatch(metadata["generated_at"]):
        fail("$.metadata.generated_at", "must be RFC3339 UTC")
    if not isinstance(metadata["source_revision"], str) or not metadata["source_revision"]:
        fail("$.metadata.source_revision", "must not be empty")
    limits = config["parser_limits"]
    require_type(limits, dict, "$.parser_limits")
    if "max_file_bytes" in limits:
        fail("$.parser_limits.max_file_bytes", "total file size must not be capped")
    for key in ("max_depth", "max_path_bytes", "max_string_bytes", "max_collection_items"):
        require_type(limits.get(key), int, f"$.parser_limits.{key}")
        if limits[key] < 1:
            fail(f"$.parser_limits.{key}", "must be positive")
    environment = config["environment"]
    require_type(environment, dict, "$.environment")
    if environment.get("inherit") != "all_except_blocked" or environment.get("value_handling") != "literal":
        fail("$.environment", "must inherit default-open and keep literal values")
    expected_names = {"LD_PRELOAD", "LD_AUDIT", "GCONV_PATH", "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "IFS", "PS4"}
    if set(environment.get("blocked_names", [])) != expected_names:
        fail("$.environment.blocked_names", "must match the contract denylist exactly")
    if environment.get("blocked_prefixes") != ["BASH_FUNC_"]:
        fail("$.environment.blocked_prefixes", "must only block BASH_FUNC_*")
    validate_environment(environment)
    sources = config["sources"]
    require_type(sources, dict, "$.sources")
    transport = sources.get("transport")
    require_type(transport, dict, "$.sources.transport")
    if transport.get("proxy_registry_ref") != "embedded://github-proxy-registry/v1":
        fail("$.sources.transport.proxy_registry_ref", "must reference the bundled proxy registry")
    if transport.get("probe_batch_limit") != 5:
        fail("$.sources.transport.probe_batch_limit", "must preserve the five-route probe boundary")
    expected_routes = {
        "jenny92_portmaster": "release",
        "official_portmaster": "release",
        "runtime_metadata": "release",
    }
    if transport.get("routes") != expected_routes:
        fail("$.sources.transport.routes", "source capability routes do not match the endpoint contract")
    adapters = config["adapters"]
    require_type(adapters, dict, "$.adapters")
    for name, adapter in adapters.items():
        if not SAFE_ID.fullmatch(name):
            fail(f"$.adapters.{name}", "invalid adapter id")
        require_type(adapter, dict, f"$.adapters.{name}")
        require_type(adapter.get("kind"), str, f"$.adapters.{name}.kind")
        require_type(adapter.get("contract_version"), int, f"$.adapters.{name}.contract_version")
    platforms = config["platforms"]
    require_type(platforms, dict, "$.platforms")
    if not PLATFORMS.issubset(platforms):
        fail("$.platforms", f"missing required platforms {sorted(PLATFORMS.difference(platforms))}")
    for name, platform in platforms.items():
        if not SAFE_ID.fullmatch(name):
            fail(f"$.platforms.{name}", "invalid platform id")
        validate_platform(platform, f"$.platforms.{name}")
        for adapter in platform["required_adapters"]:
            if adapter not in adapters:
                fail(f"$.platforms.{name}.required_adapters", f"undefined adapter {adapter}")
    expected_frontend_policy = {
        "miniloong": (None, None, False, False, "PortMaster.sh", "PortMaster.sh"),
        "trimui": ("trimui/control.txt", None, True, True, None, "launch.sh"),
        "muos": ("muos/control.txt", "muos/PortMaster.txt", False, True, "PortMaster.sh", None),
        "rocknix": (None, None, False, False, "PortMaster.sh", None),
        "jelos": (None, None, False, False, "PortMaster.sh", None),
        "unofficialos": (None, None, False, False, "PortMaster.sh", None),
        "knulli": ("knulli/control.txt", None, True, True, None, "PortMaster.sh"),
        "batocera": ("batocera/control.txt", None, True, True, None, "PortMaster.sh"),
        "miyoo": ("miyoo/control.txt", "miyoo/PortMaster.txt", False, False, "PortMaster.sh", None),
        "generic": (None, None, False, False, "PortMaster.sh", "PortMaster.sh"),
    }
    installer_keys = ("control_source", "core_launcher_source", "remove_core_launcher", "empty_tasksetter", "core_executable", "frontend_executable")
    for name, expected in expected_frontend_policy.items():
        actual = tuple(platforms[name]["frontend"][key] for key in installer_keys)
        if actual != expected:
            fail(f"$.platforms.{name}.frontend", "installer policy does not match the launcher contract")
    expected_support = {
        "miniloong": ("tested", "detected"),
        "trimui": ("tested", "detected"),
        "muos": ("official-untested", "detected"),
        "rocknix": ("official-untested", "detected"),
        "jelos": ("official-untested", "detected"),
        "unofficialos": ("official-untested", "detected"),
        "knulli": ("official-untested", "detected"),
        "batocera": ("official-untested", "detected"),
        "miyoo": ("official-untested", "detected"),
        "generic": ("unsupported-known", "existing_core_or_override"),
    }
    for name, expected in expected_support.items():
        support = platforms[name]["support"]
        if (support["device_class"], support["target_confirmation"]) != expected:
            fail(f"$.platforms.{name}.support", "support policy does not match the device contract")
    generic_core = platforms["generic"]["paths"].get("portmaster_core", {})
    if generic_core.get("strategy") != "first_existing" or generic_core.get("on_missing") != "unresolved" or "fallback" in generic_core:
        fail("$.platforms.generic.paths.portmaster_core", "must not authorize a nonexistent fallback target")
    expected_launcher_directories = {
        "miniloong": {"strategy": "literal", "value": "/mnt/sdcard/roms"},
        "trimui": {"strategy": "literal", "value": "/mnt/SDCARD/Data"},
        "muos": {"strategy": "parent", "of": "game_data"},
        "rocknix": {"strategy": "parent", "of": "game_data"},
        "jelos": {"strategy": "parent", "of": "game_data"},
        "unofficialos": {"strategy": "parent", "of": "game_data"},
        "knulli": {"strategy": "literal", "value": "/userdata/roms"},
        "batocera": {"strategy": "literal", "value": "/userdata/roms"},
        "miyoo": {"strategy": "literal", "value": "/mnt/sdcard/Roms/PORTS64"},
        "generic": {"strategy": "parent", "of": "game_data"},
    }
    for name, expected in expected_launcher_directories.items():
        if platforms[name]["paths"]["launcher_directory"] != expected:
            fail(f"$.platforms.{name}.paths.launcher_directory", "does not match PortMaster $directory")
    if platforms["miniloong"]["python"].get("mode") != "runtime_mount":
        fail("$.platforms.miniloong.python", "must use the runtime_mount Python mode")
    for name in ("rocknix", "jelos"):
        if platforms[name]["frontend"].get("management") != "system" or platforms[name]["capabilities"].get("install_portmaster") is not False or platforms[name]["capabilities"].get("update_portmaster") is not False:
            fail(f"$.platforms.{name}", "must remain system-managed")
    # Models are scoped by containment under platforms.<id>.models.
    for name, platform in platforms.items():
        models = platform.get("models", {})
        if not models:
            continue
        require_type(models, dict, f"$.platforms.{name}.models")
        for model_name, model in models.items():
            model_path = f"$.platforms.{name}.models.{model_name}"
            require_type(model, dict, model_path)
            allow_keys(
                model,
                {"display_name", "device_manufacturer", "recognition", "display", "overrides"},
                model_path,
            )
            require_keys(model, {"display_name", "recognition", "display"}, model_path)
            if "device_manufacturer" in model and (
                not isinstance(model["device_manufacturer"], str)
                or not model["device_manufacturer"]
            ):
                fail(f"{model_path}.device_manufacturer", "must be a non-empty string")
            validate_predicate(model["recognition"], f"{model_path}.recognition")
            if "overrides" in model:
                require_type(model["overrides"], dict, f"{model_path}.overrides")
                allow_keys(model["overrides"], {"display", "input"}, f"{model_path}.overrides")
    for required in ("brick", "brick_pro", "smart_pro"):
        if required not in platforms["trimui"].get("models", {}):
            fail("$.platforms.trimui.models", f"missing required model {required}")
    walk_no_code(config)


def is_root_config(config: Any) -> bool:
    # The root config carries thin platform entries that point at detail files;
    # the merged/full config carries complete platform objects.
    platforms = config.get("platforms", {}) if isinstance(config, dict) else {}
    return isinstance(platforms, dict) and any(
        isinstance(entry, dict) and "detail" in entry for entry in platforms.values()
    )


def validate_root(config: dict) -> None:
    require_type(config, dict, "$")
    require_keys(config, ROOT_KEYS, "$")
    platforms = config.get("platforms", {})
    require_type(platforms, dict, "$.platforms")
    for name, entry in platforms.items():
        path = f"$.platforms.{name}"
        require_type(entry, dict, path)
        require_keys(entry, {"priority", "recognition", "detail"}, path)
        allow_keys(entry, {"priority", "recognition", "detail"}, path)
        if not isinstance(entry["priority"], int):
            fail(f"{path}.priority", "must be an integer")
        detail = entry["detail"]
        if not isinstance(detail, str) or not detail:
            fail(f"{path}.detail", "must be a non-empty string")
        validate_predicate(entry["recognition"], f"{path}.recognition")
    if "models" in config:
        fail("$.models", "must not appear in the root config (models live in platform detail)")


def is_platform_detail(config: Any) -> bool:
    return isinstance(config, dict) and "platform_id" in config and "platforms" not in config


def validate_platform_detail(config: dict) -> None:
    require_type(config, dict, "$")
    require_keys(config, {"format", "schema_version", "config_version", "platform_id"}, "$")
    if config["format"] != "jenny92.appmanager-config":
        fail("$.format", "unsupported format")
    if config["schema_version"] != 1:
        fail("$.schema_version", "unsupported schema version")
    if not isinstance(config["config_version"], str) or not SEMVER.fullmatch(config["config_version"]):
        fail("$.config_version", "must be semantic version")
    if not isinstance(config["platform_id"], str) or not SAFE_ID.fullmatch(config["platform_id"]):
        fail("$.platform_id", "invalid platform id")
    if "priority" in config or "recognition" in config:
        fail("$", "platform detail must not duplicate root detection fields")
    platform = {
        key: value
        for key, value in config.items()
        if key not in {"format", "schema_version", "config_version", "platform_id"}
    }
    platform["priority"] = 0
    platform["recognition"] = {"kind": "always"}
    validate_platform(platform, "$")
    for model_id, model in platform.get("models", {}).items():
        model_path = f"$.models.{model_id}"
        if not SAFE_ID.fullmatch(model_id):
            fail(model_path, "invalid model id")
        require_type(model, dict, model_path)
        allow_keys(
            model,
            {"display_name", "device_manufacturer", "recognition", "display", "overrides"},
            model_path,
        )
        require_keys(model, {"display_name", "recognition", "display"}, model_path)
        if "device_manufacturer" in model and (
            not isinstance(model["device_manufacturer"], str) or not model["device_manufacturer"]
        ):
            fail(f"{model_path}.device_manufacturer", "must be a non-empty string")
        validate_predicate(model["recognition"], f"{model_path}.recognition")
    walk_no_code(config)


def validate_resolved_closure(config: dict, platform: str, model: str | None = None) -> None:
    if platform not in config["platforms"]:
        fail("$.platforms", f"unknown resolved platform {platform}")
    if model is not None:
        models = config["platforms"][platform].get("models", {})
        entry = models.get(model)
        if entry is None:
            fail(f"$.platforms.{platform}.models", f"unknown resolved model {model}")
    for adapter_id in config["platforms"][platform]["required_adapters"]:
        adapter = config["adapters"][adapter_id]
        if adapter["kind"] not in SUPPORTED_ADAPTER_KINDS or adapter["contract_version"] != 1:
            fail(
                f"$.adapters.{adapter_id}",
                "adapter in resolved device closure is not understood by this engine",
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("config", type=Path)
    parser.add_argument("--platform")
    parser.add_argument("--model")
    args = parser.parse_args()
    try:
        config = json.loads(args.config.read_text(encoding="utf-8"))
        if is_root_config(config):
            validate_root(config)
        elif is_platform_detail(config):
            validate_platform_detail(config)
        else:
            validate(config)
            if args.platform:
                validate_resolved_closure(config, args.platform, args.model)
            elif args.model:
                fail("--model", "requires --platform")
    except (OSError, json.JSONDecodeError, ConfigError) as error:
        print(f"invalid appmanager config: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
