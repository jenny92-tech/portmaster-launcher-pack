// INPUT:  Mono.Cecil、玩家游戏 DLL、兼容 DLL 与独立输出路径
// OUTPUT: 只读 IL 报告或经重新读取验证的游戏侧兼容入口补丁
// POS:    为官方 Godot 接回兼容层，不修改引擎或覆盖原游戏程序集
using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Security.Cryptography;

const string GameType = "MegaCrit.Sts2.Core.Nodes.NGame";
const string CompatType = "STS2LinuxLauncher.ModEntry";

if (args.Length == 5 && args[0] == "swap-private-diagnostic")
{
    PrivateDiagnosticResource.Write(args[1], args[2], args[3], args[4]);
    return;
}

if (args.Length == 4 && args[0] == "restrict-languages")
{
    LanguageRestrictionHooks.Write(args[1], args[2], args[3]);
    return;
}

static MethodDefinition FindEntry(AssemblyDefinition assembly)
{
    var type = assembly.MainModule.GetType(GameType)
        ?? throw new InvalidOperationException("NGame type missing");
    return type.Methods.Single(m => m.Name == "_EnterTree" && !m.IsStatic &&
        m.Parameters.Count == 0 && m.ReturnType.FullName == "System.Void" && m.HasBody);
}

static bool IsCompatCall(Instruction instruction) =>
    instruction.OpCode == OpCodes.Call && instruction.Operand is MethodReference method &&
    method.DeclaringType.FullName == CompatType && method.Name == "ApplyOfficialRuntime";

static string? GpuActivationBridge(Instruction instruction)
{
    if (instruction.OpCode != OpCodes.Call && instruction.OpCode != OpCodes.Callvirt) return null;
    if (instruction.Operand is not MethodReference method || !method.HasThis ||
        method.ReturnType.FullName != "System.Void" ||
        method.DeclaringType.FullName is not ("Godot.GpuParticles2D" or "Godot.GpuParticles3D")) return null;
    if (method.Name == "Restart" && method.Parameters.Count == 0) return "RestartGpu";
    if ((method.Name is "set_Emitting" or "SetEmitting") && method.Parameters.Count == 1 &&
        method.Parameters[0].ParameterType.FullName == "System.Boolean") return "SetGpuEmitting";
    return null;
}

if (args.Length == 3 && args[0] == "verify-texture-diagnostic")
{
    const string resourceName = "STS2LinuxLauncher.TextureDiagnostic.pck";
    using var assembly = AssemblyDefinition.ReadAssembly(args[1]);
    var resources = assembly.MainModule.Resources.Where(r => r.Name == resourceName).ToArray();
    if (resources.Length != 1 || resources[0] is not EmbeddedResource embedded)
        throw new InvalidOperationException("Expected exactly one embedded texture diagnostic resource");
    using var resourceStream = embedded.GetResourceStream();
    using var packStream = File.OpenRead(args[2]);
    long size = resourceStream.Length;
    if (size != packStream.Length)
        throw new InvalidOperationException("Embedded texture diagnostic resource size mismatch");
    var resourceHash = SHA256.HashData(resourceStream);
    var packHash = SHA256.HashData(packStream);
    if (!CryptographicOperations.FixedTimeEquals(resourceHash, packHash))
        throw new InvalidOperationException("Embedded texture diagnostic resource SHA-256 mismatch");
    Console.WriteLine(JsonSerializer.Serialize(new { resource = resourceName,
        sha256 = Convert.ToHexString(resourceHash).ToLowerInvariant(), size_bytes = size }));
    return;
}

if (args.Length == 2 && args[0] == "inspect-vfx-material-usage")
{
    var path = Path.GetFullPath(args[1]);
    using var stream = File.OpenRead(path);
    var inputSha = Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    using var assembly = AssemblyDefinition.ReadAssembly(path);
    var flagAccesses = new List<object>();
    var processMaterial = new List<object>();
    int methods = 0;
    foreach (var method in assembly.MainModule.GetTypes().SelectMany(t => t.Methods).Where(m => m.HasBody))
    {
        methods++;
        foreach (var instruction in method.Body.Instructions)
        {
            if (instruction.Operand is MethodReference reference)
            {
                if (reference.Name.Contains("Turbulence", StringComparison.OrdinalIgnoreCase) &&
                    (reference.Name.StartsWith("get_", StringComparison.OrdinalIgnoreCase) ||
                     reference.Name.StartsWith("set_", StringComparison.OrdinalIgnoreCase)))
                    flagAccesses.Add(new { method = method.FullName, offset = instruction.Offset, operand = reference.FullName });
                if (reference.Name.Contains("ProcessMaterial", StringComparison.OrdinalIgnoreCase) ||
                    reference.DeclaringType.FullName.Contains("ParticleProcessMaterial", StringComparison.OrdinalIgnoreCase))
                    processMaterial.Add(new { method = method.FullName, offset = instruction.Offset, operand = reference.FullName });
            }
            else if (instruction.OpCode == OpCodes.Ldstr && instruction.Operand is string text &&
                     (text.Contains("turbulence_enabled", StringComparison.OrdinalIgnoreCase) ||
                      text.Contains("get_turbulence", StringComparison.OrdinalIgnoreCase) ||
                      text.Contains("set_turbulence", StringComparison.OrdinalIgnoreCase)))
                flagAccesses.Add(new { method = method.FullName, offset = instruction.Offset, operand = text });
        }
    }
    Console.WriteLine(JsonSerializer.Serialize(new { source_sha256 = inputSha, methods_scanned = methods,
        turbulence_flag_accesses = flagAccesses, process_material_references = processMaterial,
        limitation = "Static IL only; dynamic calls, native code and visual/collision semantics are not proven." },
        new JsonSerializerOptions { WriteIndented = true }));
    return;
}

