-- INPUT:  model、operations 与功能页面构建方法
-- OUTPUT: Shell.new()；统一功能导航、列表/字段呈现及固定操作栏
-- POS:    APP Manager 各级页面共用的导航与内容骨架
local Shell={}

function Shell.new(model,operations)
    local kit,L,page=model.kit,model.L,model.pages
    local builders
    local self={}
    local sections={
        {page.HOME,"library",L("Installed","已安装"),"games","build_home"},
        {page.ZIP,"install",L("Install games","安装游戏"),"install","build_zip_install"},
        {page.STORAGE,"storage",L("Storage","存储清理"),"cleanup","build_storage"},
        {page.SYSTEM,"system",L("Environment","运行环境"),"runtime","build_system"},
        {page.REMOTE,"remote",L("Remote","远程管理"),"remote","build_remote"},
        {page.SETTINGS,"settings",L("Settings","设置"),"settings","build_settings"},
    }
    local parent={
        [page.GAMES]=page.HOME,[page.ITEM]=page.HOME,
        [page.JUNK]=page.STORAGE,[page.TRASH]=page.STORAGE,
        [page.MANAGE]=page.SYSTEM,[page.RUNTIME]=page.SYSTEM,[page.ENV]=page.SYSTEM,
        [page.ABOUT]=page.SETTINGS,
        [page.DEVICE]=page.SYSTEM,
    }
    function self.bind(value) builders=value end
    function self.set_page(index,title,rows,options)
        local opts=options or {}
        local section=parent[index] or index
        local icons={
            ["system:portmaster"]="settings",["system:runtimes"]="repair",["system:details"]="diagnostics",
            ["storage:leftovers"]="cleanup",["storage:appledouble"]="cleanup",["storage:trash"]="cleanup",
            ["settings:input"]="games",["settings:tutorial"]="help",["settings:about"]="app",
            ["item:repair"]="repair",
        }
        local toolbar_icons={
            ["library:refresh"]="refresh",["storage:refresh"]="refresh",["zip-rescan"]="refresh",
            ["manage:check"]="refresh",
        }
        local function toolbar(row)
            row.header_toolbar=true
            row.toolbar_align="right"
            row.height=52; row.label_px=20; row.chevron=false; row.menu_item=false
            row.icon=row.icon or toolbar_icons[row.id]
            row.appearance="toolbar"
            opts.toolbar_row=true
            opts.toolbar_auto=true
        end
        for _,row in ipairs(rows) do
            if row.kind=="button" and not row.inline then
                row.height=row.height or 84
                row.label_px=row.label_px or 24
                row.icon=row.icon or icons[row.id]
                row.menu_item=not row.library_item
            elseif row.kind=="button" and row.inline and row.header_toolbar==nil then
                toolbar(row)
            elseif row.kind=="picker" and row.label~="" then
                row.form_field=true; row.dropdown=true
            elseif row.kind=="checkbox" then
                row.selection_item=true; row.label_px=24; row.detail_px=17
                row.detail_max_lines=1
            end
            if index==page.SETTINGS then row.height=84; row.label_px=24 end
            if row.kind=="textview" then
                row.hero=row.heading==true
                row.form_field=not row.heading and not row.centered
                row.metric=row.id=="storage:free"
                row.surface=false
                row.label_px=row.heading and 26 or 18
                row.value_px=row.metric and 32 or row.value_px or 20
                if row.metric then row.focusable=false; row.expandable=false end
                row.max_lines=row.max_lines or 2
                row.thumbnail=row.hero and (row.thumbnail or "../share/appmanager.png") or row.thumbnail
                if row.hero then row.max_lines=1 end
                local detail=opts.sidebar_details and opts.sidebar_details[row.id]
                if detail then row.description=detail.body end
            end
        end
        local actions={}
        for _,row in ipairs(opts.sidebar or {}) do
            if row.action~=kit.back_page then actions[#actions+1]=row end
        end
        if #actions>0 then
            local header_rows={}
            for _,row in ipairs(actions) do
                toolbar(row)
                header_rows[#header_rows+1]=row
            end
            opts.toolbar_row=true
            for _,row in ipairs(rows) do header_rows[#header_rows+1]=row end
            rows=header_rows
        end
        for _,row in ipairs(rows) do
            if row.header_toolbar and row.kind=="button" then toolbar(row) end
            if row.header_toolbar then opts.toolbar_row=true; opts.toolbar_auto=true end
        end
        if index==page.GAMES or index==page.RUNTIME or index==page.TRASH or index==page.JUNK then
            for _,row in ipairs(rows) do
                if row.kind=="checkbox" and row.disabled~=true then row.default_focus=true; break end
            end
        end
        local navigation={}
        for _,item in ipairs(sections) do
            local destination,method=item[1],item[5]
            if index==destination then opts.compact_title=item[3] end
            navigation[#navigation+1]=kit.button(item[3],function()
                builders[method](true)
                kit.goto_page(destination)
            end,{id="nav:"..item[2],icon=item[4],active=section==destination,
                appearance="navigation",select_on_focus=true})
        end
        navigation[#navigation+1]=kit.button(L("Exit","退出"),operations.show_exit_dialog,
            {id="nav:quit",icon="quit",appearance="navigation",group="bottom"})
        opts.root=section==index
        opts.navigation=true
        opts.sidebar=navigation
        opts.sidebar_details=nil
        opts.sidebar_footer=nil
        opts.row_layout=opts.row_layout or {mode="flow",max_columns=1}
        opts.row_layout.max_width=1000
        if opts.row_layout.mode=="grid" then
            opts.row_layout.mode="flow"
            opts.row_layout.max_columns=1
        end
        if index~=page.HOME then
            for _,row in ipairs(rows) do
                if row.default_focus then break end
                if row.focusable and not row.header_toolbar and row.disabled~=true then row.default_focus=true; break end
            end
        end
        kit.set_page(index,title,rows,opts)
    end
    return self
end

return Shell
