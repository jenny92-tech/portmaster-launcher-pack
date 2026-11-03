// INPUT:  显式诊断开关与游戏现有资源加载会话
// OUTPUT: 加载前后资源类别、托管堆和可选 glibc 映射统计
// POS:    只读统计，不改变预载、卸载、对象生命周期或 GC 行为
using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;

namespace STS2LinuxLauncher.Patches;

public static class AssetCacheDiagnostics
{
    private static readonly bool enabled = Environment.GetEnvironmentVariable("SLL_ASSET_DIAG") == "1";
    private static readonly bool mallocEnabled = enabled && Environment.GetEnvironmentVariable("SLL_MALLOC_DIAG") == "1";
    private static readonly bool pathsEnabled = enabled && Environment.GetEnvironmentVariable("SLL_ASSET_DIAG_PATHS") == "1";
    private static int snapshots, commonPathsClaimed;
    private static readonly ConditionalWeakTable<object, object> completed = new();
    private const int MaxSnapshots = 64;
    private const int MaxPaths = 1200;
    private const BindingFlags Fields = BindingFlags.Instance | BindingFlags.NonPublic;

    public static void Begin(object session)
    {
        if (!enabled) return;
        try
        {
            if (Interlocked.Increment(ref snapshots) > MaxSnapshots) return;
            var type = session.GetType();
            var name = type.GetField("_name", Fields)?.GetValue(session) as string;
            var load = type.GetField("_toLoad", Fields)?.GetValue(session) as IEnumerable<string>;
            var vfx = type.GetField("_vfxScenes", Fields)?.GetValue(session) as IEnumerable<string>;
            if (load == null || vfx == null) return;
            var counts = new Counts();
            foreach (var path in load) counts.Add(path);
            foreach (var path in vfx) counts.Add(path);
            Console.Error.WriteLine($"[ASSET-DIAG] phase=begin set={Label(name)} {counts} managed_bytes={GC.GetTotalMemory(false)}{MallocSummary()}");
            if (!pathsEnabled || name != "Common" ||
                Interlocked.CompareExchange(ref commonPathsClaimed, 1, 0) != 0) return;
            int emitted = 0, eligible = 0;
            foreach (var path in load) EmitPath(path, ref emitted, ref eligible);
            foreach (var path in vfx) EmitPath(path, ref emitted, ref eligible);
            Console.Error.WriteLine($"[ASSET-DIAG] phase=common_paths emitted={emitted} eligible={eligible} truncated={eligible > emitted} limit={MaxPaths}");
        }
        catch { }
    }

    public static void Complete(object session)
    {
        if (!enabled || Volatile.Read(ref snapshots) > MaxSnapshots) return;
        try
        {
            lock (completed)
            {
                if (completed.TryGetValue(session, out _)) return;
                completed.Add(session, new object());
            }
            var type = session.GetType();
            var name = type.GetField("_name", Fields)?.GetValue(session) as string;
            var cache = type.GetField("_cache", Fields)?.GetValue(session);
            var keys = cache?.GetType().GetProperty("Keys")?.GetValue(cache) as IEnumerable<string>;
            if (keys == null) return;
            var counts = new Counts();
            foreach (var path in keys) counts.Add(path);
            var owner = type.GetField("_assetCache", Fields)?.GetValue(session);
            var missed = owner?.GetType().GetProperty("MissedCacheAssetCount")?.GetValue(owner);
            string missedText = missed is int n ? n.ToString() : "unknown";
            Console.Error.WriteLine($"[ASSET-DIAG] phase=complete set={Label(name)} {counts} missed={missedText} managed_bytes={GC.GetTotalMemory(false)}{MallocSummary()}");
        }
        catch { }
    }