if (args.Length == 3 && args[0] == "inspect-vfx-callers")
{
    using var assembly = AssemblyDefinition.ReadAssembly(args[1]);
    using var catalog = JsonDocument.Parse(File.ReadAllText(args[2]));
    var paths = catalog.RootElement.GetProperty("scenes").EnumerateArray()
        .Select(e => e.GetProperty("path").GetString()!)
        .SelectMany(p => new[] { p, p.Replace("res://scenes/", "").Replace(".tscn", "") }).ToHashSet();
    foreach (var method in assembly.MainModule.GetTypes().SelectMany(t => t.Methods).Where(m => m.HasBody))
    {
        var matches = method.Body.Instructions.Where(i => i.OpCode == OpCodes.Ldstr && i.Operand is string s && paths.Contains(s)).ToList();
        if (matches.Count == 0) continue;
        Console.WriteLine("METHOD " + method.FullName);
        foreach (var instruction in method.Body.Instructions) Console.WriteLine("  " + instruction);
    }
    return;
}

if (args.Length == 3 && args[0] == "inspect-type")
{
    using var assembly = AssemblyDefinition.ReadAssembly(args[1]);
    foreach (var type in assembly.MainModule.GetTypes().Where(t =>
        t.FullName.Contains(args[2], StringComparison.OrdinalIgnoreCase)))
    {
        Console.WriteLine("TYPE " + type.FullName);
        foreach (var method in type.Methods.Where(m => m.HasBody))
        {
            Console.WriteLine(method.FullName);
            foreach (var instruction in method.Body.Instructions)
                Console.WriteLine("  " + instruction);
        }
    }
    return;
}

if (args.Length == 2 && args[0] == "inspect-particle-waits")
{
    using var assembly = AssemblyDefinition.ReadAssembly(args[1]);
    foreach (var method in assembly.MainModule.GetTypes().SelectMany(t => t.Methods).Where(m => m.HasBody))
    {
        bool gpu = method.Body.Instructions.Any(i =>
            i.Operand is MemberReference reference && reference.FullName.Contains("GpuParticles"));
        bool wait = method.Body.Instructions.Any(i =>
            i.Operand is MethodReference reference && reference.Name.Contains("ToSignal"));
        if (!gpu || !wait) continue;
        Console.WriteLine(method.FullName);
        foreach (var instruction in method.Body.Instructions)
            Console.WriteLine("  " + instruction);
    }
    return;
}

if (args.Length == 2 && args[0] is "inspect" or "inspect-particles")
{
    using var assembly = AssemblyDefinition.ReadAssembly(args[1]);
    if (args[0] == "inspect-particles")
    {
        foreach (var group in assembly.MainModule.GetTypes().SelectMany(t => t.Methods)
            .Where(m => m.HasBody).SelectMany(m => m.Body.Instructions)
            .Select(i => i.Operand).OfType<MethodReference>()
            .Where(m => m.DeclaringType.FullName.Contains("Particles"))
            .GroupBy(m => m.FullName).OrderBy(g => g.Key))
            Console.WriteLine($"{group.Count()} {group.Key}");
        return;
    }
    if (assembly.Name.Name == "GodotSharp")
    {
        foreach (var type in assembly.MainModule.Types.Where(t => t.FullName is
            "Godot.Engine" or "Godot.SceneTree" or "Godot.GpuParticles2D" or "Godot.GpuParticles3D" or
            "Godot.GodotObject" or "Godot.Callable" or "Godot.StringName"))
        {
            foreach (var method in type.Methods.Where(m => m.Name is "GetMainLoop" or "Connect" or
                "Disconnect" or "From" or "op_Implicit"))
                Console.WriteLine(method.FullName);
            foreach (var item in type.Events.Where(e => e.Name is "NodeAdded" or "ProcessFrame"))
                Console.WriteLine($"event {item.FullName}; delegate={item.EventType.FullName}");
            foreach (var property in type.Properties.Where(p => p.Name is
                "Emitting" or "Preprocess" or "Visible" or "Amount"))
                Console.WriteLine(property.FullName);
        }
        return;
    }
    foreach (var type in assembly.MainModule.Types.Where(t => t.FullName == GameType ||
        t.FullName.EndsWith(".NMainMenu") || t.FullName.EndsWith(".PreloadManager")))
    {
        foreach (var method in type.Methods.Where(m => m.Name is "_EnterTree" or "_Ready" or
            "Create" or "LoadCommonAndMainMenuAssets" or "LoadMainMenuAssets"))
        {
            Console.WriteLine(method.FullName);
            if (method.HasBody)
                foreach (var instruction in method.Body.Instructions)
                    Console.WriteLine("  " + instruction);
        }
    }
    return;
}

