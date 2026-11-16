# INPUT: Native probe and optional explicitly selected existing build container.
# OUTPUT: Build identity plus executable ABI/cleanup/dispatch and failure checks.
# POS: Isolated fake SDL/Vulkan libraries; no devices, real windows or presentation.
from pathlib import Path
import hashlib,os,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[1]
FAKE=r'''
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>
#include <vulkan/vulkan.h>
#include <SDL2/SDL_vulkan.h>
static int fail(const char *name){const char *v=getenv("PROBE_TEST_FAIL");return v && !strcmp(v,name);}
static void event(const char *v){FILE *f=fopen(getenv("PROBE_TEST_TRACE"),"a");if(f){fprintf(f,"%s\n",v);fclose(f);}}
int SDL_Init(Uint32 flags){if(flags!=SDL_INIT_VIDEO)abort();event("init");return 0;}
void SDL_Quit(void){event("quit");}
const char *SDL_GetError(void){return "test failure";}
SDL_Window *SDL_CreateWindow(const char*t,int x,int y,int w,int h,Uint32 flags){(void)t;(void)x;(void)y;(void)w;(void)h;
 if(!(flags&SDL_WINDOW_HIDDEN))abort();event(flags&SDL_WINDOW_VULKAN ? "native-window":"plain-window");return (void*)1;}
void SDL_DestroyWindow(SDL_Window*w){(void)w;event("window-destroy");}
int SDL_GetWindowDisplayIndex(SDL_Window*w){(void)w;return 0;}
int SDL_GetDisplayBounds(int display,SDL_Rect *bounds){if(display!=0)abort();*bounds=(SDL_Rect){0,0,960,720};return 0;}
SDL_bool SDL_GetWindowWMInfo(SDL_Window*w,SDL_SysWMinfo*i){(void)w;i->subsystem=SDL_SYSWM_WAYLAND;i->info.wl.display=(void*)2;i->info.wl.surface=(void*)3;return SDL_TRUE;}
const char *SDL_GetCurrentVideoDriver(void){return "wayland";}
SDL_bool SDL_Vulkan_GetInstanceExtensions(SDL_Window*w,unsigned*c,const char**e){(void)w;if(*c<1)abort();*c=1;e[0]="VK_KHR_surface";return SDL_TRUE;}
SDL_bool SDL_Vulkan_CreateSurface(SDL_Window*w,VkInstance i,VkSurfaceKHR*s){(void)w;if(!i)abort();if(fail("surface"))return SDL_FALSE;*s=(VkSurfaceKHR)4;return SDL_TRUE;}
VkResult vkEnumerateInstanceVersion(uint32_t*v){*v=VK_API_VERSION_1_1;return VK_SUCCESS;}
VkResult vkCreateInstance(const VkInstanceCreateInfo*c,const VkAllocationCallbacks*a,VkInstance*i){(void)a;if(!c)abort();*i=(VkInstance)5;event("instance-create");return VK_SUCCESS;}
void vkDestroyInstance(VkInstance i,const VkAllocationCallbacks*a){(void)a;if(!i)abort();event("instance-destroy");}
void vkDestroySurfaceKHR(VkInstance i,VkSurfaceKHR s,const VkAllocationCallbacks*a){(void)a;if(!i||!s)abort();event("surface-destroy");}
VkResult vkCreateWaylandSurfaceKHR(VkInstance i,const void*c,const VkAllocationCallbacks*a,VkSurfaceKHR*s){(void)a;if(!i||!c||!s)abort();if(fail("surface"))return VK_ERROR_INITIALIZATION_FAILED;*s=(VkSurfaceKHR)4;return VK_SUCCESS;}
VkResult vkEnumeratePhysicalDevices(VkInstance i,uint32_t*c,VkPhysicalDevice*d){if(!i)abort();*c=1;if(d)*d=(VkPhysicalDevice)6;return VK_SUCCESS;}
void vkGetPhysicalDeviceProperties(VkPhysicalDevice d,VkPhysicalDeviceProperties*p){(void)d;memset(p,0,sizeof(*p));p->apiVersion=VK_API_VERSION_1_1;strcpy(p->deviceName,"fixture GPU");}
void vkGetPhysicalDeviceFeatures(VkPhysicalDevice d,VkPhysicalDeviceFeatures*f){(void)d;memset(f,0,sizeof(*f));f->independentBlend=!fail("blend");}
void vkGetPhysicalDeviceQueueFamilyProperties(VkPhysicalDevice d,uint32_t*c,VkQueueFamilyProperties*p){(void)d;*c=1;if(p){memset(p,0,sizeof(*p));p->queueFlags=VK_QUEUE_GRAPHICS_BIT;p->queueCount=1;}}
VkResult vkEnumerateDeviceExtensionProperties(VkPhysicalDevice d,const char*l,uint32_t*c,VkExtensionProperties*p){(void)d;(void)l;*c=fail("swapchain") ? 0:1;if(p&&*c)strcpy(p->extensionName,"VK_KHR_swapchain");return VK_SUCCESS;}
VkResult vkGetPhysicalDeviceSurfaceSupportKHR(VkPhysicalDevice d,uint32_t q,VkSurfaceKHR s,VkBool32*p){(void)d;(void)q;if(!s)abort();*p=!fail("queue");return VK_SUCCESS;}
VkResult vkGetPhysicalDeviceSurfaceFormatsKHR(VkPhysicalDevice d,VkSurfaceKHR s,uint32_t*c,VkSurfaceFormatKHR*p){(void)d;(void)s;(void)p;*c=fail("formats") ? 0:1;return VK_SUCCESS;}
VkResult vkGetPhysicalDeviceSurfacePresentModesKHR(VkPhysicalDevice d,VkSurfaceKHR s,uint32_t*c,VkPresentModeKHR*p){(void)d;(void)s;(void)p;*c=1;return VK_SUCCESS;}
PFN_vkVoidFunction vkGetInstanceProcAddr(VkInstance i,const char*n){
 if(!i)return !strcmp(n,"vkCreateInstance") ? (PFN_vkVoidFunction)vkCreateInstance:NULL;
 #define ENTRY(name) if(!strcmp(n,"vk" #name))return (PFN_vkVoidFunction)vk##name;
 ENTRY(DestroyInstance) ENTRY(DestroySurfaceKHR) ENTRY(CreateWaylandSurfaceKHR) ENTRY(EnumeratePhysicalDevices)
 ENTRY(GetPhysicalDeviceProperties) ENTRY(GetPhysicalDeviceFeatures) ENTRY(GetPhysicalDeviceQueueFamilyProperties)
 ENTRY(EnumerateDeviceExtensionProperties) ENTRY(GetPhysicalDeviceSurfaceSupportKHR) ENTRY(GetPhysicalDeviceSurfaceFormatsKHR) ENTRY(GetPhysicalDeviceSurfacePresentModesKHR)
 return NULL;
}
'''