    private static string MallocSummary()
    {
        if (!mallocEnabled) return "";
        if (!OperatingSystem.IsLinux() || IntPtr.Size != 8) return " malloc=unavailable";
        IntPtr library = IntPtr.Zero;
        try
        {
            if (!NativeLibrary.TryLoad("libc.so.6", out library) ||
                !NativeLibrary.TryGetExport(library, "gnu_get_libc_version", out var version) ||
                !NativeLibrary.TryGetExport(library, "malloc", out var malloc) ||
                !NativeLibrary.TryGetExport(library, "mallinfo2", out var function) ||
                version != Dlsym(IntPtr.Zero, "gnu_get_libc_version") ||
                malloc != Dlsym(IntPtr.Zero, "malloc"))
                return " malloc=unavailable";
            return FormatMallinfo2(function);
        }
        catch { return " malloc=unavailable"; }
        finally { if (library != IntPtr.Zero) NativeLibrary.Free(library); }
    }

    // On glibc Linux, RTLD_DEFAULT is zero. Require the process-global libc
    // and malloc symbols to match, so a replacement allocator is not reported
    // as though mallinfo2 covered it. Missing libdl or symbols is unavailable.
    [DllImport("libdl.so.2", EntryPoint = "dlsym", CharSet = CharSet.Ansi)]
    private static extern IntPtr Dlsym(IntPtr handle, string symbol);

    // glibc's returned structure contains exactly ten size_t fields. Do not
    // convert to signed integers or combine fields: neither is an RSS total.
    [StructLayout(LayoutKind.Sequential)]
    private struct Mallinfo2
    {
        public nuint arena, ordblks, smblks, hblks, hblkhd, usmblks, fsmblks, uordblks, fordblks, keepcost;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate Mallinfo2 Mallinfo2Function();

    internal static string FormatMallinfo2(IntPtr function)
    {
        var value = Marshal.GetDelegateForFunctionPointer<Mallinfo2Function>(function)();
        return $" malloc=mallinfo2 arena_bytes={value.arena} uordblks_bytes={value.uordblks} fordblks_bytes={value.fordblks} hblkhd_bytes={value.hblkhd}";
    }

    private static void EmitPath(string path, ref int emitted, ref int eligible)
    {
        if (path == null || path.Length <= 6 || path.Length > 4096 ||
            !path.StartsWith("res://", StringComparison.Ordinal) || path.IndexOf('\\') >= 0) return;
        foreach (char character in path) if (char.IsControl(character)) return;
        foreach (var part in path.Substring(6).Split('/'))
            if (part.Length == 0 || part == "." || part == "..") return;
        eligible++;
        if (emitted >= MaxPaths) return;
        Console.Error.WriteLine("[ASSET-DIAG-PATH] " + path);
        emitted++;
    }

    private static string Label(string name)
    {
        if (name == "Common") return "common";
        if (name != null && name.StartsWith("characters=", StringComparison.Ordinal)) return "run";
        if (name == "Combat Room") return "combat";
        if (name == "MainMenu" || name == "MainMenuEssentials" || name == "IntroLogo") return "menu";
        return "other";
    }

    private sealed class Counts
    {
        private int total, vfx, screens, rooms, characters, images, materials, other;
        public void Add(string path)
        {
            total++;
            if (path == null) { other++; return; }
            if (path.StartsWith("res://scenes/vfx/", StringComparison.Ordinal)) vfx++;
            else if (path.StartsWith("res://scenes/screens/", StringComparison.Ordinal)) screens++;
            else if (path.StartsWith("res://scenes/rooms/", StringComparison.Ordinal)) rooms++;
            else if (path.StartsWith("res://scenes/creature", StringComparison.Ordinal) || path.StartsWith("res://scenes/character", StringComparison.Ordinal)) characters++;
            else if (path.StartsWith("res://images/", StringComparison.Ordinal)) images++;
            else if (path.StartsWith("res://materials/", StringComparison.Ordinal) || path.StartsWith("res://shaders/", StringComparison.Ordinal)) materials++;
            else other++;
        }
        public override string ToString() => $"total={total} vfx={vfx} screens={screens} rooms={rooms} characters={characters} images={images} materials={materials} other={other}";
    }
}
