-- INPUT:  launcher 共享声明式启动器框架
-- OUTPUT: 丝之歌设置页面及 SILK_* 启动参数
-- POS:    丝之歌的画面模式、帧率、渲染比例、内存和按键选项定义
local launcher = require("launcher")

launcher.define {
    id = "silksong",
    title = {en = "Hollow Knight: Silksong Launcher", zh = "空洞骑士：丝之歌 启动器"},
    strings = {
        advanced = {en = "Advanced  >", zh = "高级设置  >"},
        advanced_title = {en = "Advanced", zh = "高级设置"},
        effects = {en = "Effects  >", zh = "效果开关  >"},
        effects_title = {en = "Effects", zh = "效果开关"},
    },
    credits = {
        {"credit_dev", "Team Cherry"},
        {"credit_porter", "Bili 解腻Jenny"},
    },
    fields = {
        launcher.select {
            key = "quality", label = {en = "Picture Mode:", zh = "画面模式:"}, default = "low", env = "SILK_QUALITY",
            options = {
                {"low", {en = "Low / stable", zh = "低画 / 稳定"}},
                {"original", {en = "Original color", zh = "原彩"}},
            },
        },
        launcher.select {
            key = "fps", label = {en = "Frame Cap:", zh = "帧率上限:"}, default = "45", env = "SILK_FPS",
            options = {
                {"60", "60 FPS"},
                {"45", "45 FPS"},
                {"30", "30 FPS"},
                {"25", "25 FPS"},
            },
        },
        launcher.render_scale {env = "SILK_RENDER_PERCENT", default = "75"},
        launcher.select {
            key = "decorative", label = {en = "Decorations:", zh = "装饰物:"}, default = "75", env = "SILK_DECORATIVE_PERCENT",
            options = {
                {"50", {en = "Lean (50%)", zh = "精简 (50%)"}},
                {"75", {en = "Balanced (75%)", zh = "平衡 (75%)"}},
                {"100", {en = "Full (100%)", zh = "全开 (100%)"}},
            },
        },
        launcher.output_resolution {env = {"SILK_WIDTH", "SILK_HEIGHT"}},
        launcher.toggle {key = "file_elf", label = {en = "EXP: Reduce Memory Pressure:", zh = "实验：降低内存压力:"}, default = "on", env = "SILK_FILE_BACKED_ELF"},
        launcher.toggle {key = "assetbundle_unload", label = {en = "EXP: Unload Bundle Cache:", zh = "实验：卸载资源包缓存:"}, default = "on", env = "SILK_ASSETBUNDLE_UNLOAD"},
        launcher.toggle {key = "swap_ab", label = {en = "Swap A/B:", zh = "交换 A/B:"}, env = "SILK_SWAP_AB"},
        launcher.toggle {key = "swap_xy", label = {en = "Swap X/Y:", zh = "交换 X/Y:"}, env = "SILK_SWAP_XY"},
        launcher.select {
            key = "ambient_particles", label = {en = "Ambient Particles:", zh = "环境粒子:"}, default = "auto", env = "SILK_AMBIENT_PARTICLES",
            options = {
                {"auto", {en = "Follow mode", zh = "跟随画面模式"}},
                {"on", {en = "On", zh = "开"}},
                {"off", {en = "Off", zh = "关"}},
            },
        },
        launcher.select {
            key = "bloom", label = {en = "Bloom:", zh = "Bloom:"}, default = "auto", env = "SILK_BLOOM",
            options = {
                {"auto", {en = "Follow mode", zh = "跟随画面模式"}},
                {"on", {en = "On", zh = "开"}},
                {"off", {en = "Off", zh = "关"}},
            },
        },
        launcher.select {
            key = "camera_blur_plane", label = {en = "Camera Blur:", zh = "CameraBlurPlane:"}, default = "auto", env = "SILK_CAMERA_BLUR_PLANE",
            options = {
                {"auto", {en = "Follow mode", zh = "跟随画面模式"}},
                {"on", {en = "On", zh = "开"}},
                {"off", {en = "Off", zh = "关"}},
            },
        },
        launcher.select {
            key = "light_blur", label = {en = "Light Blur:", zh = "LightBlur:"}, default = "auto", env = "SILK_LIGHT_BLUR",
            options = {
                {"auto", {en = "Follow mode", zh = "跟随画面模式"}},
                {"on", {en = "On", zh = "开"}},
                {"off", {en = "Off", zh = "关"}},
            },
        },
        launcher.select {
            key = "uber_postprocess", label = {en = "Uber Post:", zh = "Uber后处理:"}, default = "auto", env = "SILK_UBER_POSTPROCESS",
            options = {
                {"auto", {en = "Follow mode", zh = "跟随画面模式"}},
                {"on", {en = "On", zh = "开"}},
                {"off", {en = "Off", zh = "关"}},
            },
        },
    },
    pages = {
        {title = "title", rows = {"quality", "fps", "render_scale", "decorative", launcher.button("advanced", "page:2")}, actions = {"start", "quit"}},
        {title = "advanced_title", rows = {"resolution", "file_elf", "assetbundle_unload", "swap_ab", "swap_xy", launcher.button("effects", "page:3")}, actions = {"start", "back"}},
        {title = "effects_title", fields = {"ambient_particles", "bloom", "camera_blur_plane", "light_blur", "uber_postprocess"}, actions = {"start", "back"}},
    },
    legacy = {
        path = "../conf/godot/app_userdata/Silksong Launcher/launch_config.env",
        state_path = "../conf/godot/app_userdata/Silksong Launcher/silksong_launcher_state.json",
    },
    launch_count_env = "SILK_LAUNCH_COUNT",
}
