// INPUT:  系统 EGL/Wayland EGL、libdl 与 pthread_once
// OUTPUT: EGL 扩展查询、过程地址、窗口表面及 wl_egl_window_* 兼容符号
// POS:    仅在余烬灯塔单窗口进程中适配原厂 MiniLoong Mali g13p0
/* SPDX-License-Identifier: MIT
 * Per-process adapter for Godot 4.3's EGL 1.4 loader on LoongOS.
 * Its second GLAD load queries display extensions and loses client-only
 * platform_base. Keep supported platform tokens available for that dispatch.
 * No driver, compositor, EGL version or configuration is replaced. Native
 * draws are followed by glFinish for the stock Mali streamed-buffer defect.
 * Built freestanding: the existing host libc/libdl provide these POSIX calls.
 */
#include <stddef.h>

typedef void *EGLDisplay;
typedef void (*EGLProc)(void);
typedef const char *(*QueryString)(EGLDisplay, int);
typedef EGLProc (*GetProcAddress)(const char *);
extern void *dlopen(const char *, int);
extern void *dlsym(void *, const char *);
extern int pthread_once(int *, void (*)(void));

static int once;
static QueryString native_query;
static GetProcAddress native_proc;
static unsigned client_platform_flags;
static int wayland_once;
static void *(*native_window_create)(void *, int, int);
static void (*native_window_resize)(void *, int, int, int, int);
static void (*native_window_destroy)(void *);
static void (*native_window_size)(void *, int *, int *);
static void *(*native_surface_create)(void *, void *, void *, const int *);
static void *main_native_window;
static __thread char extension_buffer[16384];

const char *eglQueryString(EGLDisplay display, int name);
EGLProc eglGetProcAddress(const char *name);
void *eglCreateWindowSurface(void *, void *, void *, const int *);

static size_t length(const char *text) {
    size_t n = 0;
    if (text) while (text[n]) ++n;
    return n;
}

static int same(const char *a, const char *b) {
    if (!a || !b) return 0;
    while (*a && *a == *b) { ++a; ++b; }
    return *a == *b;
}

static int has_token(const char *list, const char *token) {
    size_t n = length(token);
    if (!list) return 0;
    while (*list) {
        size_t i = 0;
        while (list[i] && list[i] != ' ') ++i;
        if (i == n) {
            size_t k = 0;
            while (k < n && list[k] == token[k]) ++k;
            if (k == n) return 1;
        }
        list += i;
        while (*list == ' ') ++list;
    }
    return 0;
}

static void initialize(void) {
    /* Absolute system path bypasses this game's private LD_LIBRARY_PATH.
     * DEEPBIND keeps firmware hook dependencies bound to their real library. */
    void *real = dlopen("/usr/lib/libEGL.so.1", 2 | 8);
    if (!real) return;
    native_query = (QueryString)dlsym(real, "eglQueryString");
    native_proc = (GetProcAddress)dlsym(real, "eglGetProcAddress");
    native_surface_create = (void *(*)(void *, void *, void *, const int *))dlsym(real, "eglCreateWindowSurface");
    if (native_surface_create == eglCreateWindowSurface) native_surface_create = NULL;
    if (native_query == eglQueryString) native_query = NULL;
    if (native_proc == eglGetProcAddress) native_proc = NULL;
}

const char *eglQueryString(EGLDisplay display, int name) {
    pthread_once(&once, initialize);
    if (!native_query) return NULL;
    const char *original = native_query(display, name);
    const char *tokens[] = {"EGL_EXT_platform_base", "EGL_KHR_platform_wayland"};
    if (!display && name == 0x3055) {
        unsigned flags = 0;
        for (size_t t = 0; t < 2; ++t)
            if (has_token(original, tokens[t])) flags |= 1u << t;
        __atomic_store_n(&client_platform_flags, flags, __ATOMIC_RELEASE);
        return original;
    }
    if (!display || name != 0x3055 || !original) return original;
    /* Remember only an explicit client query. Hidden queries can introduce
     * EGL errors on drivers without client extensions; never issue one here. */
    unsigned flags = __atomic_load_n(&client_platform_flags, __ATOMIC_ACQUIRE);
    if (!flags) return original;
    size_t n = length(original);
    if (n + 64 >= sizeof extension_buffer) return original;
    for (size_t i = 0; i <= n; ++i) extension_buffer[i] = original[i];
    for (size_t t = 0; t < 2; ++t) {
        if (!(flags & (1u << t)) || has_token(original, tokens[t])) continue;
        extension_buffer[n++] = ' ';
        for (size_t i = 0; tokens[t][i]; ++i) extension_buffer[n++] = tokens[t][i];
        extension_buffer[n] = 0;
    }
    return extension_buffer;
}

/* Stock MLP1 Mali g13p0 mis-tracks Godot's in-flight streamed canvas
 * buffers. Serialize each draw before the CPU can reuse its storage. This is
 * the per-draw barrier established by PortMaster-mlp1 at pinned 1e751b7.
 * Only this explicitly selected LoongOS compatibility adapter enables it.
 */
