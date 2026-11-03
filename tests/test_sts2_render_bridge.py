# INPUT:  可选 STS2_PATCH_DOTNET、真实渲染桥源码和隔离 GodotSharp 替身
# OUTPUT: 不运行游戏的反射边界、材质/缓存和战斗预热回归
# POS:    验证桥使用调用方 Godot API、处理失败并保持节点/资源所有权
import os
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
DOTNET = os.environ.get("STS2_PATCH_DOTNET")
FIXTURE = r'''
using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using STS2LinuxLauncher.Patches;
namespace STS2LinuxLauncher { public static class PortPaths { public static string GameDir = "."; } }
namespace HarmonyLib { public static class AccessTools { public static Type TypeByName(string n) => typeof(MegaCrit.Sts2.Core.Nodes.NGame); } }
namespace Godot {
 public class GodotObject : IDisposable {
  public bool Disposed; public void Dispose() { Disposed = true; }
  public Error Connect(StringName n, Callable c, uint f) { Engine.Callable = c; return Engine.FailConnect ? Error.Failed : Error.Ok; }
  public Variant Callv(StringName name, Collections.Array args) {
   var a = args.Items; switch (name.Text) {
    case "is_compat_ready": return Variant.From(true);
    case "is_startup_effects_ready": if (Engine.FailStartup) throw new Exception("fixture diagnostic failure"); return Variant.From(Engine.StartupReady);
    case "simple_effects_enabled": return Variant.From(Engine.SimpleEffects);
    case "remap_material": return Variant.From(Engine.Replacement);
    case "is_resource_protected": return Variant.From(ReferenceEquals(a[0].Value, Engine.Protected));
    case "prepare_room": Engine.Prepared = a; return default;
    case "get_preparing_room": return Variant.From(Engine.Room);
    case "receive_hit_effects": Engine.Received = (Collections.Array)a[0].Value; return default;
    default: throw new Exception(name.Text);
   }
  }
 }
 public enum Error { Ok, Failed }
 public class StringName : IDisposable { public string Text; public static implicit operator StringName(string s) => new(){Text=s}; public void Dispose() { Engine.NamesDisposed++; } }
 public struct Variant : IDisposable {
  public object Value; public enum Kind { Nil, Object, Bool, Other }
  public Kind VariantType => Value == null ? Kind.Nil : Value is bool ? Kind.Bool : Value is GodotObject ? Kind.Object : Kind.Other;
  public static Variant From<T>(in T v) => new(){Value=v};
  public GodotObject AsGodotObject() => (GodotObject)Value; public bool AsBool() => (bool)Value;
  public void Dispose() { Engine.VariantsDisposed++; }
 }
 public struct Callable { public Action Action; public static Callable From(Action a) => new(){Action=a}; }
 public class NodePath : IDisposable { public string Text; public static implicit operator NodePath(string s) => new(){Text=s}; public void Dispose() {} }
 public class Node : GodotObject {
  public Node Parent; public bool Freed; public Node GetParent() => Parent; public void QueueFree() {Freed=true;}
  public void AddChild(Node n, bool force=false, int mode=0) { n.Parent=this; }
  public bool HasMarker; public Node GetNodeOrNull(NodePath path) => HasMarker && path.Text == "PortSimpleEffect" ? new Node() : null;
 }
 public class CanvasItem : Node { public Material Material {get;set;} }
 public class Material : GodotObject { public string ResourcePath {get;set;} }
 public class ShaderMaterial : Material {}
 public class SceneTree { public Node Root {get;} = new(); private Action handler; public int Subscriptions;
  public event Action ProcessFrame { add {handler += value; Subscriptions++;} remove {handler -= value; Subscriptions--;} }
  public void Frame() => handler?.Invoke(); }
 public static class Engine { public static SceneTree Tree = new(); public static Callable Callable; public static bool FailConnect, SimpleEffects, StartupReady, FailStartup;
  public static int NamesDisposed, VariantsDisposed; public static Material Replacement, Protected; public static Node Room;
  public static List<Variant> Prepared; public static Collections.Array Received; public static SceneTree GetMainLoop() => Tree; }
 public static class RenderingServer { public static event Action FramePostDraw { add {} remove {} } }
 public class PackedScene : GodotObject { public Node Instantiate(int edit=0) => new(); }
 public static class ResourceLoader { public static PackedScene Load(string path, string hint="", int mode=0) => new(); }
 namespace Collections { public class Array : IDisposable { public List<Variant> Items = new(); public void Add(Variant v) => Items.Add(v); public void Dispose() {} } }
}
namespace MegaCrit.Sts2.Core.Nodes { public class NGame : Godot.Node {
 public int Calls; public int ThreadId; public bool Arg; public bool Throw; public TaskCompletionSource Completion;
 public Task LoadMainMenu(bool value) { Calls++; ThreadId = Environment.CurrentManagedThreadId; Arg=value;
  if (Throw) throw new Exception("menu failure"); return Completion?.Task ?? Task.CompletedTask; }
} }
namespace MegaCrit.Sts2.Core.Nodes.Rooms { public class NCombatRoom : Godot.Node {
 public string Mode {get;set;} = "ActiveCombat"; public Godot.Node CombatVfxContainer {get;} = new();
 public List<Actor> CreatureNodes {get;} = new(); }
 public class Actor { public Creature Entity {get;set;} }
 public class Creature { public bool IsAlive {get;set;}=true; public Monster Monster {get;set;}=new(); }
 public class Monster { public bool HasHurtSfx => true; public string HurtSfx => "hurt"; public string TakeDamageSfx => "damage"; }
}
namespace MegaCrit.Sts2.Core.Nodes.Vfx { using MegaCrit.Sts2.Core.Nodes.Rooms;
 public class NHitSparkVfx : Godot.Node { public static List<Godot.Node> Created = new();
  public static Godot.Node Create(Creature c, bool v) { FirstCardTrace.Resource("begin", "GetScene", "res://factory-spark.tscn"); var node = new Godot.Node(); Created.Add(node); return node; } }
}
namespace MegaCrit.Sts2.Core.Nodes.Vfx.Ui {
 public class NPowerAppliedDebuffVfx : Godot.Node {}
 public class NPowerAppliedBuffVfx : Godot.Node {}
}
namespace MegaCrit.Sts2.Core.Nodes.Vfx { using MegaCrit.Sts2.Core.Nodes.Rooms;
 public class NVfxParticleSystem : Godot.Node {}
 public static class NDamageNumVfx { public static bool Fail;
  public static Godot.Node Create(Creature c, int n, bool v) { FirstCardTrace.Resource("begin", "GetScene", "res://factory-damage.tscn"); if (Fail) throw new Exception("fixture factory failure"); return new(); } }
}
namespace MegaCrit.Sts2.Core.Nodes.Audio { public class NAudioManager {
 public static NAudioManager Instance {get;}=new(); public int Calls; public float Volume; public bool DamageParameter;
 public void PlayOneShot(string path, Dictionary<string,float> args, float volume) {Calls++; Volume=volume; if (path == "damage") DamageParameter = args?["EnemyImpact_Intensity"] == 2f;}
} }
namespace MegaCrit.Sts2.Core.Nodes.Cards { public class NCard {
 public Godot.Material _portraitBlurMaterial, _canvasGroupMaskBlurMaterial, _canvasGroupBlurMaterial, _canvasGroupMaskMaterial;
 public Godot.CanvasItem _portrait=new(), _ancientPortrait=new(), _portraitCanvasGroup=new();
} }
public static class Program { public static void Main(string[] args) {
 var beforeInstall = new MegaCrit.Sts2.Core.Nodes.Vfx.NHitSparkVfx {HasMarker=true};
 var beforeDebuff = new MegaCrit.Sts2.Core.Nodes.Vfx.Ui.NPowerAppliedDebuffVfx {HasMarker=true};
 var beforeBuff = new MegaCrit.Sts2.Core.Nodes.Vfx.Ui.NPowerAppliedBuffVfx {HasMarker=true};
 if (!RenderPreparationBridge.IsSimpleEffect(beforeInstall) || !RenderPreparationBridge.IsSimpleEffect(beforeDebuff) || !RenderPreparationBridge.IsSimpleEffect(beforeBuff) || RenderPreparationBridge.IsSimpleEffect(new Godot.Node {HasMarker=true})) throw new Exception("marker before bridge initialization");
 Godot.Engine.FailConnect = args.Length != 0;
 RenderPreparationBridge.Install(); Godot.Engine.Tree.Frame();
 var original = new Godot.Material {ResourcePath="res://old"}; var replacement = new Godot.Material();
 Godot.Engine.Replacement=replacement; Godot.Engine.Protected=original;
 if (args.Length != 0) {
  if (!RenderPreparationBridge.IsSimpleEffect(beforeInstall) || !RenderPreparationBridge.IsSimpleEffect(beforeBuff)) throw new Exception("marker after bridge failure");
  if (!ReferenceEquals(RenderPreparationBridge.RemapMaterial(original,"x"),original)) throw new Exception("connect failure did not disable bridge");
  Console.WriteLine("connect failure: PASS"); return;
 }
 var game = new MegaCrit.Sts2.Core.Nodes.NGame();
 int caller = Environment.CurrentManagedThreadId;
 var wait = RenderPreparationBridge.LoadMainMenuAfterStartup(game, false);
 if (wait.IsCompleted || game.Calls != 0 || Godot.Engine.Tree.Subscriptions != 1) throw new Exception("menu was not deferred");
 Godot.Engine.Tree.Frame();
 if (wait.IsCompleted || game.Calls != 0) throw new Exception("menu ran before terminal state");
 game.Completion = new TaskCompletionSource(); Godot.Engine.StartupReady = true; Godot.Engine.Tree.Frame();
 if (game.Calls != 1 || game.ThreadId != caller || game.Arg || wait.IsCompleted || Godot.Engine.Tree.Subscriptions != 0) throw new Exception("menu forwarding or event cleanup");
 game.Completion.SetResult(); wait.GetAwaiter().GetResult(); Godot.Engine.Tree.Frame();
 if (game.Calls != 1) throw new Exception("menu called twice");
 game.Completion = null; game.Throw = true;
 try { RenderPreparationBridge.LoadMainMenuAfterStartup(game, false); throw new Exception("menu exception swallowed"); }
 catch (Exception error) when (error.Message == "menu failure") { if (game.Calls != 2) throw new Exception("menu exception retried"); }
 game.Throw = false; Godot.Engine.StartupReady = false;
 var failed = RenderPreparationBridge.LoadMainMenuAfterStartup(game, false);
 Godot.Engine.FailStartup = true; Godot.Engine.Tree.Frame(); failed.GetAwaiter().GetResult();
 if (game.Calls != 3 || Godot.Engine.Tree.Subscriptions != 0) throw new Exception("preload failure did not resume");
 Godot.Engine.FailStartup = false;
 var timed = RenderPreparationBridge.LoadMainMenuAfterStartup(game, false);
 Thread.Sleep(7100); Godot.Engine.Tree.Frame(); timed.GetAwaiter().GetResult();
 if (game.Calls != 4 || game.ThreadId != caller || Godot.Engine.Tree.Subscriptions != 0) throw new Exception("timeout did not resume once on frame thread");
 Godot.Engine.StartupReady = true;
 if (!ReferenceEquals(RenderPreparationBridge.RemapMaterial(original,"x"),replacement)) throw new Exception("remap");
 if (RenderPreparationBridge.FilterEvicted(original) != null || !ReferenceEquals(RenderPreparationBridge.FilterEvicted(replacement),replacement)) throw new Exception("eviction");
 var card = new MegaCrit.Sts2.Core.Nodes.Cards.NCard {_portraitBlurMaterial=original}; card._portrait.Material=original;
 RenderPreparationBridge.RepairCachedMaterials(card);
 if (!ReferenceEquals(card._portraitBlurMaterial,replacement) || !ReferenceEquals(card._portrait.Material,replacement)) throw new Exception("cached material repair");
 var room = new MegaCrit.Sts2.Core.Nodes.Rooms.NCombatRoom(); room.CreatureNodes.Add(new(){Entity=new()}); Godot.Engine.Room=room;
 room.Mode="Inactive"; RenderPreparationBridge.CombatRoomReady(room); if (Godot.Engine.Prepared != null) throw new Exception("inactive room");
 room.Mode="ActiveCombat"; RenderPreparationBridge.CombatRoomReady(room);
 if (Godot.Engine.Prepared.Count != 3 || !ReferenceEquals(Godot.Engine.Prepared[2].Value,room.CombatVfxContainer)) throw new Exception("container");
 Godot.Engine.Callable.Action();
 if (Godot.Engine.Received.Items.Count != 3) throw new Exception("effect factories");
 var audio = MegaCrit.Sts2.Core.Nodes.Audio.NAudioManager.Instance;
 if (audio.Calls != 2 || audio.Volume != 0 || !audio.DamageParameter) throw new Exception("muted hurt audio");
 if (original.Disposed || replacement.Disposed || room.Disposed || Godot.Engine.NamesDisposed == 0 || Godot.Engine.VariantsDisposed == 0) throw new Exception("ownership");
 var markedHit = new MegaCrit.Sts2.Core.Nodes.Vfx.NHitSparkVfx { HasMarker = true };
 var markedDebuff = new MegaCrit.Sts2.Core.Nodes.Vfx.Ui.NPowerAppliedDebuffVfx { HasMarker = true };
 var markedBuff = new MegaCrit.Sts2.Core.Nodes.Vfx.Ui.NPowerAppliedBuffVfx { HasMarker = true };
 if (!RenderPreparationBridge.IsSimpleEffect(markedHit) || !RenderPreparationBridge.IsSimpleEffect(markedDebuff) || !RenderPreparationBridge.IsSimpleEffect(markedBuff) || RenderPreparationBridge.IsSimpleEffect(new MegaCrit.Sts2.Core.Nodes.Vfx.Ui.NPowerAppliedBuffVfx()) || RenderPreparationBridge.IsSimpleEffect(new MegaCrit.Sts2.Core.Nodes.Vfx.NVfxParticleSystem {HasMarker=true}) || RenderPreparationBridge.IsSimpleEffect(new MegaCrit.Sts2.Core.Nodes.Vfx.NHitSparkVfx()) || RenderPreparationBridge.IsSimpleEffect(new Godot.Node {HasMarker=true})) throw new Exception("simple marker recognition");
 var sparks = MegaCrit.Sts2.Core.Nodes.Vfx.NHitSparkVfx.Created;
 sparks.Clear(); Godot.Engine.SimpleEffects = true; Godot.Engine.Received = null;
 Godot.Engine.Callable.Action();
 if (sparks.Count != 0 || Godot.Engine.Received.Items.Count != 2 || audio.Calls != 4) throw new Exception("simple warmup skips spark but retains numbers and audio");
 Godot.Engine.SimpleEffects = false;
 sparks.Clear(); MegaCrit.Sts2.Core.Nodes.Vfx.NDamageNumVfx.Fail = true;
 Godot.Engine.Received = null;
 Godot.Engine.Callable.Action();
 if (sparks.Count != 1 || !sparks[0].Freed || Godot.Engine.Received != null) throw new Exception("factory failure cleanup");
 FirstCardTrace.Resource("end", "GetScene", "res://after-factory-failure.tscn");
 Console.WriteLine("remap, eviction, cache repair, active room, effect ownership, muted audio: PASS");
} }
'''

