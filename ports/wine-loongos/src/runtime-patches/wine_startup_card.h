// INPUT:  会话全屏标记、只读 BGRA 启动画面与机型实际宽高
// OUTPUT: Wine 临时 SHM 窗口背景填充及主窗口全屏策略
// POS:    在首个 GPU 画面前复用启动器画面，避免普通空白窗闪现
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <sys/mman.h>
#include <sys/stat.h>

static int wine_runner_fullscreen(HWND hwnd)
{
    const char *mode = getenv("WINE_RUNNER_FULLSCREEN");
    return mode && !strcmp(mode, "1") &&
           !(NtUserGetWindowLongW(hwnd, GWL_STYLE) & WS_CHILD) &&
           !NtUserGetWindowRelative(hwnd, GW_OWNER);
}

static pthread_once_t wine_runner_card_once = PTHREAD_ONCE_INIT;
static const uint32_t *wine_runner_card;
static int wine_runner_width, wine_runner_height;

static void wine_runner_load_card(void)
{
    const char *w = getenv("WINE_RUNNER_WIDTH"), *h = getenv("WINE_RUNNER_HEIGHT");
    struct stat st;
    char *end;
    long width, height;
    int fd;
    size_t size;
    void *pixels;
    if (!w || !h) return;
    width = strtol(w, &end, 10);
    if (*end || width < 320 || width > 4096) return;
    height = strtol(h, &end, 10);
    if (*end || height < 200 || height > 4096) return;
    size = (size_t)width * (size_t)height * 4;
    fd = open("/work/loading.bgra", O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size != (off_t)size)
    {
        close(fd);
        return;
    }
    pixels = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (pixels == MAP_FAILED) return;
    wine_runner_card = pixels;
    wine_runner_width = width;
    wine_runner_height = height;
}

static void wine_runner_paint_card(HWND hwnd, void *data, int width, int height)
{
    int x, y;
    uint32_t *destination = data;
    if (!wine_runner_fullscreen(hwnd) || width <= 0 || height <= 0) return;
    pthread_once(&wine_runner_card_once, wine_runner_load_card);
    if (!wine_runner_card) return;
    for (y = 0; y < height; ++y)
        for (x = 0; x < width; ++x)
            destination[(size_t)y * width + x] =
                wine_runner_card[(size_t)(y * wine_runner_height / height) * wine_runner_width +
                                 x * wine_runner_width / width] | 0xff000000u;
}