class IdentityTests(unittest.TestCase):
    def test_prebuilt_release_matches_own_source(self):
        revision=hashlib.sha256((ROOT/'_kit/graphics_probe.c').read_bytes()).hexdigest()
        self.assertEqual((ROOT/'_kit/graphics-probe-revision.txt').read_text().strip(),revision)
        self.assertIn(('PORTKIT_GRAPHICS_PROBE Release '+revision).encode(),(ROOT/'_kit/runtime/graphics-probe.aarch64').read_bytes())

@unittest.skipUnless(os.environ.get('GRAPHICS_PROBE_TEST_CONTAINER'),'Set GRAPHICS_PROBE_TEST_CONTAINER to an existing Linux build container')
class ExecutionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.container=os.environ['GRAPHICS_PROBE_TEST_CONTAINER']
        cls.directory=os.environ.get('GRAPHICS_PROBE_TEST_DIR','/out/portkit-graphics-probe/tests')
        cls.headers=os.environ.get('GRAPHICS_PROBE_VULKAN_HEADERS','/src/dm/linux/out/toolchain/vulkan-headers')
        cls.docker('mkdir','-p',cls.directory)
        with tempfile.TemporaryDirectory()as t:
            fake=Path(t)/'fake.c';fake.write_text(FAKE)
            for source,name in [(fake,'fake.c'),(ROOT/'_kit/graphics_probe.c','probe.c')]:
                subprocess.run(['docker','cp',str(source),cls.container+':'+cls.directory+'/'+name],check=True,capture_output=True)
        cls.docker('cc','-std=gnu11','-O2','-I'+cls.headers,cls.directory+'/probe.c','-ldl','-o',cls.directory+'/probe')
        cls.docker('cc','-std=gnu11','-fPIC','-shared','-O2','-I'+cls.headers,cls.directory+'/fake.c','-o',cls.directory+'/libfake.so')
        for name in ['libSDL2-2.0.so.0','libvulkan.so.1']:cls.docker('ln','-sf','libfake.so',cls.directory+'/'+name)
    @classmethod
    def docker(cls,*args):
        r=subprocess.run(['docker','exec','-e','TMPDIR='+cls.directory,cls.container,*args],capture_output=True,text=True,timeout=30)
        if r.returncode:raise AssertionError(r.stdout+r.stderr)
        return r.stdout
    def probe(self,failure='',wsi=False,backend=True):
        trace=self.directory+'/trace-'+str(id(self))+('-wsi'if wsi else '')
        args=['docker','exec','-e','LD_LIBRARY_PATH='+self.directory,'-e','PROBE_TEST_FAIL='+failure,'-e','PROBE_TEST_TRACE='+trace,'-e','SDL_VIDEODRIVER=',self.container,self.directory+'/probe']
        if backend:args+=['--video-driver','wayland']
        if wsi:args+=['--wsi',self.directory+'/libfake.so','--layer','VK_LAYER_fixture']
        r=subprocess.run(args,capture_output=True,text=True,timeout=10)
        events=self.docker('cat',trace).splitlines()if backend else []
        return r,events
    def test_native_and_wsi_report_actual_bounds_and_release_every_resource(self):
        for wsi in (False,True):
            with self.subTest(wsi=wsi):
                r,events=self.probe(wsi=wsi)
                self.assertEqual(r.returncode,0,r.stderr)
                for marker in ['PORTKIT_VULKAN_PROBE=1','PORTKIT_DISPLAY_WIDTH=960','PORTKIT_DISPLAY_HEIGHT=720','PORTKIT_INDEPENDENT_BLEND=1']:self.assertIn(marker,r.stdout.splitlines())
                self.assertEqual(events,['init','plain-window'if wsi else'native-window','instance-create','surface-destroy','instance-destroy','window-destroy','quit'])
    def test_failed_surface_queue_formats_and_swapchain_never_emit_success(self):
        for failure in ['surface','queue','formats','swapchain']:
            with self.subTest(failure=failure):
                r,events=self.probe(failure)
                self.assertNotEqual(r.returncode,0);self.assertNotIn('PORTKIT_VULKAN_PROBE=1',r.stdout)
                self.assertEqual(events[-3:],['instance-destroy','window-destroy','quit'])
    def test_optional_feature_is_reported_separately(self):
        r,_=self.probe('blend');self.assertEqual(r.returncode,0,r.stderr);self.assertIn('PORTKIT_INDEPENDENT_BLEND=0',r.stdout)
    def test_missing_backend_refuses_before_video_initialization(self):
        r,events=self.probe(backend=False);self.assertNotEqual(r.returncode,0);self.assertEqual(events,[]);self.assertIn('explicit SDL video backend',r.stderr)

if __name__=='__main__':unittest.main()
