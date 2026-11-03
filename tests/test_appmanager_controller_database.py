#!/usr/bin/env python3
# INPUT:  APP 随包 SDL 数据库与 ui.gptk
# OUTPUT: APP 基础操作覆盖及同 GUID 冲突回归结果
# POS:    只验证 APP 自身需要的控制器映射，不要求完整游戏手柄功能
from pathlib import Path
import hashlib
import json
import unittest

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "ports/appmanager"
ADDED_GUIDS = [
    "03002758091200000031000011010000",
    "19000226010000000100000001010000",
    "1900dea8010000000200000001010000",
    "03009b4d4b4800000111000000010000",
    "19009b4d4b4800000111000000010000",
    "1900a4dd726b333536322d6a6f797300",
    "1900adda4b4800001211000000010000",
    "19009321b0c300000002000010000000",
    "190014b301000000a20a000000010000",
    "1900e5914b4800007711000077010000",
    "1900e7444b4800000111000034020000",
    "03001a3447616d65466f726365204100",
    "1900c3ea010000000100000001010000",
    "1900d632010000002c0a000000010000",
    "0300879bfeca00000550000011010000",
    "1900c3bbb0c300000002000010000000",
    "0300f353202000000130000001000000",
    "0300b605202000000130000001000000",
    "1900365541594e204f64696e20476100",
    "030081b85e0400008e02000000020000",
    "0300f5a35e040000120b000001000000"
]
OTHER_ADDED_GUIDS = [
    "060000006d750000050000006f730000",
    "060000006d750000060000006f730000",
    "060000006d750000033500006f730000",
    "060000006d750000020700006f730000",
    "060000006d750000030700006f730000",
    "060000006d750000040700006f730000",
    "060000006d750000050700006f730000",
    "060000006d750000060700006f730000",
    "060000006d750000070700006f730000",
    "060000006d750000080700006f730000",
    "060000006d750000090700006f730000",
    "060000006d7500000a0700006f730000",
    "060000006d7500000b0700006f730000",
    "060000006d7500000c0700006f730000",
    "060000006d750000010700006f730000",
    "060000006d750000013500006f730000",
    "060000006d750000023500006f730000",
    "060000006d750000030000006f730000",
    "060000006d750000020000006f730000",
    "060000006d750000010000006f730000",
    "190043d2010000000221000000010000",
    "1c000000014000002904000000010000",
    "0300fd574c050000e60c000011810000",
    "0300f9c34c050000f20d000000810000"
]
BASIC = {"dpup", "dpdown", "dpleft", "dpright",
         "a", "b", "x", "y", "leftshoulder", "rightshoulder"}


def records():
    result = {}
    for line in (APP / "portable/share/gamecontrollerdb.txt").read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split(",")
        mapping = dict(field.split(":", 1) for field in fields[2:] if ":" in field)
        result.setdefault((fields[0], mapping.get("platform")), []).append(mapping)
    return result


class ControllerDatabaseTests(unittest.TestCase):
    def test_all_aurknix_entries_preserve_complete_nonconflicting_mappings(self):
        # Pinned AURKNIX 9cf9ebe: all 25 GUIDs considered. The two same-GUID
        # conflicts are tested separately; no optional fields are stripped.
        database = records()
        matching = ADDED_GUIDS + [
            "1900fcf27a65645f6a6f797374696300",  # Zed: already identical
            "1900f6a24b480000df14000000010000",  # H700: already identical
        ]
        mappings = {}
        for guid in matching:
            self.assertEqual(len(database[(guid, "Linux")]), 1)
            mappings[guid] = database[(guid, "Linux")][0]
        digest = hashlib.sha256(json.dumps(mappings, sort_keys=True).encode()).hexdigest()
        self.assertEqual(digest, "5c97e7f99d5e0e30aaf36a7d51de78c3a321213b57d3aadac26fac2c6a156719")

    def test_added_guids_have_app_controls_without_duplicates(self):
        database = records()
        for guid in ADDED_GUIDS + OTHER_ADDED_GUIDS:
            with self.subTest(guid=guid):
                self.assertRegex(guid, r"^[0-9a-f]{32}$")
                entries = database[(guid, "Linux")]
                self.assertEqual(len(entries), 1)
                self.assertTrue(BASIC <= entries[0].keys())
                for key in BASIC:
                    self.assertRegex(entries[0][key], r"^(b[0-9]+|h[0-9]+\.[1248]|[+-]?a[0-9]+~?)$")
        self.assertEqual(len(ADDED_GUIDS), len(set(ADDED_GUIDS)))
        self.assertEqual(len(OTHER_ADDED_GUIDS), 24)
        self.assertEqual(len(set(ADDED_GUIDS + OTHER_ADDED_GUIDS)), 45)

    def test_app_button_semantics(self):
        config = {}
        for line in (APP / "love/ui.gptk").read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                key, value = (part.strip() for part in line.split("=", 1))
                config.setdefault(key, []).append(value)
        for key in ("a", "b"):
            self.assertEqual(config[key], ["enter"])
        for key in ("x", "y"):
            self.assertEqual(config[key], ["esc"])
        self.assertEqual(config["l1"], ["pageup"])
        self.assertEqual(config["r1"], ["pagedown"])
        self.assertEqual(config["start"], ["f10"])
        self.assertEqual(config["back"], ["f10"])
        for key in ("up", "down", "left", "right"):
            self.assertIn(key, config[key])

    def test_existing_conflicts_are_not_overwritten(self):
        database = records()
        ultra = database[("03001354474f2d556c74726120476100", "Linux")]
        self.assertEqual(len(ultra), 1)
        self.assertEqual(ultra[0]["dpup"], "b8")
        self.assertEqual(ultra[0]["start"], "b17")
        r36s = database[("19003982010000008811000088010000", "Linux")]
        self.assertEqual(len(r36s), 1)
        self.assertEqual(r36s[0]["guide"], "b10")
        for guid in ("190000004b4800000011000000010000",
                     "1900f6a24b480000df14000000010000"):
            self.assertEqual(len(database[(guid, "Linux")]), 1)
            self.assertTrue(BASIC <= database[(guid, "Linux")][0].keys())


if __name__ == "__main__":
    unittest.main()
