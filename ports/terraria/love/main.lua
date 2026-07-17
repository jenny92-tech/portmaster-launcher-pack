-- Terraria launcher (LÖVE) -- config only; shared skeleton lives in kit.lua.
-- launch_config.env -> launcher.sh stage-2 rewrites the config.json language + toml.

local kit = require("kit")

local RESOLUTIONS = {"auto", "640x480", "720x720", "960x540", "960x720", "1280x720"}
local LANG_VALUES = {"1", "7", "12"}   -- 1=en, 7=zh-Hans, 12=zh-Hant
local TOGGLES     = {"off", "on"}

local port = {}

port.state = {
    ui_lang = "zh", launch_count = 0,
    resolution = "auto", language = "7",
    swap_ab = "off", swap_xy = "off",
}

port.strings = {
    title    = {en = "Terraria Launcher",       zh = "泰拉瑞亚 启动器"},
    language = {en = "Game Language:",          zh = "游戏语言:"},
    lang_en  = {en = "English",                 zh = "英文"},
    lang_zh  = {en = "Chinese (Simplified)",    zh = "简体中文"},
    lang_zht = {en = "Chinese (Traditional)",   zh = "繁体中文"},
    swap_ab  = {en = "Swap A/B:",               zh = "换 A/B:"},
    swap_xy  = {en = "Swap X/Y:",               zh = "换 X/Y:"},
}

port.credits = {
    {"credit_dev", "Re-Logic / 505 Games"},
    {"credit_porter", "Bili 解腻Jenny"},
}

port.legacy_env = {
    path = "../conf/godot/app_userdata/泰拉瑞亚启动器/launch_config.env",
    state_path = "../conf/godot/app_userdata/泰拉瑞亚启动器/terraria_launcher_state.json",
    fields = {
        resolution = {width="TER_WIDTH", height="TER_HEIGHT", allowed=RESOLUTIONS},
        language = {name="TER_LANGUAGE", allowed=LANG_VALUES},
        swap_ab = {name="TER_SWAP_AB", allowed=TOGGLES},
        swap_xy = {name="TER_SWAP_XY", allowed=TOGGLES},
    },
}

local RES_LABELS  = {auto="res_auto", ["640x480"]="640×480", ["720x720"]="720×720",
    ["960x540"]="960×540", ["960x720"]="960×720", ["1280x720"]="1280×720"}
local LANG_LABELS = {["1"]="lang_en", ["7"]="lang_zh", ["12"]="lang_zht"}
local TOG_LABELS  = {off="off", on="on"}


function port.build_pages(k, state)
    k.add_page("title", {
        k.picker("resolution", RESOLUTIONS, RES_LABELS,  "resolution"),
        k.picker("language",   LANG_VALUES, LANG_LABELS, "language"),
        k.picker("swap_ab",    TOGGLES,     TOG_LABELS,  "swap_ab"),
        k.picker("swap_xy",    TOGGLES,     TOG_LABELS,  "swap_xy"),
        k.button("start_game", "start"),
        k.button("quit_menu", "quit"),
    })
end


function port.write_env(f, state, k)
    local w, h = k.resolution_wh()
    f:write("TER_WIDTH=" .. w .. "\n")
    f:write("TER_HEIGHT=" .. h .. "\n")
    f:write("TER_LANGUAGE=" .. state.language .. "\n")
    f:write("TER_SWAP_AB=" .. state.swap_ab .. "\n")
    f:write("TER_SWAP_XY=" .. state.swap_xy .. "\n")
    f:write("TER_LAUNCH_COUNT=" .. tostring(state.launch_count) .. "\n")
end

kit.run(port)
