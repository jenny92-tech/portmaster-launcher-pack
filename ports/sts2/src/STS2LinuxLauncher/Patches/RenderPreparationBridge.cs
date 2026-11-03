// INPUT:  游戏的 GodotSharp、port_compat.pck 场景与经验证的游戏侧入口
// OUTPUT: Install()、LoadMainMenuAfterStartup()、CombatRoomReady() 与材质/缓存桥
// POS:    无 GodotSharp 编译引用的原生渲染适配桥，保留实际后端与游戏存档行为
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Threading.Tasks;
using HarmonyLib;

namespace STS2LinuxLauncher.Patches;

public static class RenderPreparationBridge
{
    private static Assembly _api;
    private static object _node;
    private static object _tree;
    private static EventInfo _startEvent;
    private static object _eventTarget;
    private static Delegate _startHandler;
    private static bool _ready;
    private static Type _objectType, _arrayType, _variantType, _nameType;
    private static MethodInfo _variantFrom, _arrayAdd, _callv, _makeName;
    private static object _effectCallable;
    private static bool _reportedError;

    public static void Install()
    {
        if (_ready || _startHandler != null) return;
        var type = AccessTools.TypeByName("MegaCrit.Sts2.Core.Nodes.NGame")?.BaseType;
        while (type != null && type.Assembly.GetName().Name != "GodotSharp") type = type.BaseType;
        _api = type?.Assembly ?? throw new InvalidOperationException("Render preparation: game GodotSharp missing");
        _tree = _api.GetType("Godot.Engine").GetMethod("GetMainLoop", Type.EmptyTypes).Invoke(null, null);
        if (_tree != null)
        {
            _startEvent = _tree.GetType().GetEvent("ProcessFrame");
            _eventTarget = _tree;
        }
        else
        {
            _startEvent = _api.GetType("Godot.RenderingServer").GetEvent("FramePostDraw");
            _eventTarget = null;
        }
        if (_startEvent == null) throw new InvalidOperationException("Render preparation: native deferred start unavailable");
        _startHandler = Delegate.CreateDelegate(_startEvent.EventHandlerType,
            typeof(RenderPreparationBridge).GetMethod(nameof(StartOnFrame)));
        _startEvent.AddEventHandler(_eventTarget, _startHandler);
    }

    public static void StartOnFrame()
    {
        _startEvent.RemoveEventHandler(_eventTarget, _startHandler);
        _startHandler = null;
        try
        {
            _tree = _api.GetType("Godot.Engine").GetMethod("GetMainLoop", Type.EmptyTypes).Invoke(null, null);
            if (_tree == null) throw new InvalidOperationException("Scene tree unavailable");
            _objectType = _api.GetType("Godot.GodotObject");
            _arrayType = _api.GetType("Godot.Collections.Array");
            _variantType = _api.GetType("Godot.Variant");
            _nameType = _api.GetType("Godot.StringName");
            _variantFrom = _variantType.GetMethods().Single(m => m.Name == "From" && m.IsGenericMethodDefinition && m.GetParameters().Length == 1);
            _arrayAdd = _arrayType.GetMethod("Add", new[] { _variantType });
            _makeName = _nameType.GetMethods().Single(m => m.Name == "op_Implicit" && m.ReturnType == _nameType && m.GetParameters()[0].ParameterType == typeof(string));
            _callv = _objectType.GetMethod("Callv", new[] { _nameType, _arrayType });
            if (_callv == null || _arrayAdd == null) throw new InvalidOperationException("Native Callv/Array interface unavailable");
            var loader = _api.GetType("Godot.ResourceLoader").GetMethods().First(m => m.Name == "Load" && !m.IsGenericMethod && m.GetParameters().Length == 3);
            var packed = loader.Invoke(null, DefaultArguments(loader, "res://port_compat/render_compat.tscn"));
            if (packed == null) throw new InvalidOperationException("Render compatibility scene missing");
            var instantiate = packed.GetType().GetMethods().Single(m => m.Name == "Instantiate" && !m.IsGenericMethod && m.GetParameters().Length == 1);
            _node = instantiate.Invoke(packed, DefaultArguments(instantiate));
            var root = Read(_tree, "Root");
            var addChild = root.GetType().GetMethods().First(m => m.Name == "AddChild" && !m.IsGenericMethod && m.GetParameters().Length == 3);
            addChild.Invoke(root, DefaultArguments(addChild, _node));
            if (!CallBool("is_compat_ready")) throw new InvalidOperationException("Render script did not become ready");
            var callableType = _api.GetType("Godot.Callable");
            var from = callableType.GetMethod("From", new[] { typeof(Action) });
            _effectCallable = from.Invoke(null, new object[] { (Action)CreateWarmHitEffects });
            var signal = _makeName.Invoke(null, new object[] { "effects_requested" });
            try
            {
                var status = _objectType.GetMethod("Connect", new[] { _nameType, callableType, typeof(uint) })
                    .Invoke(_node, new[] { signal, _effectCallable, (object)0u });
                if (Convert.ToInt32(status) != 0) throw new InvalidOperationException("Connecting effects_requested failed: " + status);
            }
            finally { (signal as IDisposable)?.Dispose(); }
            _ready = true;
            if (Environment.GetEnvironmentVariable("SLL_TEXTURE_DIAG") == "1")
                TextureDiagnosticBridge.Install(_api, root);
            Console.Error.WriteLine("[RENDER-COMPAT] game-side bridge ready; actual Vulkan/OpenGL policy owned by native runtime");
        }
        catch (Exception error) { Report(error); _ready = false; }
    }

