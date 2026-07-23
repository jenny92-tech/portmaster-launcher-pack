#!/usr/bin/env python3
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
                "trimui",
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
        allowed = {"display_name", "recognition", "display", "overrides"}
        models = self.config["platforms"]["trimui"]["models"]
        for model in ("brick", "brick_pro", "smart_pro"):
            entry = models[model]
            self.assertNotIn("inherits", entry)
            self.assertLessEqual(set(entry), allowed)
            self.assertLessEqual(set(entry.get("overrides", {})), {"display", "input"})
        # Parentage is represented by containment, so model ids can be reused
        # independently by another platform.
        duplicate = copy.deepcopy(models["brick"])
        config = copy.deepcopy(self.config)
        config["platforms"]["generic"]["models"] = {"brick": duplicate}
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
        for platform in ("rocknix", "jelos"):
            self.assertEqual(
                self.config["platforms"][platform]["frontend"]["management"],
                "system",
            )
            self.assertFalse(
                self.config["platforms"][platform]["capabilities"]["manage_portmaster"]
            )

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
            if name in {"miniloong", "trimui"}:
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
        for name, strategy in expected.items():
            self.assertEqual(
                self.config["platforms"][name]["paths"]["launcher_directory"],
                strategy,
                name,
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
