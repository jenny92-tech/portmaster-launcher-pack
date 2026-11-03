# INPUT: isolated synthetic Godot scene and optional texture diagnostic
# OUTPUT: bounded, deduplicated texture metadata test without game code
# POS: headless host fixture; not a GPU performance measurement
import os
import hashlib
import json
import sys
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'ports/sts2/src/tools/godot_pck'))
import low_texture_overlay as low

DEFAULT=ROOT/'.cache/sts2-vulkan-trial/build-tools/godot-4.5.1-macos/Godot.app/Contents/MacOS/Godot'

class TextureDiagnosticTests(unittest.TestCase):
    def test_font_cache_observation_is_native_and_non_creating(self):
        godot=Path(os.environ.get('STS2_TEST_GODOT',str(DEFAULT)))
        if not godot.is_file(): self.skipTest('Godot 4.5.1 unavailable')
        with tempfile.TemporaryDirectory() as temp:
            project=Path(temp);(project/'project.godot').write_text('[application]\nconfig/name="Font cache fixture"\n')
            (project/'port_diagnostics').mkdir()
            shutil.copy(ROOT/'ports/sts2/src/texture_diagnostics/font_cache_diagnostic.gd',project/'port_diagnostics/font_cache_diagnostic.gd')
            shutil.copy(ROOT/'tests/sts2_font_cache_diagnostic_fixture.gd',project/'fixture.gd')
            run=subprocess.run([str(godot),'--headless','--path',str(project),'--script','res://fixture.gd'],capture_output=True,text=True,timeout=20)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn('FONT_CACHE_DIAGNOSTIC_FIXTURE_OK',run.stdout)

    def test_font_cache_observation_on_device_version_arm64(self):
        docker=shutil.which('docker')
        engine=ROOT/'.cache/sts2-vulkan-trial/engine-rebuild-928/richtext4096/godot-candidate-4096'
        if not docker or not engine.is_file(): self.skipTest('matching Linux ARM64 engine unavailable')
        check=subprocess.run([docker,'image','inspect','--format','{{.Architecture}}','debian:bookworm-slim'],capture_output=True,text=True,timeout=10)
        if check.returncode or check.stdout.strip()!='arm64': self.skipTest('local ARM64 image unavailable')
        with tempfile.TemporaryDirectory() as temp:
            project=Path(temp);(project/'project.godot').write_text('[application]\nconfig/name="Font Linux fixture"\n')
            (project/'port_diagnostics').mkdir()
            shutil.copy(ROOT/'ports/sts2/src/texture_diagnostics/font_cache_diagnostic.gd',project/'port_diagnostics/font_cache_diagnostic.gd')
            shutil.copy(ROOT/'tests/sts2_font_cache_diagnostic_fixture.gd',project/'fixture.gd')
            command=[docker,'run','--rm','--pull=never','--network=none','--read-only','-v',str(engine)+':/godot:ro','-v',str(project)+':/fixture:ro','--tmpfs','/tmp:rw,noexec,nosuid,size=32m','-e','XDG_DATA_HOME=/tmp/godot-data','debian:bookworm-slim','/godot','--headless','--path','/fixture','--script','res://fixture.gd']
            run=subprocess.run(command,capture_output=True,text=True,timeout=30)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn('FONT_CACHE_DIAGNOSTIC_FIXTURE_OK',run.stdout)
    def test_shared_texture_is_counted_once(self):
        godot=Path(os.environ.get('STS2_TEST_GODOT',str(DEFAULT)))
        if not godot.is_file(): self.skipTest('Godot 4.5.1 unavailable')
        with tempfile.TemporaryDirectory() as temp:
            project=Path(temp)
            (project/'project.godot').write_text('[application]\nconfig/name="Texture diagnostic fixture"\n')
            shutil.copy(ROOT/'ports/sts2/src/texture_diagnostics/texture_diagnostic.gd',project/'texture_diagnostic.gd')
            (project/'port_diagnostics').mkdir()
            shutil.copy(ROOT/'ports/sts2/src/texture_diagnostics/font_cache_diagnostic.gd',project/'port_diagnostics/font_cache_diagnostic.gd')
            shutil.copy(ROOT/'tests/sts2_texture_diagnostic_fixture.gd',project/'fixture.gd')
            run=subprocess.run([str(godot),'--headless','--path',str(project),'--script','res://fixture.gd'],capture_output=True,text=True,timeout=20)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn('TEXTURE_DIAGNOSTIC_FIXTURE_OK',run.stdout)

    def test_resource_stats_native_enums_and_missing_services(self):
        godot=Path(os.environ.get('STS2_TEST_GODOT',str(DEFAULT)))
        if not godot.is_file(): self.skipTest('Godot 4.5.1 unavailable')
        with tempfile.TemporaryDirectory() as temp:
            project=Path(temp);(project/'project.godot').write_text('[application]\nconfig/name="Resource stats fixture"\n')
            folder=project/'port_diagnostics';folder.mkdir()
            for name in ('resource_stats.gd','texture_diagnostic.gd','texture_diagnostic_runner.gd','font_cache_diagnostic.gd'):
                shutil.copy(ROOT/'ports/sts2/src/texture_diagnostics'/name,folder/name)
            shutil.copy(ROOT/'tests/sts2_resource_stats_fixture.gd',project/'fixture.gd')
            run=subprocess.run([str(godot),'--headless','--path',str(project),'--script','res://fixture.gd'],capture_output=True,text=True,timeout=20)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn('RESOURCE_STATS_FIXTURE_OK',run.stdout)

    def test_resource_stats_on_linux_arm64_engine(self):
        docker=shutil.which('docker')
        engine=ROOT/'.cache/sts2-vulkan-trial/official45/godot45.mono.aarch64'
        if not docker or not engine.is_file(): self.skipTest('Linux ARM64 engine unavailable')
        check=subprocess.run([docker,'image','inspect','--format','{{.Architecture}}','debian:bookworm-slim'],capture_output=True,text=True,timeout=10)
        if check.returncode or check.stdout.strip()!='arm64': self.skipTest('local ARM64 image unavailable')
        with tempfile.TemporaryDirectory() as temp:
            project=Path(temp);(project/'project.godot').write_text('[application]\nconfig/name="Stats Linux fixture"\n')
            folder=project/'port_diagnostics';folder.mkdir()
            for name in ('resource_stats.gd','texture_diagnostic.gd','texture_diagnostic_runner.gd','font_cache_diagnostic.gd'):
                shutil.copy(ROOT/'ports/sts2/src/texture_diagnostics'/name,folder/name)
            shutil.copy(ROOT/'tests/sts2_resource_stats_fixture.gd',project/'fixture.gd')
            command=[docker,'run','--rm','--pull=never','--network=none','--read-only','-v',str(engine)+':/godot:ro','-v',str(project)+':/fixture:ro','--tmpfs','/tmp:rw,noexec,nosuid,size=32m','-e','XDG_DATA_HOME=/tmp/godot-data','debian:bookworm-slim','/godot','--headless','--path','/fixture','--script','res://fixture.gd']
            run=subprocess.run(command,capture_output=True,text=True,timeout=30)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn('RESOURCE_STATS_FIXTURE_OK',run.stdout)

    def test_cache_lookup_is_non_loading_and_does_not_pin(self):
        godot=Path(os.environ.get('STS2_TEST_GODOT',str(DEFAULT)))
        if not godot.is_file(): self.skipTest('Godot 4.5.1 unavailable')
        with tempfile.TemporaryDirectory() as temp:
            project=Path(temp)
            (project/'project.godot').write_text('[application]\nconfig/name="Cache fixture"\n')
            shutil.copy(ROOT/'tests/sts2_texture_cache_fixture.gd',project/'cache.gd')
            run=subprocess.run([str(godot),'--headless','--path',str(project),'--script','res://cache.gd'],capture_output=True,text=True,timeout=20)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn('TEXTURE_CACHE_FIXTURE_OK',run.stdout)

    def test_independent_diagnostic_pack_mounts(self):
        godot=Path(os.environ.get('STS2_TEST_GODOT',str(DEFAULT)))
        if not godot.is_file(): self.skipTest('Godot 4.5.1 unavailable')
        with tempfile.TemporaryDirectory() as temp:
            project=Path(temp)
            (project/'project.godot').write_text('[application]\nconfig/name="Texture pack fixture"\n')
            shutil.copy(ROOT/'tests/sts2_texture_diagnostic_mount_fixture.gd',project/'mount.gd')
            source='images/example.png'
            digest=hashlib.md5(('res://'+source).encode()).hexdigest()
            target='.godot/imported/example.png-'+digest+'.ctex'
            imp=project/'example.import';imp.write_text('[remap]\npath="res://'+target+'"\n')
            ctex=project/'texture';ctex.write_bytes(b'fixture')
            font_import=project/'font.import';font_target='.godot/imported/font.otf-test.fontdata'
            font_import.write_text('[remap]\ntype="FontFile"\npath="res://'+font_target+'"\n')
            font_file=project/'font';font_file.write_bytes(b'font fixture')
            shared=project/'shared';shared.write_text('[gd_resource type="FontVariation" format=3]\n')
            base=project/'source.pck';low.write_pack([(source+'.import',imp),(target,ctex),('fonts/example.otf.import',font_import),(font_target,font_file),('themes/shared.tres',shared)],base)
            report=project/'texture-report.json';report.write_text(json.dumps({'source_sha256':low.file_hash(base),'output_sha256':'0'*64,'resources':[{'kind':'texture','path':target,'source_path':source}]}))
            pack=project/'diagnostic.pck'
            build=subprocess.run(['python3',str(ROOT/'ports/sts2/src/scripts/make-texture-diagnostic-pck.py'),'--source-pck',str(base),'--texture-report',str(report),'--output',str(pack)],capture_output=True,text=True,timeout=10)
            self.assertEqual(build.returncode,0,build.stdout+build.stderr)
            run=subprocess.run([str(godot),'--headless','--path',str(project),'--script','res://mount.gd','--',str(pack)],capture_output=True,text=True,timeout=20)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn('DIAGNOSTIC_MOUNT_OK',run.stdout)
            self.assertLess(pack.stat().st_size,100000)
            directory=low.read_pack(pack)
            with pack.open('rb') as f: metadata=json.loads(low.entry_bytes(f,directory['port_diagnostics/texture_candidates.json']))
            self.assertEqual(set(metadata['font_paths']),{'res://fonts/example.otf','res://'+font_target,'res://themes/shared.tres'})

if __name__=='__main__': unittest.main()
