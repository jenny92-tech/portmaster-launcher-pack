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
            key = "fps", label = {en = "Frame Cap:", zh = "帧率上限:"}, default = "config", env = "SILK_FPS",
            options = {
                {"config", {en = "Game preset", zh = "跟随游戏预设"}},
                {"90", "90 FPS"},
                {"60", "60 FPS"},
                {"45", "45 FPS"},
                {"30", "30 FPS"},
                {"25", "25 FPS"},
            },
        },
        launcher.render_scale {env = "SILK_RENDER_PERCENT"},
        launcher.memory_mode {env = "SILK_MEMORY_MODE"},
        launcher.graphics_api {env = "SILK_GRAPHICS_API", vulkan = true},
        launcher.select {
            key = "decorative", label = {en = "Decorations:", zh = "装饰物:"}, default = "75", env = "SILK_DECORATIVE_PERCENT",
            options = {
                {"50", {en = "Lean (50%)", zh = "精简 (50%)"}},
                {"75", {en = "Balanced (75%)", zh = "平衡 (75%)"}},
                {"100", {en = "Full (100%)", zh = "全开 (100%)"}},
            },
        },
        launcher.output_resolution {env = {"SILK_WIDTH", "SILK_HEIGHT"}},
        launcher.toggle {key = "swap_ab", label = {en = "Swap A/B:", zh = "交换 A/B:"}, env = "SILK_SWAP_AB"},
        launcher.toggle {key = "swap_xy", label = {en = "Swap X/Y:", zh = "交换 X/Y:"}, env = "SILK_SWAP_XY"},
    },
    pages = {
        {title = "title", rows = {"render_scale", "memory_mode", launcher.button("advanced", "page:2")}, actions = {"start", "quit"}},
        {title = "advanced_title", rows = {"graphics_api", "resolution", "quality", "fps", "decorative", "swap_ab", "swap_xy"}, actions = {"start", "back"}},
    },
    legacy = {
        path = "../conf/godot/app_userdata/Silksong Launcher/launch_config.env",
        state_path = "../conf/godot/app_userdata/Silksong Launcher/silksong_launcher_state.json",
    },
    launch_count_env = "SILK_LAUNCH_COUNT",
}
