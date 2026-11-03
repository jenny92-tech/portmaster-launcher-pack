# INPUT: synthetic STS2 packs, build outputs and local fake ADB
# OUTPUT: offline installation, planning and failure-safety checks
# POS: no real player content or device connection
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / 'ports/sts2/src/tools'
sys.path.insert(0, str(TOOLS / 'device_tools'))
spec = importlib.util.spec_from_file_location('install_handheld', TOOLS / 'device_tools/install_handheld.py')
installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)
spec = importlib.util.spec_from_file_location('fixture_pack', TOOLS / 'godot_pck/low_texture_overlay.py')
pack = importlib.util.module_from_spec(spec); spec.loader.exec_module(pack)


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


class FakeAdb:
    def __init__(self, fail=False): self.fail = fail; self.calls = []; self.target = 'fake'
    def run(self, command, data=None):
        self.calls.append(command)
        if self.fail and 'install.py' in command: raise RuntimeError('simulated transport failure')
        result = subprocess.run(['/bin/sh', '-c', command], input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode: raise RuntimeError(result.stderr.decode())
        return result.stdout.decode().strip()
    def reconnect(self, attempt): pass


class HandheldInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name).resolve(); build = base / 'build'; build.mkdir()
        parent = base / 'device'; parent.mkdir(); root = parent / 'sts2-vk-test'; root.mkdir()
        game = parent / 'sts2/data_sts2_linuxbsd_arm64'; game.mkdir(parents=True)
        source = parent / 'sts2/gamedata/pcks/SlayTheSpire2.pck'; source.parent.mkdir(parents=True)
        entry = parent / 'entry.sh'; shutil.copyfile(ROOT / 'ports/sts2/love/vulkan-trial.sh.template', entry)
        texture = build / 'texture.pck'; texture_name = '.godot/imported/test.png-0123456789abcdef0123456789abcdef.ctex'
        old = base / 'old'; old.write_bytes(b'old texture')
        new = base / 'new'; new.write_bytes(b'new texture')
        other = base / 'other'; other.write_bytes(b'other game data')
        pack.write_pack([(texture_name, old), ('project.binary', other)], source)
        pack.write_pack([(texture_name, new)], texture)
        report = {'source_sha256': sha(source), 'output_sha256': sha(texture), 'verified_spine_loader': True,
                  'resources': [{'path': texture_name, 'category': 'other_2d', 'output_md5': hashlib.md5(new.read_bytes()).hexdigest()}]}
        texture_report = build / 'texture-report.json'; texture_report.write_text(json.dumps(report))
        result = subprocess.run([sys.executable, str(installer.MERGE), '--source', str(source), '--overlay', str(texture), '--report', str(texture_report), '--output-dir', str(build/'merged')], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        merged = next((build/'merged').glob('*.pck'))
        patch = build/'patch'; patch.mkdir(); game_input = build/'game-input'; game_input.mkdir()
        for name in ('sts2.dll','sts2.deps.json'):
            (game/name).write_bytes(('original ' + name).encode()); shutil.copyfile(game/name, game_input/name)
        for name in installer.FILES: (patch/name).write_bytes(('patched ' + name).encode())
        manifest = {'files': {name:sha(patch/name) for name in installer.FILES}, 'source_files': {name:sha(game/name) for name in ('sts2.dll','sts2.deps.json')}}
        (patch/'manifest.json').write_text(json.dumps(manifest))
        patch_id=sha(patch/'manifest.json')
        (root/'patches').mkdir(); shutil.copytree(patch, root/'patches'/patch_id)
        (root/'active-patch').write_text(patch_id+'\n')
        build_report = {'texture_overlay':str(texture), 'texture_report':str(texture_report), 'texture':{k:v for k,v in report.items() if k!='resources'},
                        'input_sha256':{'source_pck':sha(source), 'game_dll':sha(game/'sts2.dll'), 'game_deps':sha(game/'sts2.deps.json')},
                        'tool_sha256':{'merge':sha(installer.MERGE)}, 'patch_manifest_sha256':patch_id, 'patch_files':manifest['files'], 'merged_sha256':merged.stem, 'merged_bytes':merged.stat().st_size}
        (build/'build-report.json').write_text(json.dumps(build_report))
        profile=base/'trusted-profile.json'
        profile.write_text(json.dumps({k+'_sha256':v for k,v in build_report['input_sha256'].items()}))
        patch_profile=mock.patch.object(installer, 'PROFILE', profile); patch_profile.start(); self.addCleanup(patch_profile.stop)
        state=base/'state'; state.mkdir(mode=0o700)
        self.args = argparse.Namespace(state_dir=str(state),target='fake',device_root=str(root),device_source_pck=str(source),device_game_dir=str(game),device_entry=str(entry),entry_sha256=sha(entry),build_dir=str(build),plan=False,allow_unverified_spine_binary=True)
        fake_proc=base/'upload-proc'; fake_proc.mkdir()
        patch_proc=mock.patch.object(installer.upload,'REMOTE',installer.upload.REMOTE.replace("proc = '/proc'",'proc = '+repr(str(fake_proc))))
        patch_proc.start(); self.addCleanup(patch_proc.stop)
        self.root=root; self.build=build; self.merged_id=merged.stem; self.patch_id=patch_id

    def test_plan_is_local_and_detects_tampering(self):
        argv = []
        for name in ('target','device_root','device_source_pck','device_game_dir','device_entry','entry_sha256','build_dir','state_dir'):
            argv += ['--'+name.replace('_','-'), getattr(self.args,name)]
        with mock.patch.object(installer.upload, 'Adb', side_effect=AssertionError('device accessed')):
            self.assertEqual(installer.main(argv+['--plan', '--allow-unverified-spine-binary']), 0)
            (self.build/'patch/sts2.dll').write_bytes(b'tampered')
            self.assertEqual(installer.main(argv+['--plan', '--allow-unverified-spine-binary']), 1)

    def test_profile_mismatch_refused_before_contact(self):
        report=json.loads((self.build/'build-report.json').read_text())
        for key in ('source_pck','game_dll','game_deps'):
            profile=json.loads(installer.PROFILE.read_text()); original=profile[key+'_sha256']
            profile[key+'_sha256']='0'*64; installer.PROFILE.write_text(json.dumps(profile))
            with self.assertRaisesRegex(ValueError, 'trusted handheld profile'):
                installer.validate(self.args)
            profile[key+'_sha256']=original; installer.PROFILE.write_text(json.dumps(profile))
        self.assertEqual(installer.validate(self.args)['patch_id'],self.patch_id)

    def test_unverified_spine_requires_opt_in_before_contact(self):
        self.args.allow_unverified_spine_binary=False
        with self.assertRaisesRegex(ValueError, 'Spine binary'):
            installer.validate(self.args)
        self.args.plan=True
        build=installer.validate(self.args)
        with self.assertRaisesRegex(ValueError, 'Spine binary'):
            installer.install(self.args,build,FakeAdb())
        self.args.allow_unverified_spine_binary=True
        self.assertEqual(installer.validate(self.args)['patch_id'],self.patch_id)

    def test_spine_excluded_requires_no_opt_in(self):
        report_path=self.build/'texture-report.json'; tr=json.loads(report_path.read_text())
        tr['verified_spine_loader']=False; report_path.write_text(json.dumps(tr))
        build_path=self.build/'build-report.json'; report=json.loads(build_path.read_text())
        report['texture']['verified_spine_loader']=False; build_path.write_text(json.dumps(report))
        self.args.allow_unverified_spine_binary=False
        self.assertEqual(installer.validate(self.args)['patch_id'],self.patch_id)

    def test_spine_exclusion_must_match_resource_category(self):
        report_path=self.build/'texture-report.json'; tr=json.loads(report_path.read_text())
        tr['verified_spine_loader']=False; tr['resources'][0]['category']='spine_page_or_neighbor'
        report_path.write_text(json.dumps(tr))
        build_path=self.build/'build-report.json'; report=json.loads(build_path.read_text())
        report['texture']['verified_spine_loader']=False; build_path.write_text(json.dumps(report))
        self.args.allow_unverified_spine_binary=False
        with self.assertRaisesRegex(ValueError, 'includes Spine'): installer.validate(self.args)

    def test_state_directory_must_be_private_and_exist(self):
        state=Path(self.args.state_dir)
        state.chmod(0o755)
        with self.assertRaisesRegex(ValueError, 'private'): installer.validate(self.args)
        state.chmod(0o700)
        self.args.state_dir=str(state/'missing')
        with self.assertRaises(OSError): installer.validate(self.args)

    def test_owned_staged_partial_resumes_after_interruption(self):
        stage=self.root/'stage'; stage.mkdir()
        source=self.build/'patch/sts2.dll'; adb=FakeAdb(); original=installer.upload.remote
        interrupted=[False]
        def remote_once(adb, directory, op, name, *args, **kwargs):
            result=original(adb,directory,op,name,*args,**kwargs)
            if op=='write' and not interrupted[0]:
                interrupted[0]=True; raise RuntimeError('connection lost after write')
            return result
        with mock.patch.object(installer.upload,'remote',side_effect=remote_once):
            with self.assertRaisesRegex(RuntimeError,'connection lost'):
                installer.send_file(adb,str(stage),'sts2.dll',source,self.args.state_dir)
        self.assertTrue(interrupted[0])
        installer.send_file(adb,str(stage),'sts2.dll',source,self.args.state_dir)
        self.assertEqual((stage/'sts2.dll').read_bytes(),source.read_bytes())

    def test_unowned_staged_partial_is_never_modified(self):
        stage=self.root/'stage'; stage.mkdir()
        source=self.build/'patch/sts2.dll'
        partial=stage/('sts2.dll.'+sha(source)+'.partial'); partial.write_bytes(b'foreign')
        with self.assertRaises(RuntimeError): installer.send_file(FakeAdb(),str(stage),'sts2.dll',source,self.args.state_dir)
        self.assertEqual(partial.read_bytes(),b'foreign')
        self.assertFalse((stage/'sts2.dll').exists())

    def test_missing_and_bad_inputs_never_connect(self):
        self.args.entry_sha256 = 'wrong'
        with self.assertRaises(ValueError): installer.validate(self.args)
        self.args.entry_sha256 = '0'*64
        self.args.build_dir = str(self.build/'missing')
        with self.assertRaises(ValueError): installer.validate(self.args)

    def test_install_and_retry_with_local_fake_transport(self):
        build=installer.validate(self.args); adb=FakeAdb()
        proc=self.root.parent/'fake-proc'; proc.mkdir()
        with mock.patch.object(installer, 'REMOTE', installer.REMOTE.replace("'/proc'", repr(str(proc))).replace("'/proc/'", repr(str(proc)+'/'))):
            installer.install(self.args,build,adb)
        self.assertFalse((self.root/'textures'/(build['report']['texture']['output_sha256']+'.pck')).exists())
        self.assertEqual((self.root/'active-texture').read_text().strip(), self.merged_id)
        self.assertEqual((self.root/'active-patch').read_text().strip(), self.patch_id)
        self.assertEqual(sha(self.root/'merged'/(self.merged_id+'.pck')),self.merged_id)
        self.assertFalse(any(self.root.glob('.install-*')))
        with mock.patch.object(installer, 'REMOTE', installer.REMOTE.replace("'/proc'", repr(str(proc))).replace("'/proc/'", repr(str(proc)+'/'))):
            installer.install(self.args,build,adb)

    def use_distinct_old_patch(self):
        old_dir=self.root/'patches'/self.patch_id
        (old_dir/'sts2_compat.dll').write_bytes(b'old compatible patch')
        manifest=json.loads((old_dir/'manifest.json').read_text())
        manifest['files']['sts2_compat.dll']=sha(old_dir/'sts2_compat.dll')
        (old_dir/'manifest.json').write_text(json.dumps(manifest))
        old_id=sha(old_dir/'manifest.json'); old_dir.rename(self.root/'patches'/old_id)
        (self.root/'active-patch').write_text(old_id+'\n')
        return old_id

    def test_interrupted_patch_temp_retries_without_publishing_short_file(self):
        build=installer.validate(self.args); old_id=self.use_distinct_old_patch()
        stage=self.root/('.install-'+build['patch_id']+'-'+build['merged_id']); stage.mkdir()
        (stage/'interrupt-once').write_text('trigger')
        marker="    try:\n        with os.fdopen(fd,'wb') as f:"
        trigger="    if os.path.exists(stage+'/interrupt-once'):\n        os.unlink(stage+'/interrupt-once'); os.write(fd,b'partial'); os.fsync(fd); os._exit(71)\n"+marker
        remote=installer.REMOTE.replace(marker,trigger)
        self.assertNotEqual(remote,installer.REMOTE)
        with mock.patch.object(installer,'REMOTE',remote):
            with self.assertRaises(RuntimeError): installer.install(self.args,build,FakeAdb())
            self.assertEqual((self.root/'active-patch').read_text().strip(),old_id)
            self.assertFalse((self.root/'patches'/self.patch_id/'manifest.json').exists())
            result=installer.install(self.args,build,FakeAdb())
        self.assertEqual((self.root/'active-patch').read_text().strip(),self.patch_id)
        self.assertEqual(sha(self.root/'patches'/self.patch_id/'manifest.json'),self.patch_id)
        self.assertIn('stage retained',result)
        self.assertEqual(len(list((stage/'patch-tmp').glob('*.incoming'))),1)

    def test_no_replace_unsupported_fails_before_activation(self):
        build=installer.validate(self.args); old_id=self.use_distinct_old_patch()
        remote=installer.REMOTE.replace("if rename(tfd,os.fsencode(os.path.basename(temp)),dfd,os.fsencode(n),flag)!=0:", "if True:")
        remote=remote.replace('error=ctypes.get_errno()', 'error=errno.ENOSYS')
        with mock.patch.object(installer,'REMOTE',remote):
            with self.assertRaises(RuntimeError): installer.install(self.args,build,FakeAdb())
        self.assertEqual((self.root/'active-patch').read_text().strip(),old_id)
        self.assertFalse((self.root/'active-texture').exists())
        self.assertEqual(list((self.root/'patches'/self.patch_id).iterdir()),[])

    def test_directory_fsync_unsupported_never_activates_on_retry(self):
        build=installer.validate(self.args); old_id=self.use_distinct_old_patch()
        remote=installer.REMOTE.replace('os.fsync(dfd)', "raise OSError(errno.EINVAL,'unsupported directory fsync')")
        with mock.patch.object(installer,'REMOTE',remote):
            for _ in range(2):
                with self.assertRaises(RuntimeError): installer.install(self.args,build,FakeAdb())
                self.assertEqual((self.root/'active-patch').read_text().strip(),old_id)
                self.assertFalse((self.root/'active-texture').exists())

    def install_existing_main_fixture(self):
        merged_dir=self.root/'merged'; merged_dir.mkdir(exist_ok=True)
        merged=merged_dir/(self.merged_id+'.pck')
        shutil.copyfile(self.build/'merged'/(self.merged_id+'.pck'),merged)
        meta=json.loads((self.build/'merged'/(self.merged_id+'.json')).read_text())
        source=Path(self.args.device_source_pck)
        meta['source_stat']={'size':source.stat().st_size,'mtime_ns':source.stat().st_mtime_ns}
        meta['merged_stat']={'size':merged.stat().st_size,'mtime_ns':merged.stat().st_mtime_ns}
        (merged_dir/(self.merged_id+'.json')).write_text(json.dumps(meta))
        (self.root/'active-texture').write_text(self.merged_id+'\n')
        return merged

    def test_reuse_main_installs_patch_without_texture_or_merge(self):
        build=installer.validate(self.args); self.use_distinct_old_patch()
        merged=self.install_existing_main_fixture(); before=sha(merged)
        marker=self.root/'active-texture'; marker_before=marker.stat().st_mtime_ns
        self.args.reuse_main=True; adb=FakeAdb()
        remote=installer.REMOTE.replace("subprocess.run(['python3',stage+'/merge.py'", "raise RuntimeError('unexpected merge'); subprocess.run(['python3',stage+'/merge.py'")
        log=str(self.root.parent/'hashes.log')
        log_call="    open("+repr(log)+",'a').write(p+'\\n')\n"
        remote=remote.replace('def digest(p):\n', 'def digest(p):\n'+log_call)
        preflight=installer.REUSE_CHECK.replace('def sha(p):\n', 'def sha(p):\n'+log_call)
        with mock.patch.object(installer,'REMOTE',remote), mock.patch.object(installer,'REUSE_CHECK',preflight), mock.patch.object(installer.upload,'upload',side_effect=AssertionError('unexpected texture upload')):
            installer.install(self.args,build,adb)
            self.assertFalse(any(self.root.glob('.install-*')))
            installer.install(self.args,build,adb)
        lines=Path(log).read_text().splitlines()
        self.assertEqual(lines.count(str(merged)),2)
        self.assertEqual(lines.count(self.args.device_source_pck),2)
        self.assertEqual(sha(merged),before)
        self.assertEqual((self.root/'active-texture').read_text().strip(),self.merged_id)
        self.assertEqual(marker.stat().st_mtime_ns,marker_before)
        self.assertEqual((self.root/'active-patch').read_text().strip(),self.patch_id)
        self.assertFalse((self.root/'textures').exists())
        self.assertFalse(any(self.root.glob('.install-*')))

    def test_reuse_main_damage_refused_before_any_transfer(self):
        build=installer.validate(self.args); old_id=self.use_distinct_old_patch()
        merged=self.install_existing_main_fixture(); self.args.reuse_main=True
        original=merged.read_bytes(); st=merged.stat()
        merged.write_bytes(bytes([original[0]^1])+original[1:]); os.utime(merged,ns=(st.st_atime_ns,st.st_mtime_ns))
        adb=FakeAdb()
        with mock.patch.object(installer.upload,'upload',side_effect=AssertionError('unexpected texture upload')), mock.patch.object(installer,'send_file',side_effect=AssertionError('unexpected transfer')):
            with self.assertRaises(RuntimeError): installer.install(self.args,build,adb)
        self.assertEqual((self.root/'active-patch').read_text().strip(),old_id)
        self.assertEqual((self.root/'active-texture').read_text().strip(),self.merged_id)
        self.assertFalse(any(self.root.glob('.install-*')))
        merged.write_bytes(original)

    def test_reuse_main_changed_after_preflight_never_activates(self):
        build=installer.validate(self.args); old_id=self.use_distinct_old_patch()
        merged=self.install_existing_main_fixture(); self.args.reuse_main=True
        class MutatingAdb(FakeAdb):
            def run(self, command, data=None):
                if command.startswith('python3 ') and '/install.py ' in command:
                    st=merged.stat(); content=merged.read_bytes()
                    merged.write_bytes(bytes([content[0]^1])+content[1:]); os.utime(merged,ns=(st.st_atime_ns,st.st_mtime_ns))
                return super().run(command,data)
        with self.assertRaises(RuntimeError): installer.install(self.args,build,MutatingAdb())
        self.assertEqual((self.root/'active-patch').read_text().strip(),old_id)
        self.assertEqual((self.root/'active-texture').read_text().strip(),self.merged_id)

    def test_reuse_main_rejects_sidecar_and_selector_mismatch_before_transfer(self):
        build=installer.validate(self.args); old_id=self.use_distinct_old_patch()
        self.install_existing_main_fixture(); self.args.reuse_main=True
        side=self.root/'merged'/(self.merged_id+'.json'); original=side.read_text()
        marker=self.root/'active-texture'
        for mutation in ('overlay','source','selector'):
            with self.subTest(mutation=mutation):
                meta=json.loads(original)
                if mutation=='overlay': meta['overlay_sha256']='0'*64
                if mutation=='source': meta['source_sha256']='0'*64
                side.write_text(json.dumps(meta))
                if mutation=='selector': marker.write_text('0'*64+'\n')
                with mock.patch.object(installer,'send_file',side_effect=AssertionError('unexpected transfer')), mock.patch.object(installer.upload,'upload',side_effect=AssertionError('unexpected upload')):
                    with self.assertRaises(RuntimeError): installer.install(self.args,build,FakeAdb())
                self.assertEqual((self.root/'active-patch').read_text().strip(),old_id)
                self.assertFalse(any(self.root.glob('.install-*')))
                marker.write_text(self.merged_id+'\n')
        side.write_text(original)

    def test_foreign_final_patch_file_is_never_overwritten(self):
        build=installer.validate(self.args); old_id=self.use_distinct_old_patch()
        dest=self.root/'patches'/self.patch_id; dest.mkdir()
        (dest/'manifest.json').write_bytes(b'foreign incomplete file')
        with self.assertRaises(RuntimeError): installer.install(self.args,build,FakeAdb())
        self.assertEqual((dest/'manifest.json').read_bytes(),b'foreign incomplete file')
        self.assertEqual((self.root/'active-patch').read_text().strip(),old_id)
        self.assertFalse((self.root/'active-texture').exists())

    def test_second_selector_failure_keeps_valid_old_patch(self):
        build=installer.validate(self.args)
        old_id=self.use_distinct_old_patch()
        remote=installer.REMOTE.replace("select('active-patch',patch_id)", "raise ValueError('simulated second selector failure')")
        with mock.patch.object(installer,'REMOTE',remote):
            with self.assertRaises(RuntimeError): installer.install(self.args,build,FakeAdb())
        self.assertEqual((self.root/'active-patch').read_text().strip(),old_id)
        self.assertEqual((self.root/'active-texture').read_text().strip(),self.merged_id)
        self.assertEqual(sha(self.root/'merged'/(self.merged_id+'.pck')),self.merged_id)

    def test_cleanup_retains_in_use_overlay_and_unknown_stage_file(self):
        build=installer.validate(self.args); adb=FakeAdb()
        proc=self.root.parent/'fake-proc'; (proc/'123/fd').mkdir(parents=True)
        (proc/'123/maps').write_text('')
        overlay=self.root/'textures'/(build['report']['texture']['output_sha256']+'.pck')
        (proc/'123/fd/3').symlink_to(overlay)
        stage=self.root/('.install-'+build['patch_id']+'-'+build['merged_id']); stage.mkdir()
        (stage/'foreign').write_text('do not remove')
        with mock.patch.object(installer, 'REMOTE', installer.REMOTE.replace("'/proc'", repr(str(proc))).replace("'/proc/'", repr(str(proc)+'/'))):
            result=installer.install(self.args,build,adb)
        self.assertIn('overlay retained', result)
        self.assertIn('stage retained', result)
        self.assertTrue(overlay.exists())
        self.assertEqual((stage/'foreign').read_text(),'do not remove')
        self.assertEqual((self.root/'active-texture').read_text().strip(),self.merged_id)
        self.assertEqual((self.root/'active-patch').read_text().strip(),self.patch_id)

    def test_wrong_device_entry_and_source_cannot_activate(self):
        build=installer.validate(self.args)
        before=(self.root/'active-patch').read_bytes()
        Path(self.args.device_entry).write_text('invalid entry')
        with self.assertRaises(RuntimeError): installer.install(self.args,build,FakeAdb())
        self.assertEqual((self.root/'active-patch').read_bytes(),before)
        self.assertFalse((self.root/'active-texture').exists())

    def test_wrong_device_source_cannot_activate(self):
        build=installer.validate(self.args)
        before=(self.root/'active-patch').read_bytes()
        Path(self.args.device_source_pck).write_bytes(b'wrong source')
        with self.assertRaises(RuntimeError): installer.install(self.args,build,FakeAdb())
        self.assertEqual((self.root/'active-patch').read_bytes(),before)
        self.assertFalse((self.root/'active-texture').exists())

    def test_transport_failure_cannot_activate(self):
        build=installer.validate(self.args); before=(self.root/'active-patch').read_bytes()
        with self.assertRaises(RuntimeError): installer.install(self.args,build,FakeAdb(fail=True))
        self.assertEqual((self.root/'active-patch').read_bytes(),before)
        self.assertFalse((self.root/'active-texture').exists())


if __name__ == '__main__': unittest.main()
