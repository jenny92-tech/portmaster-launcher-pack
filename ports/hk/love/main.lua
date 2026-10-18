-- INPUT:  launcher 共享声明式启动器框架
-- OUTPUT: 空洞骑士设置页面及 HKL_* 启动参数
-- POS:    空洞骑士分辨率、渲染比例、画质、内存和按键选项定义
local launcher = require("launcher")

launcher.define {
    id = "hk",
    title = {en = "Hollow Knight Launcher", zh = "空洞骑士 启动器"},
    credits = {
        {"credit_dev", "Team Cherry"},
        {"credit_porter", "Bili 解腻Jenny"},
    },
    fields = {
        launcher.output_resolution {env = {"HKL_WIDTH", "HKL_HEIGHT"}},
        launcher.render_scale {env = "HKL_RENDER_PERCENT"},
        launcher.memory_mode {env = "HKL_MEMORY_MODE"},
        launcher.graphics_api {env = "HKL_GRAPHICS_API"},
        launcher.select {
            key = "texmax", requires_feature = "texture_limits", unavailable_value = "0", label = {en = "Texture Quality:", zh = "纹理质量:"}, default = "384", env = "HKL_TEXMAX",
            options = {
                {"384", {en = "Low", zh = "低"}},
                {"512", {en = "Medium", zh = "中"}},
                {"720", {en = "High", zh = "高"}},
                {"0", {en = "Original", zh = "原画"}},
            },
        },
        launcher.toggle {key = "swap_ab", label = {en = "Swap A/B:", zh = "交换 A/B:"}, env = "HKL_SWAP_AB"},
        launcher.toggle {key = "swap_xy", label = {en = "Swap X/Y:", zh = "交换 X/Y:"}, env = "HKL_SWAP_XY"},
    },
    pages = {
        {title = "title", rows = {"render_scale", "memory_mode", launcher.button("advanced", "page:2")}},
        {title = "advanced_title", fields = {"resolution", "texmax", "swap_ab", "swap_xy"}, actions = {"start", "back"}},
    },
    legacy = {
        path = "../conf/godot/app_userdata/Hollow Knight Launcher/launch_config.env",
        state_path = "../conf/godot/app_userdata/Hollow Knight Launcher/hk_launcher_state.json",
    },
    launch_count_env = "HKL_LAUNCH_COUNT",
}