    // Called only by the original LaunchMainMenu state machine. The timer and
    // ResourceLoader remain on Godot's frame thread, as does LoadMainMenu.
    public static Task LoadMainMenuAfterStartup(object game, bool openTimeline)
    {
        var method = game.GetType().GetMethod("LoadMainMenu", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic,
            null, new[] { typeof(bool) }, null) ?? throw new InvalidOperationException("LoadMainMenu missing");
        Task Invoke()
        {
            try { return (Task)method.Invoke(game, new object[] { openTimeline }); }
            catch (TargetInvocationException error) when (error.InnerException != null)
            {
                ExceptionDispatchInfo.Capture(error.InnerException).Throw();
                throw;
            }
        }
        bool continueNow;
        try
        {
            continueNow = (_ready && CallBool("is_startup_effects_ready")) || (!_ready && _startHandler == null);
        }
        catch (Exception error) { Report(error); continueNow = true; }
        if (continueNow) return Invoke();
        var completion = new TaskCompletionSource();
        var started = Stopwatch.GetTimestamp();
        EventInfo frame = null;
        Delegate handler = null;
        void Poll()
        {
            bool done;
            try { done = _ready ? CallBool("is_startup_effects_ready") : _startHandler == null; }
            catch (Exception error) { Report(error); done = true; }
            if (!done && Stopwatch.GetElapsedTime(started).TotalSeconds < 7) return;
            try { frame.RemoveEventHandler(_tree, handler); }
            catch (Exception error) { Report(error); }
            Console.Error.WriteLine($"[RENDER-COMPAT] startup effects gate {(done ? "terminal; continuing" : "timed out; continuing")} elapsed_ms={Stopwatch.GetElapsedTime(started).TotalMilliseconds:F0}");
            try
            {
                var task = Invoke();
                void Finish()
                {
                    try { task.GetAwaiter().GetResult(); completion.TrySetResult(); }
                    catch (OperationCanceledException) { completion.TrySetCanceled(); }
                    catch (Exception error) { completion.TrySetException(error); }
                }
                if (task.IsCompleted) Finish(); else task.GetAwaiter().OnCompleted(Finish);
            }
            catch (Exception error) { completion.TrySetException(error); }
        }
        try
        {
            frame = _tree?.GetType().GetEvent("ProcessFrame") ?? throw new InvalidOperationException("Startup frame event unavailable");
            Action poll = Poll;
            handler = Delegate.CreateDelegate(frame.EventHandlerType, poll.Target, poll.Method);
            frame.AddEventHandler(_tree, handler);
        }
        catch (Exception error)
        {
            Report(error);
            return Invoke();
        }
        return completion.Task;
    }

    private static object[] DefaultArguments(MethodInfo method, params object[] first)
    {
        var parameters = method.GetParameters();
        var values = new object[parameters.Length];
        for (int i = 0; i < values.Length; i++)
            values[i] = i < first.Length ? first[i] : parameters[i].HasDefaultValue ? parameters[i].DefaultValue :
                parameters[i].ParameterType.IsValueType ? Activator.CreateInstance(parameters[i].ParameterType) : null;
        return values;
    }

