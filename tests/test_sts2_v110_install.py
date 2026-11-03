# INPUT: local fixtures for installer preflight and atomic bundle commit
# OUTPUT: source bindings, interruption safety, selector and mismatch regressions
# POS: synthetic host filesystem; never contacts a device or starts a game
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import shutil
import os
import sys
import tempfile
import unittest
from unittest import mock
from tests.test_sts2_prepare_windows_game import pe, prepare

ROOT=Path(__file__).resolve().parents[1];DIR=ROOT/'ports/sts2/src/tools/device_tools';sys.path.insert(0,str(DIR))
spec=importlib.util.spec_from_file_location('install_v110_fixture',DIR/'install_v110.py');install=importlib.util.module_from_spec(spec);spec.loader.exec_module(install)


class InstallTest(unittest.TestCase):
    def test_assembly_snapshot_used_only_for_engine_build(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d).resolve();source=root/'source.py';source.write_text('current')
            current=install.sha(source);old=hashlib.sha256(b'parent').hexdigest()
            report={'build_source_sha256':{'source.py':old},'assembly_source_sha256':{'source.py':current},'engine_sha256':install.ENGINE_SHA}
            with mock.patch.object(install,'REPO',root):
                install.validate_source_snapshots(report)
                for bad in ({}, {'other.py':current}, {'source.py':old}):
                    with self.assertRaises((ValueError,FileNotFoundError)):
                        install.validate_source_snapshots(dict(report,assembly_source_sha256=bad))
                with self.assertRaises(ValueError):install.validate_source_snapshots({'build_source_sha256':{'source.py':old}})
                install.validate_source_snapshots({'build_source_sha256':{'source.py':current}})

    def test_release_evidence_pins_parent_and_compat_candidate(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);base=root/'base-build-report.json';evidence=root/'compat-build-evidence.json'
            parent={'code.py':'a'*64};source='f'*64
            def check(parent_in=parent,candidate=install.DELIVERY_COMPAT_SHA):
                base.write_text(json.dumps({'build_source_sha256':parent_in}))
                evidence.write_text(json.dumps({'candidate_compat_sha256':candidate,'source_pck_sha256':source}))
                with mock.patch.object(install,'BASE_REPORT_SHA',install.sha(base)),mock.patch.object(install,'COMPAT_EVIDENCE_SHA',install.sha(evidence)):
                    install.validate_release_evidence(root,{'build_source_sha256':parent,'input_sha256':{'source_pck':source}})
            check()
            with self.assertRaisesRegex(ValueError,'parent build'):check({'code.py':'b'*64})
            with self.assertRaisesRegex(ValueError,'compat build'):check(candidate='0'*64)
            with mock.patch.object(install,'BASE_REPORT_SHA','0'*64):
                with self.assertRaisesRegex(ValueError,'identity mismatch'):
                    install.validate_release_evidence(root,{'build_source_sha256':parent,'input_sha256':{'source_pck':source}})

    def test_two_locale_binds_input_output_and_evidence(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);source=root/'locale-dll-input.dll';source.write_bytes(b'audited input')
            evidence=root/'locale-dll-evidence.json';input_sha=install.sha(source);output_sha=hashlib.sha256(b'candidate').hexdigest();game_sha='f'*64
            (root/'base-build-report.json').write_text(json.dumps({'patch_files':{'sts2.dll':input_sha}}))
            def check(allowed):
                e={'input_sha256':input_sha,'output_sha256':output_sha,'source_pck_sha256':game_sha,'allowed':allowed,'removed_count':13,
                   'cecil_readback':True,'other_method_il_unchanged':True,'synthetic_clr_fixture':True}
                evidence.write_text(json.dumps(e));evidence_sha=install.sha(evidence)
                r={'engine_sha256':install.ENGINE_SHA,'input_sha256':{'source_pck':game_sha},'two_locale':{'input_sha256':input_sha,'output_sha256':output_sha,'evidence_sha256':evidence_sha}}
                with mock.patch.object(install,'LOCALE_INPUT_SHA',input_sha),mock.patch.object(install,'LOCALE_OUTPUT_SHA',output_sha),mock.patch.object(install,'LOCALE_EVIDENCE_SHA',evidence_sha):
                    install.validate_two_locale(root,r,{'files':{'sts2.dll':output_sha}})
                    with self.assertRaisesRegex(ValueError,'identity mismatch'):
                        install.validate_two_locale(root,r,{'files':{'sts2.dll':'a'*64}})
            check(['eng','zhs'])
            with self.assertRaisesRegex(ValueError,'evidence mismatch'):check(['eng','jpn'])

    def test_local_copy_has_large_file_timeout(self):
        class Adb:
            target='fixture'
            def run(self,command,timeout):
                self.timeout=timeout
                return '1:2'
        with tempfile.TemporaryDirectory() as d:
            adb=Adb(); calls=[None,'a'*64]
            with mock.patch.object(install.upload,'remote_hash',side_effect=calls),mock.patch.object(install.upload,'remote',return_value=''):
                install.reuse_main(adb,'/tmp/root','b'*64,'c'*64,'a'*64,Path(d))
            self.assertEqual(adb.timeout,900)

    def test_completed_copy_cleans_owned_marker_after_lost_response(self):
        class Adb:
            target='fixture'
            def run(self,command):return '1:2'
        with tempfile.TemporaryDirectory() as d:
            state=Path(d);oldid='b'*64;newid='c'*64;wanted='a'*64;token='d'*64;directory='/tmp/root/builds/'+newid
            name='v110-copy-'+hashlib.sha256(('fixture'+directory+wanted).encode()).hexdigest()+'.json'
            (state/name).write_text(json.dumps({'old':oldid,'new':newid,'sha256':wanted,'token':token}))
            with mock.patch.object(install.upload,'remote_hash',side_effect=[wanted,hashlib.sha256(token.encode()).hexdigest()]),mock.patch.object(install.upload,'remote',return_value='') as remote:
                install.reuse_main(Adb(),'/tmp/root',oldid,newid,wanted,state)
            self.assertEqual(remote.call_args.args[2],'finish')

    def test_local_main_copy_resumes_only_matching_owned_prefix(self):
        sha=lambda d:hashlib.sha256(d).hexdigest()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d).resolve();data=bytes(range(256))*4000;wanted=sha(data)
            oldraw=(json.dumps({'main_sha256':wanted})+'\n').encode();newraw=(json.dumps({'main_sha256':wanted,'other':'new'})+'\n').encode()
            oldid=sha(oldraw);newid=sha(newraw);old=root/'builds'/oldid;new=root/'builds'/newid;old.mkdir(parents=True);new.mkdir()
            (root/'active-build').write_text(oldid+'\n');(old/'manifest.json').write_bytes(oldraw);(new/'manifest.json').write_bytes(newraw);(old/'main.pck').write_bytes(data)
            st=(old/'main.pck').stat();(old/'main.stat.json').write_text(json.dumps({'build_sha256':oldid,'main_sha256':wanted,'size':st.st_size,'mtime_ns':st.st_mtime_ns}))
            token='a'*64;partial=new/('main.pck.'+wanted+'.partial');owner=new/(partial.name+'.owner')
            partial.write_bytes(data[:12345]);owner.write_text(token)
            command=[sys.executable,'-c',install.COPY_MAIN,str(root),oldid,newid,wanted,token]
            run=subprocess.run(command,capture_output=True,text=True);self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertEqual(partial.read_bytes(),data);self.assertEqual((old/'main.pck').read_bytes(),data)
            partial.write_bytes(b'corrupt');run=subprocess.run(command,capture_output=True,text=True);self.assertNotEqual(run.returncode,0)
            self.assertEqual(partial.read_bytes(),b'corrupt')

    def test_budget_closed_set_detects_unapproved_replacements(self):
        low=install.low
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);before={name:('old-'+name).encode() for name in install.budget_gate.EXPECTED};before['ordinary']=b'unchanged'
            for name in install.budget_gate.EXPECTED-{install.budget_gate.trial.BOLD}:before[name+'.import']=b'import'
            delta={name:('new-'+name).encode() for name in install.budget_gate.EXPECTED}
            after=dict(before);after.update(delta);records={}
            for name in install.budget_gate.EXPECTED:
                rec={'base_sha256':hashlib.sha256(before[name]).hexdigest(),'output_sha256':hashlib.sha256(delta[name]).hexdigest()}
                if name!=install.budget_gate.trial.BOLD:rec.update(import_path=name+'.import',import_sha256=hashlib.sha256(b'import').hexdigest())
                records[name]=rec
            def pack(name,items):
                files=[]
                for i,(key,data) in enumerate(sorted(items.items())):
                    f=root/(name+str(i));f.write_bytes(data);files.append((key,f))
                out=root/(name+'.pck');low.write_pack(files,out);return out
            base=pack('base',before);out=pack('good',after);patch=pack('delta',delta)
            install.validate_budget_entries(base,out,patch,records)
            after['ordinary']=b'unexpected';bad=pack('bad',after)
            with self.assertRaisesRegex(ValueError,'unapproved change'):install.validate_budget_entries(base,bad,patch,records)

    def test_reviewed_budget_copy_requires_fixed_sidecar(self):
        sha=lambda d:hashlib.sha256(d).hexdigest()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d).resolve();data=b'budget main'*4096;wanted=sha(data)
            oldraw=(json.dumps({'main_sha256':'a'*64})+'\n').encode();newraw=(json.dumps({'main_sha256':wanted})+'\n').encode()
            oldid=sha(oldraw);newid=sha(newraw);old=root/'builds'/oldid;new=root/'builds'/newid;old.mkdir(parents=True);new.mkdir()
            (root/'active-build').write_text(oldid+'\n');(old/'manifest.json').write_bytes(oldraw);(new/'manifest.json').write_bytes(newraw)
            packs=root/'font-budget-trial-a1/packs';packs.mkdir(parents=True);source=packs/(wanted+'.pck');source.write_bytes(data)
            st=source.stat();side={'source_sha256':'099bb1f8e7b3985b30617365335d0e5534d2b426e2e7774cbd59d68c7e5db14c','overlay_sha256':'4119d66135932df11eb3f1187488ca0db6fc9700858accf5658b2fb7cdbb999b','merged_sha256':wanted,'merged_stat':{'size':st.st_size,'mtime_ns':st.st_mtime_ns}}
            sidefile=packs/(wanted+'.json');sidefile.write_text(json.dumps(side))
            code=install.COPY_MAIN.replace(install.BUDGET_MAIN_SHA,wanted);args=[sys.executable,'-c',code,str(root),oldid,newid,wanted,'d'*64,'reviewed-font']
            side['source_sha256']='f'*64;sidefile.write_text(json.dumps(side));bad=subprocess.run(args,capture_output=True,text=True);self.assertNotEqual(bad.returncode,0)
            side['source_sha256']='099bb1f8e7b3985b30617365335d0e5534d2b426e2e7774cbd59d68c7e5db14c';sidefile.write_text(json.dumps(side));done=subprocess.run(args,capture_output=True,text=True)
            self.assertEqual(done.returncode,0,done.stdout+done.stderr);self.assertEqual((new/('main.pck.'+wanted+'.partial')).read_bytes(),data)

    def test_mono_closed_set_rejects_unrelated_changes(self):
        low=install.low
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);target=install.mono_gate.candidate.MONO
            def pack(name,items):
                files=[]
                for i,(key,data) in enumerate(sorted(items.items())):
                    f=root/(name+str(i));f.write_bytes(data);files.append((key,f))
                out=root/(name+'.pck');low.write_pack(files,out);return out
            base=pack('base',{target:b'old','ordinary':b'untouched'})
            delta=pack('delta',{target:b'new'});good=pack('good',{target:b'new','ordinary':b'untouched'})
            bad=pack('bad',{target:b'new','ordinary':b'changed'})
            record={'base_sha256':hashlib.sha256(b'old').hexdigest(),'output_sha256':hashlib.sha256(b'new').hexdigest()}
            install.validate_mono_entries(base,good,delta,record)
            with self.assertRaisesRegex(ValueError,'unapproved change'):install.validate_mono_entries(base,bad,delta,record)

    def test_reviewed_mono_copy_requires_fixed_sidecar(self):
        sha=lambda d:hashlib.sha256(d).hexdigest()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d).resolve();data=b'mono main'*4096;wanted=sha(data)
            oldraw=(json.dumps({'main_sha256':'a'*64})+'\n').encode();newraw=(json.dumps({'main_sha256':wanted})+'\n').encode()
            oldid=sha(oldraw);newid=sha(newraw);old=root/'builds'/oldid;new=root/'builds'/newid;old.mkdir(parents=True);new.mkdir()
            (root/'active-build').write_text(oldid+'\n');(old/'manifest.json').write_bytes(oldraw);(new/'manifest.json').write_bytes(newraw)
            packs=root/'mono-subset-trial-a1/packs';packs.mkdir(parents=True);source=packs/(wanted+'.pck');source.write_bytes(data)
            st=source.stat();side={'source_sha256':install.BUDGET_MAIN_SHA,'overlay_sha256':install.mono_gate.DELTA,'merged_sha256':wanted,'merged_stat':{'size':st.st_size,'mtime_ns':st.st_mtime_ns}}
            sidefile=packs/(wanted+'.json');sidefile.write_text(json.dumps(side))
            code=install.COPY_MAIN.replace(install.MONO_MAIN_SHA,wanted);args=[sys.executable,'-c',code,str(root),oldid,newid,wanted,'d'*64,'reviewed-mono']
            side['overlay_sha256']='f'*64;sidefile.write_text(json.dumps(side));bad=subprocess.run(args,capture_output=True,text=True);self.assertNotEqual(bad.returncode,0)
            side['overlay_sha256']=install.mono_gate.DELTA;sidefile.write_text(json.dumps(side));done=subprocess.run(args,capture_output=True,text=True)
            self.assertEqual(done.returncode,0,done.stdout+done.stderr);self.assertEqual((new/('main.pck.'+wanted+'.partial')).read_bytes(),data)

    def test_reviewed_private_copy_requires_bound_sidecar_and_stable_source(self):
        sha=lambda d:hashlib.sha256(d).hexdigest()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d).resolve();data=b'reviewed main'*4096;wanted=sha(data)
            oldraw=(json.dumps({'main_sha256':'a'*64})+'\n').encode();newraw=(json.dumps({'main_sha256':wanted})+'\n').encode()
            oldid=sha(oldraw);newid=sha(newraw);old=root/'builds'/oldid;new=root/'builds'/newid;old.mkdir(parents=True);new.mkdir()
            (root/'active-build').write_text(oldid+'\n');(old/'manifest.json').write_bytes(oldraw);(new/'manifest.json').write_bytes(newraw)
            packs=root/'refine-trial-abff4b541ac9aa9e/packs';packs.mkdir(parents=True);source=packs/(wanted+'.pck');source.write_bytes(data)
            st=source.stat();side={'source_sha256':'7ec4bb3f96fd01dc42bde20b6daa2f98cd16f09cec3b8ef404efd53f089615f1','overlay_sha256':'447f1186d5a86495d8b0b5276c95eb1b514413433220fd01bea29abf1939cf16','merged_sha256':wanted,'merged_stat':{'size':st.st_size,'mtime_ns':st.st_mtime_ns}}
            sidefile=packs/(wanted+'.json');sidefile.write_text(json.dumps(side));token='d'*64
            code=install.COPY_MAIN.replace('099bb1f8e7b3985b30617365335d0e5534d2b426e2e7774cbd59d68c7e5db14c',wanted)
            command=[sys.executable,'-c',code,str(root),oldid,newid,wanted,token,'reviewed-099']
            side['overlay_sha256']='f'*64;sidefile.write_text(json.dumps(side));bad=subprocess.run(command,capture_output=True,text=True)
            self.assertNotEqual(bad.returncode,0);self.assertFalse((new/('main.pck.'+wanted+'.partial')).exists())
            side['overlay_sha256']='447f1186d5a86495d8b0b5276c95eb1b514413433220fd01bea29abf1939cf16';sidefile.write_text(json.dumps(side))
            done=subprocess.run(command,capture_output=True,text=True);self.assertEqual(done.returncode,0,done.stdout+done.stderr)
            self.assertEqual((new/('main.pck.'+wanted+'.partial')).read_bytes(),data);self.assertEqual(source.read_bytes(),data)

    def test_low_space_allows_only_bound_resume(self):
        with self.assertRaises(ValueError):install.check_capacity(100,1000,False)
        install.check_capacity(100,1000,True)

    def test_maskfix_exact_entry_diff_and_report(self):
        low=install.low
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);old=root/'main-port_compat.pck';new=root/'port_compat.pck';report=root/'maskfix-overlay-report.json'
            before={install.MASK_PATH:b'old script'}|{f'other/{i:03d}':str(i).encode() for i in range(177)}
            after=dict(before);after[install.MASK_PATH]=b'new script'
            def make(path,items):
                files=[]
                for i,(name,data) in enumerate(sorted(items.items())):
                    f=root/(path.name+str(i));f.write_bytes(data);files.append((name,f))
                low.write_pack(files,path)
            def write_report():
                metadata={'base_sha256':install.sha(old),'candidate_sha256':install.sha(new),'source_sha256':hashlib.sha256(after[install.MASK_PATH]).hexdigest(),'entry_count':178,'replaced':[install.MASK_PATH],
                    'entries':[{'path':k,'before_sha256':hashlib.sha256(before[k]).hexdigest(),'after_sha256':hashlib.sha256(after[k]).hexdigest()} for k in sorted(before)]}
                report.write_text(json.dumps(metadata));return metadata
            make(old,before);make(new,after);write_report()
            def verify():
                with mock.patch.object(install,'MASK_BASE',install.sha(old)),mock.patch.object(install,'MASK_NEW',install.sha(new)), \
                     mock.patch.object(install,'MASK_REPORT',install.sha(report)),mock.patch.object(install,'MASK_OLD_ENTRY',hashlib.sha256(before[install.MASK_PATH]).hexdigest()), \
                     mock.patch.object(install,'MASK_NEW_ENTRY',hashlib.sha256(after[install.MASK_PATH]).hexdigest()):
                    return install.validate_maskfix(root,{'main_compat_sha256':install.sha(old),'maskfix_overlay_report':str(report)},new)
            self.assertEqual(verify(),install.sha(old))
            after['other/000']=b'unexpected change';new.unlink();make(new,after);write_report()
            with self.assertRaisesRegex(ValueError,'entry mismatch'):verify()

    def test_preflight_and_atomic_commit(self):
        sha=lambda d:hashlib.sha256(d).hexdigest()
        with tempfile.TemporaryDirectory() as d:
            ports=Path(d).resolve();root=ports/'sts2-vk-test';original=ports/'sts2';base=original/'data_sts2_linuxbsd_arm64';base.mkdir(parents=True);root.mkdir()
            entry=ports/'entry.sh';old=b'old entry';new=b'new entry';entry.write_bytes(old)
            (base/'sts2.deps.json').write_bytes(b'old deps');(base/'GodotSharp.dll').write_bytes(b'old godot');(base/'System.dll').write_bytes(prepare.patch_pure_il(pe()))
            (root/'active-patch').write_text('a'*64+'\n');(root/'active-texture').write_text('b'*64+'\n')
            names=['sts2.dll','sts2.deps.json','GodotSharp.dll'];gamefiles={'sts2.dll':b'game','sts2.deps.json':b'deps','GodotSharp.dll':b'new godot'}
            paths=['addons/spine/linux/libspine_godot.linux.template_release.arm64.so','addons/fmod/libs/linux/libGodotFmod.linux.template_release.arm64.so']+[f'addons/fmod/libs/linux/{n}' for n in ('libfmod.so','libfmod.so.14','libfmod.so.14.6','libfmodstudio.so','libfmodstudio.so.14','libfmodstudio.so.14.6')]
            for n in paths:
                f=original/n;f.parent.mkdir(parents=True,exist_ok=True);f.write_bytes(n.encode())
            # The real preflight pins the installed Spine binary; the fixture
            # substitutes its known synthetic digest, without weakening code.
            preflight=install.PREFLIGHT.replace('8cb9dbc0aac823a5d305ab058b71a6d7f57aa4eaaced7638cb0a8f1435968438',sha(paths[0].encode()))
            args=[str(root),str(original),str(entry),sha(old),sha(new),json.dumps(names),'1',sha(b'old deps'),sha(b'old godot')]
            audit=(DIR/'managed_dll_arch.py').read_text()
            p=subprocess.run([sys.executable,'-c',audit+'\n'+preflight,*args],capture_output=True,text=True);self.assertEqual(p.returncode,0,p.stdout+p.stderr);pre=json.loads(p.stdout)
            patchfiles={'sts2.dll':b'patched','sts2.deps.json':b'patched deps','sts2_compat.dll':b'compat','port_compat.pck':b'pack'}
            patch={'files':{n:sha(v) for n,v in patchfiles.items()},'source_files':{n:sha(gamefiles[n]) for n in ('sts2.dll','sts2.deps.json')}}
            rawpatch=(json.dumps(patch)+'\n').encode();main=b'fake merged pck';release=b'{"version":"v0.110.1"}'
            manifest={'source_pck_sha256':'1'*64,'main_sha256':sha(main),'main_bytes':len(main),'patch_sha256':sha(rawpatch),'game_files':{n:sha(v) for n,v in gamefiles.items()},'release_sha256':sha(release),'entry_sha256':sha(new),'runtime_binding':pre['runtime_binding'],'baseline_files':pre['baseline_files'],'extension_files':pre['extension_files']}
            raw=(json.dumps(manifest,sort_keys=True,indent=2)+'\n').encode();identity=sha(raw);bundle=root/'builds'/identity;(bundle/'patch').mkdir(parents=True);(bundle/'data').mkdir()
            for n,v in gamefiles.items():(bundle/'data'/n).write_bytes(v)
            for n,v in patchfiles.items():(bundle/'patch'/n).write_bytes(v)
            (bundle/'patch/manifest.json').write_bytes(rawpatch);(bundle/'manifest.json').write_bytes(raw);(bundle/'main.pck').write_bytes(main);(bundle/'release_info.json').write_bytes(release);(bundle/'entry.sh').write_bytes(new)
            commit=[sys.executable,'-c',audit+'\n'+install.COMMIT,str(root),str(original),str(entry),identity,sha(old),sha(new),'a'*64,'b'*64,'']
            (bundle/'data/GodotSharp.dll').write_bytes(b'wrong');bad=subprocess.run(commit,capture_output=True,text=True)
            self.assertNotEqual(bad.returncode,0);self.assertEqual(entry.read_bytes(),old);self.assertFalse((root/'active-build').exists())
            (bundle/'data/GodotSharp.dll').write_bytes(gamefiles['GodotSharp.dll'])
            done=subprocess.run(commit,capture_output=True,text=True);self.assertEqual(done.returncode,0,done.stdout+done.stderr)
            self.assertEqual(entry.read_bytes(),new);self.assertEqual((root/'active-build').read_text().strip(),identity)
            retry=subprocess.run(commit,capture_output=True,text=True);self.assertEqual(retry.returncode,0,retry.stdout+retry.stderr)
            # A custom engine is part of the immutable manifest. A failed or
            # substituted upload must never change the selected bundle.
            engine=b'audited synthetic engine'; manifest['engine_sha256']=sha(engine)
            raw2=(json.dumps(manifest,sort_keys=True,indent=2)+'\n').encode();identity2=sha(raw2);bundle2=root/'builds'/identity2
            shutil.copytree(bundle,bundle2);(bundle2/'manifest.json').write_bytes(raw2);(bundle2/'main.stat.json').unlink()
            (bundle2/'engine.bin').write_bytes(b'tampered')
            code=install.COMMIT.replace(install.ENGINE_SHA,sha(engine))
            commit2=[sys.executable,'-c',audit+'\n'+code,str(root),str(original),str(entry),identity2,sha(old),sha(new),'a'*64,'b'*64,identity]
            bad=subprocess.run(commit2,capture_output=True,text=True);self.assertNotEqual(bad.returncode,0)
            self.assertEqual((root/'active-build').read_text().strip(),identity)
            (bundle2/'engine.bin').unlink();os.symlink(bundle/'entry.sh',bundle2/'engine.bin')
            bad=subprocess.run(commit2,capture_output=True,text=True);self.assertNotEqual(bad.returncode,0)
            self.assertEqual((root/'active-build').read_text().strip(),identity)
            (bundle2/'engine.bin').unlink();(bundle2/'engine.bin').write_bytes(engine)
            good=subprocess.run(commit2,capture_output=True,text=True);self.assertEqual(good.returncode,0,good.stdout+good.stderr)
            self.assertEqual((root/'active-build').read_text().strip(),identity2)


if __name__=='__main__':unittest.main()
