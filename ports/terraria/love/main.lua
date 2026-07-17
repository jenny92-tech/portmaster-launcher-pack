local launcher = require("launcher")

launcher.define {
    id = "terraria",
    title = {en = "Terraria Launcher", zh = "泰拉瑞亚 启动器"},
    credits = {
        {"credit_dev", "Re-Logic / 505 Games"},
        {"credit_porter", "Bili 解腻Jenny"},
    },
    fields = {
        launcher.resolution {env = {"TER_WIDTH", "TER_HEIGHT"}},
        launcher.select {
            key = "language", label = {en = "Game Language:", zh = "游戏语言:"}, default = "7", env = "TER_LANGUAGE",
            options = {
                {"1", {en = "English", zh = "英文"}}, {"7", {en = "Chinese (Simplified)", zh = "简体中文"}},
                {"12", {en = "Chinese (Traditional)", zh = "繁体中文"}},
            },
        },
        launcher.toggle {key = "swap_ab", label = {en = "Swap A/B:", zh = "交换 A/B:"}, env = "TER_SWAP_AB"},
        launcher.toggle {key = "swap_xy", label = {en = "Swap X/Y:", zh = "交换 X/Y:"}, env = "TER_SWAP_XY"},
    },
    field_order = {"resolution", "language", "swap_ab", "swap_xy"},
    legacy = {
        path = "../conf/godot/app_userdata/泰拉瑞亚启动器/launch_config.env",
        state_path = "../conf/godot/app_userdata/泰拉瑞亚启动器/terraria_launcher_state.json",
    },
    launch_count_env = "TER_LAUNCH_COUNT",
}
