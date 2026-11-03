# INPUT: synthetic exported Godot configuration and ARM64 resource rewrites
# OUTPUT: narrowly-scoped startup overrides and fail-closed identity checks
# POS: validates startup resources without loading a game or device
import importlib.util
import struct
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('runtime_resources', ROOT / 'ports/sts2/src/scripts/windows_runtime_resources.py')
RUNTIME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNTIME)

def record(name, value):
    name = name.encode()
    return struct.pack('<I', len(name)) + name + struct.pack('<I', len(value)) + value

class StartupResourceTests(unittest.TestCase):
    def test_project_removes_only_sentry_autoload(self):
        before = record('a', b'one')
        target = record('autoload/SentryBootstrap', b'*res://addons/sentry/SentryBootstrap.cs')
        after = record('autoload/FmodManager', b'two')
        source = b'ECFG' + struct.pack('<I', 3) + before + target + after
        self.assertEqual(RUNTIME.rewrite_project(source), b'ECFG' + struct.pack('<I', 2) + before + after)
        for invalid in (source[:-1], source.replace(b'SentryBootstrap.cs', b'SentryBootstray.cs'), source + b'!'):
            with self.assertRaises(ValueError): RUNTIME.rewrite_project(invalid)

    def test_fmod_adds_arm64_without_dropping_existing_platforms(self):
        source = b'[configuration]\nentry_symbol = "fmod_library_init"\n[libraries]\nwindows.release.x86_64 = "win"\n\n[icons]\n[dependencies]\nlinux.release.x86_64 = {\n"libs/linux/libfmod.so": ""\n}\n'
        out = RUNTIME.rewrite_fmod(source)
        self.assertIn(b'windows.release.x86_64 = "win"', out)
        self.assertIn(b'linux.release.arm64 = "res://addons/fmod/libs/linux/libGodotFmod.linux.template_release.arm64.so"', out)
        self.assertIn(b'linux.release.arm64 = {\n"libs/linux/libfmod.so": ""\n}', out)
        with self.assertRaises(ValueError): RUNTIME.rewrite_fmod(out)
        with self.assertRaises(ValueError): RUNTIME.rewrite_fmod(source.replace(b'linux.release.x86_64', b'linux.debug.x86_64'))

    def test_spine_changes_only_three_arm_paths(self):
        source = (b'linux.release.x86_64 = "linux/existing.so"\n'
            b'linux.editor.arm64 = "linux/libspine_godot.linux.editor.arm64.so"\n'
            b'linux.debug.arm64 = "linux/libspine_godot.linux.template_debug.arm64.so"\n'
            b'linux.release.arm64 = "linux/libspine_godot.linux.template_release.arm64.so"\n')
        out = RUNTIME.rewrite_spine(source)
        self.assertEqual(out.count(b'res://addons/spine/linux/'), 3)
        self.assertEqual(out.replace(b'res://addons/spine/linux/', b'linux/'), source)
        with self.assertRaises(ValueError): RUNTIME.rewrite_spine(out)

if __name__ == '__main__': unittest.main()