static void (*finish_draw)(void);
static void (*draw_arrays)(unsigned, int, int);
static void (*draw_elements)(unsigned, int, unsigned, const void *);
static void (*draw_arrays_instanced)(unsigned, int, int, int);
static void (*draw_elements_instanced)(unsigned, int, unsigned, const void *, int);

static void serialized_arrays(unsigned mode, int first, int count) {
    draw_arrays(mode, first, count);
    finish_draw();
}
static void serialized_elements(unsigned mode, int count, unsigned type, const void *indices) {
    draw_elements(mode, count, type, indices);
    finish_draw();
}
static void serialized_arrays_instanced(unsigned mode, int first, int count, int instances) {
    draw_arrays_instanced(mode, first, count, instances);
    finish_draw();
}
static void serialized_elements_instanced(unsigned mode, int count, unsigned type, const void *indices, int instances) {
    draw_elements_instanced(mode, count, type, indices, instances);
    finish_draw();
}

static int draw_once;
static void initialize_draws(void) {
    if (!native_proc) return;
    finish_draw = (void (*)(void))native_proc("glFinish");
    draw_arrays = (void (*)(unsigned, int, int))native_proc("glDrawArrays");
    draw_elements = (void (*)(unsigned, int, unsigned, const void *))native_proc("glDrawElements");
    draw_arrays_instanced = (void (*)(unsigned, int, int, int))native_proc("glDrawArraysInstanced");
    draw_elements_instanced = (void (*)(unsigned, int, unsigned, const void *, int))native_proc("glDrawElementsInstanced");
}

EGLProc eglGetProcAddress(const char *name) {
    pthread_once(&once, initialize);
    if (same(name, "glDrawArrays") || same(name, "glDrawElements") ||
            same(name, "glDrawArraysInstanced") || same(name, "glDrawElementsInstanced")) {
        pthread_once(&draw_once, initialize_draws);
        if (finish_draw && same(name, "glDrawArrays")) {
            if (draw_arrays) return (EGLProc)serialized_arrays;
        }
        if (finish_draw && same(name, "glDrawElements")) {
            if (draw_elements) return (EGLProc)serialized_elements;
        }
        if (finish_draw && same(name, "glDrawArraysInstanced")) {
            if (draw_arrays_instanced) return (EGLProc)serialized_arrays_instanced;
        }
        if (finish_draw && same(name, "glDrawElementsInstanced")) {
            if (draw_elements_instanced) return (EGLProc)serialized_elements_instanced;
        }
    }
    if (same(name, "eglCreateWindowSurface")) return (EGLProc)eglCreateWindowSurface;
    if (same(name, "eglQueryString")) return (EGLProc)eglQueryString;
    if (same(name, "eglGetProcAddress")) return (EGLProc)eglGetProcAddress;
    return native_proc ? native_proc(name) : NULL;
}

/* Godot 4.3 also dereferences the raw wl_egl_window in its EGL 1.4 legacy
 * surface path. Record the real opaque handle without changing it, then repair
 * precisely that legacy argument. This adapter is for the game's single window.
 * Native Wayland EGL operations still receive exactly their original handles.
 */
static void initialize_wayland(void) {
    void *real = dlopen("/usr/lib/libwayland-egl.so.1", 2 | 8);
    if (!real) return;
    native_window_create = (void *(*)(void *, int, int))dlsym(real, "wl_egl_window_create");
    native_window_resize = (void (*)(void *, int, int, int, int))dlsym(real, "wl_egl_window_resize");
    native_window_destroy = (void (*)(void *))dlsym(real, "wl_egl_window_destroy");
    native_window_size = (void (*)(void *, int *, int *))dlsym(real, "wl_egl_window_get_attached_size");
}

void *wl_egl_window_create(void *surface, int width, int height) {
    pthread_once(&wayland_once, initialize_wayland);
    void *window = native_window_create ? native_window_create(surface, width, height) : NULL;
    __atomic_store_n(&main_native_window, window, __ATOMIC_RELEASE);
    return window;
}

void wl_egl_window_resize(void *window, int width, int height, int dx, int dy) {
    pthread_once(&wayland_once, initialize_wayland);
    if (native_window_resize) native_window_resize(window, width, height, dx, dy);
}

void wl_egl_window_destroy(void *window) {
    pthread_once(&wayland_once, initialize_wayland);
    void *expected = window;
    __atomic_compare_exchange_n(&main_native_window, &expected, NULL, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
    if (native_window_destroy) native_window_destroy(window);
}

void wl_egl_window_get_attached_size(void *window, int *width, int *height) {
    pthread_once(&wayland_once, initialize_wayland);
    if (native_window_size) native_window_size(window, width, height);
}

void *eglCreateWindowSurface(void *display, void *config, void *window, const int *attrs) {
    pthread_once(&once, initialize);
    if (!native_surface_create) return NULL;
    void *real_window = __atomic_load_n(&main_native_window, __ATOMIC_ACQUIRE);
    if (real_window && window == *(void **)real_window) window = real_window;
    return native_surface_create(display, config, window, attrs);
}
