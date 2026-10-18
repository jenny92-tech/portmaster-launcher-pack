-- INPUT:  launcher 共享声明式启动器框架
-- OUTPUT: 吸血鬼幸存者 1.14 设置页面及 VS_* 启动参数
-- POS:    吸血鬼幸存者 1.14 的画面、内存和按键选项定义
local launcher = require("launcher")

launcher.define {
    id = "vampiresurvivors114",
    title = {en = "Vampire Survivors 1.14 Launcher", zh = "吸血鬼幸存者 1.14 启动器"},
    credits = {
        {"credit_dev", "poncle"},
        {"credit_porter", "Bili 解腻Jenny"},
    },
    fields = {
        launcher.output_resolution {env = {"VS_WIDTH", "VS_HEIGHT"}},
        launcher.render_scale {env = "VS_RENDER_PERCENT"},
        launcher.memory_mode {env = "VS_MEMORY_MODE"},
        launcher.graphics_api {env = "VS_GRAPHICS_API", vulkan = true},
        launcher.toggle {key = "swap_ab", label = {en = "Swap A/B:", zh = "交换 A/B:"}, env = "VS_SWAP_AB"},
        launcher.toggle {key = "swap_xy", label = {en = "Swap X/Y:", zh = "交换 X/Y:"}, env = "VS_SWAP_XY"},
    },
    pages = {
        {title = "title", rows = {"render_scale", "memory_mode", launcher.button("advanced", "page:2")}},
        {title = "advanced_title", fields = {"graphics_api", "resolution", "swap_ab", "swap_xy"}, actions = {"start", "back"}},
    },
    legacy = {
        path = "../conf/godot/app_userdata/Vampire Survivors Launcher/launch_config.env",
        state_path = "../conf/godot/app_userdata/Vampire Survivors Launcher/vs_launcher_state.json",
    },
    launch_count_env = "VS_LAUNCH_COUNT",
}
