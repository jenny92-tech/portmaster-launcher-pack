// INPUT:  当前私有 Wine 桌面的 Win32 窗口枚举和消息接口
// OUTPUT: 向本会话可见顶层窗口发送 WM_CLOSE 后正常退出
// POS:    为隔离游戏提供正常关窗请求，不结束进程或 Wine 服务
typedef void *HANDLE;
typedef long long LPARAM;
typedef unsigned int UINT;
__declspec(dllimport) HANDLE __stdcall LoadLibraryA(const char *);
__declspec(dllimport) void *__stdcall GetProcAddress(HANDLE, const char *);
__declspec(dllimport) void __stdcall ExitProcess(UINT);
static int (__stdcall *visible)(HANDLE);
static int (__stdcall *post)(HANDLE, UINT, unsigned long long, LPARAM);
static int __stdcall close_window(HANDLE window, LPARAM unused) {
    (void)unused;
    if (visible(window)) post(window, 0x10, 0, 0);
    return 1;
}
void mainCRTStartup(void) {
    HANDLE user = LoadLibraryA("user32.dll");
    int (__stdcall *enumerate)(void *, LPARAM) = GetProcAddress(user, "EnumWindows");
    visible = GetProcAddress(user, "IsWindowVisible");
    post = GetProcAddress(user, "PostMessageA");
    if (!enumerate || !visible || !post) ExitProcess(1);
    enumerate(close_window, 0);
    ExitProcess(0);
}
