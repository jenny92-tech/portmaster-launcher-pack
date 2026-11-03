// INPUT:  显式诊断开关、Godot 反射 API 与输入事件
// OUTPUT: 首个主菜单开始的有界焦点、设备和事件类别计数
// POS:    不修改或消费输入事件，不记录按键值或文本
using System;
using System.Diagnostics;
using System.Reflection;
using System.Threading;

namespace STS2LinuxLauncher.Patches;

public static class InputDiagnostics
{
    private static readonly bool Enabled = Environment.GetEnvironmentVariable("SLL_INPUT_DIAG") == "1";
    private static long started;
    private static int done, lastInterval, keyboard, joyButton, joyMotion, mouse, other;

    public static void Observe(object inputEvent)
    {
        if (!Enabled || Volatile.Read(ref done) != 0 || Volatile.Read(ref started) == 0) return;
        try
        {
            var type = inputEvent?.GetType();
            while (type != null)
            {
                switch (type.FullName)
                {
                    case "Godot.InputEventKey": Interlocked.Increment(ref keyboard); return;
                    case "Godot.InputEventJoypadButton": Interlocked.Increment(ref joyButton); return;
                    case "Godot.InputEventJoypadMotion": Interlocked.Increment(ref joyMotion); return;
                    case "Godot.InputEventMouse": Interlocked.Increment(ref mouse); return;
                }
                type = type.BaseType;
            }
            Interlocked.Increment(ref other);
        }
        catch { }
    }

    public static void Start(object node)
    {
        if (!Enabled || Volatile.Read(ref done) != 0 || Volatile.Read(ref started) != 0) return;
        try
        {
            if (Interlocked.CompareExchange(ref started, Stopwatch.GetTimestamp(), 0) == 0)
                Snapshot(node, "start", 0);
        }
        catch { Interlocked.Exchange(ref done, 1); }
    }

    public static void Tick(object node)
    {
        long beginning = Volatile.Read(ref started);
        if (!Enabled || beginning == 0 || Volatile.Read(ref done) != 0) return;
        try
        {
            var seconds = Stopwatch.GetElapsedTime(beginning).TotalSeconds;
            int interval = Math.Min(4, (int)(seconds / 15));
            if (interval <= lastInterval) return;
            lastInterval = interval;
            if (interval == 4) Interlocked.Exchange(ref done, 1);
            Snapshot(node, interval == 4 ? "end" : "progress", (int)seconds);
        }
        catch { Interlocked.Exchange(ref done, 1); }
    }

    private static void Snapshot(object node, string phase, int elapsedSeconds)
    {
        string focus = "unknown", count = "unknown";
        try
        {
            var type = node?.GetType();
            while (type != null && type.Assembly.GetName().Name != "GodotSharp") type = type.BaseType;
            var api = type?.Assembly;
            var display = api?.GetType("Godot.DisplayServer");
            var method = display?.GetMethod("WindowIsFocused", BindingFlags.Public | BindingFlags.Static, null, new[] { typeof(int) }, null);
            if (method?.Invoke(null, new object[] { 0 }) is bool focused) focus = focused ? "true" : "false";
        }
        catch { }
        try
        {
            var type = node?.GetType();
            while (type != null && type.Assembly.GetName().Name != "GodotSharp") type = type.BaseType;
            var input = type?.Assembly.GetType("Godot.Input");
            var joypads = input?.GetMethod("GetConnectedJoypads", BindingFlags.Public | BindingFlags.Static, null, Type.EmptyTypes, null)?.Invoke(null, null);
            try { if (joypads?.GetType().GetProperty("Count")?.GetValue(joypads) is int n) count = n.ToString(); }
            finally { (joypads as IDisposable)?.Dispose(); }
        }
        catch { }
        Console.Error.WriteLine($"[INPUT-DIAG] phase={phase} elapsed_s={elapsedSeconds} focused={focus} joypads={count} key={Volatile.Read(ref keyboard)} joy_button={Volatile.Read(ref joyButton)} joy_motion={Volatile.Read(ref joyMotion)} mouse={Volatile.Read(ref mouse)} other={Volatile.Read(ref other)}");
    }
}
