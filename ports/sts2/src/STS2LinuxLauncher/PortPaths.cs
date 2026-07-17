using System;
using System.IO;
using System.Reflection;

namespace STS2LinuxLauncher;

/// GAMEDIR derived from assembly location. Config reads env vars first
/// (set by launcher.sh), falling back to launch_config.env.
public static class PortPaths
{
    public static readonly string GameDir;
    private static readonly string[] _envFiles;

    static PortPaths()
    {
        try
        {
            var dllDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            GameDir = Path.GetDirectoryName(dllDir);
        }
        catch { GameDir = "."; }
        _envFiles = new[]
        {
            Path.Combine(GameDir, "love_ui", "launch_config.env"),
            Path.Combine(GameDir, "conf", "godot", "app_userdata", "STS2 Linux Launcher", "launch_config.env"),
        };
    }

    public static string Get(string key)
    {
        var v = Environment.GetEnvironmentVariable(key);
        if (!string.IsNullOrEmpty(v)) return v;
        try
        {
            foreach (var envFile in _envFiles)
            {
                if (!File.Exists(envFile)) continue;
                foreach (var line in File.ReadAllLines(envFile))
                    if (line.StartsWith(key + "=", StringComparison.Ordinal))
                        return line.Substring(key.Length + 1).Trim().Trim('"');
            }
        }
        catch { }
        return null;
    }
}
