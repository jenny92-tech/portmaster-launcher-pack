#!/usr/bin/env python3
# INPUT:  D2R NS 安装/打包模块、临时文件与 Python unittest
# OUTPUT: 校验、独立档案、重复安装和覆盖层合并的回归结果
# POS:    无设备、无真实游戏资源的 D2R NS 行为验证
import hashlib
import importlib.util
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest

PORT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


setup = module('d2r_ns_setup', PORT / 'src/setup_runtime.py')
ui_setup = module('d2r_ns_ui_setup', PORT / 'src/setup_ui_runtime.py')
package = module('d2r_ns_package', PORT / 'src/scripts/package.py')


class RuntimeTests(unittest.TestCase):
    def bundle(self, root):
        paths = ['runtime/d2r-linux-novideo', 'runtime/run-bringup.sh',
                 'runtime/wayland-wsi/libVkLayer_window_system_integration.so',
                 'runtime/wayland-wsi/VkLayer_window_system_integration.json',
                 'native/main.patched.bin', 'native/sdk.patched.bin',
                 'native/subsdk0.patched.bin', 'bin/portkit-launcher']
        files = {}
        for name in paths:
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
            files[name] = {'bytes': path.stat().st_size,
                           'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'mode': 0o755}
        (root / 'runtime-files.json').write_text(json.dumps({'files': files}))
        (root / 'config').mkdir()
        (root / 'config/default-settings.json').write_text('{"Legacy Graphics Mode": 2}')
        return files

    def test_first_install_then_preserve_existing_profile(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); bundle = root / 'bundle'; bundle.mkdir()
            self.bundle(bundle)
            runtime, profile = root / 'runtime', root / 'profile'
            installed = setup.install(bundle, runtime, profile)
            self.assertTrue((installed / 'runtime/d2r-linux-novideo').stat().st_mode & 0o111)
            self.assertEqual(sorted(p.name for p in (profile / 'save').iterdir()), ['Settings'])
            settings = profile / 'save/Settings/Settings.json'
            settings.write_text('{"player_setting": 7}')
            character = profile / 'save/Player/Player.d2s'
            character.parent.mkdir(); character.write_bytes(b'keep character')
            identity = profile / 'identity/device-id.bin'; identity.write_bytes(b'keep identity')
            before = {str(p): p.read_bytes() for p in (settings, character, identity)}
            self.assertEqual(setup.install(bundle, runtime, profile), installed)
            self.assertEqual(before, {str(p): p.read_bytes() for p in (settings, character, identity)})
            self.assertEqual(len(list(runtime.glob('kit-*'))), 1)

    def test_corrupt_runtime_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); bundle = root / 'bundle'; bundle.mkdir()
            self.bundle(bundle)
            (bundle / 'native/main.patched.bin').write_bytes(b'wrong bytes')
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                setup.install(bundle, root / 'runtime', root / 'profile')
            self.assertFalse((root / 'profile').exists())

    def test_manifest_cannot_escape_bundle(self):
        with self.assertRaisesRegex(ValueError, 'invalid'):
            files = {name: {'bytes': 0, 'sha256': '0' * 64, 'mode': 0o644}
                     for name in ['runtime/d2r-linux-novideo', 'runtime/run-bringup.sh',
                                  'runtime/wayland-wsi/libVkLayer_window_system_integration.so',
                                  'runtime/wayland-wsi/VkLayer_window_system_integration.json',
                                  'native/main.patched.bin', 'native/sdk.patched.bin',
                                  'native/subsdk0.patched.bin', 'bin/portkit-launcher',
                                  'runtime/../../outside']}
            setup.checked_files({'files': files})

    def test_flatten_uses_menu_then_world_then_base(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            layers = ['game/Update/RomFS', 'overlays/world', 'overlays/menu']
            for layer in layers:
                (root / layer / 'data').mkdir(parents=True)
                (root / layer / 'data/.build.config').write_text(layer)
            (root / layers[0] / 'data/build_manifest.psv').write_text('old index')
            (root / layers[0] / 'data/00-00000008.data').write_text('shadowed bytes')
            (root / layers[1] / 'data/build_manifest.psv').write_text('world index')
            (root / layers[1] / 'data/00-00000008.data').write_text('world bytes')
            (root / layers[2] / 'data/00-00000001.data').write_text('menu bytes')
            (root / 'profile').mkdir(); (root / 'profile/Player.d2s').write_text('private')
            effective, before = package.effective_romfs(root)
            self.assertEqual(effective['data/.build.config'].read_text(), layers[2])
            self.assertEqual(effective['data/build_manifest.psv'].read_text(), 'world index')
            self.assertEqual(effective['data/00-00000008.data'].read_text(), 'world bytes')
            self.assertEqual(len(effective), 4)
            self.assertGreater(before, sum(p.stat().st_size for p in effective.values()))

    def test_ui_runtime_is_executable_and_rejects_corruption(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            love = root / 'portmaster/love'
            (love / 'libs.aarch64').mkdir(parents=True)
            (love / 'love.aarch64').write_bytes(b'love executable')
            (love / 'libs.aarch64/liblove.so').write_bytes(b'love library')
            gptokeyb = root / 'portmaster/gptokeyb'; gptokeyb.write_bytes(b'input helper')
            installed = ui_setup.install(love, gptokeyb, root / 'userdata/ui-runtime')
            for name in ('love/love.aarch64', 'gptokeyb'):
                self.assertTrue((installed / name).stat().st_mode & 0o111)
            self.assertEqual((installed / 'love/libs.aarch64/liblove.so').read_bytes(), b'love library')
            self.assertEqual(ui_setup.install(love, gptokeyb, root / 'userdata/ui-runtime'), installed)
            (installed / 'love/libs.aarch64/liblove.so').write_bytes(b'bad library')
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                ui_setup.install(love, gptokeyb, root / 'userdata/ui-runtime')

    def test_ui_cancel_start_and_missing_handoff(self):
        for code, write_env, expected_game, expected_status in (
                (0, False, False, 0), (42, True, True, 0), (42, False, False, 1)):
            with self.subTest(code=code, write_env=write_env), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                data = root / 'd2r_ns'; data.mkdir()
                files = self.bundle(data)
                events = root / 'events'
                control = root / 'xdg/PortMaster'; runtime = control / 'runtimes/love_fixture'
                (runtime / 'libs.aarch64').mkdir(parents=True)
                (control / 'gamecontrollerdb.txt').touch()
                (control / 'control.txt').write_text(
                    'CFW_NAME=Test\ndirectory=unused\nsdl_controllerconfig=fixture\n'
                    'get_controls() { :; }\npm_platform_helper() { :; }\n'
                    'pm_finish() { echo finish >> ' + shlex.quote(str(events)) + '; }\n'
                    'GPTOKEYB=" $controlfolder/gptokeyb -1"\n')
                (control / 'gptokeyb').write_text('#!/bin/sh\nprintf "%s\\n" "$@" > ' +
                    shlex.quote(str(root / 'gpt-args')) + '\nexec sleep 30\n')
                (control / 'gptokeyb').chmod(0o644)
                (runtime / 'love.txt').write_text(
                    'export LOVE_GPTK=fixture-love\n'
                    'export LOVE_RUN=' + shlex.quote(str(root / 'ui')) + '\n'
                    'export D2R_NS_UI_PRIVATE=ui-only\n')
                (root / 'ui').write_text('#!/bin/sh\nsleep 0.1\n' +
                    ('printf "D2R_NS_LAUNCH_COUNT=1\\n" > "$1/launch_config.env"\n' if write_env else '') +
                    'exit ' + str(code) + '\n')
                (root / 'ui').chmod(0o644)
                shutil.copyfile(root / 'ui', runtime / 'love.aarch64')
                helper = data / 'bin/portkit-launcher'
                helper.write_text('#!/bin/sh\ncase "$1" in\nruntime) printf "%s\\n" ' +
                                  shlex.quote(str(runtime / 'love.txt')) + ';;\n'
                                  'font) exit 1;;\nesac\n')
                helper.chmod(0o755)
                files['bin/portkit-launcher'].update(bytes=helper.stat().st_size,
                    sha256=hashlib.sha256(helper.read_bytes()).hexdigest())
                (data / 'runtime-files.json').write_text(json.dumps({'files': files}))
                (data / 'libexec').mkdir()
                shutil.copyfile(PORT / 'src/setup_runtime.py', data / 'libexec/setup_runtime.py')
                shutil.copyfile(PORT / 'src/setup_ui_runtime.py', data / 'libexec/setup_ui_runtime.py')
                (data / 'libexec/run-game.sh').write_text('#!/bin/sh\n'
                    'test -z "${D2R_NS_UI_PRIVATE:-}" || exit 9\n'
                    'test "$3" = ' + shlex.quote(str(root / 'userdata/profile')) + ' || exit 10\n'
                    'echo game >> ' + shlex.quote(str(events)) + '\n')
                (data / 'love_ui').mkdir(); (data / 'love_ui/main.lua').touch()
                script = root / 'Je-暗黑破坏神II_NS.sh'
                repo = PORT.parents[1]
                subprocess.run(['bash', str(repo / '_kit/assemble.sh'),
                                str(PORT / 'love/launcher.sh.template'), str(script)],
                               check=True, capture_output=True, text=True)
                result = subprocess.run(['env', 'XDG_DATA_HOME=' + str(root / 'xdg'),
                    'D2R_NS_USER_DIR=' + str(root / 'userdata'), 'bash', str(script)],
                    capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, expected_status, result.stderr)
                actual = events.read_text().splitlines()
                self.assertEqual(actual.count('game'), int(expected_game))
                self.assertEqual(actual.count('finish'), 1)
                self.assertEqual((root / 'gpt-args').read_text().splitlines(),
                    ['-1', 'fixture-love', '-c', str((data / 'love_ui/ui.gptk').resolve())])


if __name__ == '__main__':
    unittest.main()
