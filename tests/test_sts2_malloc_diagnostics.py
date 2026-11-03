# INPUT: local C compiler, optional .NET SDK and actual diagnostic marshalling
# OUTPUT: validates native struct-return layout and unsigned values without the game
# POS: synthetic ABI fixture only; does not inspect a running process
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
DOTNET = os.environ.get('STS2_PATCH_DOTNET')
CC = shutil.which('cc')

@unittest.skipUnless(DOTNET and CC, 'set STS2_PATCH_DOTNET and install a C compiler')
class MallocDiagnosticsTests(unittest.TestCase):
    def test_native_struct_return_and_unsigned_format(self):
        with tempfile.TemporaryDirectory(prefix='sts2-malloc-abi-') as tmp:
            path = Path(tmp)
            (path / 'fake.c').write_text('''#include <stddef.h>\n#include <stdint.h>\nstruct info { size_t arena, ordblks, smblks, hblks, hblkhd, usmblks, fsmblks, uordblks, fordblks, keepcost; };\nstruct info fixture(void) { struct info v = {(size_t)0xfedcba9876543210ULL, 1, 2, 3, 0x400000004ULL, 5, 6, 0x100000001ULL, 0x200000002ULL, 9}; return v; }\n''')
            dylib = path / 'fake.so'
            subprocess.run([CC, '-shared', '-fPIC', str(path / 'fake.c'), '-o', str(dylib)], check=True, capture_output=True, text=True)
            source = ROOT / 'ports/sts2/src/STS2LinuxLauncher/Patches/AssetCacheDiagnostics.cs'
            (path / 'Fixture.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net9.0</TargetFramework></PropertyGroup><ItemGroup><Compile Include="' + escape(str(source), {'"':'&quot;'}) + '" Link="Diagnostics.cs"/></ItemGroup></Project>')
            (path / 'Program.cs').write_text('''using System; using System.Runtime.InteropServices; using STS2LinuxLauncher.Patches;\nvar lib = NativeLibrary.Load(args[0]); try { Console.WriteLine(AssetCacheDiagnostics.FormatMallinfo2(NativeLibrary.GetExport(lib, "fixture"))); } finally { NativeLibrary.Free(lib); }\n''')
            config = path / 'NuGet.Config'
            config.write_text('<configuration><packageSources><clear/></packageSources></configuration>')
            env = dict(os.environ, DOTNET_CLI_HOME=str(path / 'cli'), DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_GENERATE_ASPNET_CERTIFICATE='false')
            subprocess.run([DOTNET, 'build', str(path / 'Fixture.csproj'), '-c', 'Release', '--nologo', '-v:q', '-p:NuGetAudit=false', '-p:RestoreConfigFile=' + str(config)], check=True, env=env, capture_output=True, text=True)
            run = subprocess.run([DOTNET, str(path / 'bin/Release/net9.0/Fixture.dll'), str(dylib)], check=True, env=env, capture_output=True, text=True)
            self.assertEqual(run.stdout.strip(), 'malloc=mallinfo2 arena_bytes=18364758544493064720 uordblks_bytes=4294967297 fordblks_bytes=8589934594 hblkhd_bytes=17179869188')

if __name__ == '__main__':
    unittest.main()
