# INPUT: isolated synthetic Godot controls and optional observer
# OUTPUT: inert default, safe metadata, redaction and bounded UI strings
# POS: host-only; no game, device, screenshots or input injection
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid

ROOT=Path(__file__).resolve().parents[1]
DEFAULT=ROOT/'.cache/sts2-vulkan-trial/build-tools/godot-4.5.1-macos/Godot.app/Contents/MacOS/Godot'
class UiDiagnosticTests(unittest.TestCase):
    def test_control_snapshot_is_inert_and_skips_sensitive_nodes(self):
        godot=Path(os.environ.get('STS2_TEST_GODOT',str(DEFAULT)))
        if not godot.is_file():self.skipTest('Godot 4.5.1 unavailable')
        with tempfile.TemporaryDirectory() as temp:
            project=Path(temp)
            (project/'project.godot').write_text('[application]\nconfig/name="UI diagnostic fixture"\n')
            shutil.copy(ROOT/'ports/sts2/src/texture_diagnostics/ui_diagnostic.gd',project/'ui_diagnostic.gd')
            shutil.copy(ROOT/'tests/sts2_ui_diagnostic_fixture.gd',project/'fixture.gd')
            run=subprocess.run([str(godot),'--headless','--path',str(project),'--script','res://fixture.gd'],capture_output=True,text=True,timeout=20)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn('UI_DIAGNOSTIC_FIXTURE_OK',run.stdout)

    def test_isolated_gate_checks_real_user_directory_and_symlinks(self):
        godot=Path(os.environ.get('STS2_TEST_GODOT',str(DEFAULT)))
        if not godot.is_file():self.skipTest('Godot 4.5.1 unavailable')
        with tempfile.TemporaryDirectory() as temp:
            isolated=str(Path('/tmp')/('sts2-memory-diag-'+uuid.uuid4().hex))
            linked=str(Path('/tmp')/('sts2-memory-diag-'+uuid.uuid4().hex))
            Path(isolated).mkdir();Path(linked).mkdir()
            self.addCleanup(shutil.rmtree,isolated,ignore_errors=True)
            self.addCleanup(shutil.rmtree,linked,ignore_errors=True)
            project=Path(temp);(project/'project.godot').write_text('[application]\nconfig/name="UI gate fixture"\n')
            folder=project/'port_diagnostics';folder.mkdir()
            for name in ('texture_diagnostic_runner.gd','texture_diagnostic.gd','resource_stats.gd'):
                shutil.copy(ROOT/'ports/sts2/src/texture_diagnostics'/name,folder/name)
            shutil.copy(ROOT/'tests/sts2_ui_diag_gate_fixture.gd',project/'gate.gd')
            (Path(isolated)/'data'/'SlayTheSpire2').mkdir(parents=True)
            (Path(linked)/'data').symlink_to(Path(isolated)/'data',target_is_directory=True)
            run=subprocess.run([str(godot),'--headless','--path',str(project),'--script','res://gate.gd','--',isolated,linked],capture_output=True,text=True,timeout=20)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn('UI_DIAG_GATE_FIXTURE_OK',run.stdout)

    def test_linux_process_requires_both_opt_ins(self):
        docker=shutil.which('docker')
        engine=ROOT/'.cache/sts2-vulkan-trial/official45/godot45.mono.aarch64'
        if not docker or not engine.is_file():self.skipTest('local Docker or Linux ARM64 Godot fixture unavailable')
        image=subprocess.run([docker,'image','inspect','--format','{{.Architecture}}','debian:bookworm-slim'],capture_output=True,text=True,timeout=10)
        if image.returncode or image.stdout.strip()!='arm64':self.skipTest('local ARM64 Debian image unavailable; no image is pulled')
        with tempfile.TemporaryDirectory() as temp:
            project=Path(temp)
            isolated=str(Path('/tmp')/('sts2-memory-diag-'+uuid.uuid4().hex))
            Path(isolated).mkdir(mode=0o700)
            self.addCleanup(shutil.rmtree,isolated,ignore_errors=True)
            (Path(isolated)/'data'/'SlayTheSpire2').mkdir(parents=True)
            (project/'project.godot').write_text('[application]\nconfig/name="UI gate"\nconfig/use_custom_user_dir=true\nconfig/custom_user_dir_name="SlayTheSpire2"\n')
            folder=project/'port_diagnostics';folder.mkdir()
            for name in ('texture_diagnostic_runner.gd','texture_diagnostic.gd','ui_diagnostic.gd','ui_diagnostic.tscn','resource_stats.gd'):
                shutil.copy(ROOT/'ports/sts2/src/texture_diagnostics'/name,folder/name)
            shutil.copy(ROOT/'tests/sts2_ui_diag_linux_integration.gd',project/'gate.gd')
            shutil.copy(ROOT/'tests/sts2_ui_diagnostic_fixture.gd',project/'native-getter.gd')
            shutil.copy(ROOT/'ports/sts2/src/texture_diagnostics/ui_diagnostic.gd',project/'ui_diagnostic.gd')
            for texture,ui in ((0,0),(1,0),(0,1),(1,1)):
                expected='enabled' if texture and ui else 'disabled'
                command=[docker,'run','--rm','--pull=never','--network=none','--read-only',
                    '-v',str(engine)+':/godot:ro','-v',str(project)+':/fixture:ro',
                    '-v',isolated+':'+isolated+':rw','--tmpfs','/tmp:rw,noexec,nosuid,size=32m',
                    '-e','XDG_DATA_HOME='+isolated+'/data','-e','SLL_DIAG_XDG_ROOT='+isolated,
                    '-e','SLL_TEXTURE_DIAG='+str(texture),'-e','SLL_UI_DIAG='+str(ui),
                    'debian:bookworm-slim','/godot','--headless','--path','/fixture','--script','res://gate.gd','--',isolated,expected]
                with self.subTest(texture=texture,ui=ui):
                    run=subprocess.run(command,capture_output=True,text=True,timeout=30)
                    self.assertEqual(run.returncode,0,run.stdout+run.stderr)
                    self.assertIn('LINUX_UI_DIAGNOSTIC_GATE_OK '+expected,run.stdout)
            native_command=[docker,'run','--rm','--pull=never','--network=none','--read-only',
                '-v',str(engine)+':/godot:ro','-v',str(project)+':/fixture:ro',
                '-v',isolated+':'+isolated+':rw','--tmpfs','/tmp:rw,noexec,nosuid,size=32m',
                '-e','XDG_DATA_HOME='+isolated+'/data',
                'debian:bookworm-slim','/godot','--headless','--path','/fixture','--script','res://native-getter.gd']
            native=subprocess.run(native_command,capture_output=True,text=True,timeout=30)
            self.assertEqual(native.returncode,0,native.stdout+native.stderr)
            self.assertIn('UI_DIAGNOSTIC_FIXTURE_OK',native.stdout)
            shutil.copy(ROOT/'tests/sts2_ui_control_linux_fixture.gd',project/'control.gd')
            control_command=native_command.copy()
            control_command[control_command.index('debian:bookworm-slim'):control_command.index('debian:bookworm-slim')]=[
                '-e','SLL_DIAG_XDG_ROOT='+isolated,'-e','SLL_TEXTURE_DIAG=1',
                '-e','SLL_UI_DIAG=1','-e','SLL_UI_CONTROL=1']
            control_command[-1]='res://control.gd'
            control=subprocess.run(control_command,capture_output=True,text=True,timeout=30)
            self.assertEqual(control.returncode,0,control.stdout+control.stderr)
            self.assertIn('LINUX_UI_CONTROL_FIXTURE_OK',control.stdout)

if __name__=='__main__':unittest.main()
