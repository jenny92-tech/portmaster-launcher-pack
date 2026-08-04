local launcher = require("launcher")

launcher.define {
    id = "sunkendragon",
    title = {en = "Sunken Dragon Launcher", zh = "龙沉异世录 启动器"},
    credits = {
        {"credit_dev", "Sunken Dragon developers"},
        {"credit_porter", "Bili 解腻Jenny"},
    },
    fields = {
        launcher.output_resolution {env = {"SDR_WIDTH", "SDR_HEIGHT"}},
        launcher.render_scale {env = "SDR_RENDER_PERCENT"},
        launcher.toggle {key = "swap_ab", label = {en = "Swap A/B:", zh = "交换 A/B:"}, env = "SDR_SWAP_AB"},
        launcher.toggle {key = "swap_xy", label = {en = "Swap X/Y:", zh = "交换 X/Y:"}, env = "SDR_SWAP_XY"},
    },
    field_order = {"resolution", "render_scale", "swap_ab", "swap_xy"},
    launch_count_env = "SDR_LAUNCH_COUNT",
    prelaunch = {
        core_files = {
            "gamefiles/lib/arm64-v8a/libil2cpp.so",
            "gamefiles/lib/arm64-v8a/libunity.so",
            "gamefiles/lib/arm64-v8a/libmain.so",
            "gamefiles/assets/bin/Data/Managed/Metadata/global-metadata.dat",
            "gamefiles/assets/bin/Data/globalgamemanagers",
            "gamefiles/.gamedata_ready",
        },
        source_glob = "GameData/*_Data/globalgamemanagers",
        missing_msg = {
            en = "Buy/download the Windows game, then copy its complete folder into GameData/.",
            zh = "请先购买并下载 Windows 正版，再把完整游戏目录复制到 GameData/。",
        },
    },
}
