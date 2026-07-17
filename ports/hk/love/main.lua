-- Hollow Knight launcher (LÖVE) -- config only; shared skeleton lives in kit.lua.
-- launch_config.env -> launcher.sh stage-2 rewrites hk.toml.

local kit = require("kit")

local RESOLUTIONS = {"auto", "640x480", "720x720", "960x540", "960x720", "1280x720"}
-- Graphics quality -> textureMaxDim: low=384 / medium=512 / high=720 / ultra=0 (no cap).
local TEXMAX      = {"384", "512", "720", "0"}
local TOGGLES     = {"off", "on"}

local port = {}

port.state = {
    ui_lang = "zh", launch_count = 0,
    resolution = "auto", texmax = "384",
    swap_ab = "off", swap_xy = "off",
}

port.strings = {
    title    = {en = "Hollow Knight Launcher", zh = "空洞骑士 启动器"},
    texmax   = {en = "Graphics:",         zh = "画面质量:"},
    q_low    = {en = "Low (384)",         zh = "低 (384)"},
    q_mid    = {en = "Medium (512)",      zh = "中 (512)"},
    q_high   = {en = "High (720)",        zh = "高 (720)"},
    q_ultra  = {en = "Ultra (uncapped)",  zh = "极致 (不限)"},
    swap_ab  = {en = "Swap A/B:",         zh = "换 A/B:"},
    swap_xy  = {en = "Swap X/Y:",         zh = "换 X/Y:"},
}

port.credits = {
    {"credit_dev", "Team Cherry"},
    {"credit_porter", "Bili 解腻Jenny"},
}

port.legacy_env = {
    path = "../conf/godot/app_userdata/Hollow Knight Launcher/launch_config.env",
    state_path = "../conf/godot/app_userdata/Hollow Knight Launcher/hk_launcher_state.json",
    fields = {
        resolution = {width="HKL_WIDTH", height="HKL_HEIGHT", allowed=RESOLUTIONS},
        texmax = {name="HKL_TEXMAX", allowed=TEXMAX},
        swap_ab = {name="HKL_SWAP_AB", allowed=TOGGLES},
        swap_xy = {name="HKL_SWAP_XY", allowed=TOGGLES},
    },
}

local RES_LABELS = {auto="res_auto", ["640x480"]="640×480", ["720x720"]="720×720",
    ["960x540"]="960×540", ["960x720"]="960×720", ["1280x720"]="1280×720"}
local TEX_LABELS = {["384"]="q_low", ["512"]="q_mid", ["720"]="q_high", ["0"]="q_ultra"}
local TOG_LABELS = {off="off", on="on"}


function port.build_pages(k, state)
    k.add_page("title", {
        k.picker("resolution", RESOLUTIONS, RES_LABELS, "resolution"),
        k.picker("texmax",     TEXMAX,      TEX_LABELS, "texmax"),
        k.picker("swap_ab",    TOGGLES,     TOG_LABELS, "swap_ab"),
        k.picker("swap_xy",    TOGGLES,     TOG_LABELS, "swap_xy"),
        k.button("start_game", "start"),
        k.button("quit_menu", "quit"),
    })
end


function port.write_env(f, state, k)
    local w, h = k.resolution_wh()
    f:write("HKL_WIDTH=" .. w .. "\n")
    f:write("HKL_HEIGHT=" .. h .. "\n")
    f:write("HKL_TEXMAX=" .. state.texmax .. "\n")
    f:write("HKL_SWAP_AB=" .. state.swap_ab .. "\n")
    f:write("HKL_SWAP_XY=" .. state.swap_xy .. "\n")
    f:write("HKL_LAUNCH_COUNT=" .. tostring(state.launch_count) .. "\n")
end

kit.run(port)
