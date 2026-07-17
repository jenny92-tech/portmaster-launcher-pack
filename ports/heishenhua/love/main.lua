-- Pixel Wukong launcher (LÖVE) -- config only; shared skeleton lives in kit.lua.
-- launch_config.env -> launcher.sh stage-2 rewrites wsm.toml.

local kit = require("kit")

local RESOLUTIONS = {"auto", "640x480", "720x720", "960x540", "960x720", "1280x720"}
local TEXMAX      = {"384", "480", "720", "0"}
local REDUCE      = {"0", "20", "40", "60", "80", "100"}
local REDUCE_MULT = {["0"]="1.0", ["20"]="0.8", ["40"]="0.6", ["60"]="0.4", ["80"]="0.2", ["100"]="0.0"}
local TOGGLES     = {"off", "on"}

local port = {}

port.state = {
    ui_lang = "zh", launch_count = 0,
    resolution = "auto", texmax = "480",
    swap_ab = "off", swap_xy = "off",
    reduce = "0", inf_mp = "off", inf_sta = "off", inf_wine = "off", skill_cd = "off",
}

port.strings = {
    title    = {en = "Pixel Wukong Launcher", zh = "像素黑神话 启动器"},
    texmax   = {en = "Graphics:",     zh = "画面质量:"},
    q_low    = {en = "Low (384)",     zh = "低 (384)"},
    q_mid    = {en = "Medium (480)",  zh = "中 (480)"},
    q_high   = {en = "High (720)",    zh = "高 (720)"},
    q_ultra  = {en = "Ultra",         zh = "极致 (不限)"},
    swap_ab  = {en = "Swap A/B:",     zh = "换 A/B:"},
    swap_xy  = {en = "Swap X/Y:",     zh = "换 X/Y:"},
    cheats   = {en = "Cheats  >",     zh = "修改 / 作弊  >"},
    cheat_title = {en = "Cheats",     zh = "修改 / 作弊"},
    reduce   = {en = "Damage Cut:",   zh = "减伤:"},
    r_0      = {en = "Off",           zh = "关"},
    r_20     = {en = "Cut 20%",       zh = "减伤 20%"},
    r_40     = {en = "Cut 40%",       zh = "减伤 40%"},
    r_60     = {en = "Cut 60%",       zh = "减伤 60%"},
    r_80     = {en = "Cut 80%",       zh = "减伤 80%"},
    r_100    = {en = "Invincible",    zh = "无敌"},
    inf_mp   = {en = "Inf. Mana:",    zh = "无限法力:"},
    inf_sta  = {en = "Inf. Stamina:", zh = "无限气力:"},
    inf_wine = {en = "Inf. Wine:",    zh = "无限酒:"},
    skill_cd = {en = "No Immob. CD:", zh = "定身无冷却:"},
}

port.credits = {
    {"credit_dev", "Bili 火山哥哥"},
    {"credit_art", "Bili 林学学LinkLin"},
    {"credit_porter", "Bili 解腻Jenny"},
}

port.legacy_env = {
    path = "../conf/godot/app_userdata/像素黑神话启动器/launch_config.env",
    state_path = "../conf/godot/app_userdata/像素黑神话启动器/heishenhua_launcher_state.json",
    fields = {
        resolution = {width="HSH_WIDTH", height="HSH_HEIGHT", allowed=RESOLUTIONS},
        texmax = {name="HSH_TEXMAX", allowed=TEXMAX},
        swap_ab = {name="HSH_SWAP_AB", allowed=TOGGLES}, swap_xy = {name="HSH_SWAP_XY", allowed=TOGGLES},
        reduce = {name="HSH_DMG", allowed=REDUCE, map={['1.0']='0',['0.8']='20',['0.6']='40',['0.4']='60',['0.2']='80',['0.0']='100'}},
        inf_mp = {name="HSH_INF_MP", allowed=TOGGLES}, inf_sta = {name="HSH_INF_STA", allowed=TOGGLES},
        inf_wine = {name="HSH_INF_WINE", allowed=TOGGLES}, skill_cd = {name="HSH_SKILL_CD", allowed=TOGGLES},
    },
}

local RES_LABELS = {auto="res_auto", ["640x480"]="640×480", ["720x720"]="720×720",
    ["960x540"]="960×540", ["960x720"]="960×720", ["1280x720"]="1280×720"}
local TEX_LABELS = {["384"]="q_low", ["480"]="q_mid", ["720"]="q_high", ["0"]="q_ultra"}
local TOG_LABELS = {off="off", on="on"}
local RED_LABELS = {["0"]="r_0", ["20"]="r_20", ["40"]="r_40", ["60"]="r_60", ["80"]="r_80", ["100"]="r_100"}


function port.build_pages(k, state)
    -- Home must be page 1: escape always returns to page 1.
    k.add_page("title", {
        k.picker("resolution", RESOLUTIONS, RES_LABELS, "resolution"),
        k.picker("texmax",     TEXMAX,      TEX_LABELS, "texmax"),
        k.picker("swap_ab",    TOGGLES,     TOG_LABELS, "swap_ab"),
        k.picker("swap_xy",    TOGGLES,     TOG_LABELS, "swap_xy"),
        k.button("cheats", "page:2"),
        k.button("start_game", "start"),
        k.button("quit_menu", "quit"),
    })
    -- Cheats page = page 2, targeted by the home page's cheats button.
    k.add_page("cheat_title", {
        k.picker("reduce",   REDUCE,  RED_LABELS, "reduce"),
        k.picker("inf_mp",   TOGGLES, TOG_LABELS, "inf_mp"),
        k.picker("inf_sta",  TOGGLES, TOG_LABELS, "inf_sta"),
        k.picker("inf_wine", TOGGLES, TOG_LABELS, "inf_wine"),
        k.picker("skill_cd", TOGGLES, TOG_LABELS, "skill_cd"),
        k.button("start_game", "start"),
        k.button("back", "page:1"),
    })
end


function port.write_env(f, state, k)
    local w, h = k.resolution_wh()
    f:write("HSH_WIDTH=" .. w .. "\n")
    f:write("HSH_HEIGHT=" .. h .. "\n")
    f:write("HSH_TEXMAX=" .. state.texmax .. "\n")
    f:write("HSH_DMG=" .. (REDUCE_MULT[state.reduce] or "1.0") .. "\n")
    f:write("HSH_SWAP_AB=" .. state.swap_ab .. "\n")
    f:write("HSH_SWAP_XY=" .. state.swap_xy .. "\n")
    f:write("HSH_INF_MP=" .. state.inf_mp .. "\n")
    f:write("HSH_INF_STA=" .. state.inf_sta .. "\n")
    f:write("HSH_INF_WINE=" .. state.inf_wine .. "\n")
    f:write("HSH_SKILL_CD=" .. state.skill_cd .. "\n")
    f:write("HSH_LAUNCH_COUNT=" .. tostring(state.launch_count) .. "\n")
end

kit.run(port)
