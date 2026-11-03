-- INPUT:  Layout-owned focus tree with rectangles, axes and eligible leaves
-- OUTPUT: move(root, current, dx, dy); directional target or nil
-- POS:    Shared container-first directional focus search, independent of rendering
local focus = {}

local function leaves(node, result)
    if node.children then
        for _,child in ipairs(node.children) do leaves(child,result) end
    elseif node.focusable then result[#result+1]=node end
end

local function choose(nodes, from, dx, dy, same_row)
    local best, best_beam, best_primary, best_secondary
    for _,node in ipairs(nodes) do
        local r=node.rect
        local vx=r.x+r.w/2-(from.x+from.w/2)
        local vy=r.y+r.h/2-(from.y+from.h/2)
        if dx*vx+dy*vy>1 then
            local beam
            if dx~=0 then beam=r.y<from.y+from.h and r.y+r.h>from.y
            else beam=r.x<from.x+from.w and r.x+r.w>from.x end
            local primary=dx~=0 and math.abs(vx) or math.abs(vy)
            local secondary=dx~=0 and math.abs(vy) or math.abs(vx)
            if (not same_row or beam) and (not best or (beam and not best_beam) or (beam==best_beam and
                (primary<best_primary or (primary==best_primary and secondary<best_secondary)))) then
                best,best_beam,best_primary,best_secondary=node,beam,primary,secondary
            end
        end
    end
    return best
end

local function find(node, id, path)
    path[#path+1]=node
    if node.id==id then return node end
    for _,child in ipairs(node.children or {}) do
        local target=find(child,id,path)
        if target then return target end
    end
    path[#path]=nil
end

function focus.move(root, id, dx, dy)
    local path={}
    local current=find(root,id,path)
    if not current then return nil end
    -- Each container gets first refusal. Only an exhausted direction bubbles.
    for depth=#path-1,1,-1 do
        local parent,branch=path[depth],path[depth+1]
        if parent.axis==nil or (parent.axis=="x" and dx~=0) or (parent.axis=="y" and dy~=0) then
            local candidates={}
            for _,child in ipairs(parent.children) do
                if child~=branch then leaves(child,candidates) end
            end
            local target=choose(candidates,current.rect,dx,dy,dx~=0 and depth==#path-1)
            if target then return target end
        end
    end
end

return focus
