# INPUT: optional asset diagnostics, Cecil hook and synthetic loading session
# OUTPUT: bounded read-only cache/managed-heap metrics and optional Common paths
# POS: validates lifecycle diagnostics without executing game code
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
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Threading.Tasks;
namespace Godot { public class Resource {} }
namespace MegaCrit.Sts2.Core.Assets {
 public class AssetCache { public int MissedCacheAssetCount => 2; }
 public class AssetLoadingSession {
  private string _name; private Queue<string> _toLoad=new(); private Queue<string> _vfxScenes=new();
  private ConcurrentDictionary<string,Godot.Resource> _cache; private AssetCache _assetCache;
  private TaskCompletionSource<bool> _completionSource=new();
  public AssetLoadingSession(string name, IEnumerable<string> paths, ConcurrentDictionary<string,Godot.Resource> cache, AssetCache assetCache) {
   _name=name; _cache=cache; _assetCache=assetCache;
   foreach(var path in paths) { if(path.StartsWith("res://scenes/vfx/")) _vfxScenes.Enqueue(path); else _toLoad.Enqueue(path); }
  }
  public void Process() { _completionSource.TrySetResult(true); }
  public bool Completed => _completionSource.Task.IsCompleted;
 }
}
public static class Program {
 public static void Main(string[] args) {
  var c=new ConcurrentDictionary<string,Godot.Resource>(); c["res://images/x.png"]=new(); c["res://scenes/vfx/y.tscn"]=new();
  var paths=new List<string>{"res://scenes/screens/a.tscn","res://scenes/vfx/b.tscn","not-resource"};
  if (args.Length > 0 && args[0] == "many") for(int i=0;i<1201;i++) paths.Add("res://images/test"+i+".png");
  if (args.Length > 0 && args[0] == "unsafe") {
   for(int i=0;i<32;i++) paths.Add("res://images/a"+(char)i+"b.png");
   for(int i=127;i<=159;i++) paths.Add("res://images/a"+(char)i+"b.png");
   paths.AddRange(new[]{"res://", "res://images//x", "res://images/./x", "res://images/../x", "res://images/x/", "res://images\\x", "res://images/é.png"});
  }
  var s=new MegaCrit.Sts2.Core.Assets.AssetLoadingSession("Common",paths,c,new());
  s.Process(); s.Process();
  if (args.Length > 0 && args[0] == "many") {
   var next = new MegaCrit.Sts2.Core.Assets.AssetLoadingSession("Common",paths,c,new()); next.Process();
   if (!next.Completed) throw new Exception("second session changed");
  }
  if (!s.Completed || c.Count != 2) throw new Exception("lifecycle changed"); Console.WriteLine("PASS");
 }
}
'''
PATCHER = r'''
using Mono.Cecil;
using var resolver=new DefaultAssemblyResolver();
resolver.AddSearchDirectory(System.IO.Path.GetDirectoryName(args[0]));
resolver.AddSearchDirectory(System.IO.Path.GetDirectoryName(args[1]));
resolver.AddSearchDirectory(System.IO.Path.GetDirectoryName(typeof(object).Assembly.Location));
using var game=AssemblyDefinition.ReadAssembly(args[0],new ReaderParameters{AssemblyResolver=resolver});
using var compat=AssemblyDefinition.ReadAssembly(args[1],new ReaderParameters{AssemblyResolver=resolver});
AssetCacheDiagnosticsHooks.Inject(game,compat);
try { AssetCacheDiagnosticsHooks.Inject(game,compat); throw new Exception("duplicate accepted"); }
catch (InvalidOperationException) { }
game.Write(args[2]);
using var check=AssemblyDefinition.ReadAssembly(args[2]); AssetCacheDiagnosticsHooks.Verify(check);
'''

@unittest.skipUnless(DOTNET, 'set STS2_PATCH_DOTNET to a .NET 9 SDK')
class AssetDiagnosticsTests(unittest.TestCase):
    def test_read_only_bounded_lifecycle_and_paths(self):
        cecil = TOOL / 'bin/Release/net9.0/Mono.Cecil.dll'
        if not cecil.exists(): self.skipTest('build official_runtime Release first')
        with tempfile.TemporaryDirectory(prefix='sts2-assets-') as tmp:
            path = Path(tmp)
            (path / 'NuGet.Config').write_text('<configuration><packageSources><clear/></packageSources></configuration>')
            for name in ('compat', 'game', 'patcher'): (path / name).mkdir()
            q = lambda p: escape(str(p), {'"': '&quot;'})
            props = '<PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net9.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><Optimize>true</Optimize></PropertyGroup>'
            source = ROOT / 'ports/sts2/src/STS2LinuxLauncher/Patches/AssetCacheDiagnostics.cs'
            (path / 'compat/compat.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net9.0</TargetFramework></PropertyGroup><ItemGroup><Compile Include="' + q(source) + '" Link="Diagnostics.cs"/></ItemGroup></Project>')
            (path / 'game/game.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk">' + props + '<ItemGroup><ProjectReference Include="../compat/compat.csproj"/></ItemGroup></Project>')
            (path / 'game/Program.cs').write_text(GAME)
            (path / 'patcher/patcher.csproj').write_text('<Project Sdk="Microsoft.NET.Sdk">' + props + '<ItemGroup><Reference Include="Mono.Cecil"><HintPath>' + q(cecil) + '</HintPath></Reference><Reference Include="Mono.Cecil.Rocks"><HintPath>' + q(cecil.with_name('Mono.Cecil.Rocks.dll')) + '</HintPath></Reference><Compile Include="' + q(TOOL / 'AssetCacheDiagnosticsHooks.cs') + '" Link="Hooks.cs"/></ItemGroup></Project>')
            (path / 'patcher/Program.cs').write_text(PATCHER)
            env = dict(os.environ, DOTNET_CLI_HOME=str(path / 'cli'), DOTNET_CLI_TELEMETRY_OPTOUT='1', DOTNET_GENERATE_ASPNET_CERTIFICATE='false')
            for name in ('game', 'patcher'):
                subprocess.run([DOTNET, 'build', str(path / name), '-c', 'Release', '--nologo', '-v:q', '-p:NuGetAudit=false', '-p:RestoreConfigFile=' + str(path / 'NuGet.Config')], check=True, env=env, capture_output=True, text=True)
            game = path / 'game/bin/Release/net9.0/game.dll'
            patched = game.with_name('patched.dll')
            subprocess.run([DOTNET, str(path / 'patcher/bin/Release/net9.0/patcher.dll'), str(game), str(game.with_name('compat.dll')), str(patched)], check=True, env=env, capture_output=True, text=True)
            patched.replace(game)
            disabled = subprocess.run([DOTNET, str(game)], check=False, env={**env, 'SLL_ASSET_DIAG':'0', 'SLL_ASSET_DIAG_PATHS':'1', 'SLL_MALLOC_DIAG':'1'}, capture_output=True, text=True)
            self.assertEqual(disabled.returncode, 0, disabled.stderr)
            self.assertEqual(disabled.stderr, '')
            counts_only = subprocess.run([DOTNET, str(game)], check=True, env={**env, 'SLL_ASSET_DIAG':'1', 'SLL_ASSET_DIAG_PATHS':'0', 'SLL_MALLOC_DIAG':'0'}, capture_output=True, text=True)
            malloc = subprocess.run([DOTNET, str(game)], check=True, env={**env, 'SLL_ASSET_DIAG':'1', 'SLL_MALLOC_DIAG':'1', 'SLL_ASSET_DIAG_PATHS':'0'}, capture_output=True, text=True)
            self.assertIn(' malloc=', malloc.stderr)
            self.assertIn('phase=complete set=common', counts_only.stderr)
            self.assertNotIn('[ASSET-DIAG-PATH]', counts_only.stderr)
            self.assertNotIn(' malloc=', counts_only.stderr)
            enabled = subprocess.run([DOTNET, str(game)], check=True, env={**env, 'SLL_ASSET_DIAG':'1', 'SLL_ASSET_DIAG_PATHS':'1'}, capture_output=True, text=True)
            self.assertIn('phase=begin set=common total=3 vfx=1 screens=1', enabled.stderr)
            self.assertIn('phase=complete set=common total=2 vfx=1', enabled.stderr)
            self.assertIn('missed=2 managed_bytes=', enabled.stderr)
            self.assertIn('phase=common_paths emitted=2 eligible=2 truncated=False limit=1200', enabled.stderr)
            self.assertEqual(enabled.stderr.count('phase=complete'), 1)
            self.assertIn('[ASSET-DIAG-PATH] res://scenes/screens/a.tscn', enabled.stderr)
            self.assertNotIn('[ASSET-DIAG-PATH] not-resource', enabled.stderr)
            capped = subprocess.run([DOTNET, str(game), 'many'], check=True, env={**env, 'SLL_ASSET_DIAG':'1', 'SLL_ASSET_DIAG_PATHS':'1'}, capture_output=True, text=True)
            self.assertEqual(capped.stderr.count('[ASSET-DIAG-PATH] '), 1200)
            self.assertIn('phase=common_paths emitted=1200 eligible=1203 truncated=True limit=1200', capped.stderr)
            self.assertEqual(capped.stderr.count('phase=common_paths'), 1)
            self.assertEqual(capped.stderr.count('phase=begin set=common'), 2)
            self.assertEqual(capped.stderr.count('phase=complete set=common'), 2)
            unsafe = subprocess.run([DOTNET, str(game), 'unsafe'], check=True, env={**env, 'SLL_ASSET_DIAG':'1', 'SLL_ASSET_DIAG_PATHS':'1'}, capture_output=True, text=True)
            self.assertIn('phase=common_paths emitted=3 eligible=3 truncated=False limit=1200', unsafe.stderr)
            self.assertEqual(unsafe.stderr.count('[ASSET-DIAG-PATH] '), 3)
            self.assertIn('[ASSET-DIAG-PATH] res://images/é.png', unsafe.stderr)
            self.assertIn('phase=begin set=common total=75', unsafe.stderr)
