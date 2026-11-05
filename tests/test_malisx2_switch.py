#!/usr/bin/env python3
# INPUT: Synthetic Linux/Android ICD records, child environments and native-probe substitutes.
# OUTPUT: Independent driver selection, fail-closed packaging checks and menu capabilities.
# POS: Host-only graphics-switch regressions; never loads the fixture ELF or starts a game.
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import unittest
try:
    from lupa import LuaRuntime
except ImportError:
    LuaRuntime = None

ROOT = Path(__file__).resolve().parents[1]
REVISION = 'd0422ed5eb5d8971f118f14d2550ce04aa1a0a5a'


class Malisx2SwitchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='graphics switch ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.runtime = self.root / "runtime 'quoted'"
        self.driver = self.runtime / 'vulkan-malisx2'
        self.driver.mkdir(parents=True)
        (self.runtime / 'rudroid.runtime').mkdir()
        wsi = self.runtime / 'vulkan-wsi'
        wsi.mkdir()
        for name in ('VkLayer_window_system_integration.json', 'libVkLayer_window_system_integration.so'):
            (wsi / name).write_text('fixture; never loaded')
        data = bytearray(1024)
        data[:6] = b'\x7fELF\x02\x01'
        struct.pack_into('<HH', data, 16, 3, 183)
        struct.pack_into('<Q', data, 32, 64)
        struct.pack_into('<HHH', data, 52, 64, 56, 2)
        struct.pack_into('<IIQQQQQQ', data, 64, 1, 5, 0, 0x10000, 0, len(data), len(data), 4096)
        struct.pack_into('<IIQQQQQQ', data, 120, 2, 4, 768, 0x10300, 0, 64, 64, 8)
        names = b'\0libc.so.6\0liblog.so\0'
        data[512:512+len(names)] = names
        for i,pair in enumerate(((5,0x10200),(10,len(names)),(1,1),(0,0))):
            struct.pack_into('<QQ',data,768+i*16,*pair)
        self.linux_library=bytes(data)
        self.write_library(self.linux_library)
        (self.driver / 'mali_icd.json').write_text(json.dumps({'file_format_version': '1.0.0',
            'ICD': {'library_path': './libvulkan_malisx2.so', 'api_version': '1.1.0'}}))
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        timeout = self.bin / 'timeout'
        timeout.write_text('#!/bin/sh\nshift 3\nexec "$@"\n')
        timeout.chmod(0o755)
        loader = self.runtime / 'unityloader'
        loader.write_text('''#!/bin/sh
if [ "$2" = --graphics-features ]; then
  echo vulkan-linear,sdl2,gles,vulkan-scale,vulkan,gles-scale
elif [ "$2" = --probe-vulkan ]; then
  if [ -n "${VK_DRIVER_FILES:-}" ]; then [ "${MALIS_OK:-0}" = 1 ] || exit 1
  else [ "${SYSTEM_OK:-0}" = 1 ] || exit 1; fi
  echo RUDROID_VULKAN=1
else exit 99; fi
''')
        loader.chmod(0o755)

    def write_library(self, data):
        (self.driver / 'libvulkan_malisx2.so').write_bytes(data)
        (self.driver / 'sources.json').write_text(json.dumps({'platform': 'linux-aarch64',
            'profile': 'Release', 'source_revision': REVISION,
            'library_sha256': hashlib.sha256(data).hexdigest()}))

    def shell(self, body, *args, **values):
        setup = '''set -eu
source "$1/_kit/launcher_platform.sh"
source "$1/_kit/launcher_compat.sh"
source "$1/_kit/launcher_unity_common.sh"
shift
PORT_NAME=silksong; CFW_NAME=Loong; BOARD=rockchip,rk3566-rk817-tablet
LOG_PREFIX=fixture; GAMEDIR="$1"; UNITY_RUNTIME_DIR="$1"
launcher_platform_matches_compatible() { [ "$1" = "$BOARD" ]; }
launcher_platform_exec() { exec "$@"; }
'''
        env = {k: v for k, v in os.environ.items() if k!='LAUNCHER_MALISX2_DIR'
               and not k.startswith(('PORTKIT_', 'UNITY_', 'VK_', 'RUDROID_'))}
        env.update(PATH=str(self.bin) + os.pathsep + env['PATH'], **values)
        return subprocess.run(['bash', '-c', setup + body, 'test', str(ROOT), str(self.runtime), *args],
                              env=env, capture_output=True, text=True, timeout=15)

    def test_candidate_selection_is_child_local_and_reselection_clears_overrides(self):
        result = self.shell('''
export VK_DRIVER_FILES=parent VK_ICD_FILENAMES=parent VK_ADD_DRIVER_FILES=parent
launcher_compat_plan unity-rudroid malisx2 "$1"
( launcher_compat_exec /bin/sh -c 'printf "%s|%s|%s|%s\\n" "$VK_DRIVER_FILES" "$VK_ICD_FILENAMES" "${VK_ADD_DRIVER_FILES-unset}" "$RUDROID_WSI_HEADLESS_SURFACE"' )
printf '%s\\n' "$VK_DRIVER_FILES"
for backend in vulkan gles; do
  launcher_compat_plan unity-rudroid "$backend" "$1"
  ( launcher_compat_exec /bin/sh -c 'printf "%s|%s\\n" "${VK_DRIVER_FILES-unset}" "${RUDROID_WSI_HEADLESS_SURFACE-unset}"' )
done
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = str(self.driver / 'mali_icd.json')
        self.assertEqual(result.stdout.splitlines(), [f'{manifest}|{manifest}|unset|1', 'parent',
                                                    'unset|unset', 'unset|unset'])

    def test_android_artifact_and_changed_library_are_refused(self):
        android=bytearray(self.linux_library)
        struct.pack_into('<QQ',android,800,1,11)
        for data in (b'Android',bytes(android),self.linux_library[:900]):
            self.write_library(data)
            result = self.shell('launcher_compat_plan unity-rudroid malisx2 "$1"')
            self.assertNotEqual(result.returncode, 0)
        self.write_library(self.linux_library)
        (self.driver / 'libvulkan_malisx2.so').write_bytes(b'changed')
        self.assertNotEqual(self.shell('launcher_compat_plan unity-rudroid malisx2 "$1"').returncode, 0)

    def test_invalid_manifest_and_profile_cannot_leave_a_valid_plan(self):
        (self.driver / 'mali_icd.json').write_text('{"ICD":{"library_path":"/system/driver.so"}}')
        result = self.shell('''launcher_compat_plan unity-rudroid vulkan "$1"
if launcher_compat_plan unity-rudroid malisx2 "$1"; then exit 99; fi
[ "$LAUNCHER_COMPAT_READY" = 0 ]
''')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_non_release_wrong_source_and_symlink_artifacts_are_refused(self):
        receipt=self.driver/'sources.json'
        original=json.loads(receipt.read_text())
        for key,value in (('profile','Debug'),('source_revision','0'*40),('platform','android-aarch64')):
            receipt.write_text(json.dumps(dict(original,**{key:value})))
            self.assertNotEqual(self.shell('launcher_compat_plan unity-rudroid malisx2 "$1"').returncode,0)
        receipt.write_text(json.dumps(original))
        library=self.driver/'libvulkan_malisx2.so'
        library.unlink();outside=self.root/'outside.so';outside.write_bytes(self.linux_library)
        library.symlink_to(outside)
        self.assertNotEqual(self.shell('launcher_compat_plan unity-rudroid malisx2 "$1"').returncode,0)

    def test_system_and_candidate_probes_are_independent(self):
        with socket.socket(socket.AF_UNIX) as display:
            display.bind(str(self.root / 'wayland-test'))
            for shared in (False,True):
                shared_env={}
                if shared:
                    common=self.root/'shared driver';self.driver.rename(common)
                    shared_env['LAUNCHER_MALISX2_DIR']=str(common)
                for system, candidate in ((0, 1), (1, 0), (1, 1), (0, 0)):
                    result = self.shell('''prepare_unity_graphics_options 1
printf 'CAPS=%s|%s\\n' "$PORTKIT_VULKAN_AVAILABLE" "$PORTKIT_MALISX2_AVAILABLE"
''', SYSTEM_OK=str(system), MALIS_OK=str(candidate),
                        XDG_RUNTIME_DIR=str(self.root), WAYLAND_DISPLAY='wayland-test',**shared_env)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(f'CAPS={system}|{candidate}', result.stdout)

    def test_unknown_device_is_rejected_before_candidate_plan(self):
        result = self.shell('BOARD=rockchip,rk3566\nlauncher_compat_plan unity-rudroid malisx2 "$1"')
        self.assertNotEqual(result.returncode, 0)

    def test_one_explicit_driver_package_can_be_shared_outside_the_runtime(self):
        shared=self.root/'shared driver package'
        self.driver.rename(shared)
        result=self.shell('''launcher_compat_plan unity-rudroid malisx2 "$1"
printf '%s' "$LAUNCHER_COMPAT_ICD_FILE"
''', LAUNCHER_MALISX2_DIR=str(shared))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout,str(shared/'mali_icd.json'))
        self.assertFalse(self.driver.exists())
        for path in ('relative',str(shared)+':other',str(shared)+'\nother'):
            self.assertNotEqual(self.shell('launcher_compat_plan unity-rudroid malisx2 "$1"',
                                          LAUNCHER_MALISX2_DIR=path).returncode,0)

    def test_saved_candidate_resolves_to_vulkan_with_its_own_driver(self):
        result = self.shell('''UNITY_GRAPHICS_PROBED_RUNTIME="$1"
PORTKIT_GRAPHICS_FEATURES=sdl2,gles,vulkan,vulkan-linear
PORTKIT_VULKAN_AVAILABLE=0; PORTKIT_MALISX2_AVAILABLE=1; PORTKIT_VULKAN_PLATFORM_SUPPORTED=1
resolve_unity_graphics_api malisx2 gles32 1
prepare_unity_vulkan_plan
printf 'SELECT=%s|%s|%s\\n' "$UNITY_GRAPHICS_API" "$UNITY_VULKAN_BACKEND" "$LAUNCHER_COMPAT_ICD_FILE"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'SELECT=vulkan|malisx2|{self.driver}/mali_icd.json', result.stdout)

    @unittest.skipIf(LuaRuntime is None, 'lupa is required for the actual Lua resolver')
    def test_three_menu_choices_keep_independent_capabilities_and_render_scaling(self):
        for system,candidate in ((False,False),(True,False),(False,True),(True,True)):
            lua=LuaRuntime(unpack_returned_tuples=True)
            lua.globals().KIT=str(ROOT/'_kit/love')
            lua.globals().SYSTEM=system;lua.globals().CANDIDATE=candidate
            lua.execute('''
package.path=KIT..'/?.lua;'..package.path
package.loaded.kit={}
os.getenv=function(key)
  if key=='PORTKIT_GRAPHICS_FEATURES' then return 'sdl2,gles,gles-scale,vulkan,vulkan-scale,vulkan-linear' end
  if key=='PORTKIT_VULKAN_AVAILABLE' or key=='PORTKIT_VULKAN_PLATFORM_SUPPORTED' then return SYSTEM and '1' or '0' end
  if key=='PORTKIT_MALISX2_AVAILABLE' then return CANDIDATE and '1' or '0' end
end
local field=require('launcher').graphics_api{env='TEST_GRAPHICS_API',vulkan=true}
assert(field.default=='gles' and #field.options==3)
assert(field.options[1][1]=='gles' and field.options[2][1]=='vulkan' and field.options[3][1]=='malisx2')
assert(field.options[2][2].zh=='系统 Vulkan')
assert(field.disabled_values.vulkan==not SYSTEM and field.disabled_values.malisx2==not CANDIDATE)
local model=field.graphics
assert(model.supports('vulkan')==SYSTEM and model.supports('malisx2')==CANDIDATE)
for _,api in ipairs{'gles','vulkan','malisx2'} do
  local value=model.resolve{graphics_api=api,render_scale='75'}
  assert(value.api==api and value.render_scale=='75')
  assert(model.validate{graphics_api=api}==model.supports(api))
end
local only_gles=require('launcher').graphics_api{env='TEST_GRAPHICS_API',vulkan=false}
assert(#only_gles.options==1 and not only_gles.graphics.supports('malisx2'))
''')


if __name__ == '__main__':
    unittest.main()
