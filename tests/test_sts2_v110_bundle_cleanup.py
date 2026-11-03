# INPUT: synthetic active/previous immutable build directories and fake proc
# OUTPUT: hash, inode and live-handle guards for exact old bundle removal
# POS: isolated host fixture; never contacts a device or game
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1];TOOLS=ROOT/'ports/sts2/src/tools/device_tools';sys.path.insert(0,str(TOOLS))
spec=importlib.util.spec_from_file_location('bundle_cleanup',TOOLS/'cleanup_v110_bundle.py');module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)


class CleanupBundleTest(unittest.TestCase):
    def test_live_file_and_bad_active_prevent_deletion(self):
        sha=lambda b:hashlib.sha256(b).hexdigest()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d).resolve()/'sts2-vk-test';original=root.parent/'sts2';root.mkdir();(original/'gamedata/pcks').mkdir(parents=True);(original/'gamedata/pcks/SlayTheSpire2.pck').write_bytes(b'original')
            def make(label):
                tmp=root/'builds'/label;(tmp/'data').mkdir(parents=True);(tmp/'patch').mkdir()
                game={'sts2.dll':label.encode(),'sts2.deps.json':b'deps'};patch={'sts2.dll':b'patched','sts2.deps.json':b'patched deps','sts2_compat.dll':b'compat','port_compat.pck':b'compat pack'}
                for n,v in game.items():(tmp/'data'/n).write_bytes(v)
                for n,v in patch.items():(tmp/'patch'/n).write_bytes(v)
                pr=(json.dumps({'files':{n:sha(v) for n,v in patch.items()},'source_files':{n:sha(v) for n,v in game.items()}})+'\n').encode();(tmp/'patch/manifest.json').write_bytes(pr)
                (tmp/'entry.sh').write_bytes(b'entry');(tmp/'release_info.json').write_bytes(b'release');(tmp/'main.pck').write_bytes(label.encode())
                m={'main_sha256':sha(label.encode()),'patch_sha256':sha(pr),'game_files':{n:sha(v) for n,v in game.items()},'entry_sha256':sha(b'entry'),'release_sha256':sha(b'release'),'runtime_binding':{},'baseline_files':{},'extension_files':{}}
                raw=(json.dumps(m)+'\n').encode();identity=sha(raw);bundle=root/'builds'/identity;tmp.rename(bundle);(bundle/'manifest.json').write_bytes(raw);st=(bundle/'main.pck').stat()
                (bundle/'main.stat.json').write_text(json.dumps({'build_sha256':identity,'main_sha256':sha(label.encode()),'size':st.st_size,'mtime_ns':st.st_mtime_ns}))
                return identity,bundle
            oldid,old=make('old');newid,new=make('new');(root/'active-build').write_text(newid+'\n');(root.parent/'Je-杀戮尖塔2-VK测试.sh').write_bytes(b'entry')
            proc=root.parent/'proc';(proc/'1/fd').mkdir(parents=True);(proc/'1/maps').write_text('');(proc/'1/fd/7').symlink_to(old/'main.pck')
            with self.assertRaisesRegex(ValueError,'open'):module.clean(root,original,newid,oldid,proc,True)
            (proc/'1/fd/7').unlink();st=(old/'main.pck').stat();(proc/'1/maps').write_text(f'0000-1000 r--p 00000000 {os.major(st.st_dev):x}:{os.minor(st.st_dev):x} {st.st_ino} /old\n')
            with self.assertRaisesRegex(ValueError,'mapped'):module.clean(root,original,newid,oldid,proc,True)
            (proc/'1/maps').write_text('');(old/'unknown').write_bytes(b'x')
            with self.assertRaisesRegex(ValueError,'unexpected'):module.clean(root,original,newid,oldid,proc,True)
            (old/'unknown').unlink()
            with mock.patch.object(module,'reject_protected_aliases',side_effect=ValueError('aliases protected')):
                with self.assertRaisesRegex(ValueError,'aliases protected'):module.clean(root,original,newid,oldid,proc,True)
            (new/'entry.sh').write_bytes(b'bad')
            with self.assertRaisesRegex(ValueError,'mismatch'):module.clean(root,original,newid,oldid,proc,True)
            self.assertTrue(old.exists());(new/'entry.sh').write_bytes(b'entry')
            result=module.clean(root,original,newid,oldid,proc,True)
            self.assertFalse(result['dry_run']);self.assertFalse(old.exists());self.assertTrue(new.exists())


if __name__=='__main__':unittest.main()
