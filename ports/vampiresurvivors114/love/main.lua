-- Vampire Survivors 1.14 launcher (LÖVE) -- config only; shared skeleton lives in kit.lua.
-- textureMaxDim changes this game's camera view, so launcher.sh pins it to 0 and it is
-- not exposed in the menu; resolution is pinned to auto for the same reason.
-- launch_config.env -> launcher.sh stage-2 rewrites vs.toml.

local kit = require("kit")

local TOGGLES = {"off", "on"}

local port = {}

port.state = {
    ui_lang = "zh", launch_count = 0,
    swap_ab = "off", swap_xy = "off",
}

port.strings = {
    title   = {en = "Vampire Survivors 1.14 Launcher", zh = "吸血鬼幸存者 1.14 启动器"},
    swap_ab = {en = "Swap A/B:", zh = "换 A/B:"},
    swap_xy = {en = "Swap X/Y:", zh = "换 X/Y:"},
}

port.credits = {
    {"credit_dev", "poncle"},
    {"credit_porter", "Bili 解腻Jenny"},
}

port.legacy_env = {
    path = "../conf/godot/app_userdata/Vampire Survivors Launcher/launch_config.env",
    state_path = "../conf/godot/app_userdata/Vampire Survivors Launcher/vs_launcher_state.json",
    fields = {
        swap_ab = {name="VS_SWAP_AB", allowed=TOGGLES},
        swap_xy = {name="VS_SWAP_XY", allowed=TOGGLES},
    },
}

local TOG_LABELS = {off="off", on="on"}


function port.build_pages(k, state)
    k.add_page("title", {
        k.picker("swap_ab", TOGGLES, TOG_LABELS, "swap_ab"),
        k.picker("swap_xy", TOGGLES, TOG_LABELS, "swap_xy"),
        k.button("start_game", "start"),
        k.button("quit_menu", "quit"),
    })
end


function port.write_env(f, state, k)
    -- Resolution pinned to auto (launcher.sh follows the device), texmax pinned to 0.
    f:write("VS_WIDTH=auto\n")
    f:write("VS_HEIGHT=auto\n")
    f:write("VS_SWAP_AB=" .. state.swap_ab .. "\n")
    f:write("VS_SWAP_XY=" .. state.swap_xy .. "\n")
    f:write("VS_LAUNCH_COUNT=" .. tostring(state.launch_count) .. "\n")
end

kit.run(port)
