# INPUT: synthetic managed PE/dependencies and explicit optional private input directories
# OUTPUT: ARM64-only metadata conversion and invalid-native rejection
# POS: host-only checks; no game, device, or native assembly execution
import copy
import hashlib
import json
import subprocess
import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import sys
from sts2_test_inputs import external_directory

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('sts2_windows_prepare',ROOT/'ports/sts2/src/tools/prepare_windows_game.py')
prepare=importlib.util.module_from_spec(spec);spec.loader.exec_module(prepare)
sys.path.insert(0,str(ROOT/'ports/sts2/src/tools/device_tools'))
from managed_dll_arch import classify_runtime_dll


def pe(flags=1,native=0):
    data=bytearray(2048);data[:2]=b'MZ';struct.pack_into('<I',data,0x3c,0x80);data[0x80:0x84]=b'PE\0\0'
    coff=0x84;struct.pack_into('<HH',data,coff,0x8664,1);struct.pack_into('<H',data,coff+16,240)
    optional=coff+20;struct.pack_into('<H',data,optional,0x20b);struct.pack_into('<I',data,optional+112+14*8,0x2000)
    struct.pack_into('<4I',data,optional+240+8,256,0x2000,256,0x400)
    struct.pack_into('<I',data,0x400+16,flags);struct.pack_into('<II',data,0x400+64,native,0)
    return bytes(data)