    private static object Read(object value, string property) => value?.GetType()
        .GetProperty(property, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance)?.GetValue(value);

    private static object Variant(object value)
    {
        if (value == null) return Activator.CreateInstance(_variantType);
        var type = _objectType.IsInstanceOfType(value) ? _objectType : value.GetType();
        return _variantFrom.MakeGenericMethod(type).Invoke(null, new[] { value });
    }

    private static object NativeArray(IEnumerable values)
    {
        var array = Activator.CreateInstance(_arrayType);
        try
        {
            foreach (var value in values)
            {
                var variant = Variant(value);
                try { _arrayAdd.Invoke(array, new[] { variant }); }
                finally { (variant as IDisposable)?.Dispose(); }
            }
            return array;
        }
        catch { (array as IDisposable)?.Dispose(); throw; }
    }

    private static object Call(string method, params object[] values)
    {
        var arguments = NativeArray(values);
        object name = null;
        try
        {
            name = _makeName.Invoke(null, new object[] { method });
            return _callv.Invoke(_node, new[] { name, arguments });
        }
        finally { (name as IDisposable)?.Dispose(); (arguments as IDisposable)?.Dispose(); }
    }

    private static object CallObject(string method, params object[] values)
    {
        var result = Call(method, values);
        try
        {
            if (Read(result, "VariantType")?.ToString() != "Object") return null;
            return _variantType.GetMethod("AsGodotObject", Type.EmptyTypes).Invoke(result, null);
        }
        finally { (result as IDisposable)?.Dispose(); }
    }

    private static bool CallBool(string method, params object[] values)
    {
        var result = Call(method, values);
        try
        {
            return Read(result, "VariantType")?.ToString() == "Bool" &&
                (bool)_variantType.GetMethod("AsBool", Type.EmptyTypes).Invoke(result, null);
        }
        finally { (result as IDisposable)?.Dispose(); }
    }

    private static void CallVoid(string method, params object[] values)
    {
        var result = Call(method, values);
        (result as IDisposable)?.Dispose();
    }

    public static object RemapMaterial(object source, string path)
    {
        if (!_ready || source == null) return source;
        try { return CallObject("remap_material", source, path ?? "") ?? source; }
        catch (Exception error) { Report(error); return source; }
    }

    public static object FilterEvicted(object resource)
    {
        if (!_ready || resource == null) return resource;
        try { return CallBool("is_resource_protected", resource) ? null : resource; }
        catch (Exception error) { Report(error); return resource; }
    }

    public static void CombatRoomReady(object room)
    {
        if (!_ready || room == null || Read(room, "Mode")?.ToString() != "ActiveCombat") return;
        try
        {
            var actors = Read(room, "CreatureNodes") as IEnumerable;
            var container = Read(room, "CombatVfxContainer");
            if (actors == null || container == null) return;
            var array = NativeArray(actors);
            try { CallVoid("prepare_room", room, array, container); }
            finally { (array as IDisposable)?.Dispose(); }
        }
        catch (Exception error) { Report(error); }
    }