@unittest.skipUnless(DOTNET, "set STS2_PATCH_DOTNET to a .NET 9 SDK")
class RenderBridgeTests(unittest.TestCase):
    def test_fake_native_bridge(self):
        source = ROOT / "ports/sts2/src/STS2LinuxLauncher/Patches/RenderPreparationBridge.cs"
        trace = source.with_name("FirstCardTrace.cs")
        texture_bridge = source.with_name("TextureDiagnosticBridge.cs")
        heap_trim = source.with_name("NativeHeapTrim.cs")
        with tempfile.TemporaryDirectory(prefix="sts2-render-bridge-") as directory:
            path = Path(directory)
            (path / "Fixture.cs").write_text(FIXTURE)
            (path / "Fixture.csproj").write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net9.0</TargetFramework><AssemblyName>GodotSharp</AssemblyName></PropertyGroup><ItemGroup><Compile Include="' + escape(str(source), {'"': '&quot;'}) + '" Link="Bridge.cs"/><Compile Include="' + escape(str(trace), {'"': '&quot;'}) + '" Link="Trace.cs"/><Compile Include="' + escape(str(texture_bridge), {'"': '&quot;'}) + '" Link="TextureDiagnosticBridge.cs"/><Compile Include="' + escape(str(heap_trim), {'"': '&quot;'}) + '" Link="NativeHeapTrim.cs"/></ItemGroup></Project>')
            config = path / "NuGet.Config"
            config.write_text('<configuration><packageSources><clear/></packageSources></configuration>')
            env = dict(os.environ, DOTNET_CLI_HOME=str(path / "cli"), DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_GENERATE_ASPNET_CERTIFICATE="false", SLL_FIRST_CARD_TRACE="1", SLL_TEXTURE_DIAG="0")
            subprocess.run([DOTNET, "build", str(path / "Fixture.csproj"), "-c", "Release", "--nologo", "-v:q", "-p:NuGetAudit=false", "-p:RestoreConfigFile=" + str(config)], check=True, env=env, capture_output=True, text=True)
            dll = path / "bin/Release/net9.0/GodotSharp.dll"
            for args, expected in [([], "muted audio: PASS"), (["fail"], "connect failure: PASS")]:
                run = subprocess.run([DOTNET, str(dll), *args], check=True, env=env, capture_output=True, text=True, timeout=20)
                self.assertIn(expected, run.stdout)
                if not args:
                    self.assertIn("resource GetScene res://factory-spark.tscn begin", run.stderr)
                    self.assertIn("resource GetScene res://factory-damage.tscn begin", run.stderr)
                    self.assertNotIn("res://after-factory-failure.tscn", run.stderr)

