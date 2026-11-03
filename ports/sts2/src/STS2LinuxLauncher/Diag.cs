// INPUT:  System.Environment 的 SLL_DEBUG
// OUTPUT: Diag.Enabled 诊断开关
// POS:    为兼容补丁统一控制可选调试输出
using System;

namespace STS2LinuxLauncher;

/// Debug toggle. launcher.sh exports SLL_DEBUG=1 when a .debug marker file
/// is found on the SD card. When off (default), diagnostics and the 500ms
/// probe ticker are skipped; only errors/warnings hit the log.
public static class Diag
{
    public static readonly bool Enabled =
        Environment.GetEnvironmentVariable("SLL_DEBUG") == "1";
}
