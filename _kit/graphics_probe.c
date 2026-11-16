// INPUT: Explicit SDL backend and optional private Wayland WSI layer.
// OUTPUT: Disposable surface/queue checks, actual display bounds and GPU features.
// POS: Shared native preflight; no guest, presentation, compositor or DRM takeover.
#define _POSIX_C_SOURCE 200809L
#define VK_NO_PROTOTYPES 1
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>
#include <vulkan/vulkan.h>
#include <SDL2/SDL_vulkan.h>
#ifndef PROBE_BUILD_REVISION
#define PROBE_BUILD_REVISION "unrevisioned"
#endif
static const char identity[] = "PORTKIT_GRAPHICS_PROBE Release " PROBE_BUILD_REVISION;
#define SDL_FUNCTIONS(X) \
 X(Init) X(Quit) X(GetError) X(CreateWindow) X(DestroyWindow) \
 X(GetDisplayBounds) X(GetWindowDisplayIndex) X(GetWindowWMInfo) \
 X(Vulkan_GetInstanceExtensions) X(Vulkan_CreateSurface) X(GetCurrentVideoDriver)
#define DECLARE_SDL(name) __typeof__(&SDL_##name) name;
typedef struct { SDL_FUNCTIONS(DECLARE_SDL) } Sdl;
#undef DECLARE_SDL
#define INSTANCE_FUNCTIONS(X) \
 X(DestroyInstance) X(EnumeratePhysicalDevices) X(GetPhysicalDeviceProperties) \
 X(GetPhysicalDeviceFeatures) X(GetPhysicalDeviceQueueFamilyProperties) \
 X(EnumerateDeviceExtensionProperties) X(GetPhysicalDeviceSurfaceSupportKHR) \
 X(GetPhysicalDeviceSurfaceFormatsKHR) X(GetPhysicalDeviceSurfacePresentModesKHR) X(DestroySurfaceKHR)
#define DECLARE_VK(name) PFN_vk##name name;
typedef struct { INSTANCE_FUNCTIONS(DECLARE_VK) } Vulkan;
#undef DECLARE_VK
// Use the stable Wayland ABI without linking libwayland or requiring its headers.
typedef struct {
    VkStructureType sType; const void *pNext; VkFlags flags;
    struct wl_display *display; struct wl_surface *surface;
} WaylandSurfaceInfo;
typedef VkResult (*CreateWaylandSurface)(VkInstance,const WaylandSurfaceInfo*,const VkAllocationCallbacks*,VkSurfaceKHR*);

