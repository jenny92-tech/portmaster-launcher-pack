#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import xml.etree.ElementTree as ET
from pathlib import Path

IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--xml", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def c_string(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"')


def main() -> None:
    args = parse_args()
    root = ET.parse(args.xml).getroot()

    methods = []
    for method in root.findall("./methods/method"):
        name = method.attrib.get("name", "")
        if name and name not in methods:
            methods.append(name)

    constants = []
    for constant in root.findall("./constants/constant"):
        name = constant.attrib.get("name", "")
        value = constant.attrib.get("value", "")
        if name and value and IDENTIFIER.match(name):
            constants.append((name, int(value, 0)))

    signals = []
    for signal in root.findall("./signals/signal"):
        name = signal.attrib.get("name", "")
        if name and name not in signals:
            signals.append(name)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8") as out:
        out.write("// Generated from GodotSteam doc_classes/Steam.xml. Do not edit by hand.\n")
        for name in methods:
            if name in {"steamInitEx", "steamInit", "run_callbacks", "runCallbacks", "isSteamRunning", "loggedOn", "getSteamID", "getPersonaName"}:
                continue
            out.write(f'    bind_stub_method("{c_string(name)}");\n')
        for name, value in constants:
            out.write(f'    ClassDB::bind_integer_constant(get_class_static(), "", "{c_string(name)}", {value}LL);\n')
        for name in signals:
            out.write(f'    ADD_SIGNAL(MethodInfo("{c_string(name)}"));\n')


if __name__ == "__main__":
    main()
