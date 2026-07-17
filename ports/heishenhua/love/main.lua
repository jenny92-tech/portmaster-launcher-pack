local launcher = require("launcher")

launcher.define {
    id = "heishenhua",
    title = {en = "Pixel Wukong Launcher", zh = "像素黑神话 启动器"},
    strings = {
        cheats = {en = "Cheats  >", zh = "修改 / 作弊  >"},
        cheat_title = {en = "Cheats", zh = "修改 / 作弊"},
    },
    credits = {
        {"credit_dev", "Bili 火山哥哥"},
        {"credit_art", "Bili 林学学LinkLin"},
        {"credit_porter", "Bili 解腻Jenny"},
    },
    fields = {
        launcher.resolution {env = {"HSH_WIDTH", "HSH_HEIGHT"}},
        launcher.select {
            key = "texmax", label = {en = "Graphics:", zh = "画面质量:"}, default = "480", env = "HSH_TEXMAX",
            options = {
                {"384", {en = "Low (384)", zh = "低 (384)"}},
                {"480", {en = "Medium (480)", zh = "中 (480)"}},
                {"720", {en = "High (720)", zh = "高 (720)"}},
                {"0", {en = "Ultra", zh = "极致 (不限)"}},
            },
        },
        launcher.toggle {key = "swap_ab", label = {en = "Swap A/B:", zh = "换 A/B:"}, env = "HSH_SWAP_AB"},
        launcher.toggle {key = "swap_xy", label = {en = "Swap X/Y:", zh = "换 X/Y:"}, env = "HSH_SWAP_XY"},
        launcher.select {
            key = "reduce", label = {en = "Damage Cut:", zh = "减伤:"}, default = "0", env = "HSH_DMG",
            encode = {['0']='1.0', ['20']='0.8', ['40']='0.6', ['60']='0.4', ['80']='0.2', ['100']='0.0'},
            legacy_map = {['1.0']='0', ['0.8']='20', ['0.6']='40', ['0.4']='60', ['0.2']='80', ['0.0']='100'},
            options = {
                {"0", {en = "Off", zh = "关"}}, {"20", {en = "Cut 20%", zh = "减伤 20%"}},
                {"40", {en = "Cut 40%", zh = "减伤 40%"}}, {"60", {en = "Cut 60%", zh = "减伤 60%"}},
                {"80", {en = "Cut 80%", zh = "减伤 80%"}}, {"100", {en = "Invincible", zh = "无敌"}},
            },
        },
        launcher.toggle {key = "inf_mp", label = {en = "Inf. Mana:", zh = "无限法力:"}, env = "HSH_INF_MP"},
        launcher.toggle {key = "inf_sta", label = {en = "Inf. Stamina:", zh = "无限气力:"}, env = "HSH_INF_STA"},
        launcher.toggle {key = "inf_wine", label = {en = "Inf. Wine:", zh = "无限酒:"}, env = "HSH_INF_WINE"},
        launcher.toggle {key = "skill_cd", label = {en = "No Immob. CD:", zh = "定身无冷却:"}, env = "HSH_SKILL_CD"},
    },
    pages = {
        {title = "title", rows = {"resolution", "texmax", "swap_ab", "swap_xy", launcher.button("cheats", "page:2")}, actions = {"start", "quit"}},
        {title = "cheat_title", fields = {"reduce", "inf_mp", "inf_sta", "inf_wine", "skill_cd"}, actions = {"start", "back"}},
    },
    legacy = {
        path = "../conf/godot/app_userdata/像素黑神话启动器/launch_config.env",
        state_path = "../conf/godot/app_userdata/像素黑神话启动器/heishenhua_launcher_state.json",
    },
    launch_count_env = "HSH_LAUNCH_COUNT",
}
