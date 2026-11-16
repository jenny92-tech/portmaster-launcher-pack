from pathlib import Path
import os,select,shlex,subprocess,tempfile,unittest
BRIDGE=Path(__file__).parents[1]/'src/menu-entry.sh'

class MenuEntryTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name).resolve()
        self.clone=self.root/'.port.sh';self.clone.write_bytes(BRIDGE.read_bytes());self.data=self.root/'soulknight_ns';(self.data/'bin').mkdir(parents=True);self.helper=self.data/'launcher.sh';self.report=self.root/'report'
    def write_helper(self,body):self.helper.write_text('#!/bin/sh\n'+body+'\n');self.helper.chmod(0o755)
    def test_handoff_preserves_pid_parent_and_literal_arguments(self):
        self.write_helper('printf "%s %s\\n" "$$" "$PPID"; printf "%s\\n" "$@" > '+shlex.quote(str(self.report))+'; IFS= read -r line; exit 7')
        args=['space 中文','literal $(no_execution)',''];proc=subprocess.Popen(['/bin/bash',str(self.clone),*args],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd='/tmp')
        try:
            self.assertTrue(select.select([proc.stdout],[],[],5)[0]);pid,parent=map(int,proc.stdout.readline().split());self.assertEqual(pid,proc.pid);self.assertEqual(parent,os.getpid())
            self.assertEqual(self.report.read_text().splitlines(),args)
            proc.communicate(b'exit\n',timeout=5);self.assertEqual(proc.returncode,7)
        finally:
            if proc.poll()is None:proc.kill();proc.communicate()
    def test_missing_native_helper_fails(self):
        run=subprocess.run(['/bin/bash',str(self.clone)],capture_output=True,timeout=5);self.assertNotEqual(run.returncode,0)
    def test_bridge_only_hands_off_identity_and_paths(self):
        text=BRIDGE.read_text();self.assertTrue(text.startswith('#!/bin/bash\n'));self.assertLessEqual(len(text.splitlines()),10)
        self.assertIn('exec -a "$0"',text)
        for token in ['launcher_compat','native-bootstrap','exec-view','PORTKIT_END']:self.assertNotIn(token,text)
        subprocess.run(['/bin/bash','-n',str(BRIDGE)],check=True)
if __name__=='__main__':unittest.main()
