local selected = 1
local labels = {"Run launcher", "Runtime repair", "Exit"}
local font

function love.load()
    love.graphics.setBackgroundColor(0.025, 0.025, 0.04, 1)
    font = love.graphics.newFont(20)
    love.graphics.setFont(font)
end
function love.keypressed(key)
    if key == "up" then selected = math.max(1, selected - 1) end
    if key == "down" then selected = math.min(#labels, selected + 1) end
    if (key == "return" or key == "confirm") and selected == #labels then
        love.event.quit(0)
    end
    if key == "escape" or key == "cancel" then love.event.quit(0) end
end

function love.draw()
    local screenW, screenH = love.graphics.getDimensions()
    local panelW, itemH, gap = 420, 64, 14
    local title = "LOVE-lite SDL2 experiment"
    local fontH = font:getHeight()
    local blockH = fontH + 42 + #labels * itemH + (#labels - 1) * gap
    local top = math.floor((screenH - blockH) / 2)
    local left = math.floor((screenW - panelW) / 2)

    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.print(title, math.floor((screenW - font:getWidth(title)) / 2), top)
    for index, label in ipairs(labels) do
        local y = top + fontH + 42 + (index - 1) * (itemH + gap)
        if index == selected then
            love.graphics.setColor(0.36, 0.20, 0.58, 1)
            love.graphics.rectangle("fill", left, y, panelW, itemH, 10, 10)
        end
        love.graphics.setColor(1, 1, 1, 1)
        local textX = left + math.floor((panelW - font:getWidth(label)) / 2)
        local textY = y + math.floor((itemH - fontH) / 2)
        love.graphics.print(label, textX, textY)
    end
end