class WindowsPrepareTests(unittest.TestCase):
    def test_machine_only_and_no_native_payload(self):
        raw=pe();out=prepare.patch_pure_il(raw)
        self.assertEqual([i for i,(a,b) in enumerate(zip(raw,out)) if a!=b],[0x85])
        self.assertEqual(struct.unpack_from('<H',out,0x84)[0],0xaa64)
        for invalid in (pe(flags=0),pe(flags=3),pe(flags=0x20001),pe(flags=0x11),pe(native=1)):
            with self.assertRaises(ValueError):prepare.patch_pure_il(invalid)
        virtual_only=bytearray(pe());optional=0x84+20
        struct.pack_into('<4I',virtual_only,optional+240+8,512,0x2000,32,0x400)
        with self.assertRaises(ValueError):prepare.patch_pure_il(virtual_only)

    def test_actual_steamworks_x64_is_pure_il_and_patch_is_deterministic(self):
        windows=external_directory(self,'STS2_TEST_WINDOWS_GAME_DIR')
        p=windows/'data_sts2_windows_x86_64/Steamworks.NET.dll'
        if not p.is_file():self.skipTest(f'explicit Windows input is missing Steamworks.NET.dll: {p}')
        raw=p.read_bytes();machine,_,flags=prepare.inspect_managed(raw)
        self.assertEqual((machine,flags),(0x8664,1))
        output=prepare.patch_pure_il(raw)
        self.assertEqual(prepare.inspect_managed(output)[0],0xaa64)
        self.assertEqual(hashlib.sha256(output).hexdigest(),'474a2af1328c2a2b32bedf8376ed46a50958423313856659ac05bee677d8fdd3')

    def test_real_preparation_converts_exactly_the_reviewed_dependency(self):
        windows=external_directory(self,'STS2_TEST_WINDOWS_GAME_DIR')
        baseline=external_directory(self,'STS2_TEST_LINUX_BASELINE_DIR')
        data=windows/'data_sts2_windows_x86_64'
        profile=json.loads((ROOT/'ports/sts2/src/tools/handheld_low_v110_profile.json').read_text())
        required=[windows/'release_info.json',data/'sts2.dll',data/'sts2.deps.json',
                  baseline/'sts2.deps.json',baseline/'GodotSharp.dll']
        required.extend(data/name for name in profile['windows_dependency_sha256'])
        missing=[str(path) for path in required if not path.is_file()]
        if missing:self.skipTest('explicit preparation inputs are missing required files: '+', '.join(missing))
        with tempfile.TemporaryDirectory() as d:
            out=Path(d)/'prepared';cmd=[sys.executable,str(ROOT/'ports/sts2/src/tools/prepare_windows_game.py'),
              '--windows-dir',str(data),'--dll-sha256',profile['windows_dll_sha256'],'--deps-sha256',profile['windows_deps_sha256'],
              '--linux-runtime-deps',str(baseline/'sts2.deps.json'),'--linux-godotsharp',str(baseline/'GodotSharp.dll'),
              '--release-info',str(windows/'release_info.json'),'--output-dir',str(out)]
            run=subprocess.run(cmd,capture_output=True,text=True);self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            report=json.loads((out/'prepare-report.json').read_text());self.assertEqual(report['converted_dependencies'],['Steamworks.NET.dll'])
            with self.assertRaises(ValueError):classify_runtime_dll((data/'Steamworks.NET.dll').read_bytes())
            for file in out.glob('*.dll'):
                self.assertIn(classify_runtime_dll(file.read_bytes()),('arm64-il','anycpu-il'))

    def test_linux_arm64_r2r_is_checked_not_rewritten(self):
        raw=bytearray(pe());struct.pack_into('<H',raw,0x84,0xd11d);struct.pack_into('<I',raw,0x400+16,0xc)
        struct.pack_into('<II',raw,0x400+64,0x2048,8);struct.pack_into('<IHH',raw,0x448,0x00525452,10,1)
        self.assertEqual(classify_runtime_dll(raw),'linux-arm64-r2r')
        struct.pack_into('<H',raw,0x44e,2)
        with self.assertRaises(ValueError):classify_runtime_dll(raw)
        with self.assertRaises(ValueError):classify_runtime_dll(pe())

    def test_runtime_metadata_rebind_preserves_new_dependencies(self):
        win='.NETCoreApp,Version=v9.0/win-x64';linux='.NETCoreApp,Version=v9.0/linux-arm64'
        old='runtimepack.Microsoft.NETCore.App.Runtime.win-x64/9.0.7';new='runtimepack.Microsoft.NETCore.App.Runtime.linux-arm64/9.0.7'
        source={'runtimeTarget':{'name':win},'targets':{win:{old:{'native':{'windows.dll':{}}},'sts2/0.1.0':{'dependencies':{'runtimepack.Microsoft.NETCore.App.Runtime.win-x64':'9.0.7','Sentry':'6.7.0'}},'Sentry/6.7.0':{'runtime':{'Sentry.dll':{}}}}},'libraries':{old:{'type':'runtimepack'},'Sentry/6.7.0':{'type':'package'}}}
        baseline={'runtimeTarget':{'name':linux},'targets':{linux:{new:{'native':{'libcoreclr.so':{}}}}},'libraries':{new:{'type':'runtimepack'}}}
        snapshot=copy.deepcopy(source);result=prepare.rebind_deps(source,baseline)
        self.assertEqual(source,snapshot)
        self.assertEqual(result['runtimeTarget']['name'],linux)
        self.assertEqual(result['targets'][linux][new]['native'],{'libcoreclr.so':{}})
        self.assertEqual(result['targets'][linux]['sts2/0.1.0']['dependencies']['Sentry'],'6.7.0')
        baseline['targets'][linux].clear()
        with self.assertRaises(ValueError):prepare.rebind_deps(source,baseline)

    def test_dependency_swap_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);new=root/'Sentry.dll';new.write_bytes(b'new sentry');godot=root/'GodotSharp.dll';godot.write_bytes(b'godot')
            expected={'Sentry.dll':hashlib.sha256(new.read_bytes()).hexdigest()};paths={'Sentry.dll':new,'GodotSharp.dll':godot}
            prepare.verify_dependencies(paths,expected)
            new.write_bytes(b'old sentry')
            with self.assertRaises(ValueError):prepare.verify_dependencies(paths,expected)


if __name__=='__main__':unittest.main()
