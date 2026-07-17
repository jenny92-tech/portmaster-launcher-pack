local launcher = require("launcher")

launcher.define {
    id = "sts2",
    title = {en = "STS2 Linux Launcher", zh = "杀戮尖塔2 启动器"},
    credits = {
        {"credit_dev", "Mega Crit"},
        {"credit_porter", "Bili 解腻Jenny"},
    },
    fields = {
        launcher.select {
            key = "language", label = {en = "Language:", zh = "语言:"}, default = "zh_CN", env = "SLL_LANGUAGE",
            options = {{"en_US", {en = "English", zh = "英文"}}, {"zh_CN", {en = "Chinese", zh = "中文"}}},
        },
        launcher.select {
            key = "quality", label = {en = "Quality:", zh = "画质:"}, default = "balanced", env = "SLL_QUALITY",
            options = {
                {"smooth", {en = "Smooth", zh = "流畅"}}, {"balanced", {en = "Balanced", zh = "均衡"}},
                {"quality", {en = "Fidelity", zh = "画质"}},
            },
        },
        launcher.toggle {key = "swap_ab", label = {en = "Swap A/B:", zh = "换 A/B:"}, default = "on", env = "SLL_SWAP_AB"},
        launcher.toggle {key = "swap_xy", label = {en = "Swap X/Y:", zh = "换 X/Y:"}, env = "SLL_SWAP_XY"},
    },
    field_order = {"language", "quality", "swap_ab", "swap_xy"},
    static_env = {{"SLL_PCK_VARIANT", "8x8"}},
    legacy = {
        path = "../conf/godot/app_userdata/STS2 Linux Launcher/launch_config.env",
        state_path = "../conf/godot/app_userdata/STS2 Linux Launcher/linux_launcher_state.json",
    },
    launch_count_env = "SLL_LAUNCH_COUNT",
}
