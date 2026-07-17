local launcher = require("launcher")

launcher.define {
    id = "hk",
    title = {en = "Hollow Knight Launcher", zh = "空洞骑士 启动器"},
    credits = {
        {"credit_dev", "Team Cherry"},
        {"credit_porter", "Bili 解腻Jenny"},
    },
    fields = {
        launcher.resolution {env = {"HKL_WIDTH", "HKL_HEIGHT"}},
        launcher.select {
            key = "texmax", label = {en = "Graphics:", zh = "画面质量:"}, default = "384", env = "HKL_TEXMAX",
            options = {
                {"384", {en = "Low (384)", zh = "低 (384)"}},
                {"512", {en = "Medium (512)", zh = "中 (512)"}},
                {"720", {en = "High (720)", zh = "高 (720)"}},
                {"0", {en = "Ultra (uncapped)", zh = "极致 (不限)"}},
            },
        },
        launcher.toggle {key = "swap_ab", label = {en = "Swap A/B:", zh = "交换 A/B:"}, env = "HKL_SWAP_AB"},
        launcher.toggle {key = "swap_xy", label = {en = "Swap X/Y:", zh = "交换 X/Y:"}, env = "HKL_SWAP_XY"},
    },
    field_order = {"resolution", "texmax", "swap_ab", "swap_xy"},
    legacy = {
        path = "../conf/godot/app_userdata/Hollow Knight Launcher/launch_config.env",
        state_path = "../conf/godot/app_userdata/Hollow Knight Launcher/hk_launcher_state.json",
    },
    launch_count_env = "HKL_LAUNCH_COUNT",
}
