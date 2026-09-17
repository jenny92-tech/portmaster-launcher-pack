# INPUT:  unittest、bash、临时 socket 与共享 launcher Shell 模块
# OUTPUT: 官方 PortMaster 引导、显示/尺寸回退、前端恢复与全部模板入口断言
# POS:    无真实设备副作用地验证统一平台启动边界
import pathlib
import socket
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
PLATFORM = ROOT / '_kit/launcher_platform.sh'


class PlatformTests(unittest.TestCase):
    def test_path_assignments_are_standalone_for_miniloong_fixer(self):
        source = (ROOT / '_kit/portmaster_bootstrap.sh').read_text()
        discovery = source.split('portmaster_discover() {', 1)[1].split('\n}', 1)[0]
        assignments = [line.strip() for line in discovery.splitlines()
                       if 'controlfolder=' in line]
        self.assertEqual(len(assignments), 4)
        for line in assignments:
            self.assertTrue(line.startswith('controlfolder='), line)

    def test_official_discovery_order(self):
        body = r'''
source "$1"
available="$2"
XDG_DATA_HOME=/fixture/data
[() {
  if builtin [ "$1" = -d ]; then
    case "$2" in
      /opt/system/Tools/PortMaster/) builtin [ "${available#a}" != "$available" ];;
      /opt/tools/PortMaster/) builtin [ "${available#*b}" != "$available" ];;
      /fixture/data/PortMaster/) builtin [ "${available#*c}" != "$available" ];;
      *) return 0;;
    esac
    return
  fi
  builtin [ "$@"
}
portmaster_discover /fixture/scripts
printf '%s' "$controlfolder"
'''
        for available, expected in (
            ('abc', '/opt/system/Tools/PortMaster'),
            ('bc', '/opt/tools/PortMaster'),
            ('c', '/fixture/data/PortMaster'),
            ('', '/roms/ports/PortMaster'),
        ):
            with self.subTest(available=available):
                self.assertEqual(self.shell(body, ROOT / '_kit/portmaster_bootstrap.sh',
                                            available), expected)

    def shell(self, body, *args):
        return subprocess.check_output(
            ['bash', '-c', 'source "$1"\nshift\n' + body,
             'platform-test', str(PLATFORM), *map(str, args)], text=True).strip()

    def test_live_socket_repairs_stale_runtime(self):
        self.assertEqual(self.shell(r'''
XDG_RUNTIME_DIR=/stale
WAYLAND_DISPLAY=wayland-0
SDL_VIDEODRIVER=kmsdrm
LIBGL_FB=4
[() {
  if builtin [ "$1" = -S ]; then
    builtin [ "$2" = /run/wayland-0 ]; return
  fi
  builtin [ "$@"
}
launcher_platform_display
printf '%s|%s|%s|%s' "$XDG_RUNTIME_DIR" "$WAYLAND_DISPLAY" "$SDL_VIDEODRIVER" "${LIBGL_FB:-}"
'''), '/run|wayland-0|wayland|')

    def test_absolute_socket(self):
        with tempfile.TemporaryDirectory(prefix='pk-') as tmp:
            endpoint = pathlib.Path(tmp) / 'wayland-test'
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(str(endpoint))
                self.assertEqual(self.shell(r'''
WAYLAND_DISPLAY="$1"
launcher_platform_display
printf '%s|%s' "$WAYLAND_DISPLAY" "$SDL_VIDEODRIVER"
''', endpoint), str(endpoint) + '|wayland')

    def test_dead_wayland_and_native_backend(self):
        body = r'''
[() { if builtin [ "$1" = -S ]; then return 1; fi; builtin [ "$@"; }
SDL_VIDEODRIVER="$1"
WAYLAND_DISPLAY=/definitely-missing-wayland
launcher_platform_display || true
printf '%s|%s' "${SDL_VIDEODRIVER:-auto}" "${WAYLAND_DISPLAY:-none}"
'''
        self.assertEqual(self.shell(body, 'wayland'), 'auto|none')
        self.assertEqual(self.shell(body, 'mali'), 'mali|none')
        self.assertEqual(self.shell(body, 'kmsdrm'), 'kmsdrm|none')

    def test_resolution_respects_firmware_and_known_rotation(self):
        body = r'''
DISPLAY_WIDTH="$1"; DISPLAY_HEIGHT="$2"; CFW_NAME="$3"
SDL_VIDEODRIVER=wayland
cat() { printf '720,960'; }
launcher_platform_resolution
printf '%s|%s' "$DISPLAY_WIDTH" "$DISPLAY_HEIGHT"
'''
        self.assertEqual(self.shell(body, '1920', '1080', 'Loong'), '1920|1080')
        self.assertEqual(self.shell(body, '', '', 'Loong'), '960|720')
        self.assertEqual(self.shell(body, '', '', 'Other'), '720|960')
        self.assertEqual(self.shell(r'''
unset DISPLAY_WIDTH DISPLAY_HEIGHT
cat() { printf 'bad'; }
launcher_platform_resolution 1280 720
printf '%s|%s' "$DISPLAY_WIDTH" "$DISPLAY_HEIGHT"
'''), '1280|720')

    def test_stock_control_api_is_sufficient(self):
        with tempfile.TemporaryDirectory(prefix='pk-') as tmp:
            control = pathlib.Path(tmp)
            (control / 'control.txt').write_text(
                'CFW_NAME=Stock\nDISPLAY_WIDTH=960\nDISPLAY_HEIGHT=720\n'
                'get_controls() { sdl_controllerconfig=stock-map; }\n'
                'pm_platform_helper() { :; }\npm_finish() { :; }\nfalse\n')
            result = self.shell(r'''
source "$1"
fixture="$2"
portmaster_discover() { controlfolder="$fixture"; }
launcher_platform_display() { return 1; }
portmaster_init /unused
printf '%s|%s|%s' "$CFW_NAME" "$sdl_controllerconfig" "$DISPLAY_WIDTH"
''', ROOT / '_kit/portmaster_bootstrap.sh', control)
            self.assertEqual(result, 'Stock|stock-map|960')

    def test_ui_backend_is_not_inherited_by_game(self):
        with tempfile.TemporaryDirectory(prefix='pk-') as tmp:
            fixture = pathlib.Path(tmp)
            (fixture / 'main.lua').write_text('-- fixture\n')
            runtime = fixture / 'runtime.txt'
            runtime.write_text('LOVE_GPTK=fake\nLOVE_RUN=fake_love\nGPTOKEYB=true\n')
            result = self.shell(r'''
source "$1"
GAMEDIR="$2"; controlfolder="$2"; runtime="$3"
PORT_NAME=test; LOG_PREFIX=test
SDL_VIDEODRIVER=kmsdrm
LIBGL_FB=parent
XDG_RUNTIME_DIR=/unused
portkit_launcher() { printf '%s\n' "$runtime"; }
_love_provide_font() { :; }
launcher_platform_display() { return 1; }
pm_platform_helper() { :; }
fake_love() { printf 'ui=%s\n' "${SDL_VIDEODRIVER:-auto}"; return 42; }
run_love_launcher_ui "$GAMEDIR"
printf 'game=%s|%s|%s\n' "$SDL_VIDEODRIVER" "$LIBGL_FB" "$launcher_exit"
''', ROOT / '_kit/portmaster_common.sh', fixture, runtime)
            self.assertIn('ui=auto', result)
            self.assertIn('game=kmsdrm|parent|42', result)

    def test_legacy_exec_identity_is_centralized(self):
        body = r'''
CFW_NAME="$1"
exec() { printf '%s|' "$@"; }
launcher_platform_exec ./godot.mono --main-pack 'a game.pck'
'''
        self.assertEqual(self.shell(body, 'Loong'),
                         '-a|unityloader|./godot.mono|--main-pack|a game.pck|')
        self.assertEqual(self.shell(body, 'Stock'),
                         './godot.mono|--main-pack|a game.pck|')

    def test_frontend_cleanup_only_resumes_owned_runner(self):
        result = self.shell(r'''
launcher_platform_display() { return 1; }
pidof() { case "$1" in MainUI) echo 101;; runtrimui.sh) echo 202;; esac; }
kill() { printf '%s %s\n' "$1" "$2"; }
sleep() { :; }
launcher_platform_acquire_display
launcher_platform_release_display
launcher_platform_release_display
''')
        self.assertEqual(result.splitlines(), ['-STOP 202', '-KILL 101', '-CONT 202'])

    def test_compositor_never_stops_frontend(self):
        self.assertEqual(self.shell(r'''
launcher_platform_display() { return 0; }
pidof() { echo unexpected; }
kill() { echo unexpected; }
launcher_platform_acquire_display
launcher_platform_release_display
'''), '')

    def test_all_ordinary_launchers_use_shared_platform(self):
        templates = sorted((ROOT / 'ports').glob('*/love/launcher.sh.template'))
        templates.append(ROOT / 'ports/batomon/src/launcher.sh')
        self.assertEqual(len(templates), 9)
        for template in templates:
            with self.subTest(template=template):
                content = template.read_text()
                self.assertIn('source "$KIT/launcher_platform.sh"', content)
                self.assertIn('portmaster_init "', content)
                code = '\n'.join(line for line in content.splitlines()
                                 if not line.lstrip().startswith('#'))
                for obsolete in ('"Loong"', '/run/wayland-0', 'restore_unity_handheld_input',
                                 'exec -a unityloader', 'killall -KILL MainUI'):
                    self.assertNotIn(obsolete, code)


if __name__ == '__main__':
    unittest.main()