    public static void RepairCachedMaterials(object instance)
    {
        if (!_ready || instance == null) return;
        try
        {
            var type = instance.GetType();
            var flags = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance;
            string[] materialNames, nodeNames;
            switch (type.FullName)
            {
                case "MegaCrit.Sts2.Core.Nodes.Cards.NCard":
                    materialNames = new[] { "_portraitBlurMaterial", "_canvasGroupMaskBlurMaterial", "_canvasGroupBlurMaterial", "_canvasGroupMaskMaterial" };
                    nodeNames = new[] { "_portrait", "_ancientPortrait", "_portraitCanvasGroup" };
                    break;
                case "MegaCrit.Sts2.Core.Nodes.Screens.MainMenu.NMainMenu":
                    materialNames = new[] { "_blur" }; nodeNames = Array.Empty<string>(); break;
                case "MegaCrit.Sts2.Core.Nodes.Screens.Timeline.NEpochSlot":
                    materialNames = new[] { "_hsv", "_blurShader" }; nodeNames = new[] { "_portrait" }; break;
                case "MegaCrit.Sts2.Core.Nodes.Vfx.NRadialBlurVfx":
                    materialNames = new[] { "_blurShader" }; nodeNames = new[] { "_rect" }; break;
                default: return;
            }
            var changed = new Dictionary<object, object>();
            foreach (var name in materialNames)
            {
                var field = type.GetField(name, flags);
                var original = field?.GetValue(instance);
                var replacement = RemapMaterial(original, Read(original, "ResourcePath") as string);
                if (original == null || ReferenceEquals(original, replacement) || !field.FieldType.IsInstanceOfType(replacement)) continue;
                field.SetValue(instance, replacement);
                changed[original] = replacement;
            }
            if (changed.Count == 0) return;
            foreach (var name in nodeNames)
                ReplaceNodeMaterial(type.GetField(name, flags)?.GetValue(instance), changed);
            if (type.FullName == "MegaCrit.Sts2.Core.Nodes.Screens.MainMenu.NMainMenu")
                ReplaceNodeMaterial(Read(instance, "BlurBackstop"), changed);
            if (type.FullName == "MegaCrit.Sts2.Core.Nodes.Screens.Timeline.NEpochSlot")
                ReplaceNodeMaterial(GetNamedNode(instance, "%Blur"), changed);
        }
        catch (Exception error) { Report(error); }
    }

    private static void ReplaceNodeMaterial(object node, Dictionary<object, object> changed)
    {
        var property = node?.GetType().GetProperty("Material");
        var original = property?.GetValue(node);
        if (original != null && changed.TryGetValue(original, out var replacement)) property.SetValue(node, replacement);
    }

    private static object GetNamedNode(object node, string path)
    {
        var api = _api;
        if (api == null)
        {
            var type = node?.GetType();
            while (type != null && type.Assembly.GetName().Name != "GodotSharp") type = type.BaseType;
            api = type?.Assembly ?? throw new InvalidOperationException("GodotSharp missing");
        }
        var pathType = api.GetType("Godot.NodePath");
        var makePath = pathType.GetMethods().Single(m => m.Name == "op_Implicit" && m.ReturnType == pathType && m.GetParameters()[0].ParameterType == typeof(string));
        var nativePath = makePath.Invoke(null, new object[] { path });
        try
        {
            var getNode = api.GetType("Godot.Node").GetMethods().Single(m => m.Name == "GetNodeOrNull" && !m.IsGenericMethod && m.GetParameters().Length == 1 && m.GetParameters()[0].ParameterType == pathType);
            return getNode.Invoke(node, new[] { nativePath });
        }
        finally { (nativePath as IDisposable)?.Dispose(); }
    }

    // The generated Smooth scenes carry this marker; original scenes never do.
    // The patched game _Ready methods preserve positioning before consulting it.
    public static bool IsSimpleEffect(object node)
    {
        try
        {
            var type = node?.GetType().FullName;
            return (type is "MegaCrit.Sts2.Core.Nodes.Vfx.NHitSparkVfx" or
                "MegaCrit.Sts2.Core.Nodes.Vfx.Ui.NPowerAppliedDebuffVfx" or
                "MegaCrit.Sts2.Core.Nodes.Vfx.Ui.NPowerAppliedBuffVfx") &&
                GetNamedNode(node, "PortSimpleEffect") != null;
        }
        catch (Exception error) { Report(error); return false; }
    }

