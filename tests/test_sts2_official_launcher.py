# INPUT:  STS2 runtime helpers, launcher templates and isolated fixtures
# OUTPUT: Graphics gates, display handoff and bounded-log regression results
# POS:    Host-only runtime contracts without historical device publishers
import importlib.util
import json
import pathlib
import os
from unittest import mock
import subprocess
import sys
import tempfile
import unittest

ROOT=pathlib.Path(__file__).resolve().parents[1]/'ports/sts2/src/tools/device_tools'
spec=importlib.util.spec_from_file_location('sts2_trimui_backend',ROOT/'sts2_trimui_backend.py')
backend=importlib.util.module_from_spec(spec);spec.loader.exec_module(backend)

class UnifiedLauncherTests(unittest.TestCase):
 def test_invalid_backend_rejected_without_reading_release_files(self):
  with mock.patch.object(sys,'argv',['backend','invalid']),mock.patch.object(backend,'check',side_effect=AssertionError('release files read')):
   with self.assertRaisesRegex(ValueError,'invalid graphics selection'):backend.main()
 def test_per_device_capabilities_and_unavailable_choice(self):
  source=(ROOT.parents[2]/'love/launcher.sh.template').read_text()
  unified=source.split('if [ "${SLL_UNIFIED_V110:-1}" = 1 ]; then',1)[1]
  self.assertIn('export SLL_VULKAN_AVAILABLE=1 SLL_GLES_AVAILABLE=0 SLL_GRAPHICS_PREFERRED=vulkan',unified)
  self.assertIn('export SLL_VULKAN_AVAILABLE SLL_GLES_AVAILABLE SLL_GRAPHICS_PREFERRED=gles',unified)
  start=unified.index('  case "${SLL_GRAPHICS_API:-}:$SLL_VULKAN_AVAILABLE:$SLL_GLES_AVAILABLE" in')
  end=unified.index('\n  esac',start)+len('\n  esac')
  case=unified[start:end]
  for api,vk,gles,allowed in (('gles','0','1',True),('gles','1','0',False),('vulkan','1','0',True),('vulkan','0','1',False)):
   script='launcher_platform_finish() { :; }\nSLL_GRAPHICS_API="$1"; SLL_VULKAN_AVAILABLE="$2"; SLL_GLES_AVAILABLE="$3"\n'+case+'\n'
   result=subprocess.run(['bash','-c',script,'test',api,vk,gles],capture_output=True)
   self.assertEqual(result.returncode==0,allowed,(api,vk,gles))
  self.assertNotIn('launcher_compat_plan godot-sdl2',source)
 def test_hardware_gate_rejects_other_devices(self):
  profile_spec=importlib.util.spec_from_file_location('profile',ROOT/'sts2_official_profile.py')
  profile=importlib.util.module_from_spec(profile_spec);profile_spec.loader.exec_module(profile)
  for device,p in profile.PROFILES.items():
   profile.check_identity(device,p['model'],p['compatible'],p['kernel'],'aarch64')
   with self.assertRaises(ValueError):profile.check_identity(device,p['model'],b'other',p['kernel'],'aarch64')
   with self.assertRaises(ValueError):profile.check_identity(device,p['model'],p['compatible'],'other','aarch64')
 def test_known_frontend_can_handoff_but_unknown_holder_is_rejected(self):
  profile_spec=importlib.util.spec_from_file_location('profile',ROOT/'sts2_official_profile.py')
  profile=importlib.util.module_from_spec(profile_spec);profile_spec.loader.exec_module(profile)
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp);runner=root/'42';(runner/'fd').mkdir(parents=True)
   (runner/'exe').symlink_to('/bin/bash');(runner/'cmdline').write_bytes(b'/bin/sh\0/usr/trimui/bin/runtrimui.sh\0')
   (runner/'stat').write_text('42 (bash) '+' '.join(['S','1']+['0']*17+['101']))
   proc=root/'43';(proc/'fd').mkdir(parents=True);(proc/'exe').symlink_to('/usr/trimui/bin/MainUI')
   (proc/'cmdline').write_bytes(b'./MainUI\0');(proc/'stat').write_text('43 (MainUI) S 42 0')
   (proc/'fd/3').symlink_to('/dev/dri/card0')
   self.assertEqual(profile.frontend_state(root),'handoff-required')
   fork=root/'44';(fork/'fd').mkdir(parents=True)
   (fork/'exe').symlink_to('/bin/bash');(fork/'cmdline').write_bytes(b'/bin/sh\0/usr/trimui/bin/runtrimui.sh\0')
   (fork/'stat').write_text('44 (bash) '+' '.join(['S','42']+['0']*17+['102']))
   self.assertEqual(profile.frontend_state(root),'handoff-required')
   with self.assertRaises(ValueError):profile.frontend_state(root,leased=True)
   (proc/'exe').unlink();(proc/'exe').symlink_to('/other/game')
   with self.assertRaises(ValueError):profile.frontend_state(root)
 def test_rejected_frontend_reports_only_bounded_process_identity(self):
  profile_spec=importlib.util.spec_from_file_location('profile',ROOT/'sts2_official_profile.py')
  profile=importlib.util.module_from_spec(profile_spec);profile_spec.loader.exec_module(profile)
  with tempfile.TemporaryDirectory() as tmp:
   root=pathlib.Path(tmp)
   for pid,ppid,start in ((42,1,101),(44,1,102)):
    proc=root/str(pid);(proc/'fd').mkdir(parents=True);(proc/'exe').symlink_to('/bin/bash')
    (proc/'cmdline').write_bytes(b'/bin/sh\0/usr/trimui/bin/runtrimui.sh\0')
    (proc/'stat').write_text(str(pid)+' (bash) '+' '.join(['S',str(ppid)]+['0']*17+[str(start)]))
   with self.assertRaises(ValueError) as error:profile.frontend_state(root)
   self.assertIn('runners=2[42:1:101,44:1:102] frontends=0[-]',str(error.exception))
 def test_only_outer_runner_and_one_direct_fork_are_accepted(self):
  modules=[]
  for name in ('sts2_official_profile','sts2_trimui_lease'):
   spec=importlib.util.spec_from_file_location(name,ROOT/(name+'.py'))
   module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);modules.append(module)
  root=(42,1,101);fork=(44,42,102)
  for module in modules:
   self.assertEqual(module.root_runner([root]),root)
   self.assertEqual(module.root_runner([fork,root]),root)
   for candidates in ([],[fork],[root,(45,1,103)],[root,(45,77,103)],[root,fork,(46,42,104)]):
    self.assertIsNone(module.root_runner(candidates),candidates)
 def test_leased_namespace_does_not_require_host_runner(self):
  profile_spec=importlib.util.spec_from_file_location('profile',ROOT/'sts2_official_profile.py')
  profile=importlib.util.module_from_spec(profile_spec);profile_spec.loader.exec_module(profile)
  with tempfile.TemporaryDirectory() as tmp:self.assertEqual(profile.frontend_state(pathlib.Path(tmp),leased=True),'leased')
 def test_lease_token_is_single_use(self):
  profile_spec=importlib.util.spec_from_file_location('profile',ROOT/'sts2_official_profile.py')
  profile=importlib.util.module_from_spec(profile_spec);profile_spec.loader.exec_module(profile)
  token='a'*64;read_fd,write_fd=os.pipe()
  os.write(write_fd,token.encode());os.close(write_fd)
  fake=mock.Mock();fake.read_bytes.return_value=b'/bin/bash\0/mnt/SDCARD/Roms/PORTS/Je-\xe6\x9d\x80\xe6\x88\xae\xe5\xb0\x96\xe5\xa1\x942[\xe4\xb8\xad].sh\0'
  with mock.patch.dict(os.environ,{'SLL_TRIMUI_LEASE_FD':str(read_fd),'SLL_TRIMUI_LEASE_TOKEN':token}),mock.patch.object(os,'getppid',return_value=1),mock.patch.object(profile.pathlib,'Path',return_value=fake):
   self.assertTrue(profile.consume_lease())
   with self.assertRaises(OSError):profile.consume_lease()
 def test_private_wsi_keeps_system_icd_search(self):
  self.assertEqual(backend.xdg_data_dirs(pathlib.Path('/private/share')),
   '/private/share:/usr/local/share:/usr/share')
 def test_implicit_layer_is_single_and_private(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=pathlib.Path(tmp)/'layer.json';p.write_text(json.dumps({'layer':{'name':'VK_LAYER_RUDROID_wayland','library_path':'old'}}))
   value=backend.implicit_manifest(p,pathlib.Path('/private/layer.so'))['layer']
   self.assertEqual(value['library_path'],'/private/layer.so')
   self.assertEqual(value['enable_environment'],{'SLL_GODOT_WSI':'1'})
   self.assertEqual(value['disable_environment'],{'SLL_GODOT_WSI_DISABLE':'1'})
 def test_vulkan_override_disallows_gl_fallback(self):
  source=(ROOT/'sts2_trimui_backend.py').read_text()
  trial=(ROOT.parents[2]/'love/vulkan-trial.sh.template').read_text()
  self.assertIn('rendering_device/fallback_to_opengl3=false',source)
  self.assertIn('rendering_device/fallback_to_opengl3=false',trial)
  self.assertIn('off) export PORTKIT_PERF_OVERLAY=0',trial)
 def test_bounded_log_policy_and_limit(self):
  logger=ROOT/'sts2_bounded_log.py'
  with tempfile.TemporaryDirectory() as tmp:
   p=pathlib.Path(tmp)/'last.log'
   def run(mode,code):return subprocess.run([sys.executable,str(logger),mode,str(p),'--',sys.executable,'-c',code],capture_output=True)
   self.assertEqual(run('off','print("success")').returncode,0);self.assertFalse(p.exists())
   self.assertEqual(run('off','print("ERROR: device")').returncode,0);self.assertIn(b'ERROR: device',p.read_bytes())
   self.assertEqual(run('on','print("x"*300000)').returncode,0);self.assertLessEqual(p.stat().st_size,128*1024)
   self.assertEqual(run('off','raise SystemExit(7)').returncode,7)

if __name__=='__main__':unittest.main()
