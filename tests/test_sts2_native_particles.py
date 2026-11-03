# INPUT:  可选 STS2_PATCH_DOTNET、真实粒子补丁源码与模拟原生事件
# OUTPUT: 无游戏/设备依赖的事件连接、派生节点及 GPU 重新激活回归
# POS:    验证官方运行时粒子策略确实响应事件且不依赖 Harmony 钩子
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
using System.Reflection;
using STS2LinuxLauncher.Patches;
namespace HarmonyLib {
    public class Harmony {
        public void Patch(MethodBase original, HarmonyMethod postfix = null) {
            throw new Exception("Native event path must not use Harmony");
        }
    }
    public class HarmonyMethod { public HarmonyMethod(Type type, string method) {} }
    public static class AccessTools {
        public static Type TypeByName(string name) => throw new Exception("Game lookup is not part of event registration");
        public static MethodInfo Method(Type type, string name) => type.GetMethod(name);
    }
}
namespace STS2LinuxLauncher {
    public static class QualityProfile {
        public static int ParticleCap => 48;
        public static string Current => "Balanced";
    }
}
namespace Fixture {
    public class Node {}
    public class GpuParticles2D : Node {
        public bool Emitting { get; set; } = true;
        public bool Visible { get; set; } = true;
        public double Preprocess { get; set; } = 400;
        public int Amount { get; set; } = 200;
        public int Restarts;
        public void Restart() { Restarts++; Emitting = true; }
    }
    public class GameSpark : GpuParticles2D {}
    public class CpuParticles2D : Node { public int Amount { get; set; } = 200; }
    public class Tree {
        public delegate void NodeAddedEventHandler(Node node);
        private NodeAddedEventHandler handler;
        public int Subscriptions;
        public event NodeAddedEventHandler NodeAdded {
            add { handler += value; Subscriptions++; }
            remove { handler -= value; Subscriptions--; }
        }
        public void Add(Node node) => handler?.Invoke(node);
    }
    public static class Program {
        public static void Main() {
            var tree = new Tree();
            ParticleDietPatches.InstallNativeTree(tree);
            ParticleDietPatches.InstallNativeTree(tree);
            if (tree.Subscriptions != 1) throw new Exception("Duplicate native event subscription");
            tree.Add(new Node());
            var gpu = new GameSpark();
            tree.Add(gpu);
            if (gpu.Emitting || gpu.Visible || gpu.Preprocess != 0)
                throw new Exception("Derived GPU emitter was not disabled by native event");
            ParticleDietPatches.RestartGpu(gpu);
            ParticleDietPatches.SetGpuEmitting(gpu, true);
            if (gpu.Restarts != 0 || gpu.Emitting)
                throw new Exception("Game restart/emission reactivated GPU particles");
            var cpu = new CpuParticles2D();
            tree.Add(cpu);
            if (cpu.Amount != 48) throw new Exception("CPU emitter was not capped");
            var smallCpu = new CpuParticles2D { Amount = 3 };
            tree.Add(smallCpu);
            if (smallCpu.Amount != 3) throw new Exception("Small CPU effect was enlarged");
            Console.WriteLine("native-events, derived-emitter, reactivation-block, CPU-cap: PASS");
        }
    }
}
'''


@unittest.skipUnless(DOTNET, "set STS2_PATCH_DOTNET to an installed .NET 9 SDK")
class NativeParticleTests(unittest.TestCase):
    def run_fixture(self, filename, fixture, assembly="NativeParticleFixture", **extra_env):
        source = ROOT / "ports/sts2/src/STS2LinuxLauncher/Patches" / filename
        with tempfile.TemporaryDirectory(prefix="sts2-particle-test-") as directory:
            path = Path(directory)
            (path / "Fixture.cs").write_text(fixture)
            (path / "NativeParticleFixture.csproj").write_text(
                '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType>'
                '<TargetFramework>net9.0</TargetFramework><ImplicitUsings>enable</ImplicitUsings><AssemblyName>' + assembly + '</AssemblyName>'
                '</PropertyGroup><ItemGroup><Compile Include="' + escape(str(source), {'"': '&quot;'}) +
                '" Link="ParticleDietPatches.cs"/></ItemGroup></Project>')
            config = path / "NuGet.Config"
            config.write_text('<configuration><packageSources><clear/></packageSources></configuration>')
            env = dict(os.environ, DOTNET_CLI_HOME=str(path / "cli"),
                DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_GENERATE_ASPNET_CERTIFICATE="false",
                SLL_GPU_PARTICLES="off", SLL_QUALITY="balanced", **extra_env)
            subprocess.run([DOTNET, "build", str(path / "NativeParticleFixture.csproj"), "-c", "Release",
                "--nologo", "-v:q", "-p:NuGetAudit=false", "-p:RestoreConfigFile=" + str(config)],
                check=True, env=env, capture_output=True, text=True)
            return subprocess.run([DOTNET, str(path / "bin/Release/net9.0" / (assembly + ".dll"))],
                check=True, env=env, capture_output=True, text=True)

    def test_native_events_disable_gpu_and_block_later_game_reactivation(self):
        run = self.run_fixture("ParticleDietPatches.cs", FIXTURE)
        self.assertIn("native-events, derived-emitter, reactivation-block, CPU-cap: PASS", run.stdout)
        self.assertIn("native node_added installed (GPU=off", run.stderr)
        self.assertNotIn("handler failed", run.stderr)

    def test_first_card_trace_captures_frame_gap_and_fails_without_breaking_frames(self):
        fixture = r'''
