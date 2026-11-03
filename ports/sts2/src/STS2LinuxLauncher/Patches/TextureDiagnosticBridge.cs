// INPUT:  显式诊断开关、内嵌小 PCK 和游戏侧 GodotSharp
// OUTPUT: 可选的诊断节点，故障仅记录且不改变现有预热或输入
// POS:    在已初始化的 SceneTree 根上挂载内嵌的只读诊断资源
using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;

namespace STS2LinuxLauncher.Patches;

internal static class TextureDiagnosticBridge
{
    private static int _attempted;

    public static void Install(Assembly api, object root)
    {
        if (Environment.GetEnvironmentVariable("SLL_TEXTURE_DIAG") != "1" ||
            Interlocked.Exchange(ref _attempted, 1) != 0) return;
        try
        {
            var pack = ExtractPack();
            var mount = api.GetType("Godot.ProjectSettings")?.GetMethod("LoadResourcePack",
                BindingFlags.Public | BindingFlags.Static, null,
                new[] { typeof(string), typeof(bool), typeof(int) }, null)
                ?? throw new InvalidOperationException("resource pack API unavailable");
            if (!(bool)mount.Invoke(null, new object[] { pack, false, 0 }))
                throw new InvalidOperationException("diagnostic pack could not be mounted");
            var loader = api.GetType("Godot.ResourceLoader").GetMethods().First(m =>
                m.Name == "Load" && !m.IsGenericMethod && m.GetParameters().Length == 3);
            var scene = loader.Invoke(null, Arguments(loader, "res://port_diagnostics/texture_diagnostic.tscn"))
                ?? throw new InvalidOperationException("diagnostic scene missing");
            var instantiate = scene.GetType().GetMethods().Single(m => m.Name == "Instantiate" &&
                !m.IsGenericMethod && m.GetParameters().Length == 1);
            var node = instantiate.Invoke(scene, Arguments(instantiate))
                ?? throw new InvalidOperationException("diagnostic scene could not be instantiated");
            var addChild = root.GetType().GetMethods().First(m => m.Name == "AddChild" &&
                !m.IsGenericMethod && m.GetParameters().Length == 3);
            addChild.Invoke(root, Arguments(addChild, node));
            Console.Error.WriteLine("[TEXTURE-DIAG] diagnostic scene installed");
        }
        catch (Exception error)
        {
            Console.Error.WriteLine("[TEXTURE-DIAG] unavailable: " + (error.InnerException ?? error).Message);
        }
    }

    // Godot may reopen the pack during the process lifetime. Retain the file
    // until exit, then remove only this randomly named file. A forced kill may
    // leave the small diagnostic file behind.
    private static string ExtractPack()
    {
        using var source = typeof(TextureDiagnosticBridge).Assembly.GetManifestResourceStream(
            "STS2LinuxLauncher.TextureDiagnostic.pck")
            ?? throw new InvalidOperationException("embedded diagnostic pack missing");
        const int limit = 1024 * 1024;
        if (source.Length <= 0 || source.Length > limit)
            throw new InvalidOperationException("embedded diagnostic pack has invalid size");
        var path = Path.Combine(Path.GetTempPath(), "sts2-texture-diag-" + Guid.NewGuid().ToString("N") + ".pck");
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write, Share = FileShare.Read };
        if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        bool owned = false;
        try
        {
            using (var file = new FileStream(path, options))
            {
                owned = true;
                source.CopyTo(file);
            }
            AppDomain.CurrentDomain.ProcessExit += (_, _) => DeleteQuietly(path);
            return path;
        }
        catch
        {
            if (owned) DeleteQuietly(path);
            throw;
        }
    }

    private static void DeleteQuietly(string path)
    {
        try { File.Delete(path); } catch { }
    }

    private static object[] Arguments(MethodInfo method, params object[] first)
    {
        var parameters = method.GetParameters();
        var values = new object[parameters.Length];
        for (int i = 0; i < values.Length; i++)
            values[i] = i < first.Length ? first[i] : parameters[i].HasDefaultValue ? parameters[i].DefaultValue :
                parameters[i].ParameterType.IsValueType ? Activator.CreateInstance(parameters[i].ParameterType) : null;
        return values;
    }
}