if (args.Length != 4 || args[0] != "patch")
    throw new ArgumentException("inspect <game.dll> | verify-texture-diagnostic <compat.dll> <pack.pck> | patch <game.dll> <compat.dll> <output.dll>");
var input = Path.GetFullPath(args[1]);
var compatPath = Path.GetFullPath(args[2]);
var output = Path.GetFullPath(args[3]);
var outputDeps = Path.ChangeExtension(output, ".deps.json");
if (input == output || compatPath == output || File.Exists(output) || File.Exists(outputDeps))
    throw new InvalidOperationException("Output must be a new file, separate from both inputs");
var deps = JsonNode.Parse(File.ReadAllText(Path.ChangeExtension(input, ".deps.json")))!.AsObject();
var targetName = deps["runtimeTarget"]!["name"]!.GetValue<string>();
var target = deps["targets"]![targetName]!.AsObject();
var runtime = target.Select(item => item.Value?["runtime"] as JsonObject)
    .Single(item => item?.ContainsKey(Path.GetFileName(input)) == true)!;
using var resolver = new DefaultAssemblyResolver();
resolver.AddSearchDirectory(Path.GetDirectoryName(input)!);
resolver.AddSearchDirectory(Path.GetDirectoryName(compatPath)!);
resolver.AddSearchDirectory(Path.GetDirectoryName(typeof(object).Assembly.Location)!);
using var game = AssemblyDefinition.ReadAssembly(input, new ReaderParameters { AssemblyResolver = resolver });
using var compat = AssemblyDefinition.ReadAssembly(compatPath, new ReaderParameters { AssemblyResolver = resolver });
var entry = FindEntry(game);
if (entry.Body.Instructions.Any(IsCompatCall))
    throw new InvalidOperationException("Compatibility entry already injected");
if (runtime.ContainsKey(Path.GetFileName(compatPath)))
    throw new InvalidOperationException("Compatibility dependency already present");
runtime.Add(Path.GetFileName(compatPath), new JsonObject());
var apply = compat.MainModule.GetType(CompatType)?.Methods.Single(m =>
    m.Name == "ApplyOfficialRuntime" && m.IsPublic && m.IsStatic && m.Parameters.Count == 0 &&
    m.ReturnType.FullName == "System.Void")
    ?? throw new InvalidOperationException("Compatible ApplyOfficialRuntime entry missing");
var call = game.MainModule.ImportReference(apply);
entry.Body.GetILProcessor().InsertBefore(entry.Body.Instructions[0],
    Instruction.Create(OpCodes.Call, call));
AtlasMemoryHooks.Inject(game, compat);
InputFocusHooks.Inject(game, compat);
AssetCacheDiagnosticsHooks.Inject(game, compat);
var particleBridge = compat.MainModule.GetType("STS2LinuxLauncher.Patches.ParticleDietPatches")
    ?? throw new InvalidOperationException("GPU policy bridge missing");
var bridges = new[] { "RestartGpu", "SetGpuEmitting" }.ToDictionary(name => name,
    name => game.MainModule.ImportReference(particleBridge.Methods.Single(m =>
        m.Name == name && m.IsPublic && m.IsStatic && m.ReturnType.FullName == "System.Void")));
int gpuCalls = 0;
foreach (var method in game.MainModule.GetTypes().SelectMany(t => t.Methods).Where(m => m.HasBody))
{
    foreach (var instruction in method.Body.Instructions)
    {
        var bridge = GpuActivationBridge(instruction);
        if (bridge == null) continue;
        instruction.OpCode = OpCodes.Call;
        instruction.Operand = bridges[bridge];
        gpuCalls++;
    }
}
if (gpuCalls == 0) throw new InvalidOperationException("No expected GPU activation calls found");
var trace = compat.MainModule.GetType("STS2LinuxLauncher.Patches.FirstCardTrace")
    ?? throw new InvalidOperationException("First-card trace helper missing");
