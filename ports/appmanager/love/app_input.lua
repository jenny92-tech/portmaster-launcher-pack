-- INPUT:  app_native 控制器状态、kit 字体与共享主题
-- OUTPUT: install()；12 键必填校准覆盖层与已有配置退出提示
-- POS:    APP 原始按键向导；图示不限定设备的字母键排列
local theme=require("ui_theme")
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
function Input.install(native,kit)
    local draw=love.draw
    love.draw=function()
        local s=native.input_status()
        if not s.active then return draw() end
        local g=love.graphics
        local w,h=g.getDimensions()
        local cs=theme.scale(w,h)
        local compact=h<360
        local frame_w=compact and w or math.min(w-40*cs,840*cs)
        local frame_h=compact and h or math.min(h-32*cs,620*cs)
        local frame_x,frame_y=(w-frame_w)/2,(h-frame_h)/2
        local margin,gap=(compact and 16 or 28)*cs,8*cs
        local left=frame_x+margin
        local width=frame_w-margin*2
        local step=s.step or 0
        local finished=step>12
        local function text(value,x,y,width,px,color,align)
            g.setFont(kit.font(px))
            g.setColor(color or theme.text); g.printf(value,x,y,width,align or "center")
        end
        local function lines(value,px,max_lines)
            local font=kit.font(px)
            local _,wrapped=font:getWrap(value,math.max(1,width))
            local kept={}
            for i=1,math.min(#wrapped,max_lines or #wrapped) do kept[i]=wrapped[i] end
            return table.concat(kept,"\n"),#kept*font:getHeight()
        end
        g.setScissor()
        g.setColor(theme.background); g.rectangle("fill",0,0,w,h)
        g.setColor(theme.surface); g.rectangle("fill",frame_x,frame_y,frame_w,frame_h,compact and 0 or 14*cs,compact and 0 or 14*cs)
        local y=frame_y+margin
        if not compact then
            text("按键校准",left,y,width,17*cs,theme.muted,"left"); y=y+kit.font(17*cs):getHeight()+gap
        end
        local title=step==0 and "连接你的手柄" or (finished and "按键已就绪" or "按下  "..labels[step])
        local progress=finished and "12 / 12" or (step>0 and string.format("%02d / 12",step) or "等待连接")
        text(title,left,y,width,28*cs,nil,"left")
        text(progress,left,y+4*cs,width,17*cs,theme.muted,"right")
        y=y+kit.font(28*cs):getHeight()+gap
        local progress_y=y+8*cs
        for i=1,12 do
            g.setColor(i<step and {0.48,0.73,0.61,1} or i==step and theme.accent or theme.border)
            g.rectangle("fill",w/2+(i-6.5)*18*cs-5*cs,progress_y,10*cs,3*cs,2*cs,2*cs)
        end
        local hint="按下后松开，自动进入下一步"
        if step>=5 and step<=8 then hint="按设备上的字母键，图中位置仅作示意" end
        if finished then hint="A 保存配置     ·     X 重新校准" end
        if step==0 then hint="请检查手柄连接与输入权限" end
        local footer=s.can_cancel and "A + B 退出 · 保留原配置" or "完成 12 个按键后，配置保存在本 APP"
        local footer_text,footer_h=lines(footer,16*cs,2)
        local message,message_h=lines(s.message or "",16*cs,2)
        local hint_text,hint_h=lines(hint,18*cs,2)
        if compact and (s.message or "")~="" then hint_text,hint_h="",0 end
        local footer_y=frame_y+frame_h-margin-footer_h
        local message_y=footer_y-gap-message_h
        local hint_y=message_y-(hint_h>0 and gap+hint_h or 0)
        local graphic_top=progress_y+18*cs
        local graphic_bottom=hint_y-14*cs
        local u=math.max(0.1,math.min(width/552,(graphic_bottom-graphic_top)/250,1.3))
        local cx,cy=w/2,(graphic_top+graphic_bottom)/2+12*u
        -- Compact oval body: one continuous silhouette, no hanging grips.
        for layer=1,2 do
            local inset=(layer-1)*3*u
            if layer==1 then g.setColor(theme.border) else g.setColor(theme.navigation_background) end
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
                g.setColor(0.816,0.729,0.969,.20)
                if i>=5 and i<=8 then g.circle("fill",x,y,29*u)
                else g.rectangle("fill",x-bw/2-5*u,y-bh/2-5*u,bw+10*u,bh+10*u,10*u,10*u) end
                g.setColor(theme.app_focused)
            elseif i<step then g.setColor(0.18,0.23,0.23,1)
            else g.setColor(0.16,0.14,0.20,1) end
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
            else
                local px=math.min(16*cs,bw/(#names[i]*0.7))
                text(names[i],x-bw/2,y-kit.font(px):getHeight()/2,bw,px)
            end
        end
        text(hint_text,left,hint_y,width,18*cs,theme.text)
        text(message,left,message_y,width,16*cs,theme.muted)
        text(footer_text,left,footer_y,width,16*cs,theme.muted)
        Input._geometry={top=frame_y+margin,graphic_top=graphic_top,graphic_bottom=graphic_bottom,
            hint_y=hint_y,footer_y=footer_y,footer_bottom=footer_y+footer_h,
            controller_x=cx,controller_y=cy,controller_scale=u}

    end
    love.calibrationClick=function(x,y)
        local w,h=love.graphics.getDimensions()
        local step=native.input_status().step or 0
        if step==13 and Input._geometry and y>=Input._geometry.hint_y and y<Input._geometry.footer_y and x>=w*0.2 and x<w*0.8 then
            native.input_command(x<w/2 and 4 or 2)
        end
    end
end
return Input
