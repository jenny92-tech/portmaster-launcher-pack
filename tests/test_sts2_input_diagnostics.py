# INPUT: opt-in input diagnostics and isolated synthetic GodotSharp API
# OUTPUT: bounded aggregate-only diagnostics and inert disabled behavior
# POS: validates the diagnostic bridge without running game code
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
DOTNET = os.environ.get('STS2_PATCH_DOTNET')
FIXTURE = r'''
using System;
using System.Diagnostics;
using System.Reflection;
using STS2LinuxLauncher.Patches;
namespace Godot {
 public class Node {} public class InputEvent {} public class InputEventKey:InputEvent {} public class InputEventJoypadButton:InputEvent {} public class InputEventJoypadMotion:InputEvent {} public class InputEventMouse:InputEvent {} public class InputEventMouseButton:InputEventMouse {}
 public static class DisplayServer { public static bool WindowIsFocused(int id) => false; }
 public class Joypads:IDisposable { public int Count => 2; public void Dispose() { Input.Disposed++; } }
 public static class Input { public static int Disposed; public static Joypads GetConnectedJoypads()=>new(); }
}
public class Program {
 public static void Main(string[] args) {
  var n=new Godot.Node(); var key=new Godot.InputEventKey();
  InputDiagnostics.Observe(key); InputDiagnostics.Tick(n); InputDiagnostics.Start(n); InputDiagnostics.Start(n);
  InputDiagnostics.Observe(key); InputDiagnostics.Observe(new Godot.InputEventJoypadButton()); InputDiagnostics.Observe(new Godot.InputEventJoypadMotion()); InputDiagnostics.Observe(new Godot.InputEventMouseButton());
  foreach (int sec in new[]{16,31,46,61}) {
   typeof(InputDiagnostics).GetField("started",BindingFlags.NonPublic|BindingFlags.Static).SetValue(null,Stopwatch.GetTimestamp()-sec*Stopwatch.Frequency);
   InputDiagnostics.Tick(n);
  }
  InputDiagnostics.Observe(key); InputDiagnostics.Tick(n);
  if(Godot.Input.Disposed != (args.Length == 0 ? 5 : 0)) throw new Exception("cleanup or disabled state");
 }
}
'''

@unittest.skipUnless(DOTNET, 'set STS2_PATCH_DOTNET to a .NET 9 SDK')
class InputDiagnosticsTests(unittest.TestCase):
    def test_bounded_opt_in_counts_without_key_values(self):
        source = ROOT / 'ports/sts2/src/STS2LinuxLauncher/Patches/InputDiagnostics.cs'
        with tempfile.TemporaryDirectory(prefix='sts2-input-diag-') as tmp:
            path = Path(tmp)
            (path / 'Fixture.cs').write_text(FIXTURE)
            (path / 'Fixture.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net9.0</TargetFramework><AssemblyName>GodotSharp</AssemblyName></PropertyGroup><ItemGroup><Compile Include="' + escape(str(source), {'"': '&quot;'}) + '" Link="InputDiagnostics.cs"/></ItemGroup></Project>')
            config = path / 'NuGet.Config'
            config.write_text('<configuration><packageSources><clear/></packageSources></configuration>')
            env = dict(os.environ, DOTNET_CLI_HOME=str(path / 'cli'), DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_GENERATE_ASPNET_CERTIFICATE='false')
            subprocess.run([DOTNET, 'build', str(path / 'Fixture.csproj'), '-c', 'Release', '--nologo', '-v:q', '-p:NuGetAudit=false', '-p:RestoreConfigFile=' + str(config)], check=True, env=env, capture_output=True, text=True)
            dll = path / 'bin/Release/net9.0/GodotSharp.dll'
            on = subprocess.run([DOTNET, str(dll)], check=True, env={**env, 'SLL_INPUT_DIAG':'1'}, capture_output=True, text=True)
            lines = on.stderr.splitlines()
            self.assertEqual(len(lines), 5)
            self.assertIn('phase=start elapsed_s=0 focused=false joypads=2', lines[0])
            self.assertIn('focused=false joypads=2 key=1 joy_button=1 joy_motion=1 mouse=1 other=0', lines[-1])
            off = subprocess.run([DOTNET, str(dll), 'disabled'], check=True, env={**env, 'SLL_INPUT_DIAG':'0'}, capture_output=True, text=True)
            self.assertEqual(off.stderr, '')
