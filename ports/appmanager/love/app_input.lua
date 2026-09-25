-- INPUT:  app_native 控制器状态、LOVE 图形与原页面绘制
-- OUTPUT: install()；12 键必填校准覆盖层与已有配置退出提示
-- POS:    APP 原始按键向导；图示不限定设备的字母键排列
local Input={}
local labels={"↑ 上","↓ 下","← 左","→ 右","A","B","X","Y","Start","Select","L1","R1"}
-- Button legends share symmetric ink bounds; no font ascent/side-bearing offsets.
local icons={
    {{0,9,0,-9},{-7,-2,0,-9,7,-2}},
    {{0,-9,0,9},{-7,2,0,9,7,2}},
    {{9,0,-9,0},{-2,-7,-9,0,-2,7}},
    {{-9,0,9,0},{2,-7,9,0,2,7}},
    {{-7,9,0,-9,7,9},{-4,2,4,2}},
    {{-6,-9,-6,9,2,9,6,6,6,3,2,0,-6,0},{-6,-9,2,-9,6,-6,6,-3,2,0}},
    {{-7,-9,7,9},{7,-9,-7,9}},
    {{-7,-9,0,0,7,-9},{0,0,0,9}},
}
function Input.install(native)
    local draw=love.draw
    love.draw=function()
        local s=native.input_status()
        if not s.active then return draw() end
        local g=love.graphics
        local w,h=g.getDimensions()
        local u=math.min(w/960,h/720)
        local fh=g.getFont():getHeight()
        local step=s.step or 0
        local finished=step>12
        local function text(value,x,y,width,shade)
            local v=shade or 0.94
            g.setColor(v,v,v,1); g.printf(value,x,y,width,"center")
        end
        g.setScissor()
        g.setColor(0.035,0.045,0.075,1); g.rectangle("fill",0,0,w,h)
        text("手柄设置",20,32*u,w-40,0.57)
        local title=step==0 and "连接你的手柄" or (finished and "按键已就绪" or "按下  "..labels[step])
        text(title,20,88*u,w-40)
        text(finished and "12 / 12" or (step>0 and string.format("%02d / 12",step) or "等待连接"),20,136*u,w-40,0.53)
        for i=1,12 do
            if i<step then g.setColor(0.29,0.77,0.58,1)
            elseif i==step then g.setColor(0.35,0.83,0.80,1)
            else g.setColor(0.19,0.22,0.31,1) end
            g.rectangle("fill",w/2+(i-6.5)*18*u-5*u,180*u,10*u,3*u,2*u,2*u)
        end
        local cx,cy=w/2,h*0.49
        -- Compact oval body: one continuous silhouette, no hanging grips.
        for layer=1,2 do
            local inset=(layer-1)*3*u
            if layer==1 then g.setColor(0.23,0.28,0.37,1) else g.setColor(0.085,0.11,0.16,1) end
            g.rectangle("fill",cx-276*u+inset,cy-86*u+inset,552*u-inset*2,188*u-inset*2,86*u,86*u)
        end
        local positions={{-165,-40},{-165,40},{-205,0},{-125,0},{205,0},{165,40},{165,-40},{125,0},{43,44},{-43,44},{-190,-112},{190,-112}}
        local names={"↑","↓","←","→","A","B","X","Y","Start","Select","L1","R1"}
        for i,p in ipairs(positions) do
            local x,y=math.floor(cx+p[1]*u)+0.5,math.floor(cy+p[2]*u)+0.5
            local bw,bh=40*u,40*u
            if i==9 or i==10 then bw,bh=78*u,34*u end
            if i>10 then bw,bh=100*u,30*u end
            if step==i then
                g.setColor(0.3,0.85,0.8,0.16+0.10*math.sin((s.elapsed or 0)*5))
                if i>=5 and i<=8 then g.circle("fill",x,y,29*u)
                else g.rectangle("fill",x-bw/2-5*u,y-bh/2-5*u,bw+10*u,bh+10*u,10*u,10*u) end
                g.setColor(0.13,0.49,0.48,1)
            elseif i<step then g.setColor(0.11,0.28,0.25,1)
            else g.setColor(0.16,0.20,0.27,1) end
            if i>=5 and i<=8 then g.circle("fill",x,y,22*u)
            else g.rectangle("fill",x-bw/2,y-bh/2,bw,bh,7*u,7*u) end
            if i<=8 then
                g.setColor(0.94,0.94,0.94,1)
                g.setLineWidth(math.max(1,math.floor(2*u+0.5)))
                for _,path in ipairs(icons[i]) do
                    local points={}
                    for j=1,#path,2 do
                        points[#points+1]=x+path[j]*u
                        points[#points+1]=y+path[j+1]*u
                    end
                    g.line(unpack(points))
                end
                g.setLineWidth(1)
            else text(names[i],x-bw/2,y-fh/2-2*u,bw) end
        end
        local hint="按下后松开，自动进入下一步"
        if step>=5 and step<=8 then hint="按设备上对应的字母键，图中位置仅作示意" end
        if finished then hint="A 保存配置     ·     X 重新校准" end
        if step==0 then hint="请检查连接或输入权限；读不到原始输入时无法校准" end
        text(hint,24,h*0.76,w-48,0.80)
        text(s.message or "",24,h*0.83,w-48,0.62)
        text(s.can_cancel and "Start + A 退出 · 保留原配置" or "完成全部 12 个按键后，配置仅保存在本 APP",24,h-fh-28*u,w-48,0.43)
    end
    love.calibrationClick=function(x,y)
        local w,h=love.graphics.getDimensions()
        local step=native.input_status().step or 0
        if step==13 and y>=h*0.75 and y<h*0.82 and x>=w*0.2 and x<w*0.8 then
            native.input_command(x<w/2 and 4 or 2)
        end
    end
end
return Input
