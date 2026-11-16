from pathlib import Path
import hashlib,importlib.util,json,os,select,struct,subprocess,tempfile,unittest
from unittest.mock import patch

PORT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('soulknight_export',PORT/'src/export.py');exporter=importlib.util.module_from_spec(spec);spec.loader.exec_module(exporter)

def runtime(identity):
    names=b'\0.text\0.soulknight_build\0.shstrtab\0';build=json.dumps(identity).encode()+b'\0';build_at=160;names_at=build_at+len(build);sections_at=(names_at+len(names)+7)&~7
    data=bytearray(sections_at+4*64);data[:16]=b'\x7fELF\x02\x01\x01'+bytes(9)
    struct.pack_into('<HHIQQQIHHHHHH',data,16,3,183,1,128,64,sections_at,0,64,56,1,64,4,3)
    struct.pack_into('<IIQQQQQQ',data,64,1,5,0,0,0,sections_at,sections_at,4096);data[128:132]=bytes.fromhex('c0035fd6');data[build_at:build_at+len(build)]=build;data[names_at:names_at+len(names)]=names
    for i,entry in enumerate([(0,0,0,0,0,0,0,0,0,0),(1,1,6,128,128,4,0,0,4,0),(7,1,2,build_at,build_at,len(build),0,0,1,0),(25,3,0,0,names_at,len(names),0,0,1,0)]):struct.pack_into('<IIQQQQIIQQ',data,sections_at+i*64,*entry)
    return bytes(data)

HOST_HELPER=exporter.REPO/'target/debug/portkit-launcher'

class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.source=self.root/'installed';self.data=self.source/'soulknight_ns';self.data.mkdir(parents=True)
        identity={'profile':'Release','kind':'linux-native-vulkan','title_id':exporter.TITLE,'game_build':exporter.BUILD,'source_revision':'0'*64}
        payload={'runtime/soulknight-ns':runtime(identity),'runtime/soulknight-ns-gles':runtime(dict(identity,kind='linux-native-gles-experiment')),'libexec/launch.py':b'old runner','runtime/vulkan-wsi/libVkLayer_window_system_integration.so':b'wsi','runtime/vulkan-wsi/VkLayer_window_system_integration.json':b'{}','RomFS/Data/globalgamemanagers':b'assets'}
        for name,data in payload.items():
            path=self.data/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
        (self.data/'runtime/LICENSE-MIT.txt').write_text('fixture license')
        self.manifest={'title_id':exporter.TITLE,'game_build':exporter.BUILD,'runtime_identity':identity,'files':{n:exporter.digest(self.data/n)for n in payload},'profile':'/old/profile'}
        self.write_manifest()
        entry=self.source/exporter.ENTRY;entry.write_text('#!/bin/sh\nexit 0\n')
        pin=patch.dict(exporter.LAUNCHER_SHA,miniloong=exporter.digest(entry),trimui=exporter.digest(entry));pin.start();self.addCleanup(pin.stop)
        for name in ['save/PlayerPrefs','identity/user.data','cache/shader.data','logs/session.log']:
            p=self.data/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('personal data')
        self.probe=self.root/'probe';self.probe.write_text('fixture')
        self.stage=self.root/'relocated 中文 package'
    def write_manifest(self):(self.data/'installation.json').write_text(json.dumps(self.manifest))
    def build(self,platform='miniloong',image=None):return exporter.export(self.source,platform,self.stage,image,self.probe,HOST_HELPER)
    def test_only_manifest_assets_are_exported_and_original_saves_untouched(self):
        before=(self.data/'save/PlayerPrefs').read_bytes();manifest=(self.data/'installation.json').read_bytes();self.build()
        result=json.loads((self.stage/'soulknight_ns/installation.json').read_text())
        self.assertEqual(result['profile'],exporter.PROFILES['miniloong'])
        self.assertEqual((self.data/'save/PlayerPrefs').read_bytes(),before);self.assertEqual((self.data/'installation.json').read_bytes(),manifest)
        self.assertFalse(any((self.stage/'soulknight_ns'/name).exists()for name in exporter.STATE))
        self.assertFalse(any(p.suffix in {'.py','.pyc'}for p in self.stage.rglob('*')))
        self.assertEqual((self.stage/'soulknight_ns/runtime/soulknight-ns').read_bytes(),(self.data/'runtime/soulknight-ns').read_bytes())
    def test_relocated_firmware_clone_read_only_check(self):
        self.build();clone=self.stage/'.port.sh';clone.write_bytes((self.stage/exporter.ENTRY).read_bytes());before=set(self.stage.rglob('*'))
        run=subprocess.run(['/bin/bash',str(clone),'--check'],cwd='/tmp',capture_output=True,text=True,timeout=20)
        self.assertEqual(run.returncode,0,run.stderr);self.assertIn('preflight passed',run.stdout);self.assertEqual(set(self.stage.rglob('*')),before)
    def test_state_traversal_and_changed_payload_fail_before_staging(self):
        for name in ['save/PlayerPrefs','../outside']:
            self.manifest['files'][name]='0'*64;self.write_manifest()
            with self.assertRaises(ValueError):self.build()
            self.assertFalse(self.stage.exists());del self.manifest['files'][name]
        self.write_manifest();(self.data/'RomFS/Data/globalgamemanagers').write_text('changed')
        with self.assertRaisesRegex(ValueError,'Changed installed'):self.build()
        self.assertFalse(self.stage.exists())
    def test_changed_entry_and_debug_runtime_fail_before_staging(self):
        (self.source/exporter.ENTRY).write_text('changed')
        with self.assertRaisesRegex(ValueError,'device-audited'):self.build()
        self.assertFalse(self.stage.exists())
        binary=self.data/'runtime/soulknight-ns';identity=dict(self.manifest['runtime_identity'],profile='Debug');binary.write_bytes(runtime(identity));self.manifest['runtime_identity']=identity;self.manifest['files']['runtime/soulknight-ns']=exporter.digest(binary);self.write_manifest()
        with self.assertRaisesRegex(ValueError,'Release'):self.build()
    def test_trimui_requires_audited_image_and_seals_same_native_payload(self):
        with self.assertRaisesRegex(ValueError,'audited'):self.build('trimui')
        path=self.data/'runtime/portable-wayland/manifest.json';path.parent.mkdir();path.write_text('{}');self.manifest['files']['runtime/portable-wayland/manifest.json']=exporter.digest(path);self.write_manifest()
        image=self.root/'weston.squashfs';image.write_bytes(b'fixture image')
        with patch.object(exporter,'WESTON_SHA',exporter.digest(image)):self.build('trimui',image)
        payload=self.stage/'soulknight_ns';manifest=json.loads((payload/'installation.json').read_text())
        self.assertEqual(manifest['profile'],exporter.PROFILES['trimui']);self.assertEqual(manifest['files']['runtime/weston_pkg_0.2.squashfs'],exporter.digest(image))
        self.assertNotIn('libexec/wayland-session.py',manifest['files'])

if __name__=='__main__':unittest.main()
