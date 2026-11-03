# INPUT: isolated launcher engine loader and release VMA fragment
# OUTPUT: private engine identity/link guards and pre-init override behavior
# POS: host fixture only; no device or game assets
import hashlib,os,subprocess,sys,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
TEMPLATE=ROOT/'ports/sts2/love/vulkan-trial.sh.template'

class ReleaseEngineTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name);self.game=self.root/'game';self.game.mkdir();self.main=self.root/'main.pck';self.main.write_bytes(b'main');(self.game/'SlayTheSpire2.pck').symlink_to(self.main)
  self.engine=self.root/'engine.bin';self.data=b'private engine fixture';self.engine.write_bytes(self.data);self.sha=hashlib.sha256(self.data).hexdigest();t=TEMPLATE.read_text();self.loader=t.split('"$PRIVATE_ENGINE" <<\'PY\' || exit 1\n',1)[1].split('\nPY\n',1)[0]
  anchor='  if [ -n "$PRIVATE_ENGINE" ]; then\n    [ -z "${SLL_MEMORY_TRIAL:-}" ]';self.release=anchor+t.split(anchor,1)[1].split('  export PULSE_SERVER=',1)[0]
 def load(self,path):return subprocess.run([sys.executable,'-c',self.loader,'unused','unused','unused',str(self.game),self.sha,str(path)],capture_output=True,text=True)
 def test_verified_engine_copy_and_reject_mismatch(self):
  result=self.load(self.engine);self.assertEqual(result.returncode,0,result.stderr);self.assertEqual((self.game/'godot.mono').read_bytes(),self.data)
  (self.game/'godot.mono').unlink();self.engine.write_bytes(b'wrong');result=self.load(self.engine);self.assertNotEqual(result.returncode,0);self.assertFalse((self.game/'godot.mono').exists())
 def test_reject_symlink_engine(self):
  link=self.root/'link';link.symlink_to(self.engine);self.assertNotEqual(self.load(link).returncode,0);self.assertFalse((self.game/'godot.mono').exists())
 def config(self,private,trial=''):
  env={**os.environ,'GAME':str(self.game),'MAIN_PACK':str(self.main),'MAIN_PACK_ARG':str(self.main),'PRIVATE_ENGINE':private,'SLL_MEMORY_TRIAL':trial,'LOG_PREFIX':'[fixture]'}
  script="printf '[rendering]\\n' > \"$GAME/override.cfg\"\n"+self.release+"printf 'pack=%s trim=%s\\n' \"$MAIN_PACK_ARG\" \"${SLL_HEAP_TRIM-}\"\ncat \"$GAME/override.cfg\"\n"
  return subprocess.run(['bash','-c',script],env=env,capture_output=True,text=True)
 def test_vma64_before_main_pack_and_legacy_default(self):
  a=self.config('engine');self.assertEqual(a.returncode,0,a.stderr);self.assertIn('preferred_large_heap_block_size_mb=64',a.stdout);self.assertIn('pack='+str(self.game/'SlayTheSpire2.pck')+' trim=1',a.stdout)
  a=self.config('');self.assertEqual(a.returncode,0,a.stderr);self.assertNotIn('preferred_large_heap_block_size_mb',a.stdout);self.assertIn('pack='+str(self.main),a.stdout)
  self.assertNotEqual(self.config('engine','worker1').returncode,0)
  (self.game/'SlayTheSpire2.pck').unlink();self.assertNotEqual(self.config('engine').returncode,0)
if __name__=='__main__':unittest.main()