    public static void CreateWarmHitEffects()
    {
        if (!_ready) return;
        var created = new List<object>();
        bool transferred = false;
        try
        {
            var room = CallObject("get_preparing_room");
            var actors = Read(room, "CreatureNodes") as IEnumerable;
            if (actors == null) return;
            // This callback follows the drawn loading cover and Spine previews.
            // Reclaim older free arena pages before preparing hit effects; later
            // deferred node deletion may still leave additional reclaimable pages.
            NativeHeapTrim.DuringCoveredPreparation();
            var game = room.GetType().Assembly;
            var spark = game.GetType("MegaCrit.Sts2.Core.Nodes.Vfx.NHitSparkVfx");
            var numbers = game.GetType("MegaCrit.Sts2.Core.Nodes.Vfx.NDamageNumVfx");
            int targets = 0;
            foreach (var actor in actors)
            {
                var entity = Read(actor, "Entity");
                if (entity == null || Read(entity, "IsAlive") is false || targets++ >= 3) continue;
                if (!CallBool("simple_effects_enabled"))
                    AddFactoryResult(created, spark, entity, 0);
                AddFactoryResult(created, numbers, entity, 6);
                AddFactoryResult(created, numbers, entity, 1234567890);
                var audioStarted = Stopwatch.GetTimestamp();
                WarmHitAudio(game, entity);
                Console.Error.WriteLine($"[RENDER-WARMUP] audio elapsed_ms={Stopwatch.GetElapsedTime(audioStarted).TotalMilliseconds:F0}");
            }
            var transferStarted = Stopwatch.GetTimestamp();
            var effects = NativeArray(created);
            try
            {
                var arguments = NativeArray(new[] { effects });
                object name = null;
                try
                {
                    name = _makeName.Invoke(null, new object[] { "receive_hit_effects" });
                    transferred = true;
                    var result = _callv.Invoke(_node, new[] { name, arguments });
                    (result as IDisposable)?.Dispose();
                }
                finally { (name as IDisposable)?.Dispose(); (arguments as IDisposable)?.Dispose(); }
            }
            finally { (effects as IDisposable)?.Dispose(); }
            Console.Error.WriteLine($"[RENDER-WARMUP] visual hit factories prepared={created.Count}; transfer_ms={Stopwatch.GetElapsedTime(transferStarted).TotalMilliseconds:F0}; audio volume=0; no damage commands");
        }
        catch (Exception error)
        {
            Report(error);
            if (!transferred)
                foreach (var node in created)
                    if (node?.GetType().GetMethod("GetParent", Type.EmptyTypes)?.Invoke(node, null) == null)
                        node?.GetType().GetMethod("QueueFree", Type.EmptyTypes)?.Invoke(node, null);
        }
    }

    private static void AddFactoryResult(List<object> output, Type type, object entity, int number)
    {
        if (type == null) return;
        var method = type.GetMethods(BindingFlags.Public | BindingFlags.Static).FirstOrDefault(m =>
            m.Name == "Create" && m.GetParameters().Length == (number == 0 ? 2 : 3) &&
            m.GetParameters()[0].ParameterType.IsInstanceOfType(entity) && m.GetParameters()[^1].ParameterType == typeof(bool) &&
            (number == 0 || m.GetParameters()[1].ParameterType == typeof(int)));
        if (method == null) return;
        var started = Stopwatch.GetTimestamp();
        object node;
        var tracing = FirstCardTrace.EnterWarmupResources();
        try
        {
            node = method.Invoke(null, number == 0 ? new[] { entity, (object)false } : new[] { entity, (object)number, false });
        }
        finally { FirstCardTrace.ExitWarmupResources(tracing); }
        Console.Error.WriteLine($"[RENDER-WARMUP] factory={type.Name} number={number} elapsed_ms={Stopwatch.GetElapsedTime(started).TotalMilliseconds:F0}");
        if (node != null) output.Add(node);
    }

    private static void WarmHitAudio(Assembly game, object entity)
    {
        var audio = game.GetType("MegaCrit.Sts2.Core.Nodes.Audio.NAudioManager")?.GetProperty("Instance", BindingFlags.Public | BindingFlags.Static)?.GetValue(null);
        var monster = Read(entity, "Monster");
        if (audio == null || monster == null) return;
        var method = audio.GetType().GetMethods().FirstOrDefault(m => m.Name == "PlayOneShot" &&
            m.GetParameters().Length == 3 && m.GetParameters()[0].ParameterType == typeof(string) &&
            m.GetParameters()[1].ParameterType == typeof(Dictionary<string, float>) &&
            m.GetParameters()[2].ParameterType == typeof(float));
        if (method == null) return;
        if (Read(monster, "TakeDamageSfx") is string damage && !string.IsNullOrWhiteSpace(damage))
            method.Invoke(audio, new object[] { damage, new Dictionary<string, float> { ["EnemyImpact_Intensity"] = 2f }, 0f });
        if (Read(monster, "HasHurtSfx") is true && Read(monster, "HurtSfx") is string hurt && !string.IsNullOrWhiteSpace(hurt))
            method.Invoke(audio, new object[] { hurt, null, 0f });
    }

    private static void Report(Exception error)
    {
        if (_reportedError) return;
        _reportedError = true;
        Console.Error.WriteLine("[RENDER-COMPAT] bridge fallback; game behavior preserved: " + error);
    }
}
