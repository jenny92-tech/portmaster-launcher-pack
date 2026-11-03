// INPUT:  HarmonyLib、Godot 场景树原生事件、QualityProfile、SLL_GPU_PARTICLES
// OUTPUT: Apply()、ApplyOfficialRuntime()、OnNativeNodeAdded()、AddChildPostfix()
// POS:    官方运行时在节点入树时关闭 GPU 粒子或限量，旧引擎保留 Harmony 路径
using System;
using System.Collections.Generic;
using System.Reflection;
using HarmonyLib;

namespace STS2LinuxLauncher.Patches;

/// Caps particle emitter Amount at AddChild time, based on the quality profile.
/// GpuParticles2D is expensive on Mali/gl_compatibility.
public static class ParticleDietPatches
{
    private static int _cap;
    private static bool _disableGpu = Environment.GetEnvironmentVariable("SLL_GPU_PARTICLES") == "off";
    private static object _nativeTree;
    private static Delegate _nativeHandler;
    private static int _disabledGpuCount;
    private static bool _nodeErrorLogged;
    private static readonly Dictionary<Type, ParticleAccess> _particleTypes = new();

    private sealed class ParticleAccess
    {
        public bool Gpu;
        public PropertyInfo Amount;
        public PropertyInfo Emitting;
        public PropertyInfo Preprocess;
        public PropertyInfo Visible;
    }

    public static void ApplyOfficialRuntime()
    {
        if (_nativeHandler != null) return;
        var type = AccessTools.TypeByName("MegaCrit.Sts2.Core.Nodes.NGame")?.BaseType;
        while (type != null && type.Assembly.GetName().Name != "GodotSharp") type = type.BaseType;
        var godotSharp = type?.Assembly ?? throw new InvalidOperationException("Game GodotSharp missing");
        var getLoop = godotSharp.GetType("Godot.Engine")?.GetMethod("GetMainLoop", Type.EmptyTypes)
            ?? throw new InvalidOperationException("Engine.GetMainLoop API missing");
        InstallNativeTree(getLoop.Invoke(null, null)
            ?? throw new InvalidOperationException("Godot scene tree missing"));
    }

    internal static void InstallNativeTree(object tree)
    {
        if (_nativeHandler != null) return;
        _cap = QualityProfile.ParticleCap;
        _nativeTree = tree;
        var nodeAdded = tree.GetType().GetEvent("NodeAdded")
            ?? throw new InvalidOperationException("SceneTree.NodeAdded event missing");
        var handler = Delegate.CreateDelegate(nodeAdded.EventHandlerType,
            typeof(ParticleDietPatches).GetMethod(nameof(OnNativeNodeAdded)));
        nodeAdded.AddEventHandler(_nativeTree, handler);
        _nativeHandler = handler;
        Console.Error.WriteLine($"[STS2 Linux Compat] ParticleDiet native node_added installed (GPU={(_disableGpu ? "off" : "capped")}, CPU cap={_cap}); no Harmony AddChild hook.");
    }

    // Game-side IL routes reactivation calls here; otherwise Restart() after
    // node_added would wake the renderer's compute path again.
    public static void RestartGpu(object emitter)
    {
        if (_disableGpu) return;
        emitter.GetType().GetMethod("Restart", Type.EmptyTypes).Invoke(emitter, null);
    }

    public static void SetGpuEmitting(object emitter, bool emitting)
    {
        if (_disableGpu) return;
        emitter.GetType().GetProperty("Emitting").SetValue(emitter, emitting);
    }