var beginTrace = game.MainModule.ImportReference(trace.Methods.Single(m => m.Name == "Begin" && m.IsStatic));
var resourceTrace = game.MainModule.ImportReference(trace.Methods.Single(m => m.Name == "Resource" && m.IsStatic));
int traceMethods = 0;
foreach (var method in game.MainModule.GetTypes().SelectMany(t => t.Methods).Where(m => m.HasBody))
{
    var il = method.Body.GetILProcessor();
    if (method.DeclaringType.FullName == "MegaCrit.Sts2.Core.Nodes.Combat.NCardPlay" && method.Name == "TryPlayCard")
    {
        method.Body.SimplifyMacros();
        il.InsertBefore(method.Body.Instructions[0], Instruction.Create(OpCodes.Call, beginTrace));
        traceMethods++;
    }
    if (method.DeclaringType.FullName != "MegaCrit.Sts2.Core.Assets.AssetCache" ||
        method.Name is not ("GetScene" or "GetMaterial") || method.Parameters.Count == 0 ||
        method.Parameters[0].ParameterType.FullName != "System.String") continue;
    method.Body.SimplifyMacros();
    var originalFirst = method.Body.Instructions[0];
    foreach (var instruction in new[] { Instruction.Create(OpCodes.Ldstr, "begin"),
        Instruction.Create(OpCodes.Ldstr, method.Name), Instruction.Create(OpCodes.Ldarg, method.Parameters[0]),
        Instruction.Create(OpCodes.Call, resourceTrace) }) il.InsertBefore(originalFirst, instruction);
    foreach (var ret in method.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToList())
    {
        ret.OpCode = OpCodes.Nop;
        var previous = ret;
        foreach (var instruction in new[] { Instruction.Create(OpCodes.Ldstr, "end"),
            Instruction.Create(OpCodes.Ldstr, method.Name), Instruction.Create(OpCodes.Ldarg, method.Parameters[0]),
            Instruction.Create(OpCodes.Call, resourceTrace), Instruction.Create(OpCodes.Ret) })
        {
            il.InsertAfter(previous, instruction);
            previous = instruction;
        }
    }
    traceMethods++;
}
if (traceMethods < 3) throw new InvalidOperationException("Expected first-card/resource trace points missing");
var render = compat.MainModule.GetType("STS2LinuxLauncher.Patches.RenderPreparationBridge")
    ?? throw new InvalidOperationException("Render preparation bridge missing");
// Delay only the startup transition into the first main menu. This keeps the
// original asynchronous loading flow and never blocks Godot's frame thread.
var startupBridge = game.MainModule.ImportReference(render.Methods.Single(m =>
    m.Name == "LoadMainMenuAfterStartup" && m.IsPublic && m.IsStatic &&
    m.ReturnType.FullName == "System.Threading.Tasks.Task" && m.Parameters.Count == 2 &&
    m.Parameters[0].ParameterType.FullName == "System.Object" && m.Parameters[1].ParameterType.FullName == "System.Boolean"));
var launchState = game.MainModule.GetType(GameType).NestedTypes.Single(t => t.Name.StartsWith("<LaunchMainMenu>d__", StringComparison.Ordinal));
var launchMove = launchState.Methods.Single(m => m.Name == "MoveNext" && m.HasBody && m.Parameters.Count == 0);
var menuCalls = launchMove.Body.Instructions.Where(i => i.OpCode == OpCodes.Call && i.Operand is MethodReference m &&
    m.FullName == "System.Threading.Tasks.Task MegaCrit.Sts2.Core.Nodes.NGame::LoadMainMenu(System.Boolean)").ToList();
if (menuCalls.Count != 1 || menuCalls[0].Previous?.OpCode != OpCodes.Ldc_I4_0)
    throw new InvalidOperationException("Unexpected startup menu transition");
menuCalls[0].Operand = startupBridge;
// Lightweight scenes keep the original managed root type. Only those marked
// by the overlay skip the original GPU-particle sequence; the hit position is
// still assigned by the original code before this gate.
var simpleEffect = game.MainModule.ImportReference(render.Methods.Single(m =>
    m.Name == "IsSimpleEffect" && m.IsPublic && m.IsStatic &&
    m.ReturnType.FullName == "System.Boolean" && m.Parameters.Count == 1 &&
    m.Parameters[0].ParameterType.FullName == "System.Object"));
