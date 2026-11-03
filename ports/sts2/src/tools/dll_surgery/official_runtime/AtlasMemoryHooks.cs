// INPUT:  Mono.Cecil、游戏与兼容程序集
// OUTPUT: AtlasMemoryHooks.Inject()、Verify()
// POS:    为显式低内存模式选择性加载和按需查询游戏图集
using Mono.Cecil;
using Mono.Cecil.Cil;
using Mono.Cecil.Rocks;

public static class AtlasMemoryHooks
{
    public static void Inject(AssemblyDefinition game, AssemblyDefinition compat)
    {
        var memory = compat.MainModule.GetType("STS2LinuxLauncher.MemoryBudget")
            ?? throw new InvalidOperationException("Memory policy missing");
        var lowMode = game.MainModule.ImportReference(memory.Methods.Single(m =>
            m.Name == "get_ExplicitLowMode" && m.IsPublic && m.IsStatic &&
            m.Parameters.Count == 0 && m.ReturnType.FullName == "System.Boolean"));
        var atlas = game.MainModule.GetType("MegaCrit.Sts2.Core.Assets.AtlasManager")
            ?? throw new InvalidOperationException("AtlasManager missing");
        MethodDefinition AtlasMethod(string name, string returnType, params string[] parameters) =>
            atlas.Methods.Single(m => m.Name == name && m.IsStatic && m.HasBody &&
                m.ReturnType.FullName == returnType && m.Parameters.Select(p => p.ParameterType.FullName).SequenceEqual(parameters));
        var loadAllAtlases = AtlasMethod("LoadAllAtlases", "System.Void");
        var essentialAtlases = AtlasMethod("LoadEssentialAtlases", "System.Void");
        var loadAtlas = AtlasMethod("LoadAtlas", "System.Void", "System.String");
        var atlasQueries = new[] {
            AtlasMethod("GetSprite", "Godot.AtlasTexture", "System.String", "System.String"),
            AtlasMethod("HasSprite", "System.Boolean", "System.String", "System.String"),
            AtlasMethod("GetSpriteCount", "System.Int32", "System.String")
        };
        loadAllAtlases.Body.SimplifyMacros();
        var atlasIl = loadAllAtlases.Body.GetILProcessor();
        var atlasOriginal = loadAllAtlases.Body.Instructions[0];
        var atlasStartup = new List<Instruction> {
            Instruction.Create(OpCodes.Call, lowMode), Instruction.Create(OpCodes.Brfalse, atlasOriginal),
            Instruction.Create(OpCodes.Call, essentialAtlases)
        };
        foreach (var name in new[] { "card_atlas", "power_atlas", "intent_atlas", "relic_atlas", "potion_atlas" })
        {
            atlasStartup.Add(Instruction.Create(OpCodes.Ldstr, name));
            atlasStartup.Add(Instruction.Create(OpCodes.Call, loadAtlas));
        }
        atlasStartup.Add(Instruction.Create(OpCodes.Ret));
        foreach (var instruction in atlasStartup) atlasIl.InsertBefore(atlasOriginal, instruction);
        foreach (var query in atlasQueries)
        {
            query.Body.SimplifyMacros();
            var il = query.Body.GetILProcessor();
            var original = query.Body.Instructions[0];
            foreach (var instruction in new[] { Instruction.Create(OpCodes.Call, lowMode),
                Instruction.Create(OpCodes.Brfalse, original), Instruction.Create(OpCodes.Ldarg, query.Parameters[0]),
                Instruction.Create(OpCodes.Call, loadAtlas) }) il.InsertBefore(original, instruction);
        }
    }

    public static void Verify(AssemblyDefinition game)
    {
        var atlas = game.MainModule.GetType("MegaCrit.Sts2.Core.Assets.AtlasManager")
            ?? throw new InvalidOperationException("AtlasManager missing after write");
        foreach (var name in new[] { "LoadAllAtlases", "GetSprite", "HasSprite", "GetSpriteCount" })
        {
            var method = atlas.Methods.Single(m => m.Name == name && m.HasBody);
            var count = method.Body.Instructions.Count(i => i.OpCode == OpCodes.Call &&
                i.Operand is MethodReference r && r.DeclaringType.FullName == "STS2LinuxLauncher.MemoryBudget" && r.Name == "get_ExplicitLowMode");
            if (count != 1) throw new InvalidOperationException("Memory hook count mismatch: " + name);
        }
    }
}
