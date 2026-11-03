// INPUT:  HarmonyLib、.NET 程序集解析、QualityProfile 与 Patches
// OUTPUT: InitializeGodotSharp()、Apply()、ApplyInternal()、ApplyOfficialRuntime()
// POS:    自编 Godot 及游戏侧官方运行时入口的兼容补丁安装编排
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using HarmonyLib;

namespace STS2LinuxLauncher;

/// Entry point for sts2_compat.dll. All Godot interaction is via reflection
/// (Harmony __instance/__result carry the game's GodotSharp bridge).
/// We never reference GodotSharp at compile time — avoids a duplicate GodotSharp
/// instance when hostfxr loads us into a separate ALC, which would SEGV.
public static class ModEntry
{
    private static bool _applied;
    private static Harmony _harmony;

    /// Called by the godot fork before sts2.dll loads. Installs a gamedata
    /// assembly resolver as a fallback (the launcher helper performs the primary incremental sync).
    [UnmanagedCallersOnly]
    public static int InitializeGodotSharp(
        IntPtr godotDllHandle,
        IntPtr outManagedCallbacks,
        IntPtr unmanagedCallbacks,
        int unmanagedCallbacksSize)
    {
        InstallGamedataResolver();
        return 1;
    }

    private static bool _resolverInstalled;
    private static string _gamedataDir;

    /// Falls back to ../gamedata/data_sts2_linuxbsd_arm64/ when the standard
    /// data_/ path is missing.
    private static void InstallGamedataResolver()
    {
        if (_resolverInstalled)
            return;
        try
        {
            var ourDir = System.IO.Path.GetDirectoryName(typeof(ModEntry).Assembly.Location);
            _gamedataDir = System.IO.Path.GetFullPath(
                System.IO.Path.Combine(ourDir, "..", "gamedata", "data_sts2_linuxbsd_arm64"));

            if (!System.IO.Directory.Exists(_gamedataDir))
            {
                Console.Error.WriteLine(
                    $"[STS2 Linux Compat] gamedata dir missing, resolver disabled: {_gamedataDir}");
                return;
            }

            System.Runtime.Loader.AssemblyLoadContext.Default.Resolving += ResolveFromGamedata;
            _resolverInstalled = true;
            Console.Error.WriteLine(
                $"[STS2 Linux Compat] gamedata resolver installed → {_gamedataDir}");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(
                $"[STS2 Linux Compat] InstallGamedataResolver failed: {ex.Message}");
        }
    }

    private static System.Reflection.Assembly ResolveFromGamedata(
        System.Runtime.Loader.AssemblyLoadContext ctx,
        System.Reflection.AssemblyName name)
    {
        var dllPath = System.IO.Path.Combine(_gamedataDir, name.Name + ".dll");
        if (!System.IO.File.Exists(dllPath))
            return null;
        try
        {
            var asm = ctx.LoadFromAssemblyPath(dllPath);
            Console.Error.WriteLine($"[STS2 Linux Compat] resolved {name.Name} ← gamedata/");
            return asm;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(
                $"[STS2 Linux Compat] resolve failed for {name.Name}: {ex.Message}");
            return null;
        }
    }

    /// Called by the godot fork after GodotPlugins init.
    [UnmanagedCallersOnly]
    public static void Apply() => ApplyInternal();

    /// Called from the patched game's NGame._EnterTree, after GodotSharp init.
    /// Preserve platform/save handling; apply only the resource/performance layer.
    public static void ApplyOfficialRuntime()
    {
        if (_applied) return;
        _applied = true;
        _harmony = new Harmony("net.jenny92.sts2_official_runtime_compat");
        QualityProfile.LogChosen();
        if (!Patches.ShaderCompatibilityPatches.LoadStaticOverlay())
            throw new InvalidOperationException("Official-runtime performance resource pack failed to load");
        if (MemoryBudget.ExplicitLowMode)
        {
            // The game-side atlas hooks handle explicit low mode; preserve all
            // native asset-set preloads, including combat and selected characters.
            Console.Error.WriteLine("[STS2 Linux Compat] explicit low memory: selective atlas loading; native asset-set preloads retained");
        }
        else
        {
            SafeApply("LifecyclePreloadPatches", () => Patches.LifecyclePreloadPatches.Apply(_harmony));
            SafeApply("AtlasLazyPatches", () => Patches.AtlasLazyPatches.Apply(_harmony));
        }
        Patches.ParticleDietPatches.ApplyOfficialRuntime();
        SafeApply("RenderPreparation", Patches.RenderPreparationBridge.Install);
        SafeApply("FirstCardTrace", Patches.FirstCardTrace.Install);
        Console.Error.WriteLine("[STS2 Linux Compat] official-runtime performance patches ready; platform/save handling preserved.");
    }

    public static void ApplyInternal()
    {
        if (_applied)
            return;
        _applied = true;

        _harmony = new Harmony("net.jenny92.sts2_linux_compat");
        QualityProfile.LogChosen();
        SafeApply("MemoryProbePatches", () => Patches.MemoryProbePatches.Apply(_harmony));
        SafeApply("PlatformPatches", () => Patches.PlatformPatches.Apply(_harmony));
        SafeApply("LifecyclePreloadPatches", () => Patches.LifecyclePreloadPatches.Apply(_harmony));
        SafeApply("AtlasLazyPatches", () => Patches.AtlasLazyPatches.Apply(_harmony));
        SafeApply("TransitionMaterialPatches", () => Patches.TransitionMaterialPatches.Apply(_harmony));
        SafeApply("ShaderCompatibilityPatches", () =>
        {
            if (!Patches.ShaderCompatibilityPatches.LoadStaticOverlay())
                throw new InvalidOperationException("Render resource pack failed to load");
        });
        SafeApply("MenuDietPatches", () => Patches.MenuDietPatches.Apply(_harmony));
        SafeApply("ParticleDietPatches", () => Patches.ParticleDietPatches.Apply(_harmony));
        SafeApply("GameSettingsDefaultPatches", () => Patches.GameSettingsDefaultPatches.Apply(_harmony));
        Console.Error.WriteLine("[STS2 Linux Compat] ready.");
    }

    private static void SafeApply(string name, Action body)
    {
        try { body(); }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[STS2 Linux Compat] {name}.Apply failed (continuing): {ex.Message}");
        }
    }
}