static int error(const char *message) {
    fprintf(stderr,"graphics-probe: %.768s\n",message ? message : "unknown error");return 1;
}
static int swapchain_supported(const Vulkan *vk,VkPhysicalDevice device) {
    uint32_t count=0; int found=0;
    if(vk->EnumerateDeviceExtensionProperties(device,NULL,&count,NULL)!=VK_SUCCESS || count>65536)return 0;
    VkExtensionProperties *items=calloc(count ? count : 1,sizeof(*items));
    if(!items)return 0;
    if(vk->EnumerateDeviceExtensionProperties(device,NULL,&count,items)==VK_SUCCESS)
        for(uint32_t i=0;i<count;i++)if(!strcmp(items[i].extensionName,VK_KHR_SWAPCHAIN_EXTENSION_NAME))found=1;
    free(items);return found;
}
int main(int argc,char **argv) {
    const char *library=NULL,*layer=NULL,*video=getenv("SDL_VIDEODRIVER");
    for(int i=1;i<argc;i++) {
        if(!strcmp(argv[i],"--build-revision")){puts(identity);return 0;}
        if(!strcmp(argv[i],"--help")){puts("graphics-probe [--wsi ABSOLUTE_LIBRARY --layer NAME] [--video-driver NAME]");return 0;}
        if(i+1>=argc)return error("option requires a value");
        if(!strcmp(argv[i],"--wsi"))library=argv[++i];
        else if(!strcmp(argv[i],"--layer"))layer=argv[++i];
        else if(!strcmp(argv[i],"--video-driver"))video=argv[++i];
        else return error("unknown option");
    }
    if((library!=NULL)!=(layer!=NULL) || (library && library[0]!='/') || (layer && !*layer))
        return error("private WSI needs an absolute library path and layer name");
    // SDL automatic selection may steal KMS/DRM from a frontend. Only the
    // calling ownership adapter may select a backend and acquire that display.
    if(!video || !*video || strchr(video,','))return error("one explicit SDL video backend is required");
    if(setenv("SDL_VIDEODRIVER",video,1))return error("cannot select SDL backend");
    void *sdl_library=dlopen("libSDL2-2.0.so.0",RTLD_NOW|RTLD_LOCAL);
    void *vk_library=NULL,*wsi_library=NULL;
    SDL_Window *window=NULL; VkInstance instance=VK_NULL_HANDLE; VkSurfaceKHR surface=VK_NULL_HANDLE;
    Sdl sdl={0}; Vulkan vk={0}; int result=1;
    if(!sdl_library)return error(dlerror());
#define LOAD_SDL(name) if(!(sdl.name=(void*)dlsym(sdl_library,"SDL_" #name))){error("missing SDL_" #name);goto cleanup;}
    SDL_FUNCTIONS(LOAD_SDL)
#undef LOAD_SDL
    if(sdl.Init(SDL_INIT_VIDEO)){error(sdl.GetError());goto cleanup;}
    window=sdl.CreateWindow("PortKit graphics preflight",SDL_WINDOWPOS_UNDEFINED,SDL_WINDOWPOS_UNDEFINED,64,64,
                            SDL_WINDOW_HIDDEN|(library ? 0 : SDL_WINDOW_VULKAN));
    if(!window){error(sdl.GetError());goto cleanup;}
    SDL_Rect bounds={0}; int display=sdl.GetWindowDisplayIndex(window);
    if(display<0 || sdl.GetDisplayBounds(display,&bounds) || bounds.w<=0 || bounds.h<=0){error("invalid SDL display bounds");goto cleanup;}
    vk_library=dlopen("libvulkan.so.1",RTLD_NOW|RTLD_LOCAL);
    if(!vk_library){error(dlerror());goto cleanup;}
    PFN_vkGetInstanceProcAddr get=(void*)dlsym(vk_library,"vkGetInstanceProcAddr");
    PFN_vkEnumerateInstanceVersion version=(void*)dlsym(vk_library,"vkEnumerateInstanceVersion");
    uint32_t api=0;
    if(!get || !version || version(&api)!=VK_SUCCESS || api<VK_API_VERSION_1_1){error("Vulkan 1.1 loader required");goto cleanup;}
    PFN_vkCreateInstance create=(void*)get(VK_NULL_HANDLE,"vkCreateInstance");
    const char *extensions[32]; unsigned count=32;
    SDL_SysWMinfo info={0};
    if(library) {
        if(strcmp(sdl.GetCurrentVideoDriver(),"wayland")){error("private WSI requires Wayland");goto cleanup;}
        wsi_library=dlopen(library,RTLD_NOW|RTLD_LOCAL);
        if(!wsi_library){error(dlerror());goto cleanup;}
        SDL_VERSION(&info.version);
        if(!sdl.GetWindowWMInfo(window,&info) || info.subsystem!=SDL_SYSWM_WAYLAND ||
           !info.info.wl.display || !info.info.wl.surface){error("Wayland window handles unavailable");goto cleanup;}
        extensions[0]=VK_KHR_SURFACE_EXTENSION_NAME;extensions[1]="VK_KHR_wayland_surface";count=2;
    } else if(!sdl.Vulkan_GetInstanceExtensions(window,&count,extensions) || !count || count>32) {
        error(sdl.GetError());goto cleanup;
    }
    VkApplicationInfo app={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.pApplicationName="PortKit graphics preflight",.apiVersion=VK_API_VERSION_1_1};
    VkInstanceCreateInfo ci={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&app,
        .enabledExtensionCount=count,.ppEnabledExtensionNames=extensions,
        .enabledLayerCount=layer ? 1u : 0u,.ppEnabledLayerNames=layer ? &layer : NULL};
    if(!create || create(&ci,NULL,&instance)!=VK_SUCCESS){error("Vulkan instance creation failed for selected route");goto cleanup;}
    // Every instance command uses the created instance's dispatch chain. NULL
    // is valid only for global commands, never as a capability test surface.
#define LOAD_VK(name) if(!(vk.name=(void*)get(instance,"vk" #name))){error("missing vk" #name);goto cleanup;}
    INSTANCE_FUNCTIONS(LOAD_VK)
#undef LOAD_VK
    if(library) {
        CreateWaylandSurface create_surface=(void*)get(instance,"vkCreateWaylandSurfaceKHR");
        WaylandSurfaceInfo wi={.sType=(VkStructureType)1000001000,.display=info.info.wl.display,.surface=info.info.wl.surface};
        if(!create_surface || create_surface(instance,&wi,NULL,&surface)!=VK_SUCCESS){error("private Wayland surface creation failed");goto cleanup;}
    } else if(!sdl.Vulkan_CreateSurface(window,instance,&surface)){error(sdl.GetError());goto cleanup;}
    uint32_t devices_count=0;
    if(vk.EnumeratePhysicalDevices(instance,&devices_count,NULL)!=VK_SUCCESS || !devices_count || devices_count>64){error("no bounded physical device set");goto cleanup;}
    VkPhysicalDevice devices[64];
    if(vk.EnumeratePhysicalDevices(instance,&devices_count,devices)!=VK_SUCCESS){error("device enumeration failed");goto cleanup;}
    for(uint32_t i=0;i<devices_count;i++) {
        VkPhysicalDeviceProperties properties; VkPhysicalDeviceFeatures features;
        vk.GetPhysicalDeviceProperties(devices[i],&properties);
        if(properties.apiVersion<VK_API_VERSION_1_1 || !swapchain_supported(&vk,devices[i]))continue;
        uint32_t queues_count=0;vk.GetPhysicalDeviceQueueFamilyProperties(devices[i],&queues_count,NULL);
        if(!queues_count || queues_count>1024)continue;
        VkQueueFamilyProperties *queues=calloc(queues_count,sizeof(*queues));if(!queues)continue;
        vk.GetPhysicalDeviceQueueFamilyProperties(devices[i],&queues_count,queues);
        int queue=-1;
        for(uint32_t q=0;q<queues_count;q++) {
            VkBool32 present=VK_FALSE;
            if(queues[q].queueCount && (queues[q].queueFlags&VK_QUEUE_GRAPHICS_BIT) &&
               vk.GetPhysicalDeviceSurfaceSupportKHR(devices[i],q,surface,&present)==VK_SUCCESS && present){queue=(int)q;break;}
        }
        free(queues);if(queue<0)continue;
        uint32_t formats=0,modes=0;
        if(vk.GetPhysicalDeviceSurfaceFormatsKHR(devices[i],surface,&formats,NULL)!=VK_SUCCESS || !formats ||
           vk.GetPhysicalDeviceSurfacePresentModesKHR(devices[i],surface,&modes,NULL)!=VK_SUCCESS || !modes)continue;
        vk.GetPhysicalDeviceFeatures(devices[i],&features);
        fprintf(stderr,"graphics-probe: route=%s sdl=%s output=%dx%d gpu=%.256s api=%u.%u.%u driver=%u queue=%d\n",
                library ? "wsi" : "native",sdl.GetCurrentVideoDriver(),bounds.w,bounds.h,properties.deviceName,
                VK_VERSION_MAJOR(properties.apiVersion),VK_VERSION_MINOR(properties.apiVersion),VK_VERSION_PATCH(properties.apiVersion),properties.driverVersion,queue);
        printf("PORTKIT_VULKAN_PROBE=1\nPORTKIT_DISPLAY_WIDTH=%d\nPORTKIT_DISPLAY_HEIGHT=%d\nPORTKIT_INDEPENDENT_BLEND=%u\n",bounds.w,bounds.h,features.independentBlend!=0);
        result=0;break;
    }
    if(result)error("no Vulkan 1.1 graphics+present device with swapchain formats/modes");
cleanup:
    if(surface && vk.DestroySurfaceKHR)vk.DestroySurfaceKHR(instance,surface,NULL);
    if(instance && vk.DestroyInstance)vk.DestroyInstance(instance,NULL);
    if(window && sdl.DestroyWindow)sdl.DestroyWindow(window);
    if(sdl.Quit)sdl.Quit();
    if(wsi_library)dlclose(wsi_library);
    if(vk_library)dlclose(vk_library);
    dlclose(sdl_library);return result;
}
