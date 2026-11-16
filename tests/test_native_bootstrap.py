#!/usr/bin/env python3
# INPUT: Temporary native helper fixtures and explicit writable cache.
# OUTPUT: Explicit debug bootstrap, noexec fallback and checksum/link rejection.
# POS: Host tests; never use device caches or change mounts.
from pathlib import Path
import hashlib, os, shutil, subprocess, tempfile, unittest
ROOT=Path(__file__).resolve().parents[1]

class NativeBootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name).resolve();self.source=self.root/'helper';self.source.write_text('#!/bin/sh\n[ "$1" = version ]\n');self.source.chmod(0o755)
        self.hash=hashlib.sha256(self.source.read_bytes()).hexdigest()
        self.source.with_name(self.source.name+'.sha256').write_text(self.hash+'\n')
    def shell(self,body,*args):
        return subprocess.run(['bash','-c','set -eu\nsource "$1/_kit/debug/launcher.sh"\nshift\n'+body,'bootstrap',str(ROOT),*map(str,args)],capture_output=True,text=True,timeout=10,env={**os.environ,'PORTKIT_DEBUG_LAUNCHER':str(self.source)})
    def test_direct_execution_requires_matching_checksum(self):
        result=self.shell('launcher_native_debug_prepare; printf "%s" "$PORTKIT_DEBUG_LAUNCHER_BIN"')
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout,str(self.source))
        self.source.write_text('changed');self.assertNotEqual(self.shell('launcher_native_debug_prepare').returncode,0)
    def test_nonexecuting_card_helper_is_copied_verified_and_reused(self):
        self.source.chmod(0o644)
        body='launcher_native_cache "$1" cache "$2" "$3"; printf "%s" "$PORTKIT_DEBUG_LAUNCHER_BIN"'
        result=self.shell(body,self.root,self.source,self.hash);self.assertEqual(result.returncode,0,result.stderr)
        cache=Path(result.stdout);self.assertEqual(cache.read_bytes(),self.source.read_bytes());self.assertTrue(os.access(cache,os.X_OK))
        stamp=cache.stat().st_mtime_ns;self.assertEqual(self.shell(body,self.root,self.source,self.hash).returncode,0);self.assertEqual(cache.stat().st_mtime_ns,stamp)
        cache.write_text('corrupt');self.assertEqual(self.shell(body,self.root,self.source,self.hash).returncode,0);self.assertEqual(cache.read_bytes(),self.source.read_bytes())
    def test_linked_cache_directory_is_refused(self):
        outside=self.root/'outside';outside.mkdir();(self.root/'cache').symlink_to(outside,target_is_directory=True)
        result=self.shell('launcher_native_cache "$1" cache "$2" "$3"',self.root,self.source,self.hash)
        self.assertNotEqual(result.returncode,0);self.assertEqual(list(outside.iterdir()),[])
    def test_explicit_debug_wrapper_preserves_literal_argv_and_status(self):
        game=self.root/'game path';game.mkdir()
        shutil.copy2(ROOT/'target/debug/portkit-debug-launch',self.source)
        self.source.with_name(self.source.name+'.sha256').write_text(hashlib.sha256(self.source.read_bytes()).hexdigest()+'\n')
        result=self.shell('launcher_native_debug_exec "$1" -- /bin/sh -c \'printf "%s" "$1"; exit 19\' fixture "$2"',game,'literal $(no_execution)')
        self.assertEqual(result.returncode,19,result.stderr);self.assertEqual(result.stdout,'literal $(no_execution)')
    def test_release_stage_accepts_only_product_binary_and_refuses_debug_leftovers(self):
        kit=self.root/'fixture/_kit';(kit/'runtime').mkdir(parents=True)
        shutil.copy2(ROOT/'_kit/stage_portkit_launcher.sh',kit/'stage_portkit_launcher.sh')
        revision=(ROOT/'_kit/portkit-launcher-revision.txt').read_text().strip()
        (kit/'portkit-launcher-revision.txt').write_text(revision+'\n')
        (kit/'portkit_launcher_revision.py').write_text('print('+repr(revision)+')\n')
        runtime=kit/'runtime/portkit-launcher.aarch64'
        shutil.copy2(ROOT/'_kit/runtime/portkit-launcher.aarch64',runtime)
        def stage(name):return subprocess.run(['bash',str(kit/'stage_portkit_launcher.sh'),str(self.root/name)],capture_output=True,text=True,timeout=10)
        good=stage('release');self.assertEqual(good.returncode,0,good.stderr)
        self.assertEqual([p.relative_to(self.root/'release').as_posix() for p in (self.root/'release').rglob('*') if p.is_file()],['bin/portkit-launcher'])
        (self.root/'leftover/debug').mkdir(parents=True)
        failed=stage('leftover');self.assertNotEqual(failed.returncode,0);self.assertIn('debug launch files',failed.stderr);self.assertFalse((self.root/'leftover/bin').exists())
        # The Release gate checks product bytes without executing this ELF.
        # Use a rejected synthetic payload, not an ignored local debug build.
        runtime.write_bytes(runtime.read_bytes()+b'\0portkit-debug-launch\0')
        failed=stage('wrong-kind');self.assertNotEqual(failed.returncode,0);self.assertIn('debug or unknown',failed.stderr);self.assertFalse((self.root/'wrong-kind').exists())

if __name__=='__main__':unittest.main()
