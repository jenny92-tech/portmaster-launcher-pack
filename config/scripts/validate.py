#!/usr/bin/env python3
# INPUT:  argparse, json, re, pathlib；配置对象或 JSON 路径
# OUTPUT: ConfigError, validate(), validate_resolved_closure(), main()
# POS:    在配置生产侧校验结构、路径、能力及有限声明式词汇
"""Structural validator for App Manager Config v1.

Rust remains the executable authority.  This validator protects the source and
generation pipeline from malformed JSON without duplicating per-platform
snapshots or device-specific business policy.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import PurePosixPath, Path
from typing import Any


FORMAT = "jenny92.appmanager-config"
SCHEMA_VERSION = 1
SAFE_ID = re.compile(r"^[a-z][a-z0-9._-]{0,127}$")
SAFE_ARCH = re.compile(r"^[a-z0-9][a-z0-9._-]{0,127}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
PREDICATES = {
    "always",
    "all",
    "any",
    "directory_exists",
    "file_exists",
    "env_equals",
    "launcher_path_prefix",
    "os_release_equals",
    "os_release_version_at_least",
}
PATH_STRATEGIES = {
    "literal",
    "first_existing",
    "launcher_dir",
    "platform_core",
    "rom_root_from_launcher",
    "xdg_data_home",
    "literal_by_launcher_prefix",
    "parent",
    "relative_to",
}
LOCATION_KINDS = {"port_scripts", "port_data", "port_images", "apps"}
LOCATION_ROLES = {
    "inventory",
    "install",
    "manage",
    "trash",
    "trash_restore",
    "cleanup_apple_double",
}
BUNDLE_FORMATS = {"port", "trimui_app"}
PORT_LOCATION_KINDS = ("port_scripts", "port_data", "port_images")
REQUIRED_CAPABILITIES = {
    "install_portmaster",
    "update_portmaster",
    "repair_runtimes",
    "manage_portmaster",
    "manage_ports",
    "inventory_ports",
    "install_ports",
    "inventory_apps",
    "manage_apps",
    "install_apps",
    "manage_artwork",
    "manage_frontend",
    "manage_images",
    "trash",
    "leftovers",
    "cleanup_appledouble",
    "scan_script_images",
}
SUPPORTED_ADAPTER_KINDS = {"predicate", "path", "frontend", "library", "python"}
FORBIDDEN_KEYS = {"run_shell", "eval", "exec", "command", "shell"}


class ConfigError(ValueError):
    pass


def fail(path: str, message: str) -> None:
    raise ConfigError(f"{path}: {message}")


def object_at(value: Any, path: str) -> dict:
    if not isinstance(value, dict):
        fail(path, "must be an object")
    return value


def array_at(value: Any, path: str) -> list:
    if not isinstance(value, list):
        fail(path, "must be an array")
    return value


def require_keys(value: dict, keys: set[str], path: str) -> None:
    missing = keys.difference(value)
    if missing:
        fail(path, f"missing required keys {sorted(missing)}")


def exact_keys(value: dict, keys: set[str], path: str) -> None:
    if set(value) != keys:
        fail(path, f"must contain exactly {sorted(keys)}")


def validate_id(value: Any, path: str) -> str:
    if not isinstance(value, str) or not SAFE_ID.fullmatch(value):
        fail(path, "invalid stable id")
    return value


def validate_literal(value: Any, path: str, *, absolute: bool | None = None) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        fail(path, "must be a non-empty path string")
    parsed = PurePosixPath(value)
    if ".." in parsed.parts or "." in parsed.parts:
        fail(path, "path must be normalized and must not contain . or ..")
    if absolute is True and not parsed.is_absolute():
        fail(path, "must be absolute")
    if absolute is False and parsed.is_absolute():
        fail(path, "must be relative")
    return value


def validate_predicate(value: Any, path: str, depth: int = 1) -> None:
    if depth > 32:
        fail(path, "predicate nesting is too deep")
    obj = object_at(value, path)
    kind = obj.get("kind")
    if kind not in PREDICATES:
        fail(f"{path}.kind", "unsupported predicate")
    if kind in {"all", "any"}:
        children = array_at(obj.get("predicates"), f"{path}.predicates")
        if not children:
            fail(f"{path}.predicates", "must not be empty")
        for index, child in enumerate(children):
            validate_predicate(child, f"{path}.predicates[{index}]", depth + 1)
    elif kind in {"directory_exists", "file_exists"}:
        validate_literal(obj.get("path"), f"{path}.path", absolute=True)
    elif kind == "launcher_path_prefix":
        validate_literal(obj.get("prefix"), f"{path}.prefix", absolute=True)
    elif kind == "env_equals":
        if not isinstance(obj.get("name"), str) or not isinstance(obj.get("value"), str):
            fail(path, "env_equals requires string name and value")
    elif kind == "os_release_equals":
        if not isinstance(obj.get("field"), str) or not isinstance(obj.get("value"), str):
            fail(path, "os_release_equals requires string field and value")
    elif kind == "os_release_version_at_least":
        if not isinstance(obj.get("field"), str) or not isinstance(obj.get("value"), str):
            fail(path, "os_release_version_at_least requires string field and value")
        parts = obj["value"].split(".")
        if not 1 <= len(parts) <= 8 or any(not part.isdigit() for part in parts):
            fail(f"{path}.value", "must contain 1 to 8 dot-separated integers")


def validate_path_strategy(value: Any, path: str) -> None:
    obj = object_at(value, path)
    strategy = obj.get("strategy")
    if strategy not in PATH_STRATEGIES:
        fail(f"{path}.strategy", "unsupported path strategy")
    if "canonicalize_existing" in obj and not isinstance(obj["canonicalize_existing"], bool):
        fail(f"{path}.canonicalize_existing", "must be a boolean")
    if strategy == "literal":
        validate_literal(obj.get("value"), f"{path}.value", absolute=True)
    elif strategy == "first_existing":
        if obj.get("expected_type") not in {"directory", "file"}:
            fail(f"{path}.expected_type", "must be directory or file")
        candidates = array_at(obj.get("candidates"), f"{path}.candidates")
        if not candidates:
            fail(f"{path}.candidates", "must not be empty")
        for index, candidate in enumerate(candidates):
            validate_literal(candidate, f"{path}.candidates[{index}]", absolute=True)
    elif strategy == "literal_by_launcher_prefix":
        for key in ("prefix", "matched"):
            validate_literal(obj.get(key), f"{path}.{key}", absolute=True)
        for index, candidate in enumerate(array_at(obj.get("fallback"), f"{path}.fallback")):
            validate_literal(candidate, f"{path}.fallback[{index}]", absolute=True)
    elif strategy in {"relative_to", "rom_root_from_launcher"}:
        key = next((name for name in ("relative", "suffix", "value") if name in obj), None)
        if key is None:
            fail(path, "relative path strategy has no suffix")
        validate_literal(obj[key], f"{path}.{key}", absolute=False)


def validate_locations(platform: dict, path: str) -> None:
    locations = array_at(platform.get("locations"), f"{path}.locations")
    if len(locations) < 2:
        fail(f"{path}.locations", "must contain at least two locations")
    ids: set[str] = set()
    install_targets: dict[str, list[str]] = {"port": [], "trimui_app": []}
    for index, value in enumerate(locations):
        item_path = f"{path}.locations[{index}]"
        item = object_at(value, item_path)
        exact_keys(item, {"id", "kind", "path", "roles", "formats", "priority"}, item_path)
        item_id = validate_id(item["id"], f"{item_path}.id")
        if item_id in ids:
            fail(f"{item_path}.id", "duplicate location id")
        ids.add(item_id)
        if item["kind"] not in LOCATION_KINDS:
            fail(f"{item_path}.kind", "unsupported location kind")
        if not isinstance(item["path"], str) or item["path"] not in platform["paths"]:
            fail(f"{item_path}.path", "must reference a named path")
        roles = array_at(item["roles"], f"{item_path}.roles")
        formats = array_at(item["formats"], f"{item_path}.formats")
        if not roles or len(roles) != len(set(roles)) or not set(roles).issubset(LOCATION_ROLES):
            fail(f"{item_path}.roles", "roles must be non-empty, unique, and supported")
        if len(formats) != len(set(formats)) or not set(formats).issubset(BUNDLE_FORMATS):
            fail(f"{item_path}.formats", "formats must be unique and supported")
        if not isinstance(item["priority"], int) or isinstance(item["priority"], bool):
            fail(f"{item_path}.priority", "must be an integer")
        if item["kind"] == "apps" and "install" in roles and "trimui_app" not in formats:
            fail(item_path, "APP locations must accept trimui_app")
        if item["kind"] in {"port_scripts", "port_data"} and "install" in roles and "port" not in formats:
            fail(item_path, "Port script/data locations must accept port")
        if "install" in roles:
            for bundle_format in formats:
                install_targets[bundle_format].append(item_id)

    for kind in PORT_LOCATION_KINDS:
        candidates = [item for item in locations if item["kind"] == kind]
        if kind in {"port_scripts", "port_data"} and not candidates:
            fail(f"{path}.locations", f"missing {kind} location")
        if candidates:
            highest = max(item["priority"] for item in candidates)
            if sum(item["priority"] == highest for item in candidates) != 1:
                fail(f"{path}.locations", f"ambiguous {kind} location at priority {highest}")

    capabilities = platform.get("capabilities") if isinstance(platform.get("capabilities"), dict) else {}
    required_port_roles = {
        role
        for capability, role in (
            ("inventory_ports", "inventory"),
            ("install_ports", "install"),
            ("manage_ports", "manage"),
            ("trash", "trash"),
            ("trash", "trash_restore"),
            ("cleanup_appledouble", "cleanup_apple_double"),
        )
        if capabilities.get(capability) is True
    }
    for kind in ("port_scripts", "port_data"):
        candidates = [
            item for item in locations
            if item["kind"] == kind
            and required_port_roles.issubset(item["roles"])
            and (capabilities.get("install_ports") is not True or "port" in item["formats"])
        ]
        if not candidates:
            fail(f"{path}.locations", f"no {kind} location supports enabled roles")
        highest = max(item["priority"] for item in candidates)
        if sum(item["priority"] == highest for item in candidates) != 1:
            fail(f"{path}.locations", f"ambiguous eligible {kind} location at priority {highest}")
    domain_requirements = [
        (
            "port_images",
            any(capabilities.get(name) is True for name in ("scan_script_images", "manage_artwork", "manage_images")),
            {
                role for capability, role in (
                    ("scan_script_images", "inventory"),
                    ("manage_artwork", "manage"),
                    ("manage_images", "manage"),
                    ("trash", "trash"),
                    ("trash", "trash_restore"),
                    ("cleanup_appledouble", "cleanup_apple_double"),
                ) if capabilities.get(capability) is True
            },
            None,
        ),
        (
            "apps",
            any(capabilities.get(name) is True for name in ("inventory_apps", "manage_apps", "install_apps")),
            {
                role for capability, role in (
                    ("inventory_apps", "inventory"),
                    ("install_apps", "install"),
                    ("manage_apps", "manage"),
                    ("trash", "trash"),
                    ("trash", "trash_restore"),
                    ("cleanup_appledouble", "cleanup_apple_double"),
                ) if capabilities.get(capability) is True
            },
            "trimui_app" if capabilities.get("install_apps") is True else None,
        ),
    ]
    for kind, required, roles, bundle_format in domain_requirements:
        if not required:
            continue
        candidates = [
            item for item in locations
            if item["kind"] == kind and roles.issubset(item["roles"])
            and (bundle_format is None or bundle_format in item["formats"])
        ]
        if not candidates:
            fail(f"{path}.locations", f"no {kind} location supports enabled roles")
        highest = max(item["priority"] for item in candidates)
        if sum(item["priority"] == highest for item in candidates) != 1:
            fail(f"{path}.locations", f"ambiguous eligible {kind} location at priority {highest}")
    if platform.get("capabilities", {}).get("install_apps"):
        targets = [item for item in locations if item["id"] in install_targets["trimui_app"]]
        if not targets:
            fail(f"{path}.locations", "install_apps requires an APP install target")
        highest = max(item["priority"] for item in targets)
        if sum(item["priority"] == highest for item in targets) != 1:
            fail(f"{path}.locations", "highest-priority APP install target is ambiguous")


def validate_models(platform: dict, path: str) -> None:
    models = array_at(platform.get("models", []), f"{path}.models")
    ids: set[str] = set()
    for index, value in enumerate(models):
        model_path = f"{path}.models[{index}]"
        model = object_at(value, model_path)
        required = {"id", "priority", "display_name", "recognition", "display"}
        allowed = required | {"device_manufacturer", "overrides"}
        require_keys(model, required, model_path)
        if not set(model).issubset(allowed):
            fail(model_path, "contains unknown Config v1 model fields")
        model_id = validate_id(model["id"], f"{model_path}.id")
        if model_id in ids:
            fail(f"{model_path}.id", "duplicate model id")
        ids.add(model_id)
        if not isinstance(model["priority"], int) or isinstance(model["priority"], bool):
            fail(f"{model_path}.priority", "must be an integer")
        validate_predicate(model["recognition"], f"{model_path}.recognition")
        object_at(model["display"], f"{model_path}.display")
        overrides = object_at(model.get("overrides", {}), f"{model_path}.overrides")
        if not set(overrides).issubset({"display", "input"}):
            fail(f"{model_path}.overrides", "unsupported override field")
        for name, override in overrides.items():
            object_at(override, f"{model_path}.overrides.{name}")


def validate_platform(platform: Any, path: str) -> None:
    value = object_at(platform, path)
    required = {
        "display_name", "priority", "recognition", "required_adapters", "paths",
        "source_route", "support", "frontend", "libraries", "python", "health",
        "preserved_dirs", "locations", "capabilities", "environment_scopes", "display", "input",
    }
    require_keys(value, required, path)
    allowed = required | {"device_manufacturer", "models"}
    if set(value) != allowed.intersection(value):
        fail(path, "contains unknown Config v1 platform fields")
    if not isinstance(value["priority"], int) or isinstance(value["priority"], bool):
        fail(f"{path}.priority", "must be an integer")
    validate_predicate(value["recognition"], f"{path}.recognition")
    paths = object_at(value["paths"], f"{path}.paths")
    for name, strategy in paths.items():
        validate_id(name, f"{path}.paths.{name}")
        validate_path_strategy(strategy, f"{path}.paths.{name}")
    for required in ("scripts", "game_data", "frontend", "launcher_directory"):
        if required not in paths:
            fail(f"{path}.paths", f"missing {required}")
    health = array_at(value["health"], f"{path}.health")
    for index, rule_value in enumerate(health):
        rule_path = f"{path}.health[{index}]"
        rule = object_at(rule_value, rule_path)
        kind = rule.get("kind")
        if kind in {"required_file", "executable_file"}:
            exact_keys(rule, {"kind", "path"}, rule_path)
            templates = [rule["path"]]
        elif kind == "one_of_files":
            exact_keys(rule, {"kind", "paths"}, rule_path)
            templates = array_at(rule["paths"], f"{rule_path}.paths")
            if not templates:
                fail(f"{rule_path}.paths", "must not be empty")
        elif kind == "archive_or_nonempty_directory":
            exact_keys(rule, {"kind", "archive", "directory"}, rule_path)
            templates = [rule["archive"], rule["directory"]]
        elif kind == "python_imports_or_runtime":
            if not set(rule).issubset({"kind", "imports", "runtime"}) or not ({"imports", "runtime"} & set(rule)):
                fail(rule_path, "requires only imports and/or runtime")
            templates = []
            if "imports" in rule:
                imports = array_at(rule["imports"], f"{rule_path}.imports")
                if not imports or any(not isinstance(name, str) or not name for name in imports):
                    fail(f"{rule_path}.imports", "must be a non-empty string array")
            if "runtime" in rule and (not isinstance(rule["runtime"], str) or not rule["runtime"]):
                fail(f"{rule_path}.runtime", "must be a non-empty string")
        else:
            fail(f"{rule_path}.kind", "unsupported health rule")
        for template in templates:
            if not isinstance(template, str) or not template.startswith("{") or "}" not in template:
                fail(rule_path, "health paths must start with a path placeholder")
            key, suffix = template[1:].split("}", 1)
            if key not in paths or "{" in suffix or "}" in suffix or ".." in Path(suffix.lstrip("/")).parts:
                fail(rule_path, "health path is unsafe or references an unknown path")
    validate_locations(value, path)
    validate_models(value, path)
    capabilities = object_at(value["capabilities"], f"{path}.capabilities")
    missing = REQUIRED_CAPABILITIES.difference(capabilities)
    if missing:
        fail(f"{path}.capabilities", f"missing explicit capabilities {sorted(missing)}")
    for name, enabled in capabilities.items():
        validate_id(name, f"{path}.capabilities.{name}")
        if type(enabled) is not bool:
            fail(f"{path}.capabilities.{name}", "must be boolean")
    if capabilities["install_portmaster"] and not capabilities["manage_portmaster"]:
        fail(f"{path}.capabilities", "install_portmaster requires manage_portmaster")
    if capabilities["update_portmaster"] and not capabilities["manage_portmaster"]:
        fail(f"{path}.capabilities", "update_portmaster requires manage_portmaster")
    if capabilities["install_ports"] and not capabilities["manage_ports"]:
        fail(f"{path}.capabilities", "install_ports requires manage_ports")
    if capabilities["install_apps"] and not capabilities["manage_apps"]:
        fail(f"{path}.capabilities", "install_apps requires manage_apps")
    has_apps = any(location["kind"] == "apps" for location in value["locations"])
    if any(capabilities[name] for name in ("inventory_apps", "manage_apps", "install_apps")) != has_apps:
        fail(f"{path}.capabilities", "APP capabilities must match configured APP locations")
    display = object_at(value["display"], f"{path}.display")
    for field in ("default_width", "default_height"):
        if type(display.get(field)) is not int or display[field] <= 0:
            fail(f"{path}.display.{field}", "must be a positive integer")
    input_config = object_at(value["input"], f"{path}.input")
    if type(input_config.get("analog_sticks")) is not int or input_config["analog_sticks"] < 0:
        fail(f"{path}.input.analog_sticks", "must be a non-negative integer")
    validate_literal(input_config.get("tty"), f"{path}.input.tty", absolute=True)
    frontend = object_at(value["frontend"], f"{path}.frontend")
    names = array_at(frontend.get("names"), f"{path}.frontend.names")
    if len(names) != len(set(names)):
        fail(f"{path}.frontend.names", "must be unique")
    primary = frontend.get("primary")
    if not isinstance(primary, str):
        fail(f"{path}.frontend.primary", "must be a string")
    if frontend.get("management") == "app" and primary not in names:
        fail(f"{path}.frontend.primary", "must be present in names for app-managed frontend")
    destinations: set[str] = set()
    sources: set[str] = set()
    for index, mapping in enumerate(array_at(frontend.get("install_map"), f"{path}.frontend.install_map")):
        mapping_path = f"{path}.frontend.install_map[{index}]"
        item = object_at(mapping, mapping_path)
        if item.get("source") in sources or item.get("target") in destinations:
            fail(mapping_path, "install source and destination must be unique")
        sources.add(item.get("source")); destinations.add(item.get("target"))
def validate(config: Any) -> None:
    value = object_at(config, "$")
    root_keys = {"format", "schema_version", "config_version", "metadata", "parser_limits", "bootstrap", "sources", "environment", "adapters", "platforms"}
    exact_keys(value, root_keys, "$")
    if value["format"] != FORMAT or value["schema_version"] != SCHEMA_VERSION:
        fail("$", "unsupported Config contract")
    if not isinstance(value["config_version"], str) or not SEMVER.fullmatch(value["config_version"]):
        fail("$.config_version", "must be numeric semantic versioning")
    validate_root_common(value)
    validate_bootstrap_and_sources(value)
    adapters = object_at(value["adapters"], "$.adapters")
    for adapter_id, adapter in adapters.items():
        validate_id(adapter_id, f"$.adapters.{adapter_id}")
        object_at(adapter, f"$.adapters.{adapter_id}")
    platforms = object_at(value["platforms"], "$.platforms")
    if not platforms:
        fail("$.platforms", "must not be empty")
    for platform_id, platform in platforms.items():
        validate_id(platform_id, f"$.platforms.{platform_id}")
        validate_platform(platform, f"$.platforms.{platform_id}")
        for adapter_id in platform["required_adapters"]:
            if adapter_id not in adapters:
                fail(f"$.platforms.{platform_id}.required_adapters", f"undefined adapter {adapter_id}")
    walk_no_code(value)


def validate_root(config: dict) -> None:
    root_keys = {"format", "schema_version", "config_version", "metadata", "parser_limits", "bootstrap", "sources", "environment", "adapters", "platforms"}
    exact_keys(config, root_keys, "$")
    if config.get("format") != FORMAT or config.get("schema_version") != SCHEMA_VERSION:
        fail("$", "unsupported root Config contract")
    if not isinstance(config.get("config_version"), str) or not SEMVER.fullmatch(config["config_version"]):
        fail("$.config_version", "must be numeric semantic versioning")
    validate_root_common(config)
    validate_bootstrap_and_sources(config)
    platforms = object_at(config.get("platforms"), "$.platforms")
    for platform_id, entry in platforms.items():
        path = f"$.platforms.{platform_id}"
        validate_id(platform_id, path)
        entry = object_at(entry, path)
        exact_keys(entry, {"priority", "recognition", "detail"}, path)
        if type(entry["priority"]) is not int:
            fail(f"{path}.priority", "must be an integer")
        validate_predicate(entry["recognition"], f"{path}.recognition")
        detail = object_at(entry["detail"], f"{path}.detail")
        if set(detail) != {"ref", "sha256", "bytes"}:
            fail(f"{path}.detail", "must contain only ref, sha256, and bytes")
        validate_literal(detail["ref"], f"{path}.detail.ref", absolute=False)
        if not isinstance(detail["sha256"], str) or not SHA256.fullmatch(detail["sha256"]):
            fail(f"{path}.detail.sha256", "must be lowercase SHA-256")
        if type(detail["bytes"]) is not int or detail["bytes"] <= 0:
            fail(f"{path}.detail.bytes", "must be a positive integer")
    walk_no_code(config)


def validate_bootstrap_and_sources(config: dict) -> None:
    bootstrap = object_at(config.get("bootstrap"), "$.bootstrap")
    exact_keys(bootstrap, {"policy", "config_url", "fallback", "transport", "required_format"}, "$.bootstrap")
    expected = {
        "policy": "remote_then_embedded",
        "fallback": "embedded_root_then_local_dir",
        "transport": "github_https",
        "required_format": FORMAT,
    }
    for key, value in expected.items():
        if bootstrap.get(key) != value:
            fail(f"$.bootstrap.{key}", "unsupported bootstrap contract")
    url = bootstrap.get("config_url")
    if not isinstance(url, str) or not url.startswith("https://raw.githubusercontent.com/") or any(ch.isspace() for ch in url):
        fail("$.bootstrap.config_url", "must be a GitHub raw HTTPS URL")

    sources = object_at(config.get("sources"), "$.sources")
    exact_keys(sources, {"endpoints", "release_routes", "runtime", "transport"}, "$.sources")
    endpoints = object_at(sources.get("endpoints"), "$.sources.endpoints")
    if not endpoints:
        fail("$.sources.endpoints", "must not be empty")
    for endpoint_id, endpoint in endpoints.items():
        validate_id(endpoint_id, f"$.sources.endpoints.{endpoint_id}")
        if not isinstance(endpoint, str) or not endpoint.startswith("https://github.com/") or any(ch.isspace() for ch in endpoint):
            fail(f"$.sources.endpoints.{endpoint_id}", "must be a GitHub HTTPS URL")
    routes = object_at(sources.get("release_routes"), "$.sources.release_routes")
    if not routes:
        fail("$.sources.release_routes", "must not be empty")
    for route_id, route_value in routes.items():
        validate_id(route_id, f"$.sources.release_routes.{route_id}")
        route = object_at(route_value, f"$.sources.release_routes.{route_id}")
        allowed_route_keys = {"manifest", "channel", "archive_name", "checksum"}
        if "install_allowed" in route:
            allowed_route_keys.add("install_allowed")
        exact_keys(route, allowed_route_keys, f"$.sources.release_routes.{route_id}")
        if route.get("manifest") not in endpoints:
            fail(f"$.sources.release_routes.{route_id}.manifest", "unknown endpoint")
        if route.get("channel") != "stable" or route.get("checksum") != "md5_from_manifest":
            fail(f"$.sources.release_routes.{route_id}", "unsupported release contract")
        archive = route.get("archive_name")
        if not isinstance(archive, str) or not archive or archive in {".", ".."} or any(ch in archive for ch in "/\\\t\r\n"):
            fail(f"$.sources.release_routes.{route_id}.archive_name", "unsafe archive name")
        if "install_allowed" in route and type(route["install_allowed"]) is not bool:
            fail(f"$.sources.release_routes.{route_id}.install_allowed", "must be boolean")
    runtime = object_at(sources.get("runtime"), "$.sources.runtime")
    exact_keys(runtime, {"metadata", "architectures", "verification"}, "$.sources.runtime")
    if runtime.get("metadata") not in endpoints:
        fail("$.sources.runtime.metadata", "unknown endpoint")
    architectures = array_at(runtime.get("architectures"), "$.sources.runtime.architectures")
    if not architectures:
        fail("$.sources.runtime.architectures", "must not be empty")
    architecture_ids: set[str] = set()
    system_names: set[str] = set()
    for index, architecture_value in enumerate(architectures):
        path = f"$.sources.runtime.architectures[{index}]"
        architecture = object_at(architecture_value, path)
        exact_keys(architecture, {"id", "system_names"}, path)
        architecture_id = validate_id(architecture.get("id"), f"{path}.id")
        if architecture_id in architecture_ids:
            fail(f"{path}.id", "duplicate Runtime architecture")
        architecture_ids.add(architecture_id)
        aliases = array_at(architecture.get("system_names"), f"{path}.system_names")
        if not aliases:
            fail(f"{path}.system_names", "must not be empty")
        for alias in aliases:
            if not isinstance(alias, str) or not SAFE_ARCH.fullmatch(alias):
                fail(f"{path}.system_names", "contains an unsafe architecture name")
            if alias in system_names:
                fail(f"{path}.system_names", "architecture name is mapped more than once")
            system_names.add(alias)
    verification = array_at(runtime.get("verification"), "$.sources.runtime.verification")
    if len(verification) != len(set(verification)) or set(verification) != {"url", "size", "md5", "squashfs_magic"}:
        fail("$.sources.runtime.verification", "does not match implemented security contract")
    transport = object_at(sources.get("transport"), "$.sources.transport")
    exact_keys(transport, {"proxy_registry_ref", "probe_batch_limit", "capabilities", "routes", "cache_scope", "resume_requires_same_formatted_endpoint"}, "$.sources.transport")
    if transport.get("proxy_registry_ref") != "embedded://github-proxy-registry/v1" or transport.get("cache_scope") != "process" or transport.get("resume_requires_same_formatted_endpoint") is not True:
        fail("$.sources.transport", "unsupported transport security contract")
    batch = transport.get("probe_batch_limit")
    if type(batch) is not int or not 1 <= batch <= 32:
        fail("$.sources.transport.probe_batch_limit", "must be from 1 to 32")
    capabilities = array_at(transport.get("capabilities"), "$.sources.transport.capabilities")
    required_capabilities = {"release", "raw", "archive", "api", "gist", "clone"}
    if len(capabilities) != len(set(capabilities)) or set(capabilities) != required_capabilities:
        fail("$.sources.transport.capabilities", "does not match the engine transport")
    transport_routes = object_at(transport.get("routes"), "$.sources.transport.routes")
    if set(transport_routes) != set(endpoints):
        fail("$.sources.transport.routes", "must map every endpoint exactly once")
    for endpoint_id in endpoints:
        if transport_routes.get(endpoint_id) != "release":
            fail(f"$.sources.transport.routes.{endpoint_id}", "must use release transport")


def validate_platform_detail(config: dict) -> None:
    if config.get("format") != FORMAT or config.get("schema_version") != SCHEMA_VERSION:
        fail("$", "unsupported detail Config contract")
    if not isinstance(config.get("config_version"), str) or not SEMVER.fullmatch(config["config_version"]):
        fail("$.config_version", "must be numeric semantic versioning")
    validate_id(config.get("platform_id"), "$.platform_id")
    platform = {key: value for key, value in config.items() if key not in {"format", "schema_version", "config_version", "platform_id"}}
    platform["priority"] = 0
    platform["recognition"] = {"kind": "always"}
    validate_platform(platform, "$")
    walk_no_code(config)


def validate_root_common(config: dict) -> None:
    metadata = object_at(config.get("metadata"), "$.metadata")
    exact_keys(metadata, {"generated_at", "source_revision"}, "$.metadata")
    if not isinstance(metadata["generated_at"], str) or not metadata["generated_at"].endswith("Z"):
        fail("$.metadata.generated_at", "must be a UTC timestamp")
    if not isinstance(metadata["source_revision"], str) or not metadata["source_revision"]:
        fail("$.metadata.source_revision", "must not be empty")
    limits = object_at(config.get("parser_limits"), "$.parser_limits")
    limit_keys = {"max_depth", "max_path_bytes", "max_string_bytes", "max_collection_items"}
    exact_keys(limits, limit_keys, "$.parser_limits")
    for name in limit_keys:
        if type(limits[name]) is not int or limits[name] <= 0:
            fail(f"$.parser_limits.{name}", "must be a positive integer")
    object_at(config.get("environment"), "$.environment")
    adapters = object_at(config.get("adapters"), "$.adapters")
    for adapter_id, adapter_value in adapters.items():
        validate_id(adapter_id, f"$.adapters.{adapter_id}")
        adapter = object_at(adapter_value, f"$.adapters.{adapter_id}")
        require_keys(adapter, {"kind", "contract_version"}, f"$.adapters.{adapter_id}")
        if not isinstance(adapter["kind"], str) or not adapter["kind"]:
            fail(f"$.adapters.{adapter_id}.kind", "must not be empty")
        if type(adapter["contract_version"]) is not int or adapter["contract_version"] <= 0:
            fail(f"$.adapters.{adapter_id}.contract_version", "must be positive")


def validate_resolved_closure(config: dict, platform: str, model: str | None = None) -> None:
    entry = config["platforms"].get(platform)
    if entry is None:
        fail("$.platforms", f"unknown resolved platform {platform}")
    if model is not None and model not in {item["id"] for item in entry.get("models", [])}:
        fail(f"$.platforms.{platform}.models", f"unknown resolved model {model}")
    for adapter_id in entry["required_adapters"]:
        adapter = config["adapters"][adapter_id]
        if adapter.get("kind") not in SUPPORTED_ADAPTER_KINDS or adapter.get("contract_version") != 1:
            fail(f"$.adapters.{adapter_id}", "selected adapter is unsupported")


def walk_no_code(value: Any) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key.lower() in FORBIDDEN_KEYS:
                fail("$", f"forbidden executable field {key}")
            walk_no_code(child)
    elif isinstance(value, list):
        for child in value:
            walk_no_code(child)


def is_root_config(config: Any) -> bool:
    platforms = config.get("platforms", {}) if isinstance(config, dict) else {}
    return isinstance(platforms, dict) and any(isinstance(item, dict) and "detail" in item for item in platforms.values())


def is_platform_detail(config: Any) -> bool:
    return isinstance(config, dict) and "platform_id" in config and "platforms" not in config


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
    except (OSError, json.JSONDecodeError, ConfigError) as error:
        print(f"invalid appmanager config: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
