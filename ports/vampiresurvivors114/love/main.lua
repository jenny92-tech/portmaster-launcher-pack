local launcher = require("launcher")

launcher.define {
    id = "vampiresurvivors114",
    title = {en = "Vampire Survivors 1.14 Launcher", zh = "吸血鬼幸存者 1.14 启动器"},
    credits = {
        {"credit_dev", "poncle"},
        {"credit_porter", "Bili 解腻Jenny"},
    },
    fields = {
        launcher.resolution {env = {"VS_WIDTH", "VS_HEIGHT"}},
        launcher.toggle {key = "swap_ab", label = {en = "Swap A/B:", zh = "交换 A/B:"}, env = "VS_SWAP_AB"},
        launcher.toggle {key = "swap_xy", label = {en = "Swap X/Y:", zh = "交换 X/Y:"}, env = "VS_SWAP_XY"},
    },
    field_order = {"resolution", "swap_ab", "swap_xy"},
    legacy = {
        path = "../conf/godot/app_userdata/Vampire Survivors Launcher/launch_config.env",
        state_path = "../conf/godot/app_userdata/Vampire Survivors Launcher/vs_launcher_state.json",
    },
    launch_count_env = "VS_LAUNCH_COUNT",
}
