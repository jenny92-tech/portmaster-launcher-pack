# INPUT: synthetic active and legacy game bundles with fake process metadata
# OUTPUT: exact cleanup, active integrity and open-file protection regressions
# POS: local-only; never operates on a device or real game data
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('v110_cleanup',ROOT/'ports/sts2/src/tools/device_tools/cleanup_v110_legacy.py');cleanup=importlib.util.module_from_spec(spec);spec.loader.exec_module(cleanup)


class CleanupTest(unittest.TestCase):
    def test_rejects_protected_inode_alias(self):
        with mock.patch.object(cleanup,'snapshot',return_value=(10,20,30,40)):
            with self.assertRaisesRegex(ValueError,'aliases protected'):
                cleanup.reject_protected_aliases([Path('/old/file')],[Path('/new/file')])

    def test_verified_cleanup_rejects_open_legacy_and_bad_active(self):
        sha=lambda b:hashlib.sha256(b).hexdigest()
        with tempfile.TemporaryDirectory() as d:
            ports=Path(d).resolve();root=ports/'sts2-vk-test';original=ports/'sts2';root.mkdir();(original/'gamedata/pcks').mkdir(parents=True);(original/'data_sts2_linuxbsd_arm64').mkdir()
            source=original/'gamedata/pcks/SlayTheSpire2.pck';source.write_bytes(b'old source')
            oldfiles={'sts2.dll':b'old','sts2.deps.json':b'old deps','sts2_compat.dll':b'compat','port_compat.pck':b'pack'}
            oldraw=(json.dumps({'files':{n:sha(v) for n,v in oldfiles.items()}})+'\n').encode();oldid=sha(oldraw);olddir=root/'patches'/oldid;olddir.mkdir(parents=True)
            for n,v in oldfiles.items():(olddir/n).write_bytes(v)
            (olddir/'manifest.json').write_bytes(oldraw)
            oldmain=b'old main';oldmainid=sha(oldmain);merged=root/'merged';merged.mkdir();oldp=merged/(oldmainid+'.pck');oldp.write_bytes(oldmain)
            st=lambda p:{'size':p.stat().st_size,'mtime_ns':p.stat().st_mtime_ns}
            (merged/(oldmainid+'.json')).write_text(json.dumps({'merged_sha256':oldmainid,'source_sha256':sha(source.read_bytes()),'merged_stat':st(oldp),'source_stat':st(source)}))
            (root/'active-patch').write_text(oldid+'\n');(root/'active-texture').write_text(oldmainid+'\n')
            temp=root/'builds'/'temp';(temp/'patch').mkdir(parents=True);(temp/'data').mkdir()
            game={'sts2.dll':b'new game','sts2.deps.json':b'new deps'};patch={'sts2.dll':b'new patched','sts2.deps.json':b'new patched deps','sts2_compat.dll':b'new compat','port_compat.pck':b'new pack'}
            for n,v in game.items():(temp/'data'/n).write_bytes(v)
            for n,v in patch.items():(temp/'patch'/n).write_bytes(v)
            pr=(json.dumps({'files':{n:sha(v) for n,v in patch.items()},'source_files':{n:sha(v) for n,v in game.items()}})+'\n').encode();(temp/'patch/manifest.json').write_bytes(pr)
            newmain=b'new main';(temp/'main.pck').write_bytes(newmain);(temp/'release_info.json').write_bytes(b'release');(temp/'entry.sh').write_bytes(b'entry');entry=ports/'Je-杀戮尖塔2-VK测试.sh';entry.write_bytes(b'entry')
            manifest={'main_sha256':sha(newmain),'patch_sha256':sha(pr),'game_files':{n:sha(v) for n,v in game.items()},'release_sha256':sha(b'release'),'entry_sha256':sha(b'entry'),'runtime_binding':{},'baseline_files':{},'extension_files':{}}
            raw=(json.dumps(manifest)+'\n').encode();buildid=sha(raw);bundle=root/'builds'/buildid;temp.rename(bundle);(bundle/'manifest.json').write_bytes(raw)
            s=st(bundle/'main.pck');(bundle/'main.stat.json').write_text(json.dumps({'build_sha256':buildid,'main_sha256':sha(newmain),**s}));(root/'active-build').write_text(buildid+'\n')
            proc=ports/'proc';(proc/'1/fd').mkdir(parents=True);(proc/'1/maps').write_text('');(proc/'1/fd/3').symlink_to(oldp)
            with self.assertRaisesRegex(ValueError,'open'):cleanup.inspect(root,original,buildid,oldid,oldmainid,proc)
            (proc/'1/fd/3').unlink();(bundle/'entry.sh').write_bytes(b'bad')
            with self.assertRaisesRegex(ValueError,'entry mismatch'):cleanup.inspect(root,original,buildid,oldid,oldmainid,proc,True)
            (bundle/'entry.sh').write_bytes(b'entry');(bundle/'data/sts2.dll').write_bytes(b'bad')
            with self.assertRaisesRegex(ValueError,'mismatch'):cleanup.inspect(root,original,buildid,oldid,oldmainid,proc,True)
            self.assertTrue(oldp.exists());(bundle/'data/sts2.dll').write_bytes(game['sts2.dll'])
            self.assertTrue(cleanup.inspect(root,original,buildid,oldid,oldmainid,proc)['dry_run'])
            self.assertFalse(cleanup.inspect(root,original,buildid,oldid,oldmainid,proc,True)['dry_run'])
            self.assertFalse(oldp.exists());self.assertFalse(olddir.exists());self.assertTrue(source.exists());self.assertTrue((bundle/'main.pck').exists())


if __name__=='__main__':unittest.main()
