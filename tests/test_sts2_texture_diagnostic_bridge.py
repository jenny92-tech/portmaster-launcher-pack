# INPUT: optional .NET SDK and the real texture diagnostic bridge
# OUTPUT: default-off, mount/load failure isolation and scene installation checks
# POS: synthetic Godot API fixture; never loads the game
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
DOTNET = os.environ.get("STS2_PATCH_DOTNET")
FIXTURE = r'''
using System;
using System.IO;
using STS2LinuxLauncher.Patches;
namespace Godot {
 public static class ProjectSettings {
  public static int Calls; public static bool Result = true;
  public static bool LoadResourcePack(string path, bool replaceFiles=true, int offset=0) {
   Calls++; if (!Path.GetFileName(path).StartsWith("sts2-texture-diag-") || File.ReadAllText(path) != "fixture" || replaceFiles || offset != 0) throw new Exception("mount contract"); return Result;
  }
 }
 public class Node { public int Children; public void AddChild(Node node, bool force=false, int mode=0) { if (node == null || force || mode != 0) throw new Exception("child contract"); Children++; } }
 public class PackedScene { public Node Instantiate(int mode=0) { if (mode != 0) throw new Exception("instantiate contract"); return new Node(); } }
 public static class ResourceLoader {
  public static int Calls; public static bool Missing;
  public static PackedScene Load(string path, string typeHint="", int cacheMode=0) {
   Calls++; if (path != "res://port_diagnostics/texture_diagnostic.tscn" || typeHint != "" || cacheMode != 0) throw new Exception("load contract");
   return Missing ? null : new PackedScene();
  }
 }
}
public static class Program {
 public static void Main(string[] args) {
  string mode = args[0], dir = args[1]; var root = new Godot.Node();
  Environment.SetEnvironmentVariable("SLL_TEXTURE_DIAG", mode == "off" ? "0" : "1");
  Godot.ProjectSettings.Result = mode != "mount_fail"; Godot.ResourceLoader.Missing = mode == "scene_fail";
  TextureDiagnosticBridge.Install(typeof(Godot.Node).Assembly, root);
  TextureDiagnosticBridge.Install(typeof(Godot.Node).Assembly, root);
  int mount = mode == "off" || mode == "missing" ? 0 : 1;
  int load = mode == "ok" || mode == "scene_fail" ? 1 : 0;
  int children = mode == "ok" ? 1 : 0;
  if (Godot.ProjectSettings.Calls != mount || Godot.ResourceLoader.Calls != load || root.Children != children) throw new Exception("unexpected bridge calls");
  if (mode != "off" && mode != "missing" && Directory.GetFiles(dir, "sts2-texture-diag-*.pck").Length != 1) throw new Exception("pack not retained until exit");
  Console.WriteLine("PASS " + mode);
 }
}
'''

@unittest.skipUnless(DOTNET, "set STS2_PATCH_DOTNET to a .NET 9 SDK")
class TextureDiagnosticBridgeTests(unittest.TestCase):
    def test_opt_in_and_failures(self):
        source = ROOT / "ports/sts2/src/STS2LinuxLauncher/Patches/TextureDiagnosticBridge.cs"
        with tempfile.TemporaryDirectory(prefix="sts2-texture-diag-") as directory:
            path = Path(directory)
            (path / "Fixture.cs").write_text(FIXTURE)
            (path / "fixture.pck").write_text("fixture")
            (path / "Fixture.csproj").write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net9.0</TargetFramework></PropertyGroup><ItemGroup><Compile Include="' + escape(str(source), {'"': '&quot;'}) + '" Link="TextureDiagnosticBridge.cs"/><EmbeddedResource Include="fixture.pck" Condition="&apos;$(NoPack)&apos; != &apos;1&apos;" LogicalName="STS2LinuxLauncher.TextureDiagnostic.pck"/></ItemGroup></Project>')
            config = path / "NuGet.Config"
            config.write_text('<configuration><packageSources><clear/></packageSources></configuration>')
            env = dict(os.environ, DOTNET_CLI_HOME=str(path / "cli"), DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_GENERATE_ASPNET_CERTIFICATE="false")
            subprocess.run([DOTNET, "build", str(path / "Fixture.csproj"), "-c", "Release", "--nologo", "-v:q", "-p:NuGetAudit=false", "-p:RestoreConfigFile=" + str(config)], check=True, env=env, capture_output=True, text=True)
            dll = path / "bin/Release/net9.0/Fixture.dll"
            for mode in ("off", "mount_fail", "scene_fail", "ok"):
                with self.subTest(mode=mode), tempfile.TemporaryDirectory(dir=directory) as game:
                    run = subprocess.run([DOTNET, str(dll), mode, game], check=True, env=dict(env, TMPDIR=game), capture_output=True, text=True)
                    self.assertIn("PASS " + mode, run.stdout)
                    self.assertEqual("[TEXTURE-DIAG]" in run.stderr, mode != "off")
                    self.assertEqual(list(Path(game).glob("sts2-texture-diag-*.pck")), [])
            subprocess.run([DOTNET, "build", str(path / "Fixture.csproj"), "-c", "Release", "--nologo", "-v:q", "-p:NoPack=1", "-t:Rebuild", "-p:NuGetAudit=false", "-p:RestoreConfigFile=" + str(config)], check=True, env=env, capture_output=True, text=True)
            with tempfile.TemporaryDirectory(dir=directory) as game:
                run = subprocess.run([DOTNET, str(dll), "missing", game], check=True, env=dict(env, TMPDIR=game), capture_output=True, text=True)
                self.assertIn("embedded diagnostic pack missing", run.stderr)
                self.assertEqual(list(Path(game).iterdir()), [])

if __name__ == "__main__":
    unittest.main()