using System;
using System.Threading;
using STS2LinuxLauncher.Patches;
namespace HarmonyLib { public static class AccessTools {
    public static Type TypeByName(string name) => typeof(Game.NGame);
} }
namespace Game { public class NGame : Godot.Node {} }
namespace Godot {
    public class Node {}
    public static class Engine { public static SceneTree GetMainLoop() => Tree; public static SceneTree Tree = new(); }
    public class SceneTree {
        private Action handler;
        public int Subscriptions;
        public event Action ProcessFrame {
            add { handler += value; Subscriptions++; }
            remove { handler -= value; Subscriptions--; }
        }
        public void Frame() => handler?.Invoke();
    }
    public static class Performance {
        public enum Monitor { PipelineCompilationsCanvas, PipelineCompilationsMesh,
            PipelineCompilationsSurface, PipelineCompilationsDraw, PipelineCompilationsSpecialization }
        public static int Canvas;
        public static bool Fail;
        public static double GetMonitor(Monitor value) {
            if (Fail) throw new InvalidOperationException("simulated monitor failure");
            return value == Monitor.PipelineCompilationsCanvas ? Canvas : 0;
        }
    }
}
public static class Program { public static void Main() {
    FirstCardTrace.Install();
    var outer = FirstCardTrace.EnterWarmupResources();
    FirstCardTrace.Resource("begin", "GetScene", "res://warmup-outer.tscn");
    var inner = FirstCardTrace.EnterWarmupResources();
    FirstCardTrace.Resource("begin", "GetMaterial", "res://warmup-inner.tres");
    FirstCardTrace.ExitWarmupResources(inner);
    var thread = new Thread(() => FirstCardTrace.Resource("begin", "GetScene", "res://other-thread.tscn"));
    thread.Start(); thread.Join();
    FirstCardTrace.Resource("end", "GetScene", "res://warmup-outer.tscn");
    FirstCardTrace.ExitWarmupResources(outer);
    FirstCardTrace.Resource("end", "GetScene", "res://after-scope.tscn");
    var limited = FirstCardTrace.EnterWarmupResources();
    for (int i = 0; i < 70; i++) FirstCardTrace.Resource("begin", "GetScene", "res://limit-" + i);
    FirstCardTrace.ExitWarmupResources(limited);
    FirstCardTrace.Begin();
    FirstCardTrace.Begin();
    FirstCardTrace.Resource("begin", "GetScene", "res://attack.tscn");
    Godot.Performance.Canvas = 2;
    Thread.Sleep(270);
    Godot.Engine.Tree.Frame();
    FirstCardTrace.Resource("end", "GetScene", "res://attack.tscn");
    Godot.Performance.Fail = true;
    Thread.Sleep(270);
    Godot.Engine.Tree.Frame();
    if (Godot.Engine.Tree.Subscriptions != 0) throw new Exception("Diagnostic failure did not remove listener");
    Godot.Engine.Tree.Frame();
    Console.WriteLine("trace-frame-gap-and-failsafe: PASS");
} }
'''
        run = self.run_fixture("FirstCardTrace.cs", fixture, assembly="GodotSharp", SLL_FIRST_CARD_TRACE="1")
        self.assertIn("trace-frame-gap-and-failsafe: PASS", run.stdout)
        self.assertIn("FRAME GAP", run.stderr)
        self.assertIn("PipelineCompilationsCanvas=2(delta=2)", run.stderr)
        self.assertIn("res://attack.tscn begin", run.stderr)
        self.assertIn("diagnostic disabled after error", run.stderr)
        self.assertEqual(run.stderr.count("[RENDER-WARMUP]"), 64)
        self.assertIn("res://warmup-inner.tres begin", run.stderr)
        self.assertIn("res://warmup-outer.tscn end", run.stderr)
        self.assertNotIn("res://other-thread.tscn", run.stderr)
        self.assertNotIn("res://after-scope.tscn", run.stderr)
        self.assertEqual(run.stderr.count("first play entered; taking pipeline baseline"), 1)

    def test_warmup_trace_disabled_is_silent(self):
        fixture = r'''
using System;
using STS2LinuxLauncher.Patches;
namespace HarmonyLib { public static class AccessTools { public static Type TypeByName(string name) => null; } }
public static class Program { public static void Main() {
    var entered = FirstCardTrace.EnterWarmupResources();
    if (entered) throw new Exception("disabled trace entered scope");
    FirstCardTrace.Resource("begin", "GetScene", "res://silent.tscn");
    FirstCardTrace.ExitWarmupResources(entered);
    Console.WriteLine("disabled: PASS");
} }
'''
        run = self.run_fixture("FirstCardTrace.cs", fixture, SLL_FIRST_CARD_TRACE="0")
        self.assertIn("disabled: PASS", run.stdout)
        self.assertNotIn("[RENDER-WARMUP]", run.stderr)
        self.assertNotIn("[FIRST-CARD]", run.stderr)


if __name__ == "__main__":
    unittest.main()
