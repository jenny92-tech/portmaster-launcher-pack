from pathlib import Path
import hashlib,importlib.util,json,os,re,selectors,signal,socket,subprocess,sys,tempfile,unittest
from unittest.mock import patch
from types import SimpleNamespace

spec=importlib.util.spec_from_file_location('soulknight_launch',Path(__file__).parents[1]/'src/launch.py')
launch=importlib.util.module_from_spec(spec);spec.loader.exec_module(launch)

class InstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve()/'installation';self.root.mkdir()
        files=['runtime/soulknight-ns','libexec/launch.py','shaders/shader_index.bin','fonts/NotoSansCJKsc-Regular.otf',
               'runtime/vulkan-wsi/libVkLayer_window_system_integration.so','RomFS/Data/globalgamemanagers']
        files += ['native/'+n+'.'+s for n in ('main','subsdk0','sdk') for s in ('patched.bin','fixups.tsv','gates.tsv')]
        hashes={}
        for name in files:
            p=self.root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(name.encode())
            hashes[name]=hashlib.sha256(p.read_bytes()).hexdigest()
        self.manifest={'title_id':launch.TITLE,'game_build':launch.BUILD,
            'runtime_identity':{'profile':'Release','kind':'linux-native-vulkan','title_id':launch.TITLE,'game_build':launch.BUILD},
            'files':hashes,'profile':str(self.root.parent/'existing-player-profile')}
        self.write_manifest()
    def write_manifest(self):
        (self.root/'installation.json').write_text(json.dumps(self.manifest))
    def test_check_preserves_player_state_and_creates_nothing(self):
        before=sorted(p.relative_to(self.root).as_posix() for p in self.root.rglob('*'))
        root,profile=launch.preflight(self.root)
        self.assertEqual(root,self.root);self.assertFalse(profile.exists())
        self.assertEqual(before,sorted(p.relative_to(self.root).as_posix() for p in self.root.rglob('*')))
    def test_profile_must_be_explicit_absolute_and_stable(self):
        for value in (None,'relative-profile','~/profile','/userdata/../profile'):
            self.manifest['profile']=value;self.write_manifest()
            with self.subTest(value=value),self.assertRaises(ValueError):launch.preflight(self.root)
    def test_changed_native_module_is_rejected_before_launch(self):
        (self.root/'native/main.patched.bin').write_bytes(b'wrong-game')
        with self.assertRaisesRegex(ValueError,'Changed installation input'):launch.preflight(self.root)

    def test_missing_storage_mount_does_not_create_a_rootfs_profile(self):
        with patch.dict(os.environ,{'XDG_DATA_HOME':str(self.root.parent/'persistent')}):
            # No /mnt/UDISK on the host: a writable /mnt is not the volume.
            if Path('/mnt/UDISK').exists() or Path('/userdata').exists():self.skipTest('host has device storage anchors')
            profile=launch.existing_profile('/mnt/UDISK/soulknight_ns/profile')
        self.assertEqual(profile,self.root.parent/'persistent/soulknight_ns/profile')
        self.assertFalse(profile.exists())

    def test_low_memory_native_route_checks_storage_before_profile_creation(self):
        profile=self.root.parent/'low-memory-profile'
        with patch.dict(os.environ,{'DISPLAY':':1'}), \
             patch.object(launch,'low_memory_mode',return_value=True), \
             patch.object(launch.shutil,'disk_usage',return_value=SimpleNamespace(free=100)):
            with self.assertRaisesRegex(ValueError,'768 MiB'):
                launch.launch(self.root,profile,presentation='native',video_driver='x11')
        self.assertFalse(profile.exists())

    def test_probe_uses_the_same_sanitized_system_libraries_as_the_game(self):
        for name in ('bin/graphics-probe','libexec/graphics-probe.sh'):
            path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('fixture')
            self.manifest['files'][name]=launch.digest(path)
        self.write_manifest()
        with patch.dict(os.environ,{'LD_LIBRARY_PATH':'/unrelated/SDL','LD_PRELOAD':'/unrelated/hook','SDL_VIDEODRIVER':'wayland'},clear=True), \
             patch.object(launch.os,'execve')as execute:
            launch.graphics_probe(self.root)
        command,arguments,env=execute.call_args.args
        self.assertEqual(command,'/bin/bash')
        self.assertEqual(arguments[-1],str(self.root/'bin/graphics-probe'))
        self.assertNotIn('LD_LIBRARY_PATH',env);self.assertNotIn('LD_PRELOAD',env)
        self.assertEqual(env['SDL_VIDEODRIVER'],'wayland')
        self.assertFalse((self.root.parent/'existing-player-profile').exists())

    def test_probe_accepts_a_storage_alias_for_its_own_verified_wsi(self):
        for name in ('bin/graphics-probe','libexec/graphics-probe.sh','runtime/vulkan-wsi/VkLayer_window_system_integration.json'):
            path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('fixture')
            self.manifest['files'][name]=launch.digest(path)
        self.write_manifest()
        alias=self.root.parent/'firmware-card-alias';alias.symlink_to(self.root,target_is_directory=True)
        library='runtime/vulkan-wsi/libVkLayer_window_system_integration.so'
        with patch.dict(os.environ,{'RUDROID_VULKAN_WSI_LIBRARY':str(alias/library)},clear=True),patch.object(launch.os,'execve')as execute:
            launch.graphics_probe(alias.resolve(strict=True))
        env=execute.call_args.args[2]
        self.assertEqual(env['RUDROID_VULKAN_WSI_LIBRARY'],str(self.root/library))
        self.assertEqual(env['VK_LAYER_PATH'],str(self.root/'runtime/vulkan-wsi'))
        outside=self.root.parent/'other-wsi.so';outside.write_text('other library')
        with patch.dict(os.environ,{'RUDROID_VULKAN_WSI_LIBRARY':str(outside)},clear=True),patch.object(launch.os,'execve')as execute:
            with self.assertRaisesRegex(ValueError,'Unexpected probe WSI'):launch.graphics_probe(self.root)
            execute.assert_not_called()

    def test_diagnostic_runtime_identity_is_rejected(self):
        self.manifest['runtime_identity']['profile']='Debug';self.write_manifest()
        with self.assertRaisesRegex(ValueError,'Wrong Release'):launch.preflight(self.root)
    def test_traversal_and_linked_payload_are_rejected(self):
        self.manifest['files']['../outside']='0'*64;self.write_manifest()
        with self.assertRaises(ValueError):launch.preflight(self.root)
        del self.manifest['files']['../outside'];self.write_manifest()
        original=self.root/'native/main.patched.bin';target=self.root/'native/copied.bin';original.rename(target);original.symlink_to(target)
        with self.assertRaisesRegex(ValueError,'Linked installation input'):launch.preflight(self.root)

    def test_private_profile_symlink_is_rejected_before_session_creation(self):
        real=self.root.parent/'real-profile';real.mkdir()
        link=self.root.parent/'linked-profile';link.symlink_to(real,target_is_directory=True)
        self.manifest['profile']=str(link);self.write_manifest()
        with self.assertRaisesRegex(ValueError,'Linked profile'):launch.preflight(self.root)
        self.assertEqual(list(real.iterdir()),[])

    def test_absolute_wayland_socket_does_not_replace_audio_runtime(self):
        with tempfile.TemporaryDirectory(prefix='rudroid-wayland-',dir='/tmp') as temporary:
            owned=Path(temporary);(owned/'xdg').mkdir();endpoint=owned/'xdg/rudroid-vulkan'
            clients=self.root/'runtime/portable-wayland';clients.mkdir();(clients/'manifest.json').write_text('{}')
            expected=[str(clients),str(owned/'weston/lib_aarch64'),str(owned/'weston/lib_aarch64/extra_wayland')]
            env={'WAYLAND_DISPLAY':str(endpoint),'XDG_RUNTIME_DIR':'/audio',
                 'PORTKIT_WAYLAND_SESSION_ROOT':str(owned),
                 'PULSE_SERVER':'unix:/audio/pulse/native','LD_LIBRARY_PATH':':'.join(expected+['/unrelated/libs'])}
            original=env.copy()
            with socket.socket(socket.AF_UNIX) as connection:
                connection.bind(str(endpoint))
                with patch.object(launch.os.path,'ismount',return_value=True):
                    self.assertEqual(launch.portable_library_path(self.root,env),':'.join(expected))
                with patch.object(launch.os.path,'ismount',return_value=False):
                    with self.assertRaisesRegex(ValueError,'Incomplete shared'):launch.portable_library_path(self.root,env)
            self.assertEqual(env,original)

    def test_private_session_accepts_the_helpers_root_outside_tmp(self):
        helper_spec=importlib.util.spec_from_file_location('shared_wayland',Path(__file__).parents[3]/'_kit/wayland_session.py')
        helper=importlib.util.module_from_spec(helper_spec);helper_spec.loader.exec_module(helper)
        temporary=tempfile.TemporaryDirectory(prefix='pr-',dir='/tmp');self.addCleanup(temporary.cleanup)
        owned=Path(temporary.name)/'custom/rudroid-wayland-fixture';(owned/'xdg').mkdir(parents=True)
        endpoint=owned/'xdg/rudroid-vulkan'
        clients=self.root/'runtime/portable-wayland';clients.mkdir();(clients/'manifest.json').write_text('{}')
        for name in ('bin/graphics-probe','libexec/graphics-probe.sh','runtime/vulkan-wsi/VkLayer_window_system_integration.json'):
            path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('fixture')
            self.manifest['files'][name]=launch.digest(path)
        self.write_manifest()
        env=helper.client_environment(self.root/'runtime',owned/'weston',endpoint,{'XDG_RUNTIME_DIR':'/audio','LD_LIBRARY_PATH':'/unrelated'})
        expected=':'.join(map(str,[clients,owned/'weston/lib_aarch64',owned/'weston/lib_aarch64/extra_wayland']))
        with socket.socket(socket.AF_UNIX)as connection:
            connection.bind(str(endpoint))
            with patch.object(launch.os.path,'ismount',return_value=True):
                self.assertEqual(launch.portable_library_path(self.root,env),expected)
                with patch.dict(os.environ,env,clear=True),patch.object(launch.os,'execve')as execute:
                    launch.graphics_probe(self.root)
                child=execute.call_args.args[2]
                self.assertEqual(child['LD_LIBRARY_PATH'],expected)
                self.assertEqual(child['XDG_RUNTIME_DIR'],'/audio')
                with patch.dict(env,{'PORTKIT_WAYLAND_SESSION_ROOT':str(owned.parent/'another-session')}):
                    with self.assertRaisesRegex(ValueError,'Not a shared Pack'):launch.portable_library_path(self.root,env)
        self.assertEqual(env['XDG_RUNTIME_DIR'],'/audio')

    def test_unapproved_private_libraries_refuse_before_profile_writes(self):
        profile=self.root.parent/'existing-player-profile'
        with tempfile.TemporaryDirectory(prefix='rudroid-wayland-',dir='/tmp') as temporary:
            owned=Path(temporary);(owned/'xdg').mkdir();endpoint=owned/'xdg/rudroid-vulkan'
            with socket.socket(socket.AF_UNIX) as connection:
                connection.bind(str(endpoint))
                with patch.dict(os.environ,{'WAYLAND_DISPLAY':str(endpoint),'LD_LIBRARY_PATH':'/unrelated/libs','PORTKIT_WAYLAND_SESSION_ROOT':str(owned)}):
                    with self.assertRaisesRegex(ValueError,'Incomplete shared'):
                        launch.launch(self.root,profile,portable_session=True)
            self.assertFalse(profile.exists())

    def test_display_check_never_enters_the_native_game_or_creates_saves(self):
        profile=self.root.parent/'existing-player-profile'
        with tempfile.TemporaryDirectory(prefix='ns-display-') as temporary:
            endpoint=Path(temporary)/'display'
            with socket.socket(socket.AF_UNIX) as connection:
                connection.bind(str(endpoint))
                with patch.dict(os.environ,{'WAYLAND_DISPLAY':str(endpoint)}), \
                     patch.object(sys,'argv',['launch.py',str(self.root),'--display-check']), \
                     patch.object(launch.time,'sleep'), \
                     patch.object(launch,'launch',side_effect=AssertionError('No game during display check')):
                    self.assertEqual(launch.main(),0)
        self.assertFalse(profile.exists())

    def test_private_bootstrap_cannot_replace_an_existing_compositor(self):
        with tempfile.TemporaryDirectory(prefix='ns-existing-') as temporary:
            endpoint=Path(temporary)/'display'
            with socket.socket(socket.AF_UNIX) as connection:
                connection.bind(str(endpoint))
                with patch.dict(os.environ,{'WAYLAND_DISPLAY':str(endpoint)}):
                    with self.assertRaisesRegex(ValueError,'existing compositor'):
                        launch.portable_command(self.root,self.root.parent/'profile',Path('/missing/image'),'16:9')

    def test_private_bootstrap_refuses_low_storage_before_creating_profile(self):
        profile=self.root.parent/'not-created-profile'
        with patch.dict(os.environ,{'WAYLAND_DISPLAY':''}), \
             patch.object(launch.shutil,'disk_usage',return_value=SimpleNamespace(free=768*1024*1024-1)), \
             patch.object(launch,'low_memory_mode',return_value=True):
            with self.assertRaisesRegex(ValueError,'768 MiB'):
                launch.portable_command(self.root,profile,Path('/missing/image'),'16:9')
        self.assertFalse(profile.exists())

    def test_cancel_deadline_survives_native_stdout_eof(self):
        read_fd,write_fd=os.pipe();os.close(write_fd)
        class Child:
            def __init__(self):self.stdout=os.fdopen(read_fd,'rb');self.returncode=None;self.terminated=False;self.killed=False
            def poll(self):return self.returncode
            def terminate(self):self.terminated=True  # Deliberately ignored by the native child.
            def kill(self):self.killed=True;self.returncode=-signal.SIGKILL
            def wait(self,timeout=None):
                if self.returncode is None:raise AssertionError('Unbounded wait after EOF')
                return self.returncode
        child=Child();handlers={};native=selectors.DefaultSelector()
        class Selector:
            def register(self,*a):return native.register(*a)
            def unregister(self,*a):return native.unregister(*a)
            def get_map(self):return native.get_map()
            def close(self):native.close()
            def select(self,timeout):
                if not native.get_map() and not child.terminated:handlers[signal.SIGTERM](signal.SIGTERM,None)
                return native.select(0)
        try:
            with tempfile.TemporaryDirectory(prefix='ns-eof-') as temporary:
                endpoint=Path(temporary)/'display'
                with socket.socket(socket.AF_UNIX) as connection:
                    connection.bind(str(endpoint))
                    with patch.dict(os.environ,{'WAYLAND_DISPLAY':str(endpoint),'SOULKNIGHT_DIAGNOSTICS':'0'}), \
                         patch.object(launch.subprocess,'Popen',return_value=child), \
                         patch.object(launch.selectors,'DefaultSelector',return_value=Selector()), \
                         patch.object(launch.signal,'signal',side_effect=lambda sig,fn:handlers.update({sig:fn})), \
                         patch.object(launch.time,'monotonic',side_effect=[0,21]):
                        self.assertEqual(launch.launch(self.root,self.root.parent/'eof-profile'),137)
            self.assertTrue(child.terminated);self.assertTrue(child.killed)
        finally:
            native.close();child.stdout.close()

