-- INPUT:  LUIS context, utils/vector/decorators and LÖVE graphics
-- OUTPUT: setluis() and new() checkbox with drawing and toggle callbacks
-- POS:    Pinned LUIS checkbox with optional vector check and inset border
local utils = require("luis.3rdparty.utils")
local Vector2D = require("luis.3rdparty.vector")
local decorators = require("luis.3rdparty.decorators")

local pointInRect = utils.pointInRect

local checkBox = {}

local luis  -- This will store the reference to the core library
function checkBox.setluis(luisObj)
    luis = luisObj
end

-- checkBox
function checkBox.new(value, size, onChange, row, col, customTheme)
    local checkboxTheme = customTheme or luis.theme.checkbox
    return {
        type = "CheckBox",
        value = value,
        width = size * luis.gridSize,
        height = size * luis.gridSize,
        onChange = onChange,
        focused = false,
        focusable = true,  -- Make the button focusable
        position = Vector2D.new((col - 1) * luis.gridSize, (row - 1) * luis.gridSize),
        checkScale = value and 1 or 0,
		theme = checkboxTheme,
		decorator = nil,

        update = function(self, mx, my, dt)
        end,

        defaultDraw = function(self)
            local x, y, size = self.position.x, self.position.y, self.width
            love.graphics.setColor(checkboxTheme.boxColor)
            love.graphics.rectangle("fill", x, y, size, self.height, checkboxTheme.cornerRadius)
            if checkboxTheme.borderColor then
                local stroke = checkboxTheme.borderWidth or 1
                love.graphics.setColor(checkboxTheme.borderColor)
                love.graphics.setLineWidth(stroke)
                love.graphics.rectangle("line", x + stroke / 2, y + stroke / 2,
                    size - stroke, self.height - stroke, checkboxTheme.cornerRadius)
            end
            love.graphics.setColor(checkboxTheme.checkColor)
            if checkboxTheme.vectorCheck then
                if self.checkScale > 0 then
                    love.graphics.setLineWidth(math.max(2, size * 0.105))
                    love.graphics.line(x + size * 0.23, y + size * 0.52,
                        x + size * 0.43, y + size * 0.71, x + size * 0.78, y + size * 0.30)
                end
            else
                local padding = size * 0.2
                love.graphics.rectangle("fill", x + padding + (size - padding * 2) * (1 - self.checkScale) / 2,
                    y + padding + (self.height - padding * 2) * (1 - self.checkScale) / 2,
                    (size - padding * 2) * self.checkScale, (self.height - padding * 2) * self.checkScale)
            end
            -- Draw focus indicator
            if self.focused then
                love.graphics.setColor(1, 1, 1, 0.5)
                love.graphics.rectangle("line", self.position.x - 2, self.position.y - 2, self.width + 4, self.height + 4, checkboxTheme.cornerRadius)
            end
        end,

		-- Draw method that can use a decorator
		draw = function(self)
			if self.decorator then
				self.decorator:draw()
			else
				self:defaultDraw()
			end
		end,

		-- Method to set a decorator
		setDecorator = function(self, decoratorType, ...)
			self.decorator = decorators[decoratorType].new(self, ...)
		end,

        click = function(self, x, y, button, istouch, presses)
            if pointInRect(x, y, self.position.x, self.position.y, self.width, self.height) then
                self.value = not self.value
                luis.flux.to(self, 0.2, { checkScale = self.value and 1 or 0 })
                if self.onChange then
                    self.onChange(self.value)
                end
                return true
            end
            return false
        end,

        setValue = function(self, value)
			self.value = value
			if self.onChange then
				self.onChange(self.value)
			end
			luis.flux.to(self, 0.2, { checkScale = self.value and 1 or 0 })
		end,

        -- Joystick-specific functions
        gamepadpressed = function(self, id, button)
            if button == 'a' and self.focused then
                self.value = not self.value
                luis.flux.to(self, 0.2, { checkScale = self.value and 1 or 0 })
                if self.onChange then
                    self.onChange(self.value)
                end
                return true
            end
            return false
        end,
    }
end

return checkBox
