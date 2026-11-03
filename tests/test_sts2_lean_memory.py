# INPUT:  可选 STS2_PATCH_DOTNET、Cecil 与真实内存策略和图集注入源码
# OUTPUT: 显式模式、原生预取和按需查询的隔离 .NET 回归
# POS:    在替身程序集验证低内存图集边界及缓存重载，不运行游戏
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
DOTNET = os.environ.get("STS2_PATCH_DOTNET")
TOOL = ROOT / "ports/sts2/src/tools/dll_surgery/official_runtime"

GAME = r'''
using System;
using System.Collections.Generic;
using STS2LinuxLauncher;
namespace Godot { public class AtlasTexture {} }
namespace MegaCrit.Sts2.Core.Assets {
 public static class AtlasManager {
  static HashSet<string> loaded = new();
  public static int loads;
  public static void LoadAllAtlases() { foreach (var x in new[]{"ui_atlas", "compressed", "card_atlas", "power_atlas", "intent_atlas", "relic_atlas", "potion_atlas", "epoch_atlas"}) LoadAtlas(x); }
  public static void LoadEssentialAtlases() { LoadAtlas("ui_atlas"); LoadAtlas("compressed"); }
  public static void LoadAtlas(string name) { if (loaded.Add(name)) loads++; }
  public static Godot.AtlasTexture GetSprite(string name, string sprite) => loaded.Contains(name) ? new() : null;
  public static bool HasSprite(string name, string sprite) => loaded.Contains(name);
  public static int GetSpriteCount(string name) => loaded.Contains(name) ? 1 : 0;
  public static void Clear() => loaded.Clear();
 }
}
public static class Program {
 public static void Main(string[] args) {
  bool low = args[0] == "low";
  if (MemoryBudget.ExplicitLowMode != low || MemoryBudget.FullLoadAllowed != (!low && MemoryBudget.TotalMB >= MemoryBudget.FullLoadFloorMB)) throw new Exception("policy");
  var a = typeof(MegaCrit.Sts2.Core.Assets.AtlasManager);
  MegaCrit.Sts2.Core.Assets.AtlasManager.LoadAllAtlases();
  int startup = MegaCrit.Sts2.Core.Assets.AtlasManager.loads;
  if (startup != (low ? 7 : 8)) throw new Exception("startup " + startup);
  if (!MegaCrit.Sts2.Core.Assets.AtlasManager.HasSprite("epoch_atlas", "x") || MegaCrit.Sts2.Core.Assets.AtlasManager.GetSpriteCount("epoch_atlas") != 1 || MegaCrit.Sts2.Core.Assets.AtlasManager.GetSprite("epoch_atlas", "x") == null) throw new Exception("query");
  if (MegaCrit.Sts2.Core.Assets.AtlasManager.loads != 8) throw new Exception("duplicate load");
  if (low) {
   MegaCrit.Sts2.Core.Assets.AtlasManager.Clear();
   if (MegaCrit.Sts2.Core.Assets.AtlasManager.GetSprite("epoch_atlas", "x") == null || MegaCrit.Sts2.Core.Assets.AtlasManager.loads != 9) throw new Exception("sprite reload after clear");
   MegaCrit.Sts2.Core.Assets.AtlasManager.Clear();
   if (MegaCrit.Sts2.Core.Assets.AtlasManager.GetSpriteCount("epoch_atlas") != 1 || MegaCrit.Sts2.Core.Assets.AtlasManager.loads != 10) throw new Exception("count reload after clear");
   MegaCrit.Sts2.Core.Assets.AtlasManager.Clear();
   if (!MegaCrit.Sts2.Core.Assets.AtlasManager.HasSprite("epoch_atlas", "x") || MegaCrit.Sts2.Core.Assets.AtlasManager.loads != 11) throw new Exception("has reload after clear");
  }
  Console.WriteLine("PASS " + args[0]);
 }
}
'''
PATCHER = r'''
using Mono.Cecil;
using var resolver = new DefaultAssemblyResolver();
resolver.AddSearchDirectory(System.IO.Path.GetDirectoryName(args[0]));
resolver.AddSearchDirectory(System.IO.Path.GetDirectoryName(args[1]));
resolver.AddSearchDirectory(System.IO.Path.GetDirectoryName(typeof(object).Assembly.Location));
using var game = AssemblyDefinition.ReadAssembly(args[0], new ReaderParameters {AssemblyResolver=resolver});
using var compat = AssemblyDefinition.ReadAssembly(args[1], new ReaderParameters {AssemblyResolver=resolver});
AtlasMemoryHooks.Inject(game, compat);
game.Write(args[2]);
using var check = AssemblyDefinition.ReadAssembly(args[2]);
AtlasMemoryHooks.Verify(check);
'''

