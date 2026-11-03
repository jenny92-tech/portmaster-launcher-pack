// INPUT:  Win64 游戏命令行、目标宽高及当前私有 Wine 桌面
// OUTPUT: 无边框最大化的目标游戏窗口、尺寸日志和原游戏退出码
// POS:    将普通 Wine/Wayland 游戏窗口贴满掌机横屏，保留正常关闭路径
typedef unsigned int DWORD, UINT;
typedef unsigned short WORD, WCHAR;
typedef int BOOL, LONG;
typedef long long LONG_PTR, LPARAM;
typedef void *HANDLE, *HWND;
#define IMPORT __declspec(dllimport)
IMPORT HANDLE __stdcall LoadLibraryA(const char *);
IMPORT void *__stdcall GetProcAddress(HANDLE, const char *);
IMPORT void __stdcall ExitProcess(DWORD);
typedef struct { LONG left,top,right,bottom; } RECT;
typedef struct { DWORD cb; WCHAR *reserved,*desktop,*title; DWORD x,y,cx,cy,xc,yc,fill,flags; WORD show,reserved2; unsigned char *reserved3; HANDLE input,output,error; } STARTUPINFO;
typedef struct { HANDLE process,thread; DWORD process_id,thread_id; } PROCESSINFO;
_Static_assert(sizeof(STARTUPINFO)==104,"STARTUPINFO Win64 size");
_Static_assert(sizeof(PROCESSINFO)==24,"PROCESSINFO Win64 size");
static DWORD child_pid;
static HWND window;
static int best_area;
static DWORD (__stdcall *window_pid)(HWND,DWORD *);
static BOOL (__stdcall *visible)(HWND);
static BOOL (__stdcall *client_rect)(HWND,RECT *);
static HANDLE log_file;
static BOOL (__stdcall *write_file)(HANDLE,const void *,DWORD,DWORD *,void *);
static int (__cdecl *format)(char *,const char *,...);
static void record(const char *s) { DWORD n=0;while(s[n])n++;DWORD written;write_file(log_file,s,n,&written,0); }
static BOOL __stdcall visit(HWND w,LPARAM unused) {
    (void)unused;DWORD pid=0;RECT r={0};window_pid(w,&pid);
    if(pid!=child_pid || !visible(w) || !client_rect(w,&r))return 1;
    int area=(r.right-r.left)*(r.bottom-r.top);
    if(area>best_area && r.right>=320 && r.bottom>=200){best_area=area;window=w;}
    return 1;
}
static WCHAR *skip(WCHAR *p) {
    while(*p==' ')p++;
    if(*p=='"'){p++;while(*p && *p!='"')p++;if(*p)p++;}
    else while(*p && *p!=' ')p++;
    while(*p==' ')p++;return p;
}
static int number(WCHAR *p){int n=0;while(*p>='0'&&*p<='9'){n=n*10+(*p++-'0');if(n>4096)return 0;}return n;}
void mainCRTStartup(void) {
    HANDLE kernel=LoadLibraryA("kernel32.dll"),user=LoadLibraryA("user32.dll");
    WCHAR *(__stdcall *cmdline)(void)=GetProcAddress(kernel,"GetCommandLineW");
    BOOL (__stdcall *create)(WCHAR *,WCHAR *,void *,void *,BOOL,DWORD,void *,WCHAR *,STARTUPINFO *,PROCESSINFO *)=GetProcAddress(kernel,"CreateProcessW");
    DWORD (__stdcall *wait)(HANDLE,DWORD)=GetProcAddress(kernel,"WaitForSingleObject");
    BOOL (__stdcall *exit_code)(HANDLE,DWORD *)=GetProcAddress(kernel,"GetExitCodeProcess");
    BOOL (__stdcall *close_handle)(HANDLE)=GetProcAddress(kernel,"CloseHandle");
    DWORD (__stdcall *last_error)(void)=GetProcAddress(kernel,"GetLastError");
    HANDLE (__stdcall *create_file)(const char *,DWORD,DWORD,void *,DWORD,DWORD,HANDLE)=GetProcAddress(kernel,"CreateFileA");
    write_file=GetProcAddress(kernel,"WriteFile");format=GetProcAddress(user,"wsprintfA");
    BOOL (__stdcall *enumerate)(void *,LPARAM)=GetProcAddress(user,"EnumWindows");
    BOOL (__stdcall *window_rect)(HWND,RECT *)=GetProcAddress(user,"GetWindowRect");
    LONG_PTR (__stdcall *get_long)(HWND,int)=GetProcAddress(user,"GetWindowLongPtrA");
    LONG_PTR (__stdcall *set_long)(HWND,int,LONG_PTR)=GetProcAddress(user,"SetWindowLongPtrA");
    BOOL (__stdcall *set_pos)(HWND,HWND,int,int,int,int,UINT)=GetProcAddress(user,"SetWindowPos");
    BOOL (__stdcall *foreground)(HWND)=GetProcAddress(user,"SetForegroundWindow");
    window_pid=GetProcAddress(user,"GetWindowThreadProcessId");visible=GetProcAddress(user,"IsWindowVisible");client_rect=GetProcAddress(user,"GetClientRect");
    log_file=create_file("Z:\\work\\window-fit.log",0x40000000,3,0,2,0x80,0);
    WCHAR *args=skip(cmdline());int width=number(args);args=skip(args);int height=number(args);args=skip(args);
    if(width<320 || height<200 || !*args){record("INVALID_WINDOW_COMMAND\r\n");ExitProcess(64);}
    STARTUPINFO si={0};si.cb=sizeof(si);si.flags=7;si.show=3;si.cx=width;si.cy=height;PROCESSINFO pi={0};
    if(!create(0,args,0,0,0,0,0,0,&si,&pi)){char line[128];format(line,"CREATE_PROCESS_FAILED error=%u\r\n",last_error());record(line);ExitProcess(70);}
    child_pid=pi.process_id;close_handle(pi.thread);
    HWND fitted_window=0;
    while(wait(pi.process,100)==258) {
        window=0;best_area=0;enumerate(visit,0);
        if(window) {
                    char line[256];RECT r={0},cr={0};window_rect(window,&r);client_rect(window,&cr);
                    DWORD style=(DWORD)get_long(window,-16),ex=(DWORD)get_long(window,-20);
                    if(window==fitted_window && !(style & 0x00cf0000u) && cr.right==width && cr.bottom==height)continue;
                    format(line,"BEFORE pid=%u style=%x ex=%x rect=%d,%d,%d,%d client=%d,%d\r\n",child_pid,style,ex,r.left,r.top,r.right,r.bottom,cr.right,cr.bottom);record(line);
                    // WS_MAXIMIZE makes Wine request native Wayland maximization.
                    // Position alone cannot place an xdg_toplevel at screen (0,0).
                    set_long(window,-16,(style & ~0x00cf0000u)|0x81000000u);
                    set_long(window,-20,ex & ~0x00020301u);
                    BOOL ok=set_pos(window,0,0,0,width,height,0x60);foreground(window);
                    window_rect(window,&r);client_rect(window,&cr);
                    format(line,"AFTER ok=%d style=%x ex=%x rect=%d,%d,%d,%d client=%d,%d\r\n",ok,(DWORD)get_long(window,-16),(DWORD)get_long(window,-20),r.left,r.top,r.right,r.bottom,cr.right,cr.bottom);record(line);
                    fitted_window=window;
        }
    }
    DWORD code=1;exit_code(pi.process,&code);char line[64];format(line,"CHILD_EXIT %u\r\n",code);record(line);close_handle(pi.process);close_handle(log_file);ExitProcess(code);
}
