# INPUT: Cecil verifier, synthetic assemblies and a self-owned pack
# OUTPUT: exact embedded resource binding and fail-closed regression
# POS: offline only; does not execute any game or compatibility assembly
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
DOTNET = os.environ.get('STS2_PATCH_DOTNET')
TOOL = ROOT / 'ports/sts2/src/tools/dll_surgery/official_runtime/bin/Release/net9.0'

@unittest.skipUnless(DOTNET and (TOOL / 'official_runtime.dll').exists(), 'build official_runtime and set STS2_PATCH_DOTNET')
class TextureDiagnosticBindingTests(unittest.TestCase):
    def test_exact_resource_and_failures(self):
        with tempfile.TemporaryDirectory(prefix='sts2-texture-binding-') as tmp:
            path = Path(tmp)
            source = '''using Mono.Cecil;
const string name = "STS2LinuxLauncher.TextureDiagnostic.pck";
foreach (string kind in new[] {"ok", "missing", "duplicate", "mismatch", "linked"}) {
 using var a = AssemblyDefinition.CreateAssembly(new AssemblyNameDefinition("fixture", new Version(1,0)), "fixture", ModuleKind.Dll);
 if (kind == "linked") a.MainModule.Resources.Add(new LinkedResource(name, ManifestResourceAttributes.Private));
 else if (kind != "missing") {
  byte[] data = System.Text.Encoding.UTF8.GetBytes(kind == "mismatch" ? "fixturf" : "fixture");
  a.MainModule.Resources.Add(new EmbeddedResource(name, ManifestResourceAttributes.Private, data));
  if (kind == "duplicate") a.MainModule.Resources.Add(new EmbeddedResource(name, ManifestResourceAttributes.Private, data));
 }
 a.Write(Path.Combine(args[0], kind + ".dll"));
}'''
            (path / 'Program.cs').write_text(source)
            (path / 'Fixture.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net9.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings></PropertyGroup><ItemGroup><Reference Include="Mono.Cecil"><HintPath>' + escape(str(TOOL / 'Mono.Cecil.dll'), {'"':'&quot;'}) + '</HintPath></Reference></ItemGroup></Project>')
            (path / 'NuGet.Config').write_text('<configuration><packageSources><clear/></packageSources></configuration>')
            env = dict(os.environ, DOTNET_CLI_HOME=str(path / 'cli'), DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_GENERATE_ASPNET_CERTIFICATE='false')
            subprocess.run([DOTNET, 'build', str(path / 'Fixture.csproj'), '-c', 'Release', '--nologo', '-v:q', '-p:NuGetAudit=false', '-p:RestoreConfigFile=' + str(path / 'NuGet.Config')], check=True, env=env, capture_output=True, text=True)
            subprocess.run([DOTNET, str(path / 'bin/Release/net9.0/Fixture.dll'), str(path)], check=True, env=env, capture_output=True, text=True)
            pack = path / 'fixture.pck'
            pack.write_bytes(b'fixture')
            command = [DOTNET, str(TOOL / 'official_runtime.dll'), 'verify-texture-diagnostic']
            before = {p: hashlib.sha256(p.read_bytes()).digest() for p in [pack, *(path / (s + '.dll') for s in ('ok', 'missing', 'duplicate', 'mismatch', 'linked'))]}
            ok = subprocess.run([*command, str(path / 'ok.dll'), str(pack)], check=True, capture_output=True, text=True)
            self.assertEqual(json.loads(ok.stdout), {'resource':'STS2LinuxLauncher.TextureDiagnostic.pck', 'sha256':hashlib.sha256(b'fixture').hexdigest(), 'size_bytes':7})
            for kind in ('missing', 'duplicate', 'mismatch', 'linked'):
                with self.subTest(kind=kind):
                    result = subprocess.run([*command, str(path / (kind + '.dll')), str(pack)], capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('mismatch' if kind == 'mismatch' else 'exactly one embedded', result.stderr)
            pack.write_bytes(b'fixtures')
            bad_size = subprocess.run([*command, str(path / 'ok.dll'), str(pack)], capture_output=True, text=True)
            self.assertNotEqual(bad_size.returncode, 0)
            self.assertIn('size mismatch', bad_size.stderr)
            pack.write_bytes(b'fixture')
            self.assertEqual(before, {p: hashlib.sha256(p.read_bytes()).digest() for p in before})

if __name__ == '__main__':
    unittest.main()