ENTRY_FIXTURE = r'''
using System;
using HarmonyLib;
using STS2LinuxLauncher;
using STS2LinuxLauncher.Patches;
namespace HarmonyLib { public class Harmony { public Harmony(string id) {} } }
namespace STS2LinuxLauncher {
 public static class QualityProfile { public static void LogChosen() {} }
}
namespace STS2LinuxLauncher.Patches {
 public static class LifecyclePreloadPatches { public static int Count; public static void Apply(Harmony h) => Count++; }
 public static class AtlasLazyPatches { public static int Count; public static void Apply(Harmony h) => Count++; }
 public static class ShaderCompatibilityPatches { public static bool LoadStaticOverlay() => true; }
 public static class ParticleDietPatches { public static void ApplyOfficialRuntime() {} public static void Apply(Harmony h) {} }
 public static class RenderPreparationBridge { public static void Install() {} }
 public static class FirstCardTrace { public static void Install() {} }
 public static class MemoryProbePatches { public static void Apply(Harmony h) {} }
 public static class PlatformPatches { public static void Apply(Harmony h) {} }
 public static class TransitionMaterialPatches { public static void Apply(Harmony h) {} }
 public static class MenuDietPatches { public static void Apply(Harmony h) {} }
 public static class GameSettingsDefaultPatches { public static void Apply(Harmony h) {} }
}
public static class Program {
 public static void Main(string[] args) {
  bool low = args[0] == "low";
  if (args[1] == "official") { ModEntry.ApplyOfficialRuntime(); ModEntry.ApplyOfficialRuntime(); }
  else { ModEntry.ApplyInternal(); ModEntry.ApplyInternal(); }
  int expected = args[1] == "official" && low ? 0 : 1;
  if (LifecyclePreloadPatches.Count != expected || AtlasLazyPatches.Count != expected)
   throw new Exception($"preload={LifecyclePreloadPatches.Count} atlas={AtlasLazyPatches.Count} expected={expected}");
  Console.WriteLine("PASS " + args[0] + " " + args[1]);
 }
}
'''