foreach (var name in new[] { "NHitSparkVfx", "Ui.NPowerAppliedDebuffVfx", "Ui.NPowerAppliedBuffVfx" })
{
    var type = game.MainModule.GetType("MegaCrit.Sts2.Core.Nodes.Vfx." + name)
        ?? throw new InvalidOperationException("Missing effect " + name);
    var ready = type.Methods.Single(m => m.Name == "_Ready" && !m.IsStatic && m.HasBody &&
        m.Parameters.Count == 0 && m.ReturnType.FullName == "System.Void");
    var code = ready.Body.Instructions;
    Instruction original;
    if (name == "NHitSparkVfx")
    {
        if (code.Count < 6 || code[0].OpCode != OpCodes.Ldarg_0 || code[1].OpCode != OpCodes.Ldarg_0 ||
            code[2].OpCode != OpCodes.Ldfld || code[2].Operand is not FieldReference creature ||
            creature.Name != "_creatureNode" || creature.DeclaringType.FullName != type.FullName ||
            code[3].OpCode != OpCodes.Callvirt || code[3].Operand is not MethodReference spawn ||
            spawn.FullName != "Godot.Vector2 MegaCrit.Sts2.Core.Nodes.Combat.NCreature::get_VfxSpawnPosition()" ||
            code[4].OpCode != OpCodes.Call || code[4].Operand is not MethodReference position ||
            position.FullName != "System.Void Godot.Node2D::set_GlobalPosition(Godot.Vector2)")
            throw new InvalidOperationException("Unexpected hit position setup");
        original = code[5];
    }
    else
    {
        if (code.Count != 5 || code[0].OpCode != OpCodes.Ldarg_0 || code[1].OpCode != OpCodes.Call ||
            code[1].Operand is not MethodReference sequence || sequence.Name != "PlaySequence" ||
            sequence.DeclaringType.FullName != type.FullName || !sequence.HasThis || sequence.Parameters.Count != 0 ||
            sequence.ReturnType.FullName != "System.Threading.Tasks.Task" || code[2].OpCode != OpCodes.Call ||
            code[2].Operand is not MethodReference safe || safe.FullName !=
                "System.Threading.Tasks.Task MegaCrit.Sts2.Core.Helpers.TaskHelper::RunSafely(System.Threading.Tasks.Task)" ||
            code[3].OpCode != OpCodes.Pop || code[4].OpCode != OpCodes.Ret)
            throw new InvalidOperationException("Unexpected power effect sequence setup: " + name);
        original = code[0];
    }
    ready.Body.SimplifyMacros();
    var il = ready.Body.GetILProcessor();
    foreach (var instruction in new[] { Instruction.Create(OpCodes.Ldarg_0), Instruction.Create(OpCodes.Call, simpleEffect),
        Instruction.Create(OpCodes.Brfalse, original), Instruction.Create(OpCodes.Ret) }) il.InsertBefore(original, instruction);
}
// This Windows build logs DXGI adapter details unconditionally. On Linux the
// DXGI library is unavailable; skip only that diagnostic block, preserving the
// surrounding system information and LogSystemInfo's original Task lifecycle.
var systemInfo = game.MainModule.GetType("MegaCrit.Sts2.Core.Debug.OsDebugInfo")?.Methods.Single(m =>
    m.Name == "GetSystemInfoString" && m.IsStatic && m.HasBody && m.Parameters.Count == 0 &&
    m.ReturnType.FullName == "System.String") ?? throw new InvalidOperationException("System info method missing");
systemInfo.Body.SimplifyMacros();
var infoCode = systemInfo.Body.Instructions;
var dxgiCalls = infoCode.Where(i => i.OpCode == OpCodes.Call && i.Operand is MethodReference r &&
    r.DeclaringType.FullName == "Vortice.DXGI.DXGI" && r.Name == "CreateDXGIFactory1").ToList();
if (dxgiCalls.Count != 1) throw new InvalidOperationException("Unexpected DXGI diagnostic call count");
var dxgiCall = dxgiCalls[0];
var dxgiStart = dxgiCall.Previous;
var resultOk = dxgiCall.Next;
var compareOk = resultOk?.Next;
var skip = compareOk?.Next;
if (dxgiStart?.OpCode != OpCodes.Ldloca || resultOk?.OpCode != OpCodes.Ldsfld ||
    resultOk.Operand is not FieldReference resultField || resultField.FullName != "SharpGen.Runtime.Result SharpGen.Runtime.Result::Ok" ||
    compareOk?.OpCode != OpCodes.Call || compareOk.Operand is not MethodReference compare ||
    compare.FullName != "System.Boolean SharpGen.Runtime.Result::op_Equality(SharpGen.Runtime.Result,SharpGen.Runtime.Result)" ||
    skip?.OpCode != OpCodes.Brfalse || skip.Operand is not Instruction afterDxgi ||
    infoCode.IndexOf(afterDxgi) <= infoCode.IndexOf(skip))
    throw new InvalidOperationException("Unexpected DXGI diagnostic block");
var startIndex = infoCode.IndexOf(dxgiStart);
var endIndex = infoCode.IndexOf(afterDxgi);
var block = infoCode.Skip(startIndex).Take(endIndex - startIndex).ToHashSet();
foreach (var instruction in infoCode.Where(i => !block.Contains(i)))
    if (instruction.Operand is Instruction branchTarget && block.Contains(branchTarget) ||
        instruction.Operand is Instruction[] targets && targets.Any(block.Contains))
        throw new InvalidOperationException("Unexpected external branch into DXGI diagnostic block");
if (systemInfo.Body.ExceptionHandlers.Any(h => new[] { h.TryStart, h.TryEnd, h.HandlerStart, h.HandlerEnd, h.FilterStart }
    .Any(i => i != null && block.Contains(i))))
    throw new InvalidOperationException("Unexpected exception boundary in DXGI diagnostic block");
