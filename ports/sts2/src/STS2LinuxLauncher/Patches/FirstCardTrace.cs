// INPUT:  SLL_FIRST_CARD_TRACE、游戏 GodotSharp、原生 ProcessFrame 与资源加载标记
// OUTPUT: Install()、Begin()、Resource() 及有界首次出牌计时日志
// POS:    区分首次出牌资源加载与绘制管线停顿，不改变攻击或特效行为
using System;
using System.Diagnostics;
using System.Reflection;
using System.Threading;
using HarmonyLib;

namespace STS2LinuxLauncher.Patches;

public static class FirstCardTrace
{
    private static readonly Stopwatch Clock = Stopwatch.StartNew();
    private static readonly bool Enabled = Environment.GetEnvironmentVariable("SLL_FIRST_CARD_TRACE") == "1";
    private static readonly string[] MonitorNames = { "PipelineCompilationsCanvas", "PipelineCompilationsMesh",
        "PipelineCompilationsSurface", "PipelineCompilationsDraw", "PipelineCompilationsSpecialization" };
    private static object _tree;
    private static EventInfo _frameEvent;
    private static Delegate _frameHandler;
    private static MethodInfo _getMonitor;
    private static object[] _monitors;
    private static double[] _baseline;
    private static int _started;
    private static int _records;
    private static int _warmupRecords;
    [ThreadStatic] private static int _warmupDepth;
    private static bool _active;
    private static bool _installed;
    private static long _deadline;
    private static long _lastFrame;
    private static long _nextHeartbeat;
    private static string _lastResource = "none";

    public static void Install()
    {
        if (!Enabled) return;
        var type = AccessTools.TypeByName("MegaCrit.Sts2.Core.Nodes.NGame")?.BaseType;
        while (type != null && type.Assembly.GetName().Name != "GodotSharp") type = type.BaseType;
        var api = type?.Assembly ?? throw new InvalidOperationException("Trace: game GodotSharp missing");
        _tree = api.GetType("Godot.Engine").GetMethod("GetMainLoop", Type.EmptyTypes).Invoke(null, null);
        _frameEvent = _tree.GetType().GetEvent("ProcessFrame")
            ?? throw new InvalidOperationException("Trace: ProcessFrame event missing");
        _frameHandler = Delegate.CreateDelegate(_frameEvent.EventHandlerType,
            typeof(FirstCardTrace).GetMethod(nameof(OnFrame)));
        var monitorType = api.GetType("Godot.Performance+Monitor");
        _getMonitor = api.GetType("Godot.Performance")?.GetMethod("GetMonitor", new[] { monitorType });
        if (_getMonitor == null) throw new InvalidOperationException("Trace: pipeline monitor API missing");
        _monitors = new object[MonitorNames.Length];
        for (int i = 0; i < _monitors.Length; i++) _monitors[i] = Enum.Parse(monitorType, MonitorNames[i]);
        _baseline = ReadCounters();
        _frameEvent.AddEventHandler(_tree, _frameHandler);
        _installed = true;
        Console.Error.WriteLine("[FIRST-CARD] armed: first play will capture resource timings and pipeline counters for at most 5 minutes; GPU effects enabled.");
    }

    public static void Begin()
    {
        if (!Enabled || !_installed || Interlocked.CompareExchange(ref _started, 1, 0) != 0) return;
        try
        {
            _deadline = Clock.ElapsedMilliseconds + 300000;
            _nextHeartbeat = Clock.ElapsedMilliseconds + 10000;
            _active = true;
            Write("first play entered; taking pipeline baseline", true);
            _baseline = ReadCounters();
            Write("pipeline baseline " + Counters(), true);
        }
        catch (Exception error) { StopAfterError(error); }
    }

    internal static bool EnterWarmupResources()
    {
        if (!Enabled) return false;
        _warmupDepth++;
        return true;
    }

    internal static void ExitWarmupResources(bool entered)
    {
        if (entered) _warmupDepth--;
    }

    public static void Resource(string phase, string kind, string path)
    {
        if (Enabled && _warmupDepth > 0)
        {
            try
            {
                if (Interlocked.Increment(ref _warmupRecords) <= 64)
                    Console.Error.WriteLine("[RENDER-WARMUP] t=" + Clock.ElapsedMilliseconds + "ms thread=" +
                        Environment.CurrentManagedThreadId + " resource " + kind + " " + path + " " + phase);
            }
            catch { /* Diagnostics must not interrupt a game resource call. */ }
        }
        if (!_active) return;
        _lastResource = kind + " " + path + " " + phase;
        Write("resource " + _lastResource);
    }

    public static void OnFrame()
    {
        try { ObserveFrame(); }
        catch (Exception error) { StopAfterError(error); }
    }

    private static void ObserveFrame()
    {
        long now = Clock.ElapsedMilliseconds;
        long gap = now - _lastFrame;
        _lastFrame = now;
        if (!_active) return;
        if (gap >= 250) Write("FRAME GAP " + gap + "ms; " + Counters() + "; last=" + _lastResource, true);
        if (now >= _nextHeartbeat)
        {
            _nextHeartbeat = now + 10000;
            Write("heartbeat " + Counters() + "; last=" + _lastResource, true);
        }
        if (now >= _deadline)
        {
            _active = false;
            _frameEvent.RemoveEventHandler(_tree, _frameHandler);
            Console.Error.WriteLine("[FIRST-CARD] capture finished; frame listener removed.");
        }
    }

    private static void StopAfterError(Exception error)
    {
        _active = false;
        _installed = false;
        try { _frameEvent?.RemoveEventHandler(_tree, _frameHandler); } catch { }
        Console.Error.WriteLine("[FIRST-CARD] diagnostic disabled after error: " + error.Message);
    }

    private static double[] ReadCounters()
    {
        var values = new double[_monitors.Length];
        for (int i = 0; i < values.Length; i++)
            values[i] = Convert.ToDouble(_getMonitor.Invoke(null, new[] { _monitors[i] }));
        return values;
    }

    private static string Counters()
    {
        var values = ReadCounters();
        var parts = new string[values.Length];
        for (int i = 0; i < values.Length; i++)
            parts[i] = MonitorNames[i] + "=" + values[i] + "(delta=" + (values[i] - _baseline[i]) + ")";
        return string.Join(" ", parts);
    }

    private static void Write(string message, bool priority = false)
    {
        if (!priority && Interlocked.Increment(ref _records) > 200) return;
        Console.Error.WriteLine("[FIRST-CARD] t=" + Clock.ElapsedMilliseconds + "ms thread=" +
            Environment.CurrentManagedThreadId + " " + message);
    }
}
