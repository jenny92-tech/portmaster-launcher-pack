#!/usr/bin/env python3
# INPUT:  Unity 启动模板、真实主机 PortKit 工具与隔离游戏/PortMaster 夹具
# OUTPUT: 五标题配置写入、路径保留、原生退出所有权和 loader 交接前失败断言
# POS:    验证游戏专用设置与共享 Rudroid 参数一起应用，不启动真实游戏
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import tomllib
import unittest
import json
import socket
import os

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'target/debug/portkit-launcher'
PREFIXES = {'hk': 'HKL', 'heishenhua': 'HSH', 'silksong': 'SILK',
            'terraria': 'TER', 'vampiresurvivors114': 'VS'}
CONFIG = '''[ui_layout] # later tables must survive
keep = "unowned HUD key"
[[il2cpp_patch]]
class = "old launcher-owned patch"
[paths]
game_files = "./gamedata/"
internal_data_path = "./conf/"
unity_shader_cache_redirect = "./cache/shaders"
[gpu]
renderWidth = 640
renderHeight = 480
renderScaleSharp = false
textureMaxDim = 384
[runtime]
stream_buffer_bytes = 4096
[game_patches.silksong_unity6]
disable_audio_preloader = false
[package]
packageName = "fixture.keep"
'''


class UnityLauncherSettingsTests(unittest.TestCase):
    def run_template(self, port, mode='balanced', choices=None, malformed=False, probe_ok=True, features=None, unavailable=False):
        with tempfile.TemporaryDirectory(prefix='unity launcher ') as temp:
            base = Path(temp).resolve()
            game = base / 'ports' / ('hollowknight' if port == 'hk' else port)
            game.mkdir(parents=True)
            conf = game / 'conf'
            conf.mkdir()
            for name in ('config.toml', 'config.low.toml', 'config.original.toml'):
                (game / name).write_text(CONFIG + ('\n[package]\nduplicate=true\n' if malformed else ''))
            loader = game / 'unityloader'
            (game/'rudroid.runtime').mkdir()
            loader.write_text('#!/bin/sh\nif [ "$2" = --graphics-features ]; then\n echo sdl2,gles,gles-scale,gles-sharp,gles-shader,gles-texture,vulkan,vulkan-scale,vulkan-linear\n exit 0\nfi\nexit 99\n')
            loader.write_text(loader.read_text().replace('exit 99', 'if [ "$2" = --probe-vulkan ]; then\n '+('echo RUDROID_VULKAN=1; exit 0' if probe_ok else 'exit 1')+'\nfi\nexit 99'))
            if features is not None:
                loader.write_text(loader.read_text().replace('sdl2,gles,gles-scale,gles-sharp,gles-shader,gles-texture,vulkan,vulkan-scale,vulkan-linear',features))
            loader.chmod(0o755)
            wsi = game / 'vulkan-wsi'
            wsi.mkdir()
            for name in ('libVkLayer_window_system_integration.so', 'VkLayer_window_system_integration.json'):
                (wsi / name).write_text('fixture')
            for relative in ('gamedata/lib/arm64-v8a/libil2cpp.so',
                             'gamedata/assets/bin/Data/Managed/Metadata/global-metadata.dat',
                             'gamedata/assets/bin/Data/data.unity3d'):
                path = game / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()
            prefs = conf / 'shared_prefs/com.TeamCherry.HollowKnight.v2.playerprefs.json'
            prefs.parent.mkdir()
            prefs.write_text('{"strings":{"Language":"keep"},"floats":{"MasterVolume":0.6}}')
            (conf / 'config.json').write_text('{"Language":1,"Volume":0.4}')
            decoy = base / 'unrelated cwd'
            decoy.mkdir()
            (decoy / 'config.toml').write_text("sentinel='untouched'\n")
            values = dict(WIDTH='auto', HEIGHT='auto', RENDER_PERCENT='config', MEMORY_MODE=mode,
                          SWAP_AB='on', SWAP_XY='on', TEXMAX='480' if port == 'heishenhua' else '512',
                          DMG='0.2', INF_MP='on', INF_STA='on', INF_WINE='on', SKILL_CD='on',
                          QUALITY='low', FPS='45', ASSETBUNDLE_UNLOAD='off', LANGUAGE='12')
            values['GRAPHICS_API']='gles'
            values.update(choices or {})
            launch_env = base / 'saved settings.env'
            launch_env.write_text(''.join(f'{PREFIXES[port]}_{key}={shlex.quote(value)}\n'
                                          for key, value in values.items()))
            prefix = f'''
source {shlex.quote(str(ROOT / '_kit/portmaster_common.sh'))}
source {shlex.quote(str(ROOT / '_kit/launcher_unity_common.sh'))}
portmaster_init() {{
  directory={shlex.quote(str(base).lstrip('/'))}
  controlfolder={shlex.quote(str(base / 'fake PortMaster'))}
  DISPLAY_WIDTH=960; DISPLAY_HEIGHT=720; CFW_NAME=Fixture
  sdl_controllerconfig=fixture
}}
portmaster_sync_launcher_artwork() {{ :; }}
launcher_platform_acquire_display() {{ :; }}
launcher_platform_release_display() {{ :; }}
pm_finish() {{ :; }}
run_love_launcher_ui() {{ LAUNCH_ENV={shlex.quote(str(launch_env))}; }}
portkit_launcher() {{ {shlex.quote(str(HELPER))} "$@"; }}
run_unity_game() {{ printf '%s\\n' "$1" > "$GAMEDIR/loader-handoff"; }}
'''
            body = (ROOT / 'ports' / port / 'love/launcher.sh.template').read_text()
            body = re.sub(r'^#@KIT-BEGIN\n.*?^#@KIT-END\n', '', body, flags=re.M | re.S)
            body = re.sub(r'^SHADER_CACHE_DIR=.*$',
                          'SHADER_CACHE_DIR=' + shlex.quote(str(base / 'shader cache')),
                          body, flags=re.M)
            script = base / 'launcher.sh'
            script.write_text(prefix + body)
            wayland=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
            wayland.bind(str(base/'fixture-wayland'))
            try:
                result = subprocess.run(['bash', str(script)], cwd=decoy, capture_output=True,
                                        text=True, timeout=10,env=dict(os.environ,XDG_RUNTIME_DIR=str(base),WAYLAND_DISPLAY='fixture-wayland'))
            finally:wayland.close()
            log = (game / ('log_silk.txt' if port == 'silksong' else 'log.txt')).read_text()
            self.assertEqual((decoy / 'config.toml').read_text(), "sentinel='untouched'\n")
            if unavailable:
                self.assertNotEqual(result.returncode,0,result.stderr+log)
                self.assertFalse((game/'loader-handoff').exists(),log)
                self.assertIn('selected Vulkan backend is disabled',log)
                for name in ('config.toml','config.low.toml','config.original.toml'):
                    self.assertEqual((game/name).read_text(),CONFIG)
                return
            if malformed:
                self.assertNotEqual(result.returncode, 0, log)
                self.assertFalse((game / 'loader-handoff').exists(), log)
                return
            self.assertEqual(result.returncode, 0, result.stderr + log)
            selected = Path((game / 'loader-handoff').read_text().strip())
            expected = game / ('config.original.toml' if port == 'silksong' and values['QUALITY'] == 'original'
                               else 'config.low.toml' if port == 'silksong' else 'config.toml')
            self.assertEqual(selected, expected)
            doc = tomllib.loads(selected.read_text())
            self.assertEqual(doc['paths'], tomllib.loads(CONFIG)['paths'])
            self.assertEqual(doc['package']['packageName'], 'fixture.keep')
            self.assertEqual(doc['runtime'], dict(stream_buffer_bytes=4096, memory_mode=mode))
            self.assertEqual((doc['device']['displayWidth'], doc['device']['displayHeight']), (960, 720))
            if values.get('RENDER_PERCENT') in ('100','75','50'):
                self.assertEqual((doc['gpu']['renderWidth'], doc['gpu']['renderHeight']), (0, 0))
            else:
                self.assertEqual((doc['gpu']['renderWidth'], doc['gpu']['renderHeight']), (640, 480))
            expected_api='vulkan' if values['GRAPHICS_API']=='vulkan' and probe_ok and (features is None or 'vulkan-linear' in features.split(',')) and port in ('silksong','vampiresurvivors114') else 'gles'
            self.assertEqual(doc['gpu']['graphicsApi'], expected_api)
            if port in ('silksong', 'vampiresurvivors114'):
                flag = '-force-vulkan' if expected_api=='vulkan' else '-force-gles32' if port=='silksong' else '-force-gles30'
                self.assertEqual(doc['package']['mainIntentBundle']['unity'], flag)
            self.assertEqual(doc['gpu']['renderScaleSharp'],False)
            self.assertEqual(doc['input']['remap'], dict(a='BUTTON_B', b='BUTTON_A', x='BUTTON_Y', y='BUTTON_X'))
            if port == 'heishenhua':
                self.assertEqual(doc['ui_layout']['keep'], 'unowned HUD key')
                self.assertEqual(doc['gpu']['textureDownsampleFilter'], 'nearest')
                self.assertEqual(len(doc['il2cpp_patch']), 0 if values['DMG'] == '1.0' else 5)
            elif port == 'silksong':
                patch = doc['game_patches']['silksong_unity6']
                self.assertFalse(patch['disable_audio_preloader'])
                self.assertFalse(patch['unload_assetbundles_after_title'])
                for effect in ('disable_ambient_particles','disable_bloom','disable_camera_blur_plane','disable_light_blur'):
                    self.assertEqual(patch[effect],values['QUALITY']!='original')
                self.assertFalse(patch['disable_uber_postprocess'])
                self.assertEqual(doc['unity']['target_fps'], int(values['FPS']))
                self.assertNotIn('frame_sync_interval_us', doc['unity'])
                self.assertEqual((game / 'config.toml').read_text(), CONFIG)
            elif port == 'hk':
                value = json.loads(prefs.read_text())
                self.assertEqual(value['strings']['Language'], 'keep')
                self.assertEqual(value['floats']['MasterVolume'], 0.6)
                width=doc['gpu']['renderWidth'] or 960*doc['gpu'].get('renderScalePercent',100)//100
                height=doc['gpu']['renderHeight'] or 720*doc['gpu'].get('renderScalePercent',100)//100
                self.assertEqual(value['ints']['Screenmanager Resolution Width'],width)
                self.assertEqual(value['ints']['Screenmanager Resolution Height'],height)
            elif port == 'terraria':
                self.assertEqual(json.loads((conf / 'config.json').read_text()), dict(Language=12, Volume=0.4))
            elif port == 'vampiresurvivors114':
                self.assertEqual(doc['gpu']['glVersionOverride'], 'OpenGL ES 3.0 Rudroid')
                self.assertFalse(doc['gpu']['shaderGles2Rewrite'])
                self.assertEqual(doc['gpu']['textureMaxDim'], 0)

    def test_native_player_owns_exit_without_a_legacy_input_killer(self):
        for status in (0, 42):
            with self.subTest(status=status), tempfile.TemporaryDirectory(prefix='native-exit-') as temp:
                base = Path(temp).resolve()
                (base / 'rudroid.runtime').mkdir()
                loader = base / 'unityloader'
                loader.write_text(f'#!/bin/sh\nsleep 0.2\nexit {status}\n')
                loader.chmod(0o755)
                killer = base / 'legacy-input-killer'
                called = base / 'killer-called'
                finished = base / 'platform-finished'
                killer.write_text('#!/bin/sh\ntouch ' + shlex.quote(str(called)) + '\n')
                killer.chmod(0o755)
                script = f'''
source {shlex.quote(str(ROOT / '_kit/launcher_unity_common.sh'))}
GAMEDIR={shlex.quote(str(base))}
CONFDIR="$GAMEDIR/conf"
UNITY_RUNTIME_DIR="$GAMEDIR"
GPTOKEYB={shlex.quote(str(killer))}
UNITY_GAME_GPTK_CONFIG="$GAMEDIR/stale-map.gptk"
touch "$UNITY_GAME_GPTK_CONFIG"
audio_setup() {{ :; }}
memory_tuning() {{ :; }}
install_exit_trap() {{ :; }}
launcher_platform_prepare_game() {{ :; }}
launcher_platform_finish() {{ touch {shlex.quote(str(finished))}; }}
run_unity_game "$GAMEDIR/config.toml"
'''
                result = subprocess.run(['bash', '-c', script], capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertFalse(called.exists(), 'a second input process must not kill the native player')
                self.assertTrue(finished.exists(), 'platform cleanup must preserve the native exit status')

    def test_unavailable_vulkan_stops_before_config_and_guest_handoff(self):
        for port in ('silksong','vampiresurvivors114'):
            self.run_template(port,choices={'GRAPHICS_API':'vulkan','RENDER_PERCENT':'75','RENDER_FILTER':'sharp'},probe_ok=False,unavailable=True)

    def test_partial_vulkan_features_reject_unavailable_headless_selection(self):
        for port in ('silksong','vampiresurvivors114'):
            self.run_template(port,choices={'GRAPHICS_API':'vulkan','RENDER_PERCENT':'75'},
                              features='sdl2,gles,gles-scale,gles-sharp,vulkan',unavailable=True)

    def test_title_gate_rejects_vulkan_even_when_the_environment_supports_it(self):
        for port in ('hk','heishenhua','terraria'):
            self.run_template(port,choices={'GRAPHICS_API':'vulkan','RENDER_PERCENT':'75'},unavailable=True)

    def test_five_titles_apply_each_memory_mode_without_overwriting_paths_or_exact_rendering(self):
        for port in PREFIXES:
            for mode in ('low_memory', 'balanced', 'performance'):
                with self.subTest(port=port, mode=mode):
                    self.run_template(port, mode)

    def test_silksong_original_mode_targets_only_its_selected_config(self):
        self.run_template('silksong', choices=dict(QUALITY='original', FPS='90',AMBIENT_PARTICLES='off',BLOOM='off',CAMERA_BLUR_PLANE='off',LIGHT_BLUR='off',UBER_POSTPROCESS='off',ASSETBUNDLE_UNLOAD='on'))

    def test_vulkan_titles_share_render_scales_without_changing_memory_mode(self):
        for port in ('silksong', 'vampiresurvivors114'):
            for percent in ('100','75','50','config'):
                with self.subTest(port=port,percent=percent):
                    self.run_template(port, mode='low_memory', choices=dict(GRAPHICS_API='vulkan', RENDER_PERCENT=percent))

    def test_heishenhua_can_remove_all_launcher_owned_hooks_without_truncating_paths(self):
        self.run_template('heishenhua', choices=dict(DMG='1.0', INF_MP='off', INF_STA='off',
                                                     INF_WINE='off', SKILL_CD='off'))

    def test_malformed_configs_stop_before_loader_handoff_for_every_title(self):
        for port in PREFIXES:
            with self.subTest(port=port):
                self.run_template(port, malformed=True)


if __name__ == '__main__':
    unittest.main()
