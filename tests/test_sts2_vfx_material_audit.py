# INPUT:  offline Cecil audit tool, .NET SDK and synthetic managed assemblies
# OUTPUT: confirms clean and explicit turbulence/material references are reported
# POS:    no game code is executed or modified
import hashlib
import json
import os
from pathlib import Path
from xml.sax.saxutils import escape
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
DOTNET = os.environ.get('STS2_PATCH_DOTNET')
TOOL_SOURCE = ROOT / 'ports/sts2/src/tools/dll_surgery/official_runtime'
CECIL = TOOL_SOURCE / 'bin/Release/net9.0/Mono.Cecil.dll'


@unittest.skipUnless(DOTNET and CECIL.is_file(), 'set STS2_PATCH_DOTNET and provide locally built Mono.Cecil')
class VfxMaterialAuditTest(unittest.TestCase):
    def test_clean_and_explicit_references(self):
        with tempfile.TemporaryDirectory(prefix='sts2-vfx-audit-') as tmp:
            path = Path(tmp)
            tool_dir = path / 'tool'
            tool_dir.mkdir()
            q = lambda value: escape(str(value), {'"': '&quot;'})
            (tool_dir / 'Tool.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net9.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Nullable>enable</Nullable></PropertyGroup><ItemGroup><Reference Include="Mono.Cecil"><HintPath>' + q(CECIL) + '</HintPath></Reference><Reference Include="Mono.Cecil.Rocks"><HintPath>' + q(CECIL.with_name('Mono.Cecil.Rocks.dll')) + '</HintPath></Reference><Compile Include="' + q(TOOL_SOURCE / 'Program.cs') + '" Link="Program.cs"/><Compile Include="' + q(TOOL_SOURCE / 'AtlasMemoryHooks.cs') + '" Link="AtlasMemoryHooks.cs"/></ItemGroup></Project>')
            (path / 'Fixture.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net9.0</TargetFramework><EnableDefaultCompileItems>false</EnableDefaultCompileItems></PropertyGroup><ItemGroup><Compile Include="Fixture.cs"/></ItemGroup></Project>')
            (path / 'NuGet.Config').write_text('<configuration><packageSources><clear/></packageSources></configuration>')
            env = dict(os.environ, DOTNET_CLI_HOME=str(path / 'cli'), DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_GENERATE_ASPNET_CERTIFICATE='false')
            subprocess.run([DOTNET, 'build', str(tool_dir / 'Tool.csproj'), '-c', 'Release', '--nologo', '-v:q', '-p:NuGetAudit=false', '-p:RestoreConfigFile=' + str(path / 'NuGet.Config')], check=True, env=env, capture_output=True, text=True)
            tool = tool_dir / 'bin/Release/net9.0/Tool.dll'
            samples = [
                ('public class Clean { public int Value() => 42; }', False),
                ('''public class ParticleProcessMaterial { public bool TurbulenceEnabled {get; set;} }
public class Dirty { public bool Use(ParticleProcessMaterial m) { m.TurbulenceEnabled = true; return m.TurbulenceEnabled; }
public string DynamicName() => "turbulence_enabled"; }''', True),
            ]
            for source, dirty in samples:
                (path / 'Fixture.cs').write_text(source)
                subprocess.run([DOTNET, 'build', str(path / 'Fixture.csproj'), '-c', 'Release', '--nologo', '-v:q', '-p:NuGetAudit=false', '-p:RestoreConfigFile=' + str(path / 'NuGet.Config')], check=True, env=env, capture_output=True, text=True)
                assembly = path / 'bin/Release/net9.0/Fixture.dll'
                run = subprocess.run([DOTNET, str(tool), 'inspect-vfx-material-usage', str(assembly)], check=True, env=env, capture_output=True, text=True)
                report = json.loads(run.stdout)
                self.assertEqual(report['source_sha256'], hashlib.sha256(assembly.read_bytes()).hexdigest())
                self.assertGreater(report['methods_scanned'], 0)
                flags = report['turbulence_flag_accesses']
                if dirty:
                    operands = [entry['operand'] for entry in flags]
                    self.assertTrue(any('get_TurbulenceEnabled' in x for x in operands))
                    self.assertTrue(any('set_TurbulenceEnabled' in x for x in operands))
                    self.assertIn('turbulence_enabled', operands)
                    self.assertTrue(report['process_material_references'])
                else:
                    self.assertEqual(flags, [])
                    self.assertEqual(report['process_material_references'], [])
                self.assertIn('Static IL only', report['limitation'])


if __name__ == '__main__':
    unittest.main()
