function love.conf(t)
    local identity = os.getenv("LOVE_IDENTITY") or "portmaster_launcher"
    local title = os.getenv("LOVE_WINDOW_TITLE") or "PortMaster Launcher"

    t.identity = identity:gsub("[^%w_.-]", "_")
    t.console = false
    t.window.title = title
    t.window.fullscreen = true
    t.window.fullscreentype = "desktop"
    t.window.resizable = false
    t.window.vsync = 1

    t.modules.physics = false
    t.modules.audio = false
    t.modules.sound = false
    -- gptokeyb is the single input path. Native joystick input would make one
    -- physical press arrive twice on several handheld firmwares.
    t.modules.joystick = false
end
