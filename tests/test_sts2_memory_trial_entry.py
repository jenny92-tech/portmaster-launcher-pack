# INPUT: trial launcher function and synthetic private execution view
# OUTPUT: isolated single-setting override and exact main-pack link checks
# POS: local fixture; never reads player assets or connects to a device
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
TEMPLATE=ROOT/'ports/sts2/love/vulkan-trial.sh.template'

class MemoryTrialEntryTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.game=self.root/'game';self.game.mkdir()
        self.main=self.root/'main.pck';self.main.write_bytes(b'fixture')
        (self.game/'SlayTheSpire2.pck').symlink_to(self.main)
        text=TEMPLATE.read_text();self.function='configure_memory_trial() {'+text.split('configure_memory_trial() {',1)[1].split('\n}\n',1)[0]+'\n}\n'

    def run_trial(self,trial='',isolated=True,diag=True):
        env={**os.environ,'GAME':str(self.game),'MAIN_PACK':str(self.main),'LOG_PREFIX':'[fixture]',
             'SLL_MEMORY_TRIAL':trial,'SLL_DIAG_XDG_ROOT':'/tmp/test-isolated' if isolated else '',
             'SLL_TEXTURE_DIAG':'1' if diag else '0'}
        script="printf '[rendering]\\nrenderer/rendering_method=\\\"mobile\\\"\\n' > \"$GAME/override.cfg\"\n"+self.function+"configure_memory_trial || exit 9\nprintf 'pack=%s\\n' \"$MAIN_PACK_ARG\"\ncat \"$GAME/override.cfg\"\n"
        return subprocess.run(['bash','-c',script],env=env,capture_output=True,text=True)

    def test_default_and_single_audited_overrides(self):
        normal=self.run_trial();self.assertEqual(normal.returncode,0,normal.stderr)
        self.assertIn('pack='+str(self.main),normal.stdout);self.assertNotIn('max_threads=',normal.stdout)
        for mode,setting in [('worker1','worker_pool/max_threads=1'),('descriptor16','rendering_device/vulkan/max_descriptors_per_pool=16'),('staging16','rendering_device/staging_buffer/max_size_mb=16')]:
            with self.subTest(mode=mode):
                result=self.run_trial(mode);self.assertEqual(result.returncode,0,result.stderr)
                self.assertIn('pack='+str(self.game/'SlayTheSpire2.pck'),result.stdout)
                self.assertIn(setting,result.stdout)
                self.assertEqual(sum(x in result.stdout for x in ('worker_pool/max_threads=','max_descriptors_per_pool=','staging_buffer/max_size_mb=')),1)
        normal=self.run_trial();self.assertNotIn('max_size_mb=',normal.stdout)

    def test_requires_isolation_diagnostics_and_exact_link(self):
        for mode,isolated,diag in [('worker1',False,True),('worker1',True,False),('unknown',True,True)]:
            with self.subTest(mode=mode,isolated=isolated,diag=diag):
                self.assertNotEqual(self.run_trial(mode,isolated,diag).returncode,0)
        (self.game/'SlayTheSpire2.pck').unlink();other=self.root/'other.pck';other.write_bytes(b'other')
        (self.game/'SlayTheSpire2.pck').symlink_to(other)
        self.assertNotEqual(self.run_trial('worker1').returncode,0)

if __name__=='__main__':unittest.main()
