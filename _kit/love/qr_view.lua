-- INPUT:  URL text, pinned pure-Lua encoder and physical-pixel bounds
-- OUTPUT: Cached low-correction QR matrices and crisp drawing with compact margins
-- POS:    Shared offline QR view for handheld pairing pages
local qr = {}
local last_value,last_matrix
local quiet_zone=2
function qr.matrix(value)
    value=tostring(value or "")
    if value==last_value then return last_matrix end
    assert(#value>0 and #value<=512,"QR value must contain 1–512 bytes")
    local ok,matrix=require("qrcode.encode").qrcode(value,1)
    assert(ok,matrix)
    last_value,last_matrix=value,matrix
    return matrix
end
function qr.draw(value,x,y,width,height)
    local matrix=qr.matrix(value)
    local size=#matrix
    local unit=math.floor(math.min(width,height)/(size+quiet_zone*2))
    if unit<1 then return end
    local side=(size+quiet_zone*2)*unit
    x=math.floor(x+(width-side)/2); y=math.floor(y+(height-side)/2)
    local g=love.graphics
    g.setColor(1,1,1,1); g.rectangle("fill",x,y,side,side)
    g.setColor(0,0,0,1)
    for row=1,size do
        local col=1
        while col<=size do
            if matrix[col][row]>0 then
                local first=col
                repeat col=col+1 until col>size or matrix[col][row]<=0
                g.rectangle("fill",x+(first-1+quiet_zone)*unit,y+(row-1+quiet_zone)*unit,(col-first)*unit,unit)
            else col=col+1 end
        end
    end
end
return qr
