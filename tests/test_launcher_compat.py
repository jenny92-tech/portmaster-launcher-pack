#!/usr/bin/env python3
# INPUT:  共享兼容模块、临时 SDL/WSI 文件、Unix socket、命令替身与端口模板
# OUTPUT: 规则准入、计划失效、私有环境隔离、参数/PID/退出码和八端口内联断言
# POS:    在主机临时目录验证自动补丁组合，不连接设备或启动游戏
from pathlib import Path
import json
import socket
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LauncherCompatTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='compat-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runtime = self.root / "runtime with 'quotes'"
        self.runtime.mkdir()
        self.wsi = self.runtime / 'vulkan-wsi'
        self.wsi.mkdir()
        for name in ['libVkLayer_window_system_integration.so', 'VkLayer_window_system_integration.json']:
            (self.wsi / name).write_text('isolated fixture; never loaded')
        self.consumer = self.root / 'consumer.py'
        self.consumer.write_text('''import json,os,sys
print(json.dumps({'pid':os.getpid(),'args':sys.argv[1:],'env':{k:os.getenv(k) for k in
['SDL_VIDEODRIVER','SDL_AUDIODRIVER','XDG_RUNTIME_DIR','WAYLAND_DISPLAY','LD_LIBRARY_PATH',
'VK_LAYER_PATH','DISABLE_WSI_LAYER','RUDROID_VULKAN_WSI_LIBRARY','LIBGL_FB']}}))
sys.exit(37 if '--exit37' in sys.argv else 0)
''')

    def shell(self, body, *args):
        setup = '''set -eu
source "$1/_kit/launcher_platform.sh"
source "$1/_kit/launcher_compat.sh"
shift
PORT_NAME=silksong; CFW_NAME=TrimUI; BOARD=allwinner,a523
launcher_platform_matches_compatible() { [ "$1" = "$BOARD" ]; }
unset SDL_VIDEODRIVER SDL_AUDIODRIVER WAYLAND_DISPLAY VK_LAYER_PATH RUDROID_VULKAN_WSI_LIBRARY DISABLE_WSI_LAYER
'''
        return subprocess.run(['bash', '-c', setup + body, 'compat-test', str(ROOT),
                               *map(str, args)], capture_output=True, text=True, timeout=10)

    def success(self, body, *args):
        r = self.shell(body, *args)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return r.stdout.strip()

    def test_exact_title_firmware_board_rules(self):
        for title in ['silksong', 'vampiresurvivors114', 'sts2']:
            for firmware, board in [('TrimUI', 'allwinner,a523'), ('Loong', 'rockchip,rk3566-rk817-tablet'),
                                    ('TrimUI', 'allwinner,a523-extra'), ('Loong', 'rockchip,rk3566'),
                                    ('unknown', 'allwinner,a523')]:
                with self.subTest(title=title, firmware=firmware, board=board):
                    r = self.shell('PORT_NAME="$1"; CFW_NAME="$2"; BOARD="$3"\nlauncher_compat_accepts unity-rudroid vulkan',
                                   title, firmware, board)
                    accepted = title != 'sts2' and (firmware, board) in [
                        ('TrimUI', 'allwinner,a523'), ('Loong', 'rockchip,rk3566-rk817-tablet')]
                    self.assertEqual(r.returncode, 0 if accepted else 1, r.stderr)

    def test_private_wsi_only_changes_child_and_keeps_literal_arguments(self):
        marker = self.root / 'unwanted'
        value = 'literal $(touch "' + str(marker) + '") ; "quote"'
        out = self.success('''
export VK_LAYER_PATH=/existing DISABLE_WSI_LAYER=parent
launcher_compat_plan unity-rudroid vulkan "$1"
( launcher_compat_exec "$2" "$3" "$4" )
printf '%s|%s' "$VK_LAYER_PATH" "$DISABLE_WSI_LAYER"
''', self.runtime, sys.executable, self.consumer, value).splitlines()
        child = json.loads(out[0])
        self.assertEqual(child['args'], [value])
        self.assertEqual(child['env']['VK_LAYER_PATH'], str(self.wsi) + ':/existing')
        self.assertEqual(child['env']['RUDROID_VULKAN_WSI_LIBRARY'], str(self.wsi / 'libVkLayer_window_system_integration.so'))
        self.assertEqual(child['env']['DISABLE_WSI_LAYER'], '1')
        self.assertEqual(out[1], '/existing|parent')
        self.assertFalse(marker.exists())

    def test_exec_preserves_background_pid_and_exit_code(self):
        output = self.success('''
launcher_compat_plan unity-rudroid gles "$1"
launcher_compat_exec "$2" "$3" --exit37 > "$4" & child=$!
if wait "$child"; then code=0; else code=$?; fi
printf '%s %s\n' "$child" "$code"
cat "$4"
''', self.runtime, sys.executable, self.consumer, self.root / 'child.json').splitlines()
        pid, code = map(int, output[0].split())
        self.assertEqual(code, 37)
        self.assertEqual(json.loads(output[1])['pid'], pid)

    def test_failed_selection_invalidates_previous_valid_plan(self):
        output = self.success('''
launcher_compat_plan unity-rudroid vulkan "$1"
if launcher_compat_plan godot-sdl2 vulkan "$1"; then exit 99; fi
if (launcher_compat_exec touch "$2"); then exit 98; fi
printf '%s' "$LAUNCHER_COMPAT_READY"
''', self.runtime, self.root / 'must-not-execute')
        self.assertEqual(output, '0')
        self.assertFalse((self.root / 'must-not-execute').exists())

    def test_missing_wsi_blocks_the_plan(self):
        (self.wsi / 'VkLayer_window_system_integration.json').unlink()
        r = self.shell('launcher_compat_plan unity-rudroid vulkan "$1"', self.runtime)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('missing private WSI', r.stderr)

    def test_gles_reselection_clears_private_wsi(self):
        result = json.loads(self.success('''
launcher_compat_plan unity-rudroid vulkan "$1"
launcher_compat_plan unity-rudroid gles "$1"
( launcher_compat_exec "$2" "$3" )
''', self.runtime, sys.executable, self.consumer))
        self.assertIsNone(result['env']['RUDROID_VULKAN_WSI_LIBRARY'])
        self.assertIsNone(result['env']['DISABLE_WSI_LAYER'])

    def test_wayland_selection_repairs_only_child_environment(self):
        endpoint = self.root / 'wayland-fixture'
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(str(endpoint))
            out = self.success('''
XDG_RUNTIME_DIR=/stale; WAYLAND_DISPLAY="$1"; LIBGL_FB=parent
launcher_compat_plan godot-sdl2 gles "$2"
( launcher_compat_exec "$3" "$4" )
printf '%s|%s' "$XDG_RUNTIME_DIR" "$LIBGL_FB"
''', endpoint, self.runtime, sys.executable, self.consumer).splitlines()
        child = json.loads(out[0])['env']
        self.assertEqual(child['SDL_VIDEODRIVER'], 'wayland')
        self.assertEqual(child['XDG_RUNTIME_DIR'], str(self.root))
        self.assertEqual(child['WAYLAND_DISPLAY'], endpoint.name)
        self.assertIsNone(child['LIBGL_FB'])
        self.assertEqual(out[1], '/stale|parent')

    def test_bundled_sdl_is_used_only_in_the_game_child(self):
        bundle = self.root / 'private SDL'
        bundle.mkdir()
        (bundle / 'libSDL2-2.0.so.0').write_bytes(b'fixture\0KMSDRM\0')
        out = self.success('''
launcher_compat_wayland_socket() { return 1; }
launcher_compat_system_sdl() { return 1; }
export LD_LIBRARY_PATH=/parent
launcher_compat_plan godot-sdl2 gles "$1" "$2"
( launcher_compat_exec "$3" "$4" )
printf '%s' "$LD_LIBRARY_PATH"
''', self.runtime, bundle, sys.executable, self.consumer).splitlines()
        child = json.loads(out[0])['env']
        self.assertEqual(child['SDL_VIDEODRIVER'], 'kmsdrm')
        self.assertEqual(child['SDL_AUDIODRIVER'], 'alsa')
        self.assertEqual(child['LD_LIBRARY_PATH'], str(bundle) + ':/parent')
        self.assertEqual(out[1], '/parent')

    def test_missing_gl_driver_does_not_launch_dummy(self):
        r = self.shell('''
launcher_compat_wayland_socket() { return 1; }
launcher_compat_system_sdl() { return 1; }
launcher_compat_plan godot-sdl2 gles "$1"
''', self.runtime)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('no selected GL video driver', r.stderr)

    def test_graphics_plan_preserves_later_audio_routing(self):
        result = json.loads(self.success('''
launcher_compat_wayland_socket() { return 1; }
SDL_VIDEODRIVER=mali
launcher_compat_plan godot-sdl2 gles "$1"
export SDL_AUDIODRIVER=pulseaudio
( launcher_compat_exec "$2" "$3" )
''', self.runtime, sys.executable, self.consumer))
        self.assertEqual(result['env']['SDL_AUDIODRIVER'], 'pulseaudio')

    def test_existing_firmware_sdl_driver_is_preserved(self):
        out = self.success('''
launcher_compat_wayland_socket() { return 1; }
SDL_VIDEODRIVER=mali
launcher_compat_plan godot-sdl2 gles "$1"
printf '%s|%s' "$LAUNCHER_COMPAT_PROFILE" "$LAUNCHER_COMPAT_SDL_DRIVER"
''', self.runtime)
        self.assertEqual(out, 'godot-sdl2-firmware|mali')

    def test_library_search_keeps_literal_path_characters(self):
        folder = self.root / 'SDL [private] with spaces'
        folder.mkdir()
        library = folder / 'libSDL2-2.0.so.0'
        library.write_text('fixture mali')
        result = self.success('LD_LIBRARY_PATH="$1"\nlauncher_compat_system_sdl', folder)
        self.assertEqual(result, str(library))

    def test_driver_hint_does_not_match_unrelated_binary_substrings(self):
        library = self.root / 'unrelated.so'
        library.write_bytes(b'normalization\0not-kmsdrm\0')
        for driver in ['mali', 'kmsdrm']:
            r = self.shell('launcher_compat_sdl_has_driver "$1" "$2"', library, driver)
            self.assertNotEqual(r.returncode, 0)
        library.write_bytes(b'normalization\0KMSDRM\0')
        self.assertEqual(self.shell('launcher_compat_sdl_has_driver "$1" kmsdrm', library).returncode, 0)

    def test_relative_or_library_separator_paths_are_rejected(self):
        for runtime, bundle in [('relative', ''), (str(self.runtime), 'relative'),
                                (str(self.runtime) + ':extra', ''), (str(self.runtime) + '\nextra', '')]:
            with self.subTest(runtime=runtime, bundle=bundle):
                r = self.shell('launcher_compat_plan unity-rudroid gles "$1" "$2"', runtime, bundle)
                self.assertNotEqual(r.returncode, 0)

    def test_all_eight_consumers_inline_the_common_module(self):
        for port in ['hk', 'heishenhua', 'silksong', 'terraria', 'vampiresurvivors114', 'sunkendragon', 'sts2', 'batomon']:
            with self.subTest(port=port):
                template = ROOT / 'ports' / port / ('src/launcher.sh' if port == 'batomon' else 'love/launcher.sh.template')
                output = self.root / (port + '.sh')
                r = subprocess.run(['bash', str(ROOT / '_kit/assemble.sh'), str(template), str(output)],
                                   capture_output=True, text=True, timeout=20)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                s = output.read_text()
                self.assertEqual(s.count('launcher_compat_plan() {'), 1)
                self.assertNotIn('source "$KIT/', s)


if __name__ == '__main__':
    unittest.main()
