# INPUT: synthetic immutable build selector, patch, runtime and main PCK metadata
# OUTPUT: coherent-bundle acceptance and fail-closed mismatch checks
# POS: executes the launcher's embedded verifier locally, never starts Godot
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
TEMPLATE=ROOT/'ports/sts2/love/vulkan-trial.sh.template'


class BundleTests(unittest.TestCase):
    def test_coherent_bundle_and_mismatches(self):
        code=TEMPLATE.read_text().split("<<'VERIFY_BUILD' || exit 1\n",1)[1].split('\nVERIFY_BUILD',1)[0]
        sha=lambda data:hashlib.sha256(data).hexdigest()
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);original=root/'original';base=original/'data_sts2_linuxbsd_arm64';base.mkdir(parents=True)
            bundle=root/'build';data=bundle/'data';patch=bundle/'patch';data.mkdir(parents=True);patch.mkdir()
            (base/'System.dll').write_bytes(b'runtime');(base/'sts2.deps.json').write_bytes(b'baseline deps');(base/'GodotSharp.dll').write_bytes(b'baseline godot')
            gf={'sts2.dll':b'new game','sts2.deps.json':b'new deps','Sentry.dll':b'new sentry','GodotSharp.dll':b'new godot'}
            for n,v in gf.items():(data/n).write_bytes(v)
            pf={'sts2.dll':b'patched game','sts2.deps.json':b'patched deps','sts2_compat.dll':b'compat','port_compat.pck':b'pack'}
            for n,v in pf.items():(patch/n).write_bytes(v)
            pm={'files':{n:sha(v) for n,v in pf.items()},'source_files':{n:sha(gf[n]) for n in ('sts2.dll','sts2.deps.json')}}
            pr=(json.dumps(pm)+'\n').encode();(patch/'manifest.json').write_bytes(pr)
            main=struct.pack('<5I',0x43504447,3,4,5,1)+b'fixture';(bundle/'main.pck').write_bytes(main)
            release=b'{"version":"v0.110.1"}';(bundle/'release_info.json').write_bytes(release);(bundle/'entry.sh').write_bytes(b'entry')
            stat=lambda p:{'sha256':sha(p.read_bytes()),'size':p.stat().st_size,'mtime_ns':p.stat().st_mtime_ns}
            paths=['addons/spine/linux/libspine_godot.linux.template_release.arm64.so','addons/fmod/libs/linux/libGodotFmod.linux.template_release.arm64.so']+[f'addons/fmod/libs/linux/{n}' for n in ('libfmod.so','libfmod.so.14','libfmod.so.14.6','libfmodstudio.so','libfmodstudio.so.14','libfmodstudio.so.14.6')]
            for n in paths:
                p=original/n;p.parent.mkdir(parents=True,exist_ok=True);p.write_bytes(n.encode())
            manifest={'source_pck_sha256':'1'*64,'main_sha256':sha(main),'main_bytes':len(main),'patch_sha256':sha(pr),'game_files':{n:sha(v) for n,v in gf.items()},'release_sha256':sha(release),'entry_sha256':sha(b'entry'),'runtime_binding':{'sts2.deps.json':sha(b'baseline deps'),'GodotSharp.dll':sha(b'baseline godot')},'baseline_files':{'System.dll':stat(base/'System.dll')},'extension_files':{n:stat(original/n) for n in paths}}
            raw=(json.dumps(manifest)+'\n').encode();identity=sha(raw);(bundle/'manifest.json').write_bytes(raw)
            ms=(bundle/'main.pck').stat();(bundle/'main.stat.json').write_text(json.dumps({'build_sha256':identity,'main_sha256':sha(main),'size':ms.st_size,'mtime_ns':ms.st_mtime_ns}))
            run=lambda:subprocess.run(['python3','-',str(bundle),identity,str(original)],input=code,text=True,capture_output=True)
            p=run();self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            for path in (data/'Sentry.dll',base/'System.dll',bundle/'main.pck',original/paths[0]):
                before=path.read_bytes();path.write_bytes(before+b'x');self.assertNotEqual(run().returncode,0);path.write_bytes(before)
                if path==base/'System.dll':manifest['baseline_files']['System.dll']=stat(path)
                elif path==bundle/'main.pck':
                    ms=path.stat();(bundle/'main.stat.json').write_text(json.dumps({'build_sha256':identity,'main_sha256':sha(main),'size':ms.st_size,'mtime_ns':ms.st_mtime_ns}))
                elif path==original/paths[0]:manifest['extension_files'][paths[0]]=stat(path)
                raw=(json.dumps(manifest)+'\n').encode();identity=sha(raw);(bundle/'manifest.json').write_bytes(raw)
                ms=(bundle/'main.pck').stat();(bundle/'main.stat.json').write_text(json.dumps({'build_sha256':identity,'main_sha256':sha(main),'size':ms.st_size,'mtime_ns':ms.st_mtime_ns}))
            (data/'foreign.dll').write_bytes(b'x');self.assertNotEqual(run().returncode,0)


if __name__=='__main__':unittest.main()
