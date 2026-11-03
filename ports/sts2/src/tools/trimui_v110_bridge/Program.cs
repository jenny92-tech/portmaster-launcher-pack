// INPUT: exact v0.110.1 compat DLL used with the existing SDL Godot fork
// OUTPUT: private DLL deferring the fork callback to the game-side entry
// POS: offline platform adaptation; no game, runtime or player data is changed
using Mono.Cecil;
using Mono.Cecil.Cil;
using System.Security.Cryptography;

const string InputHash = "96da217412e7011e2f8050fbdfcad948a425021ad358dec674775dbb33d68546";
static string Hash(string p) => Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(p))).ToLowerInvariant();
static IEnumerable<TypeDefinition> AllTypes(IEnumerable<TypeDefinition> types)
{
    foreach (var t in types) { yield return t; foreach (var n in AllTypes(t.NestedTypes)) yield return n; }
}
static Dictionary<string, MethodDefinition> Methods(AssemblyDefinition a) =>
    AllTypes(a.MainModule.Types).SelectMany(t => t.Methods).ToDictionary(m => m.FullName);
if (args.Length != 2) throw new ArgumentException("usage: Bridge <input-compat.dll> <new-output.dll>");
string input = Path.GetFullPath(args[0]), output = Path.GetFullPath(args[1]);
if (input == output || File.Exists(output) || Directory.Exists(output) || Hash(input) != InputHash)
    throw new InvalidOperationException("Input identity or output path invalid");
string temp = output + "." + Guid.NewGuid().ToString("N") + ".tmp";
try
{
    using (var assembly = AssemblyDefinition.ReadAssembly(input))
    {
        var type = assembly.MainModule.GetType("STS2LinuxLauncher.ModEntry") ?? throw new InvalidOperationException("Entry missing");
        var method = type.Methods.Single(m => m.Name == "Apply" && m.IsStatic && m.Parameters.Count == 0);
        if (!method.HasBody || method.Body.HasExceptionHandlers || method.Body.Instructions.Count != 2 ||
            method.Body.Instructions[0].OpCode != OpCodes.Call ||
            method.Body.Instructions[0].Operand is not MethodReference target || target.DeclaringType.FullName != type.FullName ||
            target.Name != "ApplyInternal" || method.Body.Instructions[1].OpCode != OpCodes.Ret ||
            !method.CustomAttributes.Any(a => a.AttributeType.FullName == "System.Runtime.InteropServices.UnmanagedCallersOnlyAttribute"))
            throw new InvalidOperationException("Unexpected fork callback body");
        method.Body.Instructions[0].OpCode = OpCodes.Nop;
        method.Body.Instructions[0].Operand = null;
        assembly.Write(temp);
    }
    using (var before = AssemblyDefinition.ReadAssembly(input))
    using (var after = AssemblyDefinition.ReadAssembly(temp))
    {
        var a = Methods(before); var b = Methods(after);
        if (before.Name.FullName != after.Name.FullName || a.Count != b.Count || a.Keys.Except(b.Keys).Any())
            throw new InvalidOperationException("Assembly or method set changed");
        foreach (var (name, left) in a)
        {
            var right = b[name];
            if (name == "System.Void STS2LinuxLauncher.ModEntry::Apply()")
            {
                if (!right.HasBody || right.Body.Instructions.Count != 2 || right.Body.Instructions[0].OpCode != OpCodes.Nop ||
                    right.Body.Instructions[1].OpCode != OpCodes.Ret) throw new InvalidOperationException("Callback readback failed");
            }
            else if (left.HasBody != right.HasBody || (left.HasBody &&
                (!left.Body.Instructions.Select(i => i.ToString()).SequenceEqual(right.Body.Instructions.Select(i => i.ToString())) ||
                 left.Body.ExceptionHandlers.Count != right.Body.ExceptionHandlers.Count)))
                throw new InvalidOperationException("Unrelated method changed: " + name);
        }
        var r1=before.MainModule.Resources.OfType<EmbeddedResource>().ToDictionary(r=>r.Name);
        var r2=after.MainModule.Resources.OfType<EmbeddedResource>().ToDictionary(r=>r.Name);
        if (before.MainModule.Resources.Count != after.MainModule.Resources.Count || r1.Count != r2.Count || r1.Keys.Except(r2.Keys).Any())
            throw new InvalidOperationException("Resource set changed");
        foreach(var name in r1.Keys)
        {
            using var s1=r1[name].GetResourceStream(); using var s2=r2[name].GetResourceStream();
            if (!SHA256.HashData(s1).SequenceEqual(SHA256.HashData(s2))) throw new InvalidOperationException("Resource changed: " + name);
        }
    }
    File.Move(temp, output, false);
    Console.WriteLine($"input={InputHash} output={Hash(output)} changed=ModEntry.Apply");
}
finally { if (File.Exists(temp)) File.Delete(temp); }