systemInfo.Body.GetILProcessor().InsertBefore(dxgiStart, Instruction.Create(OpCodes.Br, afterDxgi));
// Diagnostics are inert unless explicitly enabled; injected calls neither
// consume events nor alter game input. Start on the first main menu.
var diagnostics = compat.MainModule.GetType("STS2LinuxLauncher.Patches.InputDiagnostics")
    ?? throw new InvalidOperationException("Input diagnostics bridge missing");
var diagnosticTargets = new[] {
    ("MegaCrit.Sts2.Core.Nodes.Screens.MainMenu.NMainMenu", "_Ready", "Start", "System.Void", Array.Empty<string>()),
    ("MegaCrit.Sts2.Core.Nodes.CommonUi.NControllerManager", "_Input", "Observe", "System.Void", new[] { "Godot.InputEvent" }),
    ("MegaCrit.Sts2.Core.Nodes.CommonUi.NControllerManager", "_Process", "Tick", "System.Void", new[] { "System.Double" })
};
foreach (var (typeName, methodName, bridgeName, returnType, parameters) in diagnosticTargets)
{
    var targetType = game.MainModule.GetType(typeName) ?? throw new InvalidOperationException("Missing diagnostic target " + typeName);
    var method = targetType.Methods.Single(m => m.Name == methodName && m.HasBody && !m.IsStatic &&
        m.ReturnType.FullName == returnType && m.Parameters.Select(p => p.ParameterType.FullName).SequenceEqual(parameters));
    var bridge = game.MainModule.ImportReference(diagnostics.Methods.Single(m => m.Name == bridgeName && m.IsPublic && m.IsStatic &&
        m.ReturnType.FullName == "System.Void" && m.Parameters.Count == 1 && m.Parameters[0].ParameterType.FullName == "System.Object"));
    method.Body.SimplifyMacros();
    var il = method.Body.GetILProcessor();
    var first = method.Body.Instructions[0];
    il.InsertBefore(first, bridgeName == "Observe" ? Instruction.Create(OpCodes.Ldarg, method.Parameters[0]) : Instruction.Create(OpCodes.Ldarg_0));
    il.InsertBefore(first, Instruction.Create(OpCodes.Call, bridge));
}
var renderBridges = new[] { "CombatRoomReady", "RemapMaterial", "RepairCachedMaterials", "FilterEvicted" }
    .ToDictionary(name => name, name => game.MainModule.ImportReference(render.Methods.Single(m =>
        m.Name == name && m.IsPublic && m.IsStatic)));
var cache = game.MainModule.GetType("MegaCrit.Sts2.Core.Assets.AssetCache")
    ?? throw new InvalidOperationException("AssetCache missing");
var evict = cache.Methods.Single(m => m.Name == "RemoveAndGetResource" && m.HasBody &&
    m.Parameters.Count == 1 && m.Parameters[0].ParameterType.FullName == "System.String" &&
    m.ReturnType.FullName == "Godot.Resource");
var callers = game.MainModule.GetTypes().SelectMany(t => t.Methods).Where(m => m.HasBody &&
    m.Body.Instructions.Any(i => i.Operand is MethodReference r && r.FullName == evict.FullName)).ToList();
