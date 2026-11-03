// INPUT:  audited 0.110.1 game assembly and its language initializer
// OUTPUT: English/Simplified Chinese language list, checked after Cecil write
// POS:    offline game-DLL transformation; no save or localization files touched
using Mono.Cecil;
using Mono.Cecil.Cil;
using System.Security.Cryptography;

public static class LanguageRestrictionHooks
{
    private const string TypeName = "MegaCrit.Sts2.Core.Localization.LocManager";
    private const string FieldName = "<Languages>k__BackingField";
    private const string InputHash = "dc0a93d4e86ce8982bc696e8f713d152cec971becbca9ce4f41c5b221e885f2d";
    private static readonly string[] Original = { "eng", "zhs", "zht", "deu", "esp", "fra", "ita", "jpn", "kor", "pol", "ptb", "rus", "spa", "tha", "tur" };

    private static (MethodDefinition Method, FieldDefinition Field, Instruction Store) Find(AssemblyDefinition assembly)
    {
        var type = assembly.MainModule.GetType(TypeName) ?? throw new InvalidOperationException("LocManager missing");
        var field = type.Fields.Single(f => f.Name == FieldName && f.IsStatic && f.FieldType.FullName == "System.Collections.Generic.List`1<System.String>");
        var method = type.Methods.Single(m => m.Name == ".cctor" && m.IsStatic && m.HasBody && m.Parameters.Count == 0);
        if (method.Body.ExceptionHandlers.Count != 0) throw new InvalidOperationException("Unexpected language initializer handlers");
        var code = method.Body.Instructions;
        if (code.Any(i => i.OpCode.FlowControl is FlowControl.Branch or FlowControl.Cond_Branch))
            throw new InvalidOperationException("Unexpected language initializer branches");
        var stores = code.Where(i => i.OpCode == OpCodes.Stsfld && i.Operand is FieldReference f && f.FullName == field.FullName).ToArray();
        if (stores.Length != 1) throw new InvalidOperationException("Language store is not unique");
        var store = stores[0];
        var constructor = code.TakeWhile(i => i != store).LastOrDefault(i => i.OpCode == OpCodes.Newobj && i.Operand is MethodReference m && m.DeclaringType.FullName == field.FieldType.FullName && m.Parameters.Count == 1 && m.Parameters[0].ParameterType.FullName == "System.Int32")
            ?? throw new InvalidOperationException("Language list construction missing");
        var values = code.SkipWhile(i => i != constructor).TakeWhile(i => i != store).Where(i => i.OpCode == OpCodes.Ldstr).Select(i => (string)i.Operand).ToArray();
        if (!values.SequenceEqual(Original)) throw new InvalidOperationException("Unexpected language list");
        return (method, field, store);
    }

    public static void Inject(AssemblyDefinition assembly)
    {
        var (method, field, store) = Find(assembly);
        var next = store.Next;
        if (next == null || next.OpCode != OpCodes.Ldstr || (string)next.Operand != "en")
            throw new InvalidOperationException("Unexpected or already modified language initializer");
        var module = assembly.MainModule;
        var remove = new MethodReference("RemoveRange", module.TypeSystem.Void, field.FieldType) { HasThis = true };
        remove.Parameters.Add(new ParameterDefinition(module.TypeSystem.Int32));
        remove.Parameters.Add(new ParameterDefinition(module.TypeSystem.Int32));
        var il = method.Body.GetILProcessor();
        foreach (var i in new[] { Instruction.Create(OpCodes.Ldsfld, field), Instruction.Create(OpCodes.Ldc_I4_2),
            Instruction.Create(OpCodes.Ldc_I4_S, (sbyte)13), Instruction.Create(OpCodes.Callvirt, remove) }) il.InsertBefore(next, i);
    }

    public static void Verify(AssemblyDefinition assembly)
    {
        var (_, field, store) = Find(assembly);
        var a = store.Next; var b = a?.Next; var c = b?.Next; var d = c?.Next; var e = d?.Next;
        if (a?.OpCode != OpCodes.Ldsfld || a.Operand is not FieldReference f || f.FullName != field.FullName ||
            b?.OpCode != OpCodes.Ldc_I4_2 || c?.OpCode != OpCodes.Ldc_I4_S || Convert.ToSByte(c.Operand) != 13 ||
            d?.OpCode != OpCodes.Callvirt || d.Operand is not MethodReference m || m.Name != "RemoveRange" ||
            m.DeclaringType.FullName != field.FieldType.FullName || m.ReturnType.FullName != "System.Void" ||
            !m.HasThis || m.Parameters.Count != 2 || m.Parameters.Any(p => p.ParameterType.FullName != "System.Int32") ||
            e?.OpCode != OpCodes.Ldstr || (string)e.Operand != "en") throw new InvalidOperationException("Language hook verification failed");
    }

    public static void VerifyOtherMethods(AssemblyDefinition original, AssemblyDefinition patched)
    {
        var left = original.MainModule.GetTypes().SelectMany(t => t.Methods).ToDictionary(m => m.FullName);
        var right = patched.MainModule.GetTypes().SelectMany(t => t.Methods).ToDictionary(m => m.FullName);
        if (left.Count != right.Count || left.Keys.Except(right.Keys).Any()) throw new InvalidOperationException("Method set changed");
        foreach (var (name, a) in left)
        {
            var b = right[name];
            if (a.HasBody != b.HasBody) throw new InvalidOperationException("Method body presence changed: " + name);
            if (!a.HasBody || (a.Name == ".cctor" && a.DeclaringType.FullName == TypeName)) continue;
            if (!a.Body.Instructions.Select(i => i.ToString()).SequenceEqual(b.Body.Instructions.Select(i => i.ToString())) ||
                a.Body.ExceptionHandlers.Count != b.Body.ExceptionHandlers.Count)
                throw new InvalidOperationException("Unrelated method changed: " + name);
        }
        Verify(patched);
    }

    public static void Write(string input, string output, string referenceDirectory)
    {
        input = Path.GetFullPath(input); output = Path.GetFullPath(output);
        if (input == output || File.Exists(output) || Directory.Exists(output)) throw new InvalidOperationException("Output must be new and separate");
        if (Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(input))).ToLowerInvariant() != InputHash)
            throw new InvalidOperationException("Unknown game DLL identity");
        referenceDirectory = Path.GetFullPath(referenceDirectory);
        if (Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(Path.Combine(referenceDirectory, "Sentry.dll")))).ToLowerInvariant() != "4f1619b048d0b0f604265075bc5311f9f2e4a0ecdc09662009b7ee11d50c216c")
            throw new InvalidOperationException("Unknown dependency identity");
        var temporary = output + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using var resolver = new DefaultAssemblyResolver();
            resolver.AddSearchDirectory(referenceDirectory);
            resolver.AddSearchDirectory(Path.GetDirectoryName(typeof(object).Assembly.Location)!);
            using (var game = AssemblyDefinition.ReadAssembly(input, new ReaderParameters { AssemblyResolver = resolver })) { Inject(game); game.Write(temporary); }
            using (var original = AssemblyDefinition.ReadAssembly(input))
            using (var game = AssemblyDefinition.ReadAssembly(temporary)) VerifyOtherMethods(original, game);
            File.Move(temporary, output, false);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