@unittest.skipUnless(DOTNET and all(os.environ.get(n) for n in ("STS2_PATCH_GAME", "STS2_PATCH_COMPAT", "STS2_PATCH_TOOL")),
    "set STS2_PATCH_GAME, STS2_PATCH_COMPAT and STS2_PATCH_TOOL for offline input verification")
class OfficialDllTests(unittest.TestCase):
    def test_input_is_unchanged_hooks_and_duplicate_rejected(self):
        game = Path(os.environ["STS2_PATCH_GAME"]).resolve()
        compat = Path(os.environ["STS2_PATCH_COMPAT"]).resolve()
        tool = Path(os.environ["STS2_PATCH_TOOL"]).resolve()
        deps = game.with_suffix(".deps.json")
        before = [hashlib.sha256(p.read_bytes()).digest() for p in (game, deps)]
        with tempfile.TemporaryDirectory(prefix="sts2-cecil-patch-") as directory:
            output = Path(directory) / "sts2.dll"
            run = subprocess.run([DOTNET, str(tool), "patch", str(game), str(compat), str(output)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            for expected in ("architecture=ARM64", "policy: 451", "instrumented: 3", "DXGI diagnostic block bypass verified", "input diagnostic hooks verified", "window focus hook verified; platform overlay retained", "asset cache diagnostic hooks verified", "CombatRoomReady: 1", "RepairCachedMaterials: 6", "RemapMaterial: 1", "FilterEvicted: 2"):
                self.assertIn(expected, run.stdout)
            original_deps = json.loads(deps.read_text())
            written_deps = json.loads(output.with_suffix(".deps.json").read_text())
            self.assertEqual(original_deps["libraries"], written_deps["libraries"])
            self.assertEqual(before, [hashlib.sha256(p.read_bytes()).digest() for p in (game, deps)])
            again = subprocess.run([DOTNET, str(tool), "patch", str(output), str(compat), str(Path(directory) / "again.dll")], capture_output=True, text=True)
            self.assertNotEqual(again.returncode, 0)
            self.assertIn("already injected", again.stderr)
            self.assertFalse((Path(directory) / "again.dll").exists())

if __name__ == "__main__":
    unittest.main()