    public static void OnNativeNodeAdded(object node)
    {
        if (node == null) return;
        try
        {
            var nodeType = node.GetType();
            if (!_particleTypes.TryGetValue(nodeType, out var access))
            {
                var particleType = nodeType;
                while (particleType != null && particleType.Name != "GpuParticles2D" &&
                    particleType.Name != "GpuParticles3D" && particleType.Name != "CpuParticles2D" &&
                    particleType.Name != "CpuParticles3D") particleType = particleType.BaseType;
                if (particleType != null)
                {
                    access = new ParticleAccess { Gpu = particleType.Name.StartsWith("Gpu"),
                        Amount = nodeType.GetProperty("Amount"), Emitting = nodeType.GetProperty("Emitting"),
                        Preprocess = nodeType.GetProperty("Preprocess"), Visible = nodeType.GetProperty("Visible") };
                }
                _particleTypes[nodeType] = access;
            }
            if (access == null) return;
            if (access.Gpu && _disableGpu)
            {
                access.Emitting.SetValue(node, false);
                access.Preprocess.SetValue(node, Convert.ChangeType(0, access.Preprocess.PropertyType));
                access.Visible.SetValue(node, false);
                _disabledGpuCount++;
                if (_disabledGpuCount <= 8)
                    Console.Error.WriteLine($"[STS2 Linux Compat] GPU emitter suppressed #{_disabledGpuCount}: {nodeType.Name}");
                return;
            }
            if (Convert.ToInt64(access.Amount.GetValue(node)) > _cap)
                access.Amount.SetValue(node, Convert.ChangeType(_cap, access.Amount.PropertyType));
        }
        catch (Exception error)
        {
            if (_nodeErrorLogged) return;
            _nodeErrorLogged = true;
            Console.Error.WriteLine($"[STS2 Linux Compat] native particle handler failed: {error}");
        }
    }

    public static void Apply(Harmony harmony)
    {
        _cap = QualityProfile.ParticleCap;
        Console.Error.WriteLine($"[STS2 Linux Compat] ParticleDiet cap = {_cap} (quality={QualityProfile.Current})");

        var ngame = AccessTools.TypeByName("MegaCrit.Sts2.Core.Nodes.NGame");
        Assembly godotSharp = null;
        var t = ngame?.BaseType;
        while (t != null && t != typeof(object))
        {
            if (t.Assembly.GetName().Name == "GodotSharp") { godotSharp = t.Assembly; break; }
            t = t.BaseType;
        }
        var nodeType = godotSharp?.GetType("Godot.Node");
        if (nodeType == null)
        {
            Console.Error.WriteLine("[STS2 Linux Compat] ParticleDiet: Godot.Node unresolved");
            return;
        }

        int patched = 0;
        foreach (var m in nodeType.GetMethods(BindingFlags.Public | BindingFlags.Instance))
        {
            if (m.Name != "AddChild" || m.IsGenericMethod) continue;
            try
            {
                harmony.Patch(m, postfix: new HarmonyMethod(typeof(ParticleDietPatches), nameof(AddChildPostfix)));
                patched++;
            }
            catch { }
        }
        Console.Error.WriteLine($"[STS2 Linux Compat] ParticleDiet installed (cap={_cap}, AddChild x{patched})");
    }

    public static void AddChildPostfix(object __0)
    {
        if (__0 == null) return;
        try { CapRecursive(__0, 0); }
        catch { }
    }

    private static void CapRecursive(object node, int depth)
    {
        if (node == null || depth > 6) return;
        var nt = node.GetType();
        var name = nt.Name;
        if (name == "GpuParticles2D" || name == "CpuParticles2D" ||
            name == "GpuParticles3D" || name == "CpuParticles3D")
        {
            var amountProp = nt.GetProperty("Amount");
            if (amountProp != null)
            {
                try
                {
                    var cur = Convert.ToInt32(amountProp.GetValue(node));
                    if (cur > _cap)
                        amountProp.SetValue(node, Convert.ChangeType(_cap, amountProp.PropertyType));
                }
                catch { }
            }
        }

        var getCount = AccessTools.Method(nt, "GetChildCount");
        if (getCount == null) return;
        int count;
        try { count = (int)getCount.Invoke(node, new object[] { false }); } catch { return; }
        if (count == 0) return;

        MethodInfo getChild = null;
        foreach (var mi in nt.GetMethods(BindingFlags.Public | BindingFlags.Instance))
        {
            if (mi.Name != "GetChild" || mi.IsGenericMethod) continue;
            var ps = mi.GetParameters();
            if (ps.Length == 2 && ps[0].ParameterType == typeof(int)) { getChild = mi; break; }
        }
        if (getChild == null) return;
        for (int i = 0; i < count; i++)
        {
            object child = null;
            try { child = getChild.Invoke(node, new object[] { i, false }); } catch { }
            CapRecursive(child, depth + 1);
        }
    }
}
