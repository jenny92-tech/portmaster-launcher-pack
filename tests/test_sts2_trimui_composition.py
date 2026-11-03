# INPUT: STS2 TrimUI Weston composition selection and inherited environment.
# OUTPUT: validated private compositor policy for each supported setting.
# POS: protects the device-specific graphics setting without launching a game.
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    'sts2_trimui_backend', ROOT / 'ports/sts2/src/tools/device_tools/sts2_trimui_backend.py')
backend = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(backend)


class CompositionTests(unittest.TestCase):

    def test_default_and_on_force_composition(self):
        for mode in (None, 'on'):
            with self.subTest(mode=mode):
                env = {'RUDROID_WAYLAND_FORCE_RENDERER': '0'}
                if mode is not None:
                    env['SLL_WESTON_COMPOSITION'] = mode
                backend.apply_weston_composition(env)
                self.assertEqual(env['RUDROID_WAYLAND_FORCE_RENDERER'], '1')

    def test_off_clears_inherited_force(self):
        env = {'SLL_WESTON_COMPOSITION': 'off', 'RUDROID_WAYLAND_FORCE_RENDERER': '1'}
        backend.apply_weston_composition(env)
        self.assertNotIn('RUDROID_WAYLAND_FORCE_RENDERER', env)

    def test_invalid_rejected_without_changing_environment(self):
        for value in ('', 'auto', 'AUTO', 'false', '1'):
            with self.subTest(value=value):
                env = {'SLL_WESTON_COMPOSITION': value, 'RUDROID_WAYLAND_FORCE_RENDERER': '1'}
                original = dict(env)
                with self.assertRaises(ValueError):
                    backend.apply_weston_composition(env)
                self.assertEqual(env, original)


if __name__ == '__main__':
    unittest.main()
