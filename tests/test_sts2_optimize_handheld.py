# INPUT:  handheld-low build driver, synthetic inputs and tool version substitutes
# OUTPUT: offline plan, input validation and fail-closed upgrade regression
# POS:    isolated local fixtures; never uses player assets or a device
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT/'ports/sts2/src/tools/optimize_handheld.py'
spec = importlib.util.spec_from_file_location('optimize_handheld', SCRIPT)
tool = importlib.util.module_from_spec(spec); spec.loader.exec_module(tool)


class DriverTests(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(); self.addCleanup(self.t.cleanup)
        self.root = Path(self.t.name); self.refs = self.root/'refs'; self.refs.mkdir()
        self.pck = self.root/'game.pck'; self.pck.write_bytes(b'base')
        self.game = self.root/'sts2.dll'; self.game.write_bytes(b'game')
        self.deps = self.root/'sts2.deps.json'; self.deps.write_bytes(b'deps')
        (self.refs/'sts2.dll').write_bytes(b'game'); (self.refs/'0Harmony.dll').write_bytes(b'harmony')
        self.godot = self.root/'godot'; self.godot.write_text('#!/bin/sh\nprintf "4.5.1.stable.official.test\\n"\n'); self.godot.chmod(0o755)
        self.dotnet = self.root/'dotnet'; self.dotnet.write_text('#!/bin/sh\nprintf "9.0.100\\n"\n'); self.dotnet.chmod(0o755)
        self.out = self.root/'out'
    def args(self):
        return ['build','--source-pck',str(self.pck),'--game-dll',str(self.game),'--game-deps',str(self.deps),
                '--reference-dir',str(self.refs),'--godot',str(self.godot),'--dotnet',str(self.dotnet),'--output-dir',str(self.out)]
    def test_plan_no_output_no_device(self):
        p = subprocess.run([sys.executable,str(SCRIPT),*self.args(),'--plan'],capture_output=True,text=True)
        self.assertEqual(p.returncode,0,p.stderr); self.assertIn('no output or device writes',p.stdout); self.assertFalse(self.out.exists())
    def test_reference_mismatch_fails_before_output(self):
        (self.refs/'sts2.dll').write_bytes(b'other')
        p = subprocess.run([sys.executable,str(SCRIPT),*self.args(),'--plan'],capture_output=True,text=True)
        self.assertNotEqual(p.returncode,0); self.assertFalse(self.out.exists())
    def test_reuse_requires_both_files(self):
        p = subprocess.run([sys.executable,str(SCRIPT),*self.args(),'--reuse-verified-texture',str(self.pck),'--plan'],capture_output=True,text=True)
        self.assertNotEqual(p.returncode,0); self.assertFalse(self.out.exists())
    def test_unsupported_identity_scans_and_writes_diff_before_refusing(self):
        parser_args=tool.argparse.Namespace(source_pck=self.pck,game_dll=self.game,game_deps=self.deps,reference_dir=self.refs,
            godot=self.godot,dotnet=self.dotnet,output_dir=self.out,nuget_cache=None,texture_cache=None,
            reuse_verified_texture=None,reuse_texture_report=None,allow_unverified_spine_binary=False,plan=False)
        calls=[]
        def fake_run(command,*args,**kwargs):
            calls.append(command)
            name = 'scan' if tool.SCAN in command else 'shader-scan'
            (self.out/name).mkdir()
        with mock.patch.object(tool,'run',side_effect=fake_run):
            with self.assertRaisesRegex(ValueError,'unsupported game input'):
                tool.build(parser_args)
        self.assertEqual(len(calls),2)
        d=json.loads((self.out/'unsupported-input.json').read_text())
        self.assertEqual(set(d['differences']),{'source_pck','game_dll','game_deps'})
        self.assertFalse((self.out/'patch').exists())

    def test_spine_is_excluded_unless_explicitly_accepted(self):
        profile = self.root/'profile.json'
        digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
        profile.write_text(json.dumps({'source_pck_sha256':digest(self.pck),'game_dll_sha256':digest(self.game),'game_deps_sha256':digest(self.deps)}))
        for include in (False, True):
            with self.subTest(include=include):
                out = self.root/('with-spine' if include else 'without-spine')
                args=tool.argparse.Namespace(source_pck=self.pck,game_dll=self.game,game_deps=self.deps,reference_dir=self.refs,
                    godot=self.godot,dotnet=self.dotnet,output_dir=out,nuget_cache=None,texture_cache=None,
                    reuse_verified_texture=None,reuse_texture_report=None,allow_unverified_spine_binary=include,plan=False)
                def fake_run(command,*args,**kwargs):
                    if tool.TEXTURE in command:
                        self.assertEqual('--verified-spine-loader' in command, include)
                        raise RuntimeError('texture call observed')
                with mock.patch.object(tool,'PROFILE',profile), mock.patch.object(tool,'source_identities',return_value={}), mock.patch.object(tool,'run',side_effect=fake_run):
                    with self.assertRaisesRegex(RuntimeError,'texture call observed'): tool.build(args)

if __name__ == '__main__': unittest.main()
