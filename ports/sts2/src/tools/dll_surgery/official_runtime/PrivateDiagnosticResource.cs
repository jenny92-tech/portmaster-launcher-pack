// INPUT: exact 96da compatibility DLL and standalone private diagnostic PCK
// OUTPUT: separate DLL with only the embedded diagnostic resource changed
// POS: offline isolation test tool; never modifies the formal runtime or entry
using Mono.Cecil;
using System.Security.Cryptography;

public static class PrivateDiagnosticResource
{
    private const string InputHash = "96da217412e7011e2f8050fbdfcad948a425021ad358dec674775dbb33d68546";
    private const string PreviousHash = "da287051fcd6fa2e54a713d586c4ae1a1a1bcbe6a4dd1395be65eedd540b8eb4";
    private const string Name = "STS2LinuxLauncher.TextureDiagnostic.pck";
    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
    private static byte[] ResourceBytes(EmbeddedResource resource)
    {
        using var stream = resource.GetResourceStream();
        using var output = new MemoryStream(); stream.CopyTo(output); return output.ToArray();
    }
    private static EmbeddedResource OnlyResource(AssemblyDefinition assembly)
    {
        if (assembly.MainModule.Resources.Count != 1 || assembly.MainModule.Resources[0] is not EmbeddedResource resource || resource.Name != Name)
            throw new InvalidOperationException("Unexpected compatibility assembly resources");
        return resource;
    }
    private static void VerifyMethods(AssemblyDefinition original, AssemblyDefinition patched)
    {
        var left=original.MainModule.GetTypes().SelectMany(t=>t.Methods).ToDictionary(m=>m.FullName);
        var right=patched.MainModule.GetTypes().SelectMany(t=>t.Methods).ToDictionary(m=>m.FullName);
        if(left.Count!=right.Count || left.Keys.Except(right.Keys).Any()) throw new InvalidOperationException("Method set changed");
        foreach(var (name,a) in left)
        {
            var b=right[name];
            if(a.HasBody!=b.HasBody || (a.HasBody && (!a.Body.Instructions.Select(i=>i.ToString()).SequenceEqual(b.Body.Instructions.Select(i=>i.ToString())) || a.Body.ExceptionHandlers.Count!=b.Body.ExceptionHandlers.Count)))
                throw new InvalidOperationException("Compatibility method changed: "+name);
        }
    }
    public static void Write(string input, string pack, string output, string references)
    {
        input=Path.GetFullPath(input); pack=Path.GetFullPath(pack); output=Path.GetFullPath(output); references=Path.GetFullPath(references);
        if (input==output || pack==output || File.Exists(output) || Directory.Exists(output)) throw new InvalidOperationException("Output must be new and separate");
        if (Hash(File.ReadAllBytes(input))!=InputHash) throw new InvalidOperationException("Unexpected compatibility DLL");
        var bytes=File.ReadAllBytes(pack);
        if (bytes.Length==0 || bytes.Length>1024*1024) throw new InvalidOperationException("Diagnostic pack size invalid");
        var temporary=output+"."+Guid.NewGuid().ToString("N")+".tmp";
        try
        {
            using var resolver=new DefaultAssemblyResolver(); resolver.AddSearchDirectory(references);
            resolver.AddSearchDirectory(Path.GetDirectoryName(typeof(object).Assembly.Location)!);
            using (var original=AssemblyDefinition.ReadAssembly(input,new ReaderParameters{AssemblyResolver=resolver}))
            {
                var old=OnlyResource(original);
                if (Hash(ResourceBytes(old))!=PreviousHash) throw new InvalidOperationException("Original diagnostic resource mismatch");
                original.MainModule.Resources[0]=new EmbeddedResource(Name,old.Attributes,bytes);
                original.Write(temporary);
            }
            using (var original=AssemblyDefinition.ReadAssembly(input))
            using (var result=AssemblyDefinition.ReadAssembly(temporary))
            {
                if (original.Name.FullName!=result.Name.FullName || Hash(ResourceBytes(OnlyResource(result)))!=Hash(bytes))
                    throw new InvalidOperationException("Diagnostic resource write mismatch");
                VerifyMethods(original,result);
            }
            File.Move(temporary,output,false);
            Console.WriteLine($"private diagnostic={Hash(bytes)} compatibility={Hash(File.ReadAllBytes(output))}");
        }
        finally { if(File.Exists(temporary)) File.Delete(temporary); }
    }
}
