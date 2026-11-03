// INPUT:  Explicit SLL_HEAP_TRIM trial flag and the current Linux glibc allocator
// OUTPUT: At most one malloc_trim(0) attempt, with elapsed time and release hint
// POS:    Optional arena-page reclamation during the covered combat preparation
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace STS2LinuxLauncher.Patches;

internal static class NativeHeapTrim
{
    private static readonly bool enabled = Environment.GetEnvironmentVariable("SLL_HEAP_TRIM") == "1";
    private static int attempted;

    internal static void DuringCoveredPreparation()
    {
        if (!enabled || !OperatingSystem.IsLinux() || IntPtr.Size != 8 ||
            Interlocked.Exchange(ref attempted, 1) != 0) return;
        IntPtr library = IntPtr.Zero;
        try
        {
            if (!NativeLibrary.TryLoad("libc.so.6", out library)) return;
            foreach (var symbol in new[] { "gnu_get_libc_version", "malloc", "free", "calloc", "realloc", "malloc_trim" })
                if (!NativeLibrary.TryGetExport(library, symbol, out var address) ||
                    address == IntPtr.Zero || address != Dlsym(IntPtr.Zero, symbol))
                {
                    Console.Error.WriteLine("[NATIVE-TRIM] skipped: process allocator differs or is unavailable");
                    return;
                }
            var trim = Marshal.GetDelegateForFunctionPointer<Trim>(NativeLibrary.GetExport(library, "malloc_trim"));
            long before = ReadRssKiB();
            var started = Stopwatch.GetTimestamp();
            int result = trim(0);
            double elapsed = Stopwatch.GetElapsedTime(started).TotalMilliseconds;
            long after = ReadRssKiB();
            Console.Error.WriteLine($"[NATIVE-TRIM] release_hint={result} elapsed_ms={elapsed:F1} rss_before_kib={before} rss_after_kib={after}");
        }
        catch { Console.Error.WriteLine("[NATIVE-TRIM] skipped: native API unavailable"); }
        finally { if (library != IntPtr.Zero) NativeLibrary.Free(library); }
    }

    private static long ReadRssKiB()
    {
        try
        {
            foreach (var line in File.ReadLines("/proc/self/status"))
                if (line.StartsWith("VmRSS:", StringComparison.Ordinal))
                {
                    var fields = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                    return fields.Length == 3 && fields[2] == "kB" && long.TryParse(fields[1], out long value) ? value : -1;
                }
        }
        catch { }
        return -1;
    }

    [DllImport("libdl.so.2", EntryPoint = "dlsym", CharSet = CharSet.Ansi)]
    private static extern IntPtr Dlsym(IntPtr handle, string symbol);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int Trim(nuint pad);
}
