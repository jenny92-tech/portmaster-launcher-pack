# INPUT: isolated GLES/Vulkan dependencies and launcher child environment.
# OUTPUT: independent capability checks and a Vulkan-free SDL/KMS environment.
# POS: validates the TrimUI renderer choice without a device or graphics session.
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

profile = load('sts2_profile', 'ports/sts2/src/tools/device_tools/sts2_official_profile.py')
backend = load('sts2_backend', 'ports/sts2/src/tools/device_tools/sts2_trimui_backend.py')


class GraphicsCapabilityTests(unittest.TestCase):
    def test_trimui_vulkan_composition_resolution_and_validation(self):
        template = (ROOT / 'ports/sts2/love/launcher.sh.template').read_text()
        start = template.index('  if [ -z "${SLL_WESTON_COMPOSITION+x}" ]; then')
        end = template.index('  case "${SLL_LANGUAGE:-}"', start)
        snippet = template[start:end]
        cases = (
            ('91', 'vulkan', '1', 'unset', 'on'),
            ('91', 'vulkan', '1', 'on', 'on'),
            ('91', 'vulkan', '1', 'off', 'off'),
            ('91', 'gles', '1', 'unset', 'off'),
            ('91', 'gles', '1', 'off', 'off'),
            ('90', 'vulkan', '0', 'unset', 'off'),
            ('90', 'vulkan', '0', 'off', 'off'),
        )
        for device, api, available, requested, expected in cases:
            with self.subTest(device=device, api=api, requested=requested):
                setup = 'PROFILE_KIND="$1"; SLL_GRAPHICS_API="$2"; SLL_WESTON_COMPOSITION_AVAILABLE="$3"; unset SLL_WESTON_COMPOSITION; [ "$4" = unset ] || SLL_WESTON_COMPOSITION="$4"\n'
                script = setup + snippet + 'printf "RESULT=%s\\n" "$SLL_WESTON_COMPOSITION"\n'
                result = subprocess.run(['bash', '-c', script, 'test', device, api, available, requested], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('RESULT=' + expected, result.stdout)
        for invalid in ('auto', 'bogus', 'AUTO', 'true', ''):
            setup = 'PROFILE_KIND=91; SLL_GRAPHICS_API=vulkan; SLL_WESTON_COMPOSITION_AVAILABLE=1; SLL_WESTON_COMPOSITION="$1"\n'
            result = subprocess.run(['bash', '-c', setup + snippet, 'test', invalid], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
        unavailable = 'PROFILE_KIND=90; SLL_GRAPHICS_API=vulkan; SLL_WESTON_COMPOSITION_AVAILABLE=0; SLL_WESTON_COMPOSITION=on\n'
        self.assertNotEqual(subprocess.run(['bash', '-c', unavailable + snippet], capture_output=True).returncode, 0)

    def test_leased_probe_is_direct_child_of_launcher_shell(self):
        template = (ROOT / 'ports/sts2/love/launcher.sh.template').read_text()
        start = template.index('  early_caps_file="$(mktemp /tmp/sts2-caps.XXXXXXXX)"')
        end = template.index('  case "$early_caps" in', start)
        snippet = template[start:end]
        with tempfile.TemporaryDirectory() as tmp:
            probe = Path(tmp) / 'probe.py'
            probe.write_text('import os,sys\nassert os.getppid()==int(os.environ["TEST_BASH_PID"])\nprint("CAPS gles=1 vulkan=1")\n')
            script = 'export TEST_BASH_PID=$$\nearly_probe="$1"\n' + snippet + 'printf "%s" "$early_caps"\n'
            result = subprocess.run(['bash', '-c', script, 'test', str(probe)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, 'CAPS gles=1 vulkan=1')

    def test_missing_or_changed_dependency_disables_only_its_backend(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            engine, vk = root / 'godot', root / 'vulkan'
            engine.write_bytes(b'engine'); engine.chmod(0o700)
            vk.write_bytes(b'vulkan')
            digest = lambda value: hashlib.sha256(value).hexdigest()
            gles_files = {engine: digest(b'engine')}
            vk_files = {vk: digest(b'vulkan')}
            self.assertEqual(profile.graphics_capabilities(gles_files, vk_files, engine), (True, True))
            vk.unlink()
            self.assertEqual(profile.graphics_capabilities(gles_files, vk_files, engine), (True, False))
            vk.write_bytes(b'vulkan'); engine.write_bytes(b'changed')
            self.assertEqual(profile.graphics_capabilities(gles_files, vk_files, engine), (False, True))
            engine.write_bytes(b'engine'); engine.chmod(0o600)
            self.assertEqual(profile.graphics_capabilities(gles_files, vk_files, engine), (False, True))

    def test_gles_removes_vulkan_and_wayland_overrides(self):
        env = {'VK_INSTANCE_LAYERS': 'old', 'VK_LAYER_PATH': '/old',
               'WAYLAND_DISPLAY': 'old', 'WAYLAND_SOCKET': '3',
               'RUDROID_WAYLAND_FORCE_RENDERER': '1', 'RUDROID_VULKAN_WSI_LIBRARY': '/old',
               'SLL_GODOT_WSI': '1', 'DISABLE_WSI_LAYER': '1', 'PULSE_SERVER': '/audio'}
        backend.configure_gles(env)
        self.assertEqual(env['SDL_VIDEODRIVER'], 'kmsdrm')
        self.assertEqual(env['PULSE_SERVER'], '/audio')
        self.assertTrue(env['LD_LIBRARY_PATH'].startswith(str(backend.B / 'gamedata/libs') + ':'))
        for key in ('VK_INSTANCE_LAYERS', 'VK_LAYER_PATH', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET',
                    'RUDROID_WAYLAND_FORCE_RENDERER', 'RUDROID_VULKAN_WSI_LIBRARY', 'SLL_GODOT_WSI', 'DISABLE_WSI_LAYER'):
            self.assertNotIn(key, env)

    def test_gles_child_exit_is_returned(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(backend.run_forwarded([sys.executable, '-c', 'raise SystemExit(7)'], tmp, {}), 7)

    def test_gles_view_resolves_external_extensions_and_uses_private_mapping(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); game = root / 'game'; view = root / 'view'
            view.mkdir(); extension = game / 'addons/spine/linux/libspine.so'
            extension.parent.mkdir(parents=True); extension.write_bytes(b'library')
            with patch.object(backend, 'B', game):
                backend.prepare_gles_view(view)
            self.assertEqual((view / 'addons/spine/linux/libspine.so').read_bytes(), b'library')
            self.assertEqual((view / 'input_remap.cfg').read_text(),
                             '[buttons]\na = BUTTON_A\nb = BUTTON_B\nx = BUTTON_X\ny = BUTTON_Y\n')
            self.assertFalse((game / 'input_remap.cfg').exists())


if __name__ == '__main__':
    unittest.main()
