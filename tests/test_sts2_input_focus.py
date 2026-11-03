# INPUT: explicit Loong focus policy, Cecil hook and synthetic game assembly
# OUTPUT: original focus and overlay semantics with opt-in compatibility
# POS: verifies the guarded input hook without executing game code
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'ports/sts2/src/tools/dll_surgery/official_runtime'
DOTNET = os.environ.get('STS2_PATCH_DOTNET')
GAME = r'''
using System;
namespace Godot { public static class DisplayServer { public static bool Focused; public static bool WindowIsFocused(int id) => Focused; } }
namespace MegaCrit.Sts2.Core.Platform { public static class PlatformUtil { public static bool Overlay; public static bool IsPlatformOverlayOpen() => Overlay; } }
namespace MegaCrit.Sts2.Core.Nodes { public static class NGame {
 public static bool IsGameFocusedWindow() { return !MegaCrit.Sts2.Core.Platform.PlatformUtil.IsPlatformOverlayOpen() && Godot.DisplayServer.WindowIsFocused(0); }
} }
public static class Program { public static void Main(string[] args) {
 MegaCrit.Sts2.Core.Platform.PlatformUtil.Overlay = args[0] == "1"; Godot.DisplayServer.Focused = args[1] == "1";
 bool expected = args[2] == "1"; if (MegaCrit.Sts2.Core.Nodes.NGame.IsGameFocusedWindow() != expected) throw new Exception("focus result");
 Console.WriteLine("PASS");
} }
'''
PATCHER = r'''
using Mono.Cecil;
using var resolver = new DefaultAssemblyResolver();
resolver.AddSearchDirectory(System.IO.Path.GetDirectoryName(args[0]));
resolver.AddSearchDirectory(System.IO.Path.GetDirectoryName(args[1]));
resolver.AddSearchDirectory(System.IO.Path.GetDirectoryName(typeof(object).Assembly.Location));
using var game = AssemblyDefinition.ReadAssembly(args[0], new ReaderParameters {AssemblyResolver=resolver});
using var compat = AssemblyDefinition.ReadAssembly(args[1], new ReaderParameters {AssemblyResolver=resolver});
InputFocusHooks.Inject(game, compat);
try { InputFocusHooks.Inject(game, compat); throw new Exception("duplicate accepted"); }
catch (InvalidOperationException) { }
game.Write(args[2]);
using var check = AssemblyDefinition.ReadAssembly(args[2]);
InputFocusHooks.Verify(check);
'''

@unittest.skipUnless(DOTNET, 'set STS2_PATCH_DOTNET to a .NET 9 SDK')
class InputFocusTests(unittest.TestCase):
    def test_focus_override_preserves_overlay_and_default(self):
        cecil = TOOL / 'bin/Release/net9.0/Mono.Cecil.dll'
        if not cecil.exists(): self.skipTest('build official_runtime Release first')
        with tempfile.TemporaryDirectory(prefix='sts2-focus-') as tmp:
            path = Path(tmp)
            (path / 'NuGet.Config').write_text('<configuration><packageSources><clear/></packageSources></configuration>')
            for name in ('compat', 'game', 'patcher'): (path / name).mkdir()
            q = lambda p: escape(str(p), {'"': '&quot;'})
            props = '<PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net9.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Optimize>true</Optimize></PropertyGroup>'
            policy = ROOT / 'ports/sts2/src/STS2LinuxLauncher/Patches/InputFocusPolicy.cs'
            (path / 'compat/compat.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net9.0</TargetFramework></PropertyGroup><ItemGroup><Compile Include="' + q(policy) + '" Link="Policy.cs"/></ItemGroup></Project>')
            (path / 'game/game.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk">' + props + '<ItemGroup><ProjectReference Include="../compat/compat.csproj"/></ItemGroup></Project>')
            (path / 'game/Program.cs').write_text(GAME)
            (path / 'patcher/patcher.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk">' + props + '<ItemGroup><Reference Include="Mono.Cecil"><HintPath>' + q(cecil) + '</HintPath></Reference><Reference Include="Mono.Cecil.Rocks"><HintPath>' + q(cecil.with_name('Mono.Cecil.Rocks.dll')) + '</HintPath></Reference><Compile Include="' + q(TOOL / 'InputFocusHooks.cs') + '" Link="Hooks.cs"/></ItemGroup></Project>')
            (path / 'patcher/Program.cs').write_text(PATCHER)
            env = dict(os.environ, DOTNET_CLI_HOME=str(path / 'cli'), DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_GENERATE_ASPNET_CERTIFICATE='false')
            for name in ('game', 'patcher'):
                subprocess.run([DOTNET, 'build', str(path / name), '-c', 'Release', '--nologo', '-v:q', '-p:NuGetAudit=false', '-p:RestoreConfigFile=' + str(path / 'NuGet.Config')], check=True, env=env, capture_output=True, text=True)
            game = path / 'game/bin/Release/net9.0/game.dll'
            patched = game.with_name('patched.dll')
            subprocess.run([DOTNET, str(path / 'patcher/bin/Release/net9.0/patcher.dll'), str(game), str(game.with_name('compat.dll')), str(patched)], check=True, env=env, capture_output=True, text=True)
            patched.replace(game)
            for flag in ('0', '1', 'unexpected'):
                for overlay in (False, True):
                    for focused in (False, True):
                        expected = not overlay and (focused or flag == '1')
                        args = [str(int(overlay)), str(int(focused)), str(int(expected))]
                        result = subprocess.run([DOTNET, str(game), *args], check=True, env={**env, 'SLL_LOONG_FOCUS_COMPAT':flag}, capture_output=True, text=True)
                        self.assertIn('PASS', result.stdout)