// The returned resource may only be checked and scheduled for Dispose. Reject
// unknown control flow or any other use, rather than silently suppressing it.
if (callers.Count != 2) throw new InvalidOperationException("Unexpected cache eviction caller count");
foreach (var caller in callers)
{
    caller.Body.SimplifyMacros();
    var code = caller.Body.Instructions;
    var calls = code.Where(i => i.Operand is MethodReference r && r.FullName == evict.FullName).ToList();
    if (caller.DeclaringType != cache || calls.Count != 1)
        throw new InvalidOperationException("Unexpected cache eviction caller");
    int index = code.IndexOf(calls[0]);
    if (index + 14 >= code.Count || code[index + 1].OpCode != OpCodes.Stloc ||
        code[index + 1].Operand is not VariableDefinition local ||
        code[index + 2].OpCode != OpCodes.Ldloc || code[index + 2].Operand != local ||
        code[index + 3].OpCode != OpCodes.Brfalse ||
        code[index + 4].OpCode != OpCodes.Ldloc || code[index + 4].Operand != local ||
        code[index + 5].OpCode != OpCodes.Call || code[index + 5].Operand is not MethodReference valid ||
        valid.FullName != "System.Boolean Godot.GodotObject::IsInstanceValid(Godot.GodotObject)" ||
        code[index + 6].OpCode != OpCodes.Brfalse || code[index + 6].Operand != code[index + 3].Operand ||
        code[index + 7].OpCode != OpCodes.Ldloc || code[index + 7].Operand != local ||
        code[index + 8].OpCode != OpCodes.Dup || code[index + 9].OpCode != OpCodes.Ldvirtftn ||
        code[index + 9].Operand is not MethodReference dispose ||
        dispose.FullName != "System.Void Godot.GodotObject::Dispose()" ||
        code[index + 10].OpCode != OpCodes.Newobj || code[index + 10].Operand is not MethodReference action ||
        action.FullName != "System.Void System.Action::.ctor(System.Object,System.IntPtr)" ||
        code[index + 11].OpCode != OpCodes.Call || code[index + 11].Operand is not MethodReference from ||
        from.FullName != "Godot.Callable Godot.Callable::From(System.Action)" ||
        code[index + 12].OpCode != OpCodes.Stloc || code[index + 13].OpCode != OpCodes.Ldloca ||
        code[index + 12].Operand != code[index + 13].Operand ||
        code[index + 14].OpCode != OpCodes.Call || code[index + 14].Operand is not MethodReference empty ||
        empty.Name != "Empty" || index + 15 >= code.Count || code[index + 15].OpCode != OpCodes.Call ||
        code[index + 15].Operand is not MethodReference deferred || deferred.Name != "CallDeferred" ||
        deferred.DeclaringType.FullName != "Godot.Callable" ||
        code.Count(i => i.Operand == local) != 4)
        throw new InvalidOperationException("Unexpected cache eviction caller behavior; refusing resource protection hook: " + caller.FullName);
}
var renderTargets = new[] {
    ("MegaCrit.Sts2.Core.Nodes.Rooms.NCombatRoom", "_Ready", "CombatRoomReady"),
    ("MegaCrit.Sts2.Core.Nodes.Cards.NCard", "Reload", "RepairCachedMaterials"),
    ("MegaCrit.Sts2.Core.Nodes.Screens.MainMenu.NMainMenu", "_Ready", "RepairCachedMaterials"),
    ("MegaCrit.Sts2.Core.Nodes.Screens.Timeline.NEpochSlot", "_Ready", "RepairCachedMaterials"),
    ("MegaCrit.Sts2.Core.Nodes.Vfx.NRadialBlurVfx", "_Ready", "RepairCachedMaterials"),
    ("MegaCrit.Sts2.Core.Assets.AssetCache", "GetMaterial", "RemapMaterial"),
    ("MegaCrit.Sts2.Core.Assets.AssetCache", "RemoveAndGetResource", "FilterEvicted")
};
var renderCounts = new Dictionary<string, int>();
foreach (var (typeName, methodName, bridgeName) in renderTargets)
{
    var type = game.MainModule.GetType(typeName) ?? throw new InvalidOperationException("Missing " + typeName);
    var method = type.Methods.Single(m => m.Name == methodName && m.HasBody && !m.IsStatic &&
        (bridgeName is "RemapMaterial" or "FilterEvicted"
            ? m.Parameters.Count == 1 && m.Parameters[0].ParameterType.FullName == "System.String" &&
              m.ReturnType.FullName == (bridgeName == "RemapMaterial" ? "Godot.Material" : "Godot.Resource")
            : m.Parameters.Count == 0 && m.ReturnType.FullName == "System.Void"));
    method.Body.SimplifyMacros();
    var il = method.Body.GetILProcessor();
    var returns = method.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToList();
    if (returns.Count == 0) throw new InvalidOperationException("No return in " + method.FullName);
    foreach (var ret in returns)
    {
        ret.OpCode = OpCodes.Nop;
        var instructions = new List<Instruction>();
        if (bridgeName is "CombatRoomReady" or "RepairCachedMaterials") instructions.Add(Instruction.Create(OpCodes.Ldarg_0));
        if (bridgeName == "RemapMaterial") instructions.Add(Instruction.Create(OpCodes.Ldarg, method.Parameters[0]));
        instructions.Add(Instruction.Create(OpCodes.Call, renderBridges[bridgeName]));
        if (bridgeName is "RemapMaterial" or "FilterEvicted") instructions.Add(Instruction.Create(OpCodes.Castclass, method.ReturnType));
        instructions.Add(Instruction.Create(OpCodes.Ret));
        var previous = ret;
        foreach (var instruction in instructions) { il.InsertAfter(previous, instruction); previous = instruction; }
    }
    renderCounts[bridgeName] = renderCounts.GetValueOrDefault(bridgeName) + returns.Count;
}
Directory.CreateDirectory(Path.GetDirectoryName(output)!);
var staging = output + ".incoming";
if (File.Exists(staging))
    throw new InvalidOperationException("Staging output already exists");
