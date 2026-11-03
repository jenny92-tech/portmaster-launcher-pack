// INPUT:  显式掌机焦点兼容开关
// OUTPUT: Enabled()
// POS:    仅由已验证的平台覆盖层门禁之后的游戏侧钩子调用
using System;

namespace STS2LinuxLauncher.Patches;

public static class InputFocusPolicy
{
    private static readonly bool enabled = Environment.GetEnvironmentVariable("SLL_LOONG_FOCUS_COMPAT") == "1";
    public static bool Enabled() => enabled;
}
