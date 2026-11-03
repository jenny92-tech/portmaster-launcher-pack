-- INPUT:  Pinned Fluent icon atlas/layout and LÖVE image/quad drawing
-- OUTPUT: draw() with cached official icons rasterized at physical pixel sizes
-- POS:    Shared semantic icons with antialiased edges and no icon-font dependency
local layout=require("icons.layout")
local icons={}
local aliases={runtime="repair",storage="cleanup",library="games"}
local atlas,attempted
local quads={}

function icons.draw(name,x,y,size)
    local g=love.graphics
    if not attempted then
        attempted=true
        if g.newImage and g.newQuad then
            local ok,image=pcall(g.newImage,"icons/atlas.png")
            if ok and image and image.getDimensions then
                local width,height=image:getDimensions()
                if width==layout.width and height==layout.height then atlas=image end
            end
        end
    end
    if not atlas then return end
    local row=layout.names[aliases[name] or name] or layout.names.settings
    local pixels=math.max(layout.min_size,math.min(layout.max_size,math.floor(size+.5)))
    quads[row]=quads[row] or {}
    if not quads[row][pixels] then
        local offset=0
        for n=layout.min_size,pixels-1 do offset=offset+n+layout.padding*2 end
        quads[row][pixels]=g.newQuad(offset+layout.padding,row*layout.row_height+layout.padding,
            pixels,pixels,layout.width,layout.height)
    end
    -- An exact-size atlas cell avoids the native renderer's nearest-neighbour
    -- scaling. Round the origin too, keeping alpha edges on physical pixels.
    g.draw(atlas,quads[row][pixels],math.floor(x+(size-pixels)/2+.5),math.floor(y+(size-pixels)/2+.5))
end
return icons
