-- INPUT:  LÖVE 配置回调、LOVE_IDENTITY 与 LOVE_WINDOW_TITLE
-- OUTPUT: love.conf(t)；全屏窗口与模块开关
-- POS:    统一启动器显示配置并将手柄输入收敛到 gptokeyb 键盘映射
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
