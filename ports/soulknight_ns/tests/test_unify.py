from pathlib import Path
import json,os,select,subprocess,sys,tempfile,unittest,zipfile
from test_export import runtime,exporter,HOST_HELPER
sys.path.insert(0,str(exporter.PORT/'src'))
import unify

class UnifiedExportTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.stage=self.root/'relocated 中文 package'
        self.source=self.root/'prepared.zip';self.probe=self.root/'graphics-probe'
        self.probe.write_text('fixture only; never executed');self.probe.chmod(0o755)
        identity={'profile':'Release','kind':'linux-native-vulkan','title_id':exporter.TITLE,'game_build':exporter.BUILD,'source_revision':'2'*64}
        names=['shaders/shader_index.bin','fonts/NotoSansCJKsc-Regular.otf','runtime/vulkan-wsi/libVkLayer_window_system_integration.so','runtime/vulkan-wsi/VkLayer_window_system_integration.json','RomFS/Data/globalgamemanagers']
        names+=['native/'+n+'.'+s for n in ['main','subsdk0','sdk']for s in ['patched.bin','fixups.tsv','gates.tsv']]
        self.payload={name:name.encode()for name in names}
        self.payload.update({'runtime/soulknight-ns':runtime(identity),'runtime/soulknight-ns-gles':runtime(dict(identity,kind='linux-native-gles-experiment')),'libexec/launch.py':b'old runner','launcher.sh':b'old entry','libexec/native-bootstrap.sh':b'old debug wrapper','bin/portkit-launcher.sha256':b'old bootstrap pin','debug/run.sh':b'old debug entry','bin/portkit-debug-launch':b'old debug program'})
        self.manifest={'title_id':exporter.TITLE,'game_build':exporter.BUILD,'profile':exporter.PROFILES['trimui'],'runtime_identity':identity,'files':{k:unify.sha(v)for k,v in self.payload.items()}}
        self.write_input()
    def write_input(self):
        with zipfile.ZipFile(self.source,'w')as z:
            z.writestr('soulknight_ns/installation-trimui.json',json.dumps(self.manifest))
            for name,data in self.payload.items():
                info=zipfile.ZipInfo('soulknight_ns/'+name);info.external_attr=0o100644<<16;z.writestr(info,data)
            z.writestr('soulknight_ns/runtime/LICENSE-MIT.txt','fixture license')
            z.writestr('soulknight_ns/runtime/soulknight-ns-miniloong','unselected old runtime')
            z.writestr('soulknight_ns/save/PlayerPrefs','personal state')
    def build(self):
        unify.compose(self.source,self.stage,'installation-trimui.json',self.probe,HOST_HELPER)
        return self.stage/'soulknight_ns'
    def test_one_runtime_unchanged_assets_new_common_adapter_and_no_player_data(self):
        data=self.build();self.assertEqual((data/'runtime/soulknight-ns').read_bytes(),self.payload['runtime/soulknight-ns'])
        self.assertFalse((data/'runtime/soulknight-ns-miniloong').exists());self.assertFalse((data/'save').exists())
        self.assertFalse((data/'installation-trimui.json').exists())
        for name in ['libexec/native-bootstrap.sh','bin/portkit-launcher.sha256','debug/run.sh','bin/portkit-debug-launch']:
            self.assertFalse((data/name).exists(),name)
        manifest=json.loads((data/'installation.json').read_text())
        for name,want in manifest['files'].items():self.assertEqual(exporter.digest(data/name),want,name)
        visible=(self.stage/exporter.ENTRY).read_text()
        self.assertNotIn('exec-view',visible);self.assertNotIn('native-bootstrap.sh',visible);self.assertNotIn('JE_EXEC_READY',visible)
        entry=(data/'launcher.sh').read_text()
        self.assertIn('launcher_compat_probe ns-vulkan',entry)
        self.assertIn('portmaster_init',entry)
        for path in [self.stage/exporter.ENTRY,data/'launcher.sh']:
            subprocess.run(['/bin/bash','-n',str(path)],check=True)
        self.assertNotIn('DEVICE=miniloong',entry)
        self.assertEqual((data/'RomFS/Data/globalgamemanagers').read_bytes(),self.payload['RomFS/Data/globalgamemanagers'])
    def test_relocated_clone_read_only_check_without_initializing_platform(self):
        self.build();clone=self.stage/'.port.sh';clone.write_bytes((self.stage/exporter.ENTRY).read_bytes());before=set(self.stage.rglob('*'))
        run=subprocess.run(['/bin/bash',str(clone),'--check'],cwd='/tmp',capture_output=True,text=True,timeout=20)
        self.assertEqual(run.returncode,0,run.stderr);self.assertEqual(run.stdout.count('preflight passed'),1)
        self.assertEqual(set(self.stage.rglob('*')),before)
    def test_bridge_preserves_clone_pid_tracking_literal_arguments_and_status(self):
        data=self.build();clone=self.stage/'.port.sh';clone.write_bytes((self.stage/exporter.ENTRY).read_bytes())
        (data/'launcher.sh').write_text('''#!/bin/bash
printf '%s %s\\n' "$$" "$PPID"
printf '%s\\n' "$@"
IFS= read -r line
exit 7
''')
        (data/'launcher.sh').chmod(0o755)
        args=['--hold','space value','literal $(no_execution)']
        proc=subprocess.Popen(['/bin/bash',str(clone),*args],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd='/tmp')
        try:
            self.assertTrue(select.select([proc.stdout],[],[],5)[0]);pid,ppid=proc.stdout.readline().decode().split()
            self.assertEqual(int(pid),proc.pid);self.assertEqual(int(ppid),os.getpid())
            expected=('\n'.join(args)+'\n').encode();self.assertEqual(proc.stdout.read(len(expected)),expected)
            self.assertIn(str(clone),subprocess.check_output(['ps','-p',str(proc.pid),'-o','args='],text=True))
            proc.communicate(b'exit\n',timeout=5);self.assertEqual(proc.returncode,7)
        finally:
            if proc.poll()is None:proc.kill();proc.communicate()
    def test_changed_selected_payload_fails_before_output_is_created(self):
        self.payload['runtime/soulknight-ns']=b'changed runtime';self.write_input()
        with self.assertRaisesRegex(ValueError,'Changed exported input'):self.build()
        self.assertFalse(self.stage.exists())

if __name__=='__main__':unittest.main()
