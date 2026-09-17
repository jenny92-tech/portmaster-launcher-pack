#!/usr/bin/env python3
# INPUT:  unittest, importlib, subprocess；配置生成器、验证器、Schema 和生成 JSON
# OUTPUT: ConfigContractTests 配置契约回归测试
# POS:    验证配置生成结果与设备策略及严格校验规则一致
"""Contract tests for the generated Port App Manager device configuration."""

from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


CONFIG_DIR = Path(__file__).resolve().parents[1]
ROOT = CONFIG_DIR.parent
GENERATED = CONFIG_DIR / "config.json"
GENERATOR = CONFIG_DIR / "scripts" / "generate.py"
VALIDATOR = CONFIG_DIR / "scripts" / "validate.py"


def load_validator():
    spec = importlib.util.spec_from_file_location("appmanager_config_validator", VALIDATOR)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class ConfigContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.validator = load_validator()
        cls.raw = GENERATED.read_bytes()
        cls.root_config = json.loads(cls.raw)
        cls.config = copy.deepcopy(cls.root_config)
        cls.config["platforms"] = {}
        for platform_id, entry in cls.root_config["platforms"].items():
            detail_raw = (CONFIG_DIR / "platforms" / f"{platform_id}.json").read_bytes()
            detail = json.loads(detail_raw)
            for key in ("format", "schema_version", "config_version", "platform_id"):
                detail.pop(key)
            detail["priority"] = entry["priority"]
            detail["recognition"] = entry["recognition"]
            cls.config["platforms"][platform_id] = detail

    def test_generated_file_is_canonical_minified_utf8(self) -> None:
        self.raw.decode("utf-8")
        self.assertEqual(self.raw.count(b"\n"), 1)
        self.assertTrue(self.raw.endswith(b"\n"))
        expected = json.dumps(
            self.root_config, ensure_ascii=False, sort_keys=True, separators=(",", ":")
        ).encode("utf-8") + b"\n"
        self.assertEqual(self.raw, expected)
        subprocess.run(
            [sys.executable, str(GENERATOR), "--check"], cwd=ROOT, check=True
        )

    def test_required_metadata_and_platforms(self) -> None:
        self.assertEqual(self.config["format"], "jenny92.appmanager-config")
        self.assertEqual(self.config["schema_version"], 1)
        for key in ("config_version", "metadata"):
            self.assertIn(key, self.config)
        self.assertIn("generated_at", self.config["metadata"])
        self.assertIn("source_revision", self.config["metadata"])
        self.assertEqual(
            set(self.config["platforms"]),
            {
                "miniloong",
                "miniloong-loongos",
                "trimui",
                "arkos",
                "amberelec",
                "muos",
                "rocknix",
                "jelos",
                "unofficialos",
                "knulli",
                "batocera",
                "miyoo",
                "generic",
            },
        )

    def test_models_are_recognition_display_only_and_inherit_parent(self) -> None:
        self.assertNotIn("models", self.config)
        allowed = {"id", "priority", "display_name", "recognition", "display", "overrides"}
        models = self.config["platforms"]["trimui"]["models"]
        by_id = {model["id"]: model for model in models}
        for model in ("brick", "brick_pro", "smart_pro"):
            entry = by_id[model]
            self.assertNotIn("inherits", entry)
            self.assertLessEqual(set(entry), allowed)
            self.assertLessEqual(set(entry.get("overrides", {})), {"display", "input"})
        # Parentage is represented by containment, so model ids can be reused
        # independently by another platform.
        duplicate = copy.deepcopy(by_id["brick"])
        config = copy.deepcopy(self.config)
        config["platforms"]["generic"]["models"] = [duplicate]
        self.validator.validate(config)

    def test_v1_locations_are_stable_typed_and_never_use_scan_roots(self) -> None:
        for name, platform in self.config["platforms"].items():
            self.assertNotIn("scan_roots", platform, name)
            self.assertNotIn("apps_root", platform, name)
            ids = [location["id"] for location in platform["locations"]]
            self.assertEqual(len(ids), len(set(ids)), name)
            for location in platform["locations"]:
                self.assertIn(location["path"], platform["paths"], name)
        app_locations = [
            location for location in self.config["platforms"]["trimui"]["locations"]
            if location["kind"] == "apps"
        ]
        self.assertEqual([location["id"] for location in app_locations], ["apps-primary"])

    def test_validator_rejects_bad_location_and_capability_types(self) -> None:
        config = copy.deepcopy(self.config)
        config["platforms"]["trimui"]["locations"][0]["id"] = "apps-primary"
        with self.assertRaises(self.validator.ConfigError):
            self.validator.validate(config)

        config = copy.deepcopy(self.config)
        config["platforms"]["trimui"]["capabilities"]["install_apps"] = "yes"
        with self.assertRaises(self.validator.ConfigError):
            self.validator.validate(config)

        config = copy.deepcopy(self.config)
        config["platforms"]["trimui"]["paths"]["apps"] = {
            "strategy": "literal", "value": "/tmp/../etc"
        }
        with self.assertRaises(self.validator.ConfigError):
            self.validator.validate(config)

    def test_v1_strictness_and_location_selection_are_one_contract(self) -> None:
        mutations = []

        config = copy.deepcopy(self.config)
        config["platforms"]["generic"]["locations"][0]["future"] = True
        mutations.append(config)

        config = copy.deepcopy(self.config)
        config["platforms"]["trimui"]["models"][0].pop("display")
        mutations.append(config)

        config = copy.deepcopy(self.config)
        config["platforms"]["trimui"]["models"][0]["future"] = True
        mutations.append(config)

        config = copy.deepcopy(self.config)
        config["platforms"]["generic"]["capabilities"].pop("scan_script_images")
        mutations.append(config)

        config = copy.deepcopy(self.config)
        config["platforms"]["generic"]["locations"] = config["platforms"]["generic"]["locations"][:1]
        mutations.append(config)

        config = copy.deepcopy(self.config)
        platform = config["platforms"]["generic"]
        platform["paths"]["scripts_secondary"] = {
            "strategy": "literal", "value": "/ports-secondary"
        }
        duplicate = copy.deepcopy(platform["locations"][0])
        duplicate.update(id="ports-scripts-secondary", path="scripts_secondary")
        platform["locations"].append(duplicate)
        mutations.append(config)

        config = copy.deepcopy(self.config)
        config["platforms"]["generic"]["locations"][0]["roles"] = ["inventory"]
        mutations.append(config)

        for config in mutations:
            with self.assertRaises(self.validator.ConfigError):
                self.validator.validate(config)

        # A separate, higher-priority inventory root remains valid, but it must
        # never replace the lower-priority root that carries install/manage.
        config = copy.deepcopy(self.config)
        platform = config["platforms"]["generic"]
        platform["paths"]["inventory_scripts"] = {
            "strategy": "literal", "value": "/inventory-only"
        }
        platform["locations"].append({
            "id": "ports-scripts-inventory",
            "kind": "port_scripts",
            "path": "inventory_scripts",
            "roles": ["inventory"],
            "formats": ["port"],
            "priority": 200,
        })
        self.validator.validate(config)

    def test_environment_is_default_open_with_exact_blocklist(self) -> None:
        policy = self.config["environment"]
        self.assertEqual(policy["inherit"], "all_except_blocked")
        self.assertEqual(policy["value_handling"], "literal")
        self.assertEqual(
            set(policy["blocked_names"]),
            {
                "LD_PRELOAD",
                "LD_AUDIT",
                "GCONV_PATH",
                "BASH_ENV",
                "ENV",
                "SHELLOPTS",
                "BASHOPTS",
                "IFS",
                "PS4",
            },
        )
        self.assertEqual(policy["blocked_prefixes"], ["BASH_FUNC_"])
        self.assertEqual(
            set(policy["scopes"]),
            {"love_ui"},
        )
        self.assertEqual(policy["operation_kinds"], ["set", "prepend", "append", "unset"])
        for scope in policy["scopes"].values():
            self.assertIn("operations", scope)
            self.assertIn("profiles", scope)

    def test_platform_specific_safety_contracts(self) -> None:
        trimui = self.config["platforms"]["trimui"]
        self.assertEqual(
            trimui["libraries"]["groups"]["sdl2"]["candidates"],
            ["/usr/lib", "/usr/trimui/lib"],
        )
        self.assertEqual(
            trimui["libraries"]["groups"]["sdl2"]["required_sonames"],
            [
                "libSDL2-2.0.so.0",
                "libSDL2_image-2.0.so.0",
                "libSDL2_mixer-2.0.so.0",
                "libSDL2_ttf-2.0.so.0",
            ],
        )
        self.assertEqual(trimui["libraries"]["groups"]["gles"]["candidates"], ["/usr/lib"])
        self.assertEqual(
            self.config["platforms"]["miniloong"]["python"]["mode"],
            "runtime_mount",
        )
        self.assertEqual(
            self.config["platforms"]["miniloong-loongos"]["python"],
            {
                "mode": "system",
                "imports": ["sys", "encodings", "zipfile", "hashlib"],
            },
        )
        for platform in ("rocknix", "jelos"):
            self.assertEqual(
                self.config["platforms"][platform]["frontend"]["management"],
                "system",
            )
            self.assertFalse(
                self.config["platforms"][platform]["capabilities"]["manage_portmaster"]
            )

    def test_trimui_does_not_maintain_portmaster_but_keeps_game_management(self) -> None:
        trimui = self.config["platforms"]["trimui"]
        self.assertEqual(trimui["frontend"]["management"], "system")
        self.assertEqual(trimui["source_route"], "system")
        route = self.config["sources"]["release_routes"][trimui["source_route"]]
        self.assertFalse(route["install_allowed"])
        for capability in (
            "manage_portmaster", "install_portmaster", "update_portmaster", "manage_frontend",
        ):
            self.assertFalse(trimui["capabilities"][capability], capability)
        for capability in (
            "repair_runtimes", "inventory_ports", "manage_ports", "install_ports",
            "inventory_apps", "manage_apps", "install_apps", "manage_images",
            "manage_artwork", "trash", "leftovers", "cleanup_appledouble",
        ):
            self.assertTrue(trimui["capabilities"][capability], capability)
        # Both MiniLoong generations still use APP-managed PortMaster.
        for platform in ("miniloong", "miniloong-loongos"):
            with self.subTest(platform=platform):
                config = self.config["platforms"][platform]
                self.assertEqual(config["frontend"]["management"], "app")
                for capability in ("manage_portmaster", "install_portmaster", "update_portmaster"):
                    self.assertTrue(config["capabilities"][capability], capability)

    def test_health_capabilities_and_library_groups_are_complete(self) -> None:
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
        for name, platform in self.config["platforms"].items():
            entrypoint_rules = [
                rule for rule in platform["health"] if rule["kind"] == "one_of_files"
            ]
            self.assertEqual(len(entrypoint_rules), 1, name)
            self.assertEqual(
                entrypoint_rules[0]["paths"],
                ["{portmaster_core}/pugwash", "{portmaster_core}/harbourmaster"],
                name,
            )
            self.assertLessEqual(capability_names, set(platform["capabilities"]), name)
            for group in platform["libraries"]["groups"].values():
                self.assertTrue(group["required_sonames"], name)
                self.assertTrue(group["candidates"], name)

        broken = copy.deepcopy(self.config)
        broken["platforms"]["generic"]["health"][0] = {"kind": "required_file"}
        with self.assertRaises(self.validator.ConfigError):
            self.validator.validate(broken)

        broken = copy.deepcopy(self.config)
        apps = broken["platforms"]["trimui"]["locations"][-1]
        apps["roles"] = ["install"]
        with self.assertRaises(self.validator.ConfigError):
            self.validator.validate(broken)

    def test_subsequent_sources_use_capability_aware_proxy_registry(self) -> None:
        transport = self.config["sources"]["transport"]
        self.assertEqual(transport["proxy_registry_ref"], "embedded://github-proxy-registry/v1")
        self.assertEqual(transport["probe_batch_limit"], 5)
        for source in ("jenny92_portmaster", "official_portmaster", "runtime_metadata"):
            self.assertEqual(transport["routes"][source], "release")
        self.assertNotIn("installer_protocol", self.config["sources"]["endpoints"])

    def test_frontend_installer_policy_matches_launcher_contract(self) -> None:
        expected = {
            "miniloong": (None, None, False, False, "PortMaster.sh", "PortMaster.sh"),
            "miniloong-loongos": (None, None, False, False, "PortMaster.sh", "PortMaster.sh"),
            "trimui": ("trimui/control.txt", None, True, True, None, "launch.sh"),
            "arkos": (None, None, True, False, None, "PortMaster.sh"),
            "amberelec": (None, None, True, False, None, "PortMaster.sh"),
            "muos": ("muos/control.txt", "muos/PortMaster.txt", False, True, "PortMaster.sh", None),
            "rocknix": (None, None, False, False, "PortMaster.sh", None),
            "jelos": (None, None, False, False, "PortMaster.sh", None),
            "unofficialos": (None, None, False, False, "PortMaster.sh", None),
            "knulli": ("knulli/control.txt", None, True, True, None, "PortMaster.sh"),
            "batocera": ("batocera/control.txt", None, True, True, None, "PortMaster.sh"),
            "miyoo": ("miyoo/control.txt", "miyoo/PortMaster.txt", False, False, "PortMaster.sh", None),
            "generic": (None, None, False, False, "PortMaster.sh", "PortMaster.sh"),
        }
        keys = (
            "control_source",
            "core_launcher_source",
            "remove_core_launcher",
            "empty_tasksetter",
            "core_executable",
            "frontend_executable",
        )
        for platform, values in expected.items():
            frontend = self.config["platforms"][platform]["frontend"]
            self.assertEqual(tuple(frontend[key] for key in keys), values, platform)
        self.assertEqual(
            self.config["platforms"]["trimui"]["frontend"]["transforms"],
            [{
                "kind": "export_library_group",
                "target": "launch.sh",
                "variable": "PYSDL2_DLL_PATH",
                "library_group": "sdl2",
            }],
        )

    def test_support_classification_never_authorizes_a_guessed_generic_target(self) -> None:
        for name, platform in self.config["platforms"].items():
            support = platform["support"]
            if name in {"miniloong", "miniloong-loongos", "trimui"}:
                self.assertEqual(support["device_class"], "tested", name)
            elif name == "generic":
                self.assertEqual(support["device_class"], "unsupported-known")
            else:
                self.assertEqual(support["device_class"], "official-untested", name)
            self.assertEqual(
                support["target_confirmation"],
                "existing_core_or_override" if name == "generic" else "detected",
                name,
            )
        generic_core = self.config["platforms"]["generic"]["paths"]["portmaster_core"]
        self.assertEqual(generic_core["strategy"], "first_existing")
        self.assertEqual(generic_core["on_missing"], "unresolved")
        self.assertNotIn("fallback", generic_core)

    def test_launcher_directory_matches_portmaster_directory_contract(self) -> None:
        expected = {
            "miniloong": {"strategy": "literal", "value": "/mnt/sdcard/roms"},
            "miniloong-loongos": {"strategy": "launcher_dir"},
            "trimui": {"strategy": "literal", "value": "/mnt/SDCARD/Data"},
            "arkos": {"strategy": "parent", "of": "game_data"},
            "amberelec": {"strategy": "parent", "of": "game_data"},
            "muos": {"strategy": "parent", "of": "game_data"},
            "rocknix": {"strategy": "parent", "of": "game_data"},
            "jelos": {"strategy": "parent", "of": "game_data"},
            "unofficialos": {"strategy": "parent", "of": "game_data"},
            "knulli": {"strategy": "literal", "value": "/userdata/roms"},
            "batocera": {"strategy": "literal", "value": "/userdata/roms"},
            "miyoo": {"strategy": "literal", "value": "/mnt/sdcard/Roms/PORTS64"},
            "generic": {"strategy": "parent", "of": "game_data"},
        }
        for name, strategy in expected.items():
            self.assertEqual(
                self.config["platforms"][name]["paths"]["launcher_directory"],
                strategy,
                name,
            )

    def test_shell_directory_is_explicit_for_every_profile(self) -> None:
        for name, platform in self.config["platforms"].items():
            expected = ({"strategy": "literal", "value": "/mnt/sdcard/Roms/PORTS64"}
                        if name == "miyoo" else {"strategy": "parent", "of": "game_data"})
            self.assertEqual(platform["paths"]["shell_directory"], expected, name)

    def test_miniloong_accepts_old_and_loongos_layouts_declaratively(self) -> None:
        legacy = self.config["platforms"]["miniloong"]
        loongos = self.config["platforms"]["miniloong-loongos"]
        self.assertEqual(
            legacy["recognition"],
            {"kind": "file_exists", "path": "/loong/loong_version"},
        )
        self.assertEqual(
            legacy["paths"]["game_data"],
            {"strategy": "literal", "value": "/mnt/sdcard/roms/ports"},
        )
        self.assertEqual(legacy["input"]["analog_sticks"], 1)
        self.assertEqual(
            legacy["frontend"]["install_map"],
            [{
                "source": "miniloong/PortMaster.txt",
                "target": "PortMaster.sh",
                "executable": True,
            }],
        )
        self.assertGreater(loongos["priority"], legacy["priority"])
        self.assertEqual(
            loongos["frontend"]["install_map"],
            [{
                "source": "PortMaster.sh",
                "target": "PortMaster.sh",
                "executable": True,
            }],
        )
        self.assertEqual(
            loongos["recognition"],
            {
                "kind": "all",
                "predicates": [
                    {
                        "kind": "os_release_equals",
                        "field": "ID",
                        "value": "loong",
                        "case_insensitive": True,
                    },
                    {
                        "kind": "os_release_version_at_least",
                        "field": "VERSION_ID",
                        "value": "1.4.0.0",
                    },
                ],
            },
        )
        self.assertEqual(
            loongos["paths"]["game_data"],
            {"strategy": "literal", "value": "/roms/ports", "canonicalize_existing": True},
        )
        self.assertEqual(loongos["input"]["analog_sticks"], 1)
        self.assertEqual(
            loongos["paths"]["portmaster_core"],
            {
                "strategy": "relative_to",
                "base": "game_data",
                "suffix": "PortMaster",
                "canonicalize_existing": True,
            },
        )

    def test_official_installer_layouts_are_declarative(self) -> None:
        arkos = self.config["platforms"]["arkos"]
        self.assertEqual(
            arkos["recognition"],
            {"kind": "directory_exists", "path": "/opt/system/Tools"},
        )
        self.assertEqual(
            arkos["paths"]["game_data"],
            {
                "strategy": "first_existing",
                "expected_type": "directory",
                "candidates": ["/roms2/ports", "/roms/ports"],
            },
        )
        self.assertEqual(
            arkos["paths"]["portmaster_core"],
            {"strategy": "literal", "value": "/opt/system/Tools/PortMaster"},
        )
        self.assertEqual(
            arkos["paths"]["frontend"],
            {"strategy": "literal", "value": "/opt/system/Tools"},
        )

        amberelec = self.config["platforms"]["amberelec"]
        self.assertEqual(
            amberelec["recognition"],
            {"kind": "directory_exists", "path": "/opt/tools"},
        )
        self.assertEqual(
            amberelec["paths"]["game_data"],
            {"strategy": "literal", "value": "/roms/ports"},
        )
        self.assertEqual(
            amberelec["paths"]["portmaster_core"],
            {"strategy": "literal", "value": "/opt/tools/PortMaster"},
        )
        self.assertEqual(
            amberelec["paths"]["frontend"],
            {"strategy": "literal", "value": "/opt/tools"},
        )

    def test_no_executable_escape_hatches(self) -> None:
        forbidden = {"run_shell", "eval", "exec", "command", "shell"}

        def walk(value):
            if isinstance(value, dict):
                for key, child in value.items():
                    self.assertNotIn(key.lower(), forbidden)
                    walk(child)
            elif isinstance(value, list):
                for child in value:
                    walk(child)

        walk(self.config)

    def test_unknown_adapter_is_allowed_outside_resolved_closure(self) -> None:
        config = copy.deepcopy(self.config)
        config["adapters"]["future.adapter"] = {
            "kind": "future_kind",
            "contract_version": 99,
        }
        config["platforms"]["future-device"] = copy.deepcopy(
            config["platforms"]["generic"]
        )
        config["platforms"]["future-device"]["required_adapters"] = [
            "future.adapter"
        ]
        self.validator.validate(config)
        self.validator.validate_resolved_closure(config, "miniloong")
        with self.assertRaises(self.validator.ConfigError):
            self.validator.validate_resolved_closure(config, "future-device")

    def test_validator_rejects_code_predicates_and_bad_paths(self) -> None:
        config = copy.deepcopy(self.config)
        config["platforms"]["generic"]["recognition"] = {
            "kind": "run_shell",
            "source": "id",
        }
        with self.assertRaises(self.validator.ConfigError):
            self.validator.validate(config)

        config = copy.deepcopy(self.config)
        config["platforms"]["generic"]["paths"]["portmaster_core"] = {
            "strategy": "literal",
            "value": "/tmp/../etc",
        }
        with self.assertRaises(self.validator.ConfigError):
            self.validator.validate(config)

    def test_validator_rejects_inert_or_weakened_source_contracts(self) -> None:
        mutations = []

        config = copy.deepcopy(self.config)
        config["bootstrap"]["config_url"] = "http://example.test/config.json"
        mutations.append(config)

        config = copy.deepcopy(self.config)
        config["sources"]["runtime"]["verification"].remove("md5")
        mutations.append(config)

        config = copy.deepcopy(self.config)
        config["sources"]["release_routes"]["official"]["manifest"] = "missing"
        mutations.append(config)

        config = copy.deepcopy(self.config)
        config["sources"]["transport"]["probe_batch_limit"] = 0
        mutations.append(config)

        config = copy.deepcopy(self.config)
        config["sources"]["runtime"]["architectures"][1]["system_names"] = ["aarch64"]
        mutations.append(config)

        config = copy.deepcopy(self.config)
        config["sources"]["runtime"]["verfication"] = config["sources"]["runtime"].pop("verification")
        mutations.append(config)

        for config in mutations:
            with self.assertRaises(self.validator.ConfigError):
                self.validator.validate(config)

    def test_schema_defines_the_same_source_and_detail_contracts(self) -> None:
        schema = json.loads((CONFIG_DIR / "appmanager-config.schema.json").read_text())
        self.assertEqual(schema["properties"]["bootstrap"]["$ref"], "#/$defs/bootstrap")
        self.assertEqual(schema["properties"]["sources"]["$ref"], "#/$defs/sources")
        self.assertFalse(schema["$defs"]["bootstrap"]["additionalProperties"])
        self.assertFalse(schema["$defs"]["sources"]["additionalProperties"])
        detail_schema = json.loads((CONFIG_DIR / "platform-detail.schema.json").read_text())
        for field in ("device_manufacturer", "locations", "models"):
            self.assertIn(field, detail_schema["properties"])
        required_capabilities = set(schema["$defs"]["capabilities"]["required"])
        self.assertEqual(required_capabilities, self.validator.REQUIRED_CAPABILITIES)
        self.assertEqual(schema["$defs"]["locations"]["minItems"], 2)
        self.assertEqual(
            schema["$defs"]["locations"]["x-appmanager-unique-highest-priority-by-kind"],
            list(self.validator.PORT_LOCATION_KINDS),
        )
        self.assertEqual(
            detail_schema["properties"]["locations"]["$ref"],
            "appmanager-config.schema.json#/$defs/locations",
        )
        self.assertEqual(
            detail_schema["properties"]["capabilities"]["$ref"],
            "appmanager-config.schema.json#/$defs/capabilities",
        )

    def test_validator_cli_accepts_generated_artifact_and_schema(self) -> None:
        subprocess.run(
            [
                sys.executable,
                str(VALIDATOR),
                str(GENERATED),
            ],
            cwd=ROOT,
            check=True,
        )
        for detail in sorted((CONFIG_DIR / "platforms").glob("*.json")):
            subprocess.run(
                [sys.executable, str(VALIDATOR), str(detail)],
                cwd=ROOT,
                check=True,
            )
        json.loads((CONFIG_DIR / "appmanager-config.schema.json").read_text())
        json.loads((CONFIG_DIR / "platform-detail.schema.json").read_text())


if __name__ == "__main__":
    unittest.main()
