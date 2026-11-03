// INPUT:  Cecil 与已审计游戏/兼容程序集
// OUTPUT: 显式掌机焦点兼容钩子及写后验证
// POS:    平台覆盖层始终优先，默认沿用原生窗口焦点判断
using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;

public static class InputFocusHooks
{
    private static MethodDefinition Target(AssemblyDefinition game) =>
        game.MainModule.GetType("MegaCrit.Sts2.Core.Nodes.NGame")?.Methods.Single(m =>
            m.Name == "IsGameFocusedWindow" && m.IsStatic && m.HasBody && m.Parameters.Count == 0 &&
            m.ReturnType.FullName == "System.Boolean") ?? throw new InvalidOperationException("Focus target missing");

    private static bool Call(Instruction i, string signature) => i.OpCode == OpCodes.Call &&
        i.Operand is MethodReference m && m.FullName == signature;
    private static bool Integer(Instruction i, int value) => i.OpCode == OpCodes.Ldc_I4 &&
        i.Operand is int n && n == value;
    private const string Overlay = "System.Boolean MegaCrit.Sts2.Core.Platform.PlatformUtil::IsPlatformOverlayOpen()";
    private const string Window = "System.Boolean Godot.DisplayServer::WindowIsFocused(System.Int32)";
    private const string Policy = "System.Boolean STS2LinuxLauncher.Patches.InputFocusPolicy::Enabled()";

    public static void Inject(AssemblyDefinition game, AssemblyDefinition compat)
    {
        var method = Target(game);
        method.Body.SimplifyMacros();
        var c = method.Body.Instructions;
        if (c.Count != 7 || !Call(c[0], Overlay) || c[1].OpCode != OpCodes.Brtrue || c[1].Operand != c[5] ||
            !Integer(c[2], 0) || !Call(c[3], Window) || c[4].OpCode != OpCodes.Ret ||
            !Integer(c[5], 0) || c[6].OpCode != OpCodes.Ret || method.Body.ExceptionHandlers.Count != 0)
            throw new InvalidOperationException("Unexpected focused-window control flow");
        var policyType = compat.MainModule.GetType("STS2LinuxLauncher.Patches.InputFocusPolicy")
            ?? throw new InvalidOperationException("Input focus policy missing");
        var policy = policyType.Methods.Single(m => m.Name == "Enabled" && m.IsPublic && m.IsStatic &&
            m.Parameters.Count == 0 && m.ReturnType.FullName == "System.Boolean");
        var il = method.Body.GetILProcessor();
        var original = c[2];
        foreach (var instruction in new[] { Instruction.Create(OpCodes.Call, game.MainModule.ImportReference(policy)),
            Instruction.Create(OpCodes.Brfalse, original), Instruction.Create(OpCodes.Ldc_I4_1), Instruction.Create(OpCodes.Ret) })
            il.InsertBefore(original, instruction);
    }

    public static void Verify(AssemblyDefinition game)
    {
        var method = Target(game);
        method.Body.SimplifyMacros();
        var c = method.Body.Instructions;
        if (c.Count != 11 || !Call(c[0], Overlay) || c[1].OpCode != OpCodes.Brtrue || c[1].Operand != c[9] ||
            !Call(c[2], Policy) || c[3].OpCode != OpCodes.Brfalse || c[3].Operand != c[6] ||
            !Integer(c[4], 1) || c[5].OpCode != OpCodes.Ret || !Integer(c[6], 0) ||
            !Call(c[7], Window) || c[8].OpCode != OpCodes.Ret || !Integer(c[9], 0) || c[10].OpCode != OpCodes.Ret)
            throw new InvalidOperationException("Input focus hook verification failed");
    }
}