try
{
    game.Write(staging);
    using (var verified = AssemblyDefinition.ReadAssembly(staging))
    {
        var writtenEntry = FindEntry(verified);
        if (verified.MainModule.Architecture != game.MainModule.Architecture ||
            verified.Name.Name != game.Name.Name || verified.Name.Version != game.Name.Version ||
            !IsCompatCall(writtenEntry.Body.Instructions[0]) ||
            writtenEntry.Body.Instructions.Count(IsCompatCall) != 1 ||
            verified.MainModule.GetTypes().SelectMany(t => t.Methods).Where(m => m.HasBody)
                .SelectMany(m => m.Body.Instructions).Any(i => GpuActivationBridge(i) != null))
            throw new InvalidOperationException("Written assembly verification failed");
        Console.WriteLine($"Verified: {writtenEntry.FullName} -> {apply.FullName}; architecture={verified.MainModule.Architecture}; version={verified.Name.Version}");
        Console.WriteLine($"GPU restart/emission calls routed through game-side policy: {gpuCalls}");
        Console.WriteLine($"First-card/resource trace methods instrumented: {traceMethods}");
        var writtenLaunch = verified.MainModule.GetType(GameType).NestedTypes.Single(t => t.Name == launchState.Name)
            .Methods.Single(m => m.Name == "MoveNext" && m.HasBody);
        if (writtenLaunch.Body.Instructions.Count(i => i.OpCode == OpCodes.Call && i.Operand is MethodReference r &&
            r.DeclaringType.FullName == render.FullName && r.Name == "LoadMainMenuAfterStartup") != 1)
            throw new InvalidOperationException("Startup effects gate verification failed");
        Console.WriteLine("Startup effects gate verified before initial main menu");
        foreach (var name in new[] { "NHitSparkVfx", "Ui.NPowerAppliedDebuffVfx", "Ui.NPowerAppliedBuffVfx" })
        {
            var ready = verified.MainModule.GetType("MegaCrit.Sts2.Core.Nodes.Vfx." + name).Methods.Single(m => m.Name == "_Ready" && m.HasBody);
            var count = ready.Body.Instructions.Count(i => i.OpCode == OpCodes.Call &&
                i.Operand is MethodReference r && r.DeclaringType.FullName == render.FullName && r.Name == "IsSimpleEffect");
            if (count != 1) throw new InvalidOperationException("Simple effect hook count mismatch: " + name);
        }
        Console.WriteLine("Simple effect hooks verified: hit + debuff + buff");
        var writtenInfo = verified.MainModule.GetType("MegaCrit.Sts2.Core.Debug.OsDebugInfo").Methods.Single(m => m.Name == "GetSystemInfoString" && m.HasBody);
        var writtenDxgi = writtenInfo.Body.Instructions.Single(i => i.OpCode == OpCodes.Call && i.Operand is MethodReference r &&
            r.DeclaringType.FullName == "Vortice.DXGI.DXGI" && r.Name == "CreateDXGIFactory1");
        var branch = writtenDxgi.Previous?.Previous;
        if (branch?.OpCode != OpCodes.Br || branch.Operand is not Instruction destination ||
            writtenInfo.Body.Instructions.IndexOf(destination) <= writtenInfo.Body.Instructions.IndexOf(writtenDxgi))
            throw new InvalidOperationException("DXGI diagnostic bypass verification failed");
        Console.WriteLine("Windows-only DXGI diagnostic block bypass verified; system info Task preserved");
        foreach (var (typeName, methodName, bridgeName, returnType, parameters) in diagnosticTargets)
        {
            var method = verified.MainModule.GetType(typeName).Methods.Single(m => m.Name == methodName && m.HasBody && !m.IsStatic &&
                m.ReturnType.FullName == returnType && m.Parameters.Select(p => p.ParameterType.FullName).SequenceEqual(parameters));
            if (method.Body.Instructions.Count(i => i.OpCode == OpCodes.Call && i.Operand is MethodReference r &&
                r.DeclaringType.FullName == diagnostics.FullName && r.Name == bridgeName) != 1)
                throw new InvalidOperationException("Input diagnostic hook mismatch: " + bridgeName);
        }
        Console.WriteLine("Opt-in input diagnostic hooks verified: menu + event + frame");
        AssetCacheDiagnosticsHooks.Verify(verified);
        Console.WriteLine("Opt-in asset cache diagnostic hooks verified");
        InputFocusHooks.Verify(verified);
        Console.WriteLine("Opt-in window focus hook verified; platform overlay retained");
        AtlasMemoryHooks.Verify(verified);
        Console.WriteLine("Selective atlas hooks verified: startup + 3 queries");

        foreach (var (name, count) in renderCounts)
        {
            var actual = verified.MainModule.GetTypes().SelectMany(t => t.Methods).Where(m => m.HasBody)
                .SelectMany(m => m.Body.Instructions).Count(i => i.OpCode == OpCodes.Call &&
                    i.Operand is MethodReference r && r.DeclaringType.FullName == render.FullName && r.Name == name);
            if (actual != count) throw new InvalidOperationException("Render hook count mismatch: " + name);
            Console.WriteLine($"Render hook {name}: {actual}");
        }

    }
    File.Move(staging, output);
    File.WriteAllText(outputDeps, deps.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + "\n");
    Console.WriteLine($"Dependency resolution updated: {Path.GetFileName(compatPath)} in {targetName}; existing package versions preserved");
}
finally
{
    if (File.Exists(staging)) File.Delete(staging);
}
