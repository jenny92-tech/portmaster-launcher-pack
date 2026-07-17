function love.conf(t)
    t.identity = "love_smoke"
    t.console = false
    t.window.title = "love smoke"
    t.window.fullscreen = true
    t.window.fullscreentype = "desktop"
    t.window.resizable = false
    t.window.vsync = 1
    -- Disable unused modules to cut down on KMSDRM init risk.
    t.modules.physics = false
    t.modules.audio = false
    t.modules.sound = false
    -- joystick off: gptokeyb already translates the gamepad to keys. If love also read
    -- dpup natively, one press would arrive twice and the cursor would move two steps.
    -- Keep only the gptokeyb->keyboard path, whose mapping stays controllable in .gptk.
    t.modules.joystick = false
end