@unittest.skipUnless(DOTNET, "set STS2_PATCH_DOTNET to a .NET 9 SDK")
class LeanMemoryTests(unittest.TestCase):
    def test_official_low_avoids_harmony_and_legacy_keeps_it(self):
        with tempfile.TemporaryDirectory(prefix="sts2-memory-entry-") as tmp:
            path = Path(tmp)
            sources = ROOT / "ports/sts2/src/STS2LinuxLauncher"
            q = lambda p: escape(str(p), {'"': '&quot;'})
            (path / "Program.cs").write_text(ENTRY_FIXTURE)
            (path / "Fixture.csproj").write_text(
                '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net9.0</TargetFramework></PropertyGroup><ItemGroup>' +
                ''.join('<Compile Include="' + q(sources / name) + '" Link="' + name + '"/>' for name in ("MemoryBudget.cs", "ModEntry.cs")) +
                '</ItemGroup></Project>')
            (path / "NuGet.Config").write_text('<configuration><packageSources><clear/></packageSources></configuration>')
            env = dict(os.environ, DOTNET_CLI_HOME=str(path / "cli"), DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_GENERATE_ASPNET_CERTIFICATE="false")
            subprocess.run([DOTNET, "build", str(path / "Fixture.csproj"), "-c", "Release", "--nologo", "-v:q", "-p:NuGetAudit=false", "-p:RestoreConfigFile=" + str(path / "NuGet.Config")], check=True, env=env, capture_output=True, text=True)
            dll = path / "bin/Release/net9.0/Fixture.dll"
            for mode, entry in (("low", "official"), ("auto", "official"), ("low", "legacy"), ("auto", "legacy")):
                run = subprocess.run([DOTNET, str(dll), mode, entry], check=True, env={**env, "SLL_MEMORY_MODE": mode}, capture_output=True, text=True)
                self.assertIn("PASS " + mode + " " + entry, run.stdout)

    def test_modes_and_injected_atlas_queries(self):
        cecil = TOOL / "bin/Release/net9.0/Mono.Cecil.dll"
        if not cecil.exists():
            self.skipTest("build official_runtime Release first")
        with tempfile.TemporaryDirectory(prefix="sts2-lean-memory-") as tmp:
            path = Path(tmp)
            (path / "NuGet.Config").write_text('<configuration><packageSources><clear/></packageSources></configuration>')
            for name in ("compat", "game", "patcher"):
                (path / name).mkdir()
            q = lambda p: escape(str(p), {'"': '&quot;'})
            props = '<PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net9.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings></PropertyGroup>'
            memory = ROOT / "ports/sts2/src/STS2LinuxLauncher/MemoryBudget.cs"
            (path / "compat/compat.csproj").write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net9.0</TargetFramework></PropertyGroup><ItemGroup><Compile Include="' + q(memory) + '" Link="MemoryBudget.cs"/></ItemGroup></Project>')
            (path / "game/game.csproj").write_text('<Project Sdk="Microsoft.NET.Sdk">' + props + '<ItemGroup><ProjectReference Include="../compat/compat.csproj"/></ItemGroup></Project>')
            (path / "game/Program.cs").write_text(GAME)
            (path / "patcher/patcher.csproj").write_text('<Project Sdk="Microsoft.NET.Sdk">' + props + '<ItemGroup><Reference Include="Mono.Cecil"><HintPath>' + q(cecil) + '</HintPath></Reference><Reference Include="Mono.Cecil.Rocks"><HintPath>' + q(cecil.with_name('Mono.Cecil.Rocks.dll')) + '</HintPath></Reference><Compile Include="' + q(TOOL / "AtlasMemoryHooks.cs") + '" Link="Hooks.cs"/></ItemGroup></Project>')
            (path / "patcher/Program.cs").write_text(PATCHER)
            env = dict(os.environ, DOTNET_CLI_HOME=str(path / "cli"), DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_GENERATE_ASPNET_CERTIFICATE="false")
            for name in ("game", "patcher"):
                subprocess.run([DOTNET, "build", str(path / name), "-c", "Release", "--nologo", "-v:q", "-p:NuGetAudit=false", "-p:RestoreConfigFile=" + str(path / "NuGet.Config")], check=True, env=env, capture_output=True, text=True)
            game = path / "game/bin/Release/net9.0/game.dll"
            patched = game.with_name("patched.dll")
            compat = game.with_name("compat.dll")
            subprocess.run([DOTNET, str(path / "patcher/bin/Release/net9.0/patcher.dll"), str(game), str(compat), str(patched)], check=True, env=env, capture_output=True, text=True)
            patched.replace(game)
            for mode, value in (("auto", "auto"), ("low", "low"), ("low", "LOW"), ("auto", "unknown")):
                run = subprocess.run([DOTNET, str(game), mode], check=True, env={**env, "SLL_MEMORY_MODE": value}, capture_output=True, text=True)
                self.assertIn("PASS " + mode, run.stdout)

if __name__ == "__main__":
    unittest.main()
