local launcher = require("launcher")

launcher.define {
    id = "vampiresurvivors114",
    title = {en = "Vampire Survivors 1.14 Launcher", zh = "吸血鬼幸存者 1.14 启动器"},
    credits = {
        {"credit_dev", "poncle"},
        {"credit_porter", "Bili 解腻Jenny"},
    },
    fields = {
        launcher.toggle {key = "swap_ab", label = {en = "Swap A/B:", zh = "换 A/B:"}, env = "VS_SWAP_AB"},
        launcher.toggle {key = "swap_xy", label = {en = "Swap X/Y:", zh = "换 X/Y:"}, env = "VS_SWAP_XY"},
    },
    field_order = {"swap_ab", "swap_xy"},
    static_env = {{"VS_WIDTH", "auto"}, {"VS_HEIGHT", "auto"}},
    legacy = {
        path = "../conf/godot/app_userdata/Vampire Survivors Launcher/launch_config.env",
        state_path = "../conf/godot/app_userdata/Vampire Survivors Launcher/vs_launcher_state.json",
    },
    launch_count_env = "VS_LAUNCH_COUNT",
}