class PlatformRoutingTests(unittest.TestCase):
    def run_entry(self,mode,arguments=('--backend','vulkan')):
        source=(Path(__file__).parents[1]/'src/launcher.sh').read_text();source=re.sub(r'#@KIT-BEGIN.*?#@KIT-END','',source,flags=re.S)
        setup=r'''portmaster_init() { printf 'prepare\n' >> "$TRACE"; controlfolder=/pack; }
launcher_compat_probe() {
 printf 'probe\n' >> "$TRACE"; [ "$CASE" != unavailable ] || return 1
 LAUNCHER_COMPAT_PRESENTATION=wsi; LAUNCHER_COMPAT_SDL_DRIVER=wayland
 LAUNCHER_COMPAT_DISPLAY_WIDTH=960; LAUNCHER_COMPAT_DISPLAY_HEIGHT=720
 case "$CASE" in portable|lease-failed) LAUNCHER_COMPAT_PRESENTATION=portable; LAUNCHER_COMPAT_DISPLAY_WIDTH=1280; LAUNCHER_COMPAT_WAYLAND_IMAGE=/pack/weston.squashfs;; esac
}
launcher_compat_describe() { :; }
launcher_compat_exec() { exec "$@"; }
launcher_platform_finish() { printf 'finish\n' >> "$TRACE"; if [ "$CASE" = sdk-exit ]; then exit 0; fi; }
launcher_platform_acquire_display() { printf 'acquire\n' >> "$TRACE"; [ "$CASE" != lease-failed ]; }
audio_setup() { printf 'audio\n' >> "$TRACE"; }
memory_tuning() { printf 'memory\n' >> "$TRACE"; }
'''
        with tempfile.TemporaryDirectory()as temporary:
            root=Path(temporary);entry=root/'entry.sh';trace=root/'trace';entry.write_text(setup+source)
            helper=root/'helper';helper.write_text('#!/bin/sh\nprintf "native:%s\\n" "$*" >> "$TRACE"\ncase "$*" in *--print-profile*) printf /stable/profile;; *) [ "$CASE" != sdk-exit ] || exit 37;; esac\n');helper.chmod(0o755)
            result=subprocess.run(['bash',str(entry),*arguments],capture_output=True,text=True,env={**os.environ,'TRACE':str(trace),'CASE':mode,'PORTKIT_LAUNCHER_BIN_OVERRIDE':str(helper)})
            return result,trace.read_text().splitlines()
    def test_existing_display_keeps_ordinary_sdk_owner(self):
        result,lines=self.run_entry('existing');self.assertEqual(result.returncode,0,result.stderr);self.assertNotIn('acquire',lines);self.assertEqual(lines[-1],'finish')
    def test_private_route_prepares_audio_before_display_lease(self):
        result,lines=self.run_entry('portable');self.assertEqual(result.returncode,0,result.stderr);self.assertLess(lines.index('audio'),lines.index('acquire'));self.assertIn('wayland --runtime',lines[-2]);self.assertEqual(lines[-1],'finish')
    def test_failed_probe_finishes_sdk_without_taking_display(self):
        result,lines=self.run_entry('unavailable');self.assertNotEqual(result.returncode,0);self.assertNotIn('acquire',lines);self.assertEqual(lines[-1],'finish')
    def test_failed_display_lease_never_starts_the_native_game(self):
        result,lines=self.run_entry('lease-failed');self.assertNotEqual(result.returncode,0);self.assertEqual(lines[-1],'finish');self.assertFalse(any('wayland --runtime' in line for line in lines))
    def test_read_only_check_skips_sdk(self):
        result,lines=self.run_entry('existing',['--check']);self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(len(lines),1);self.assertTrue(lines[0].endswith('--check'))
    def test_explicit_auto_is_resolved_before_native_handoff(self):
        result,lines=self.run_entry('existing',['--backend','vulkan','--aspect','auto','--render-scale','75'])
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(lines[-2].endswith('--aspect 4:3 --backend vulkan --render-scale 75'),lines)
    def test_firmware_finish_exit_preserves_the_native_failure_status(self):
        result,lines=self.run_entry('sdk-exit');self.assertEqual(result.returncode,37,result.stderr);self.assertEqual(lines[-1],'finish')

if __name__=='__main__':unittest.main()
