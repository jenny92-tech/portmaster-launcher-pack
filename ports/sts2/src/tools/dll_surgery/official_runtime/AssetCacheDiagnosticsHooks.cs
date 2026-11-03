// INPUT:  Cecil、已审计加载会话和诊断桥
// OUTPUT: 会话开始与真实完成位置的可选只读诊断
// POS:    保留所有资源加载、释放和 Task 控制流
using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;

public static class AssetCacheDiagnosticsHooks
{
    private const string Session = "MegaCrit.Sts2.Core.Assets.AssetLoadingSession";
    private const string Bridge = "STS2LinuxLauncher.Patches.AssetCacheDiagnostics";
    private static MethodDefinition Resolve(AssemblyDefinition game, string name) =>
        game.MainModule.GetType(Session)?.Methods.Single(m => m.Name == name && m.HasBody && !m.IsStatic &&
            (name == "Process" ? m.Parameters.Count == 0 : m.Parameters.Count == 4) && m.ReturnType.FullName == "System.Void")
        ?? throw new InvalidOperationException("Asset diagnostic target missing: " + name);

    public static void Inject(AssemblyDefinition game, AssemblyDefinition compat)
    {
        var bridge = compat.MainModule.GetType(Bridge) ?? throw new InvalidOperationException("Asset diagnostics missing");
        MethodReference Hook(string name) => game.MainModule.ImportReference(bridge.Methods.Single(m => m.Name == name && m.IsPublic && m.IsStatic &&
            m.Parameters.Count == 1 && m.Parameters[0].ParameterType.FullName == "System.Object" && m.ReturnType.FullName == "System.Void"));
        var ctor = Resolve(game, ".ctor");
        if (ctor.Body.Instructions.Any(i => i.OpCode == OpCodes.Call && i.Operand is MethodReference r && r.DeclaringType.FullName == Bridge))
            throw new InvalidOperationException("Asset diagnostics already injected");
        if (!ctor.Parameters.Select(p => p.ParameterType.FullName).SequenceEqual(new[] { "System.String", "System.Collections.Generic.IEnumerable`1<System.String>",
            "System.Collections.Concurrent.ConcurrentDictionary`2<System.String,Godot.Resource>", "MegaCrit.Sts2.Core.Assets.AssetCache" }))
            throw new InvalidOperationException("Unexpected asset session constructor");
        ctor.Body.SimplifyMacros();
        var returns = ctor.Body.Instructions.Where(i => i.OpCode == OpCodes.Ret).ToList();
        if (returns.Count != 1) throw new InvalidOperationException("Unexpected asset session constructor returns");
        var il = ctor.Body.GetILProcessor();
        // Preserve any leave targets and exception-handler boundaries at the
        // original return; inserting before it can put code inside a finally.
        var originalReturn = returns[0];
        originalReturn.OpCode = OpCodes.Nop;
        var loadThis = Instruction.Create(OpCodes.Ldarg_0);
        var begin = Instruction.Create(OpCodes.Call, Hook("Begin"));
        il.InsertAfter(originalReturn, loadThis);
        il.InsertAfter(loadThis, begin);
        il.InsertAfter(begin, Instruction.Create(OpCodes.Ret));

        var process = Resolve(game, "Process");
        process.Body.SimplifyMacros();
        var code = process.Body.Instructions;
        var candidates = code.Where(i => i.OpCode == OpCodes.Ldfld && i.Operand is FieldReference f &&
            f.DeclaringType.FullName == Session && f.Name == "_completionSource").ToList();
        if (candidates.Count != 1 || (candidates[0].Previous?.OpCode != OpCodes.Ldarg || candidates[0].Previous.Operand != process.Body.ThisParameter) ||
            candidates[0].Next?.OpCode != OpCodes.Ldc_I4 || candidates[0].Next.Operand is not int one || one != 1 ||
            candidates[0].Next.Next?.OpCode != OpCodes.Callvirt || candidates[0].Next.Next.Operand is not MethodReference result ||
            result.Name != "TrySetResult" || result.DeclaringType.FullName != "System.Threading.Tasks.TaskCompletionSource`1<System.Boolean>" ||
            candidates[0].Next.Next.Next?.OpCode != OpCodes.Pop)
            throw new InvalidOperationException("Unexpected asset session completion flow");
        var anchor = candidates[0].Previous;
        if (process.Body.ExceptionHandlers.Count != 0 || code.Any(i => i.Operand == anchor ||
            i.Operand is Instruction[] targets && targets.Contains(anchor)))
            throw new InvalidOperationException("Unexpected branch or exception boundary at asset session completion");
        il = process.Body.GetILProcessor();
        il.InsertBefore(anchor, Instruction.Create(OpCodes.Ldarg_0));
        il.InsertBefore(anchor, Instruction.Create(OpCodes.Call, Hook("Complete")));
    }

    public static void Verify(AssemblyDefinition game)
    {
        foreach (var (methodName, hookName) in new[] { (".ctor", "Begin"), ("Process", "Complete") })
        {
            var method = Resolve(game, methodName);
            method.Body.SimplifyMacros();
            var calls = method.Body.Instructions.Where(i => i.OpCode == OpCodes.Call && i.Operand is MethodReference r &&
                r.DeclaringType.FullName == Bridge && r.Name == hookName).ToList();
            if (calls.Count != 1 || calls[0].Previous?.OpCode != OpCodes.Ldarg ||
                calls[0].Previous.Operand != method.Body.ThisParameter ||
                (hookName == "Begin" && calls[0].Next?.OpCode != OpCodes.Ret) ||
                (hookName == "Complete" && (calls[0].Next?.OpCode != OpCodes.Ldarg ||
                    calls[0].Next.Operand != method.Body.ThisParameter || calls[0].Next.Next?.OpCode != OpCodes.Ldfld ||
                    calls[0].Next.Next.Operand is not FieldReference field || field.Name != "_completionSource")))
                throw new InvalidOperationException("Asset diagnostic hook mismatch: " + hookName);
        }
    }
}
