-- INPUT:  model、operations、app_shell，kit 控件、环境能力和库存报告
-- OUTPUT: Pages.new()，六个功能分区、子页面与关于/退出共用的应用信息
-- POS:    APP Manager 的功能导航、业务页面与完整卸载清单
local Pages = {}

local function clear(values)
    for key in pairs(values) do values[key]=nil end
end

function Pages.new(model,operations,shell)
    local kit,L=model.kit,model.L
    local env,report,runtime_metadata=model.env,model.report,model.runtime_metadata
    local page=model.pages
    local self={}
    local environment
    local selected_home,selected_junk,selected_trash,selected_runtime={},{},{},{}
    local home_actions,junk_actions={},{}

    local function button(label,action,opts) return kit.button(label,action,opts) end
    local function portmaster_badge()
        if env.portmaster_management~="system" and env.portmaster_health=="healthy" and
           env.portmaster_python_ok~=false and model.update_state()=="update" then
            return kit.badge(L("Update","可升级"),{0.48,0.90,0.62})
        end
        return nil
    end
    local function start_home_tour()
        local state=kit.get_state()
        local log_path=model.log_path()
        kit.guide({
            title=L("Welcome to Port App Manager","欢迎使用 Port App Manager"),
            message=L(
                "Manage your games and apps in six sections. Actions stay with the content they manage.",
                "游戏和应用按六个功能分区管理，各页面只放与当前功能有关的操作。"),
            confirm=L("Start using","开始使用"),
            callouts={
                {target="nav:library",title=L("Installed","已安装"),
                    body=L("Filter games and apps, open item details to launch or uninstall, or select several items for batch uninstall.",
                    "筛选游戏和应用，打开详情后启动或卸载，也可以批量卸载。卸载前会列出完整删除路径。")},
                {target="nav:install",title=L("Install games","安装游戏"),
                    body=L("Scan storage card roots for game zip bundles and install them in one tap.",
                        "把下载好的游戏压缩包（zip）放进存储卡，这里会自动找到并一键安装。")},
                {target="nav:storage",title=L("Storage","存储清理"),
                    body=L("Find launchers, images, and data folders that no longer match.",
                        "找出不再需要的游戏残留文件和数据，清理后释放空间。")},
                {target="nav:system",title=L("Environment","运行环境"),
                    body=L("Check PortMaster, repair the Runtimes used by your games, and view device information.",
                        "查看 PortMaster 状态、修复游戏所需 Runtime，或检查设备和目录信息。")},
                {target="nav:remote",title=L("Remote management","远程管理"),
                    body=L("Enable remote management and scan the QR code with a phone on the same Wi-Fi. The link includes the pairing code.",
                        "开启后，用同一 Wi-Fi 下的手机扫码管理。配对码已经包含在链接里。")},
                {target="nav:settings",title=L("Settings & help","设置与帮助"),
                    body=L(
                        "Developer: Bilibili 解腻Jenny\nJoin "..kit.CONTACT..". When reporting a problem, include the log file: "..log_path,
                        "开发者：哔哩哔哩 解腻Jenny\n欢迎加入 "..kit.CONTACT.."。反馈问题时请同时提供日志："..log_path)},
            },
            on_confirm=function()
                state.onboarding_seen="1"
                kit.persist_state()
            end,
            on_skip=function()
                state.onboarding_seen="1"
                kit.persist_state()
            end,
        })
    end
    local function note(label,value,id)
        if id and (id:match(":empty$") or id:match(":unavailable$") or id=="runtime:not-required" or id=="remote:off") then
            return kit.empty(value,{id=id})
        end
        return kit.textview(label,value,{id=id,focusable=false,expandable=false,max_lines=3,
            expanded_lines=3,label_px=18,value_px=20,surface=false})
    end
    local function empty(values) return function() return model.selected_count(values)==0 end end
    local function enabled(name) return env[name]==true end
    local function set_root(index,title,rows,preserve_focus)
        shell.set_page(index,title,rows,{preserve_focus=preserve_focus,
            row_layout={mode="flow",max_columns=1}})
    end
    local function inline_button(label,action,id,group,columns,opts)
        opts=opts or {}; opts.id=id; opts.inline=group; opts.inline_columns=columns or 2
        opts.height=opts.height or 44; opts.label_px=opts.label_px or 18; opts.appearance=opts.appearance or "secondary"
        return button(label,action,opts)
    end
    local function exact_path(value)
        return type(value)=="string" and value~="" and value or nil
    end
    local function thumbnail(item)
        if item.app and item.app.has_icon and exact_path(item.app.folder) then
            return item.app.folder.."/icon.png"
        end
        for _,image in ipairs(item.port and item.port.images or {}) do
            if not image.is_dir and exact_path(image.path) then return image.path end
        end
    end
    local function port_name_counts()
        local counts={}
        for _,port in ipairs(report.ports or {}) do
            local name=model.display_name(port.script)
            counts[name]=(counts[name] or 0)+1
        end
        return counts
    end
    local function port_label(port,counts)
        local name=model.display_name(port.script)
        return (counts[name] or 0)>1 and port.script or name
    end
    local function primary_data_counts()
        local counts={}
        for _,port in ipairs(report.ports or {}) do
            local path=exact_path(port.data_path)
            if path then
                counts[path]=(counts[path] or 0)+1
            end
        end
        return counts
    end

    function self.bind_environment(value) environment=value end
    function self.reset_selection()
        clear(selected_home); clear(selected_junk); clear(selected_trash); clear(selected_runtime)
    end

    local function select_all_home(value)
        for key in pairs(home_actions) do selected_home[key]=value end
        self.build_games(true)
    end

    local function confirm_uninstall(chosen,return_page)
        local plan,labels,items,groups,data_counts,selected_paths,planned={},{},{},{},{},{},{}
        for _,action in ipairs(chosen) do
            selected_paths[action.script_path]=true
            if action.data_path then
                data_counts[action.data_path]=(data_counts[action.data_path] or 0)+1
            end
        end
        table.sort(chosen,function(a,b) return a.script_path<b.script_path end)
        local kept_images={}
        for _,port in ipairs(report.ports or {}) do
            if not selected_paths[port.path] then
                for _,image in ipairs(port.images or {}) do
                    local path=exact_path(image.path)
                    if path then kept_images[path]=true end
                end
            end
        end
        local function add(path,is_dir,group)
            group.items[#group.items+1]=path..(is_dir and "/" or "")
            if planned[path] then return end
            planned[path]=true
            plan[#plan+1]={kind="DELETE_MANAGED",arg=path}
            items[#items+1]=path..(is_dir and "/" or "")
        end
        -- When any script could not be parsed reliably, reference counts may miss
        -- dynamic references to a shared folder. Fail closed: uninstall the
        -- launcher and images, but never the data folder.
        local uncertain=report.classification_uncertain==true
        for _,action in ipairs(chosen) do
            labels[#labels+1]=action.label
            local group={title=action.label,thumbnail=action.thumbnail,items={}}
            groups[#groups+1]=group
            add(action.script_path,action.is_dir,group)
            for _,path in ipairs(action.image_paths) do
                if not kept_images[path] then add(path,false,group) end
            end
            if not uncertain and action.data_path and
               data_counts[action.data_path]==(report.data_refcount[action.data_path] or 0) then
                add(action.data_path,true,group)
            end
        end
        if #plan>0 then
            operations.show_confirm(L("Uninstall selected items","卸载所选项目"),plan,labels,return_page,{
                message=L("These files and folders will be deleted permanently. Folders include all their contents.",
                    "将永久删除以下内容（目录含全部文件），无法还原。"),
                items=items,item_groups=groups,confirm=L("Uninstall","卸载"),danger=true})
        end
    end

    local function uninstall_selected()
        local chosen={}
        for key,action in pairs(home_actions) do
            if selected_home[key] then chosen[#chosen+1]=action end
        end
        confirm_uninstall(chosen,page.GAMES)
    end

    local function library_items()
        local items={}
        if enabled("capability_inventory_apps") then
            for _,app in ipairs(report.apps or {}) do
                items[#items+1]={kind="app",label=model.app_label(app),app=app,
                    id="library:app:"..tostring(app.root_id or "unknown")..":"..app.name}
            end
        end
        if enabled("capability_inventory_ports") then
            local counts=port_name_counts()
            for _,port in ipairs(report.ports or {}) do
                items[#items+1]={kind="game",label=port_label(port,counts),port=port,
                    id="library:game:"..tostring(port.path or port.script)}
            end
        end
        table.sort(items,function(a,b) return a.label==b.label and a.id<b.id or a.label<b.label end)
        return items
    end

    function self.build_home(preserve_focus)
        model.ensure_report()
        local state=kit.get_state()
        local filter=state.library_filter or "all"
        local can_batch=enabled("capability_trash") and (enabled("capability_manage_ports") or enabled("capability_manage_apps"))
        local columns=can_batch and 3 or 2
        local rows={kit.select("",{"all","game","app"},{
            all=L("All","全部"),game=L("Games","游戏"),app=L("Apps","应用"),
        },"library_filter",{id="library:filter",dropdown=true,surface=false,
            inline="library-actions",inline_columns=columns,height=44,header_toolbar=true,toolbar_width=106,
            on_change=function() kit.persist_state(); self.build_home(true) end})}
        rows[#rows+1]=inline_button(L("Refresh","刷新"),function() operations.refresh_inventory(page.HOME) end,
            "library:refresh","library-actions",columns,{header_toolbar=true,toolbar_align="right",toolbar_width=112,appearance="quiet"})
        if can_batch then
            rows[#rows+1]=inline_button(L("Uninstall","批量卸载"),function()
                self.build_games(); kit.push_page(page.GAMES)
            end,"library:manage","library-actions",columns,
                {header_toolbar=true,toolbar_align="right",toolbar_width=140,appearance="quiet"})
        end
        if model.failure then
            rows[#rows+1]=kit.textview(model.failure.title,model.failure.reason,{
                id="library:failure",focusable=true,expandable=true,max_lines=3,surface=false})
            rows[#rows+1]=button(L("View failure details","查看失败原因"),operations.show_failure_details,
                {id="library:failure-details"})
        end
        if env.portmaster_health=="missing" or env.portmaster_health=="damaged" then
            local target=tostring(env.portmaster_target or env.controlfolder or "")
            rows[#rows+1]=button(model.health_label(),function()
                self.build_system(true); kit.push_page(page.SYSTEM)
            end,{id="library:environment-issue",description=L(
                "PortMaster location: "..target..". Open Environment for the cause and available repair actions; your game list remains available.",
                "PortMaster 位置："..target.."。到运行环境查看原因和可用处理方式，游戏列表仍可使用。")})
        end
        local count=0
        for _,item in ipairs(library_items()) do
            if filter=="all" or filter==item.kind then
                count=count+1
                local record=item
                local missing=item.port and model.missing_runtime(item.port.script) or ""
                rows[#rows+1]=button(item.label,function()
                    self.build_item(record); kit.push_page(page.ITEM)
                end,{id=item.id,icon=item.kind=="app" and "app" or "games",thumbnail=thumbnail(item),library_item=true,default_focus=count==1,
                    badge=missing~="" and kit.badge(L("Runtime missing","缺少 Runtime")) or nil})
            end
        end
        if count==0 then
            rows[#rows+1]=note(L("Nothing here yet","暂无内容"),
                filter=="all" and L("Open Install to scan packages on the storage card.","到「安装」页面扫描存储卡中的安装包。") or
                L("No installed items match this category.","这个分类下还没有已安装的项目。"),"library:empty")
        end
        set_root(page.HOME,L("Installed","已安装"),rows,preserve_focus)
        if state.onboarding_seen~="1" and not preserve_focus then start_home_tour() end
    end

    function self.build_item(item)
        local rows={}
        local script=item.port and exact_path(item.port.path) or exact_path(item.app.launch)
        if script then
            rows[#rows+1]=inline_button(L("Launch","启动"),function()
                kit.dialog({title=L("Launch "..item.label.."?","启动 "..item.label.."？"),
                    message=L("Port App Manager will close and "..item.label.." will start.","Port App Manager 将退出并启动"..item.label.."。"),
                    confirm=L("Launch","启动"),cancel=L("Back","返回"),danger=false,default_focus="confirm",
                    on_confirm=function()
                        local ok,reason=pcall(model.native.run,script)
                        if ok then model.clear_failure("run"); kit.quit(kit.EXIT_START)
                        else operations.report_failure("run",L("Cannot launch this item","无法启动"),reason) end
                    end})
            end,"item:launch","item-actions",2,{appearance="primary",header_toolbar=false,
                height=80,label_px=26,default_focus=true,chevron=false})
        end
        local action
        if item.port and enabled("capability_manage_ports") and script then
            local images={}
            for _,image in ipairs(item.port.images or {}) do
                local path=exact_path(image.path); if path then images[#images+1]=path end
            end
            action={label=item.label,thumbnail=thumbnail(item),script_path=script,data_path=exact_path(item.port.data_path),image_paths=images}
        elseif item.app and enabled("capability_manage_apps") and model.app_manageable(item.app) then
            local folder=exact_path(item.app.folder)
            if folder then action={label=item.label,thumbnail=thumbnail(item),script_path=folder,is_dir=true,image_paths={}} end
        end
        if action and enabled("capability_trash") then
            rows[#rows+1]=inline_button(L("Uninstall","卸载"),function() confirm_uninstall({action},page.HOME) end,
                "item:uninstall","item-actions",2,{danger=true,header_toolbar=false,
                    height=80,label_px=26,chevron=false})
        end
        for _,row in ipairs(rows) do row.inline_columns=#rows end
        local function path(label,value,id)
            if value and value~="" then
                rows[#rows+1]=kit.textview(label,value,{id=id,expandable=false,focusable=true,
                    max_lines=2,label_px=18,value_px=20,surface=false})
            end
        end
        if item.port then
            local missing=model.missing_runtime(item.port.script)
            path(L("Launcher","启动脚本"),script,"item:script")
            path(L("Game data","游戏目录"),item.port.data_path,"item:data")
            for i,image in ipairs(item.port.images or {}) do path(L("Image","配套图片"),image.path,"item:image:"..i) end
            if report.classification_uncertain or ((item.port.dir or "")~="" and not exact_path(item.port.data_path)) then
                rows[#rows+1]=note(L("Data folder","数据目录"),L(
                    "The data association could not be verified. Uninstall keeps the data folder.",
                    "无法确认数据归属，卸载时会保留数据目录。"),"item:kept-data")
            end
            if missing~="" then
                rows[#rows+1]=note(L("Missing Runtime","缺少 Runtime"),missing,"item:runtime")
                if enabled("capability_repair_runtimes") then
                    rows[#rows+1]=button(L("Repair Runtime","修复 Runtime"),function() self.build_runtime(); kit.push_page(page.RUNTIME) end,{id="item:repair"})
                end
            end
        else
            if not model.app_manageable(item.app) then
                rows[#rows+1]=note(L("System app","系统应用"),L("Protected · Cannot uninstall","受保护 · 不可卸载"),"item:protected")
            end
            path(L("App folder","应用目录"),item.app.folder,"item:folder")
            path(L("Launcher","启动脚本"),script,"item:script")
        end
        shell.set_page(page.ITEM,item.label,rows,{sidebar={},row_layout={mode="flow",max_columns=1}})
    end

    function self.build_remote(preserve_focus)
        local state=kit.get_state()
        local function toggle(on)
            local ok,endpoint=pcall(model.native.web_set,on)
            if not ok or type(endpoint)~="table" or (on and (endpoint.port or 0)<=0) then
                state.web_enabled=on and "0" or "1"
                operations.report_failure("web-set",L("Cannot switch remote management","无法切换远程管理"),not ok and endpoint or nil)
                return
            end
            model.clear_failure("web-set")
            operations.refresh_home()
            state.web_enabled=on and "1" or "0"
            state.web_port=on and tostring(endpoint.port) or nil
            state.web_code=on and tostring(endpoint.code or "") or nil
            kit.persist_state()
            self.build_remote(true)
        end
        local on=state.web_enabled=="1"
        local rows={inline_button(on and L("Turn off","关闭远程管理") or
            L("Turn on","开启远程管理"),function() toggle(not on) end,"remote:switch","remote-control",1,{
                default_focus=true,icon="remote"})}
        if state.web_enabled=="1" and state.web_port then
            local source=env.web_url or ""
            local host=source:match("^(https?://%b[])") or source:match("^(https?://[^:/]+)")
            if host then
                local url=host..":"..state.web_port..(state.web_code and state.web_code~="" and "/"..state.web_code or "")
                rows[#rows+1]=kit.qrcode(url,{id="remote:qr",fit_available=true,centered=true,surface=false})
                rows[#rows+1]=kit.textview("",url,{
                    id="remote:url",centered=true,preserve_lines=true,expandable=false,focusable=true,
                    max_lines=1,value_px=23,surface=false})

            else
                rows[#rows+1]=note(L("Connect to Wi-Fi","请连接 Wi-Fi"),L(
                    "Connect this handheld to Wi-Fi, then reopen remote management.",
                    "掌机连接 Wi-Fi 后，重新打开远程管理。"),"remote:wifi")
            end
        else
            rows[#rows+1]=kit.empty(L(
                "Enable it to manage this handheld from a phone or computer on the same Wi-Fi.",
                "同一 Wi-Fi 下，用手机扫码管理游戏和应用。"),{id="remote:off"})
        end
        set_root(page.REMOTE,L("Remote management","远程管理"),rows,preserve_focus)
    end

    function self.build_games(preserve_focus)
        local can_manage_ports=enabled("capability_manage_ports")
        local can_manage_apps=enabled("capability_manage_apps")
        local can_manage_any=can_manage_ports or can_manage_apps
        local can_trash=can_manage_any and enabled("capability_trash")
        if can_manage_any then model.ensure_report() end
        clear(home_actions)
        local rows,name_counts={},port_name_counts()
        for _,port in ipairs(can_manage_ports and (report.ports or {}) or {}) do
            local script=port.script
            local script_path=exact_path(port.path)
            local data_path=exact_path(port.data_path)
            local label=port_label(port,name_counts)
            local action_paths,image_paths={},{}
            if script_path then action_paths[#action_paths+1]=script_path end
            if data_path then action_paths[#action_paths+1]=data_path end
            for _,image in ipairs(port.images or {}) do
                local path=exact_path(image.path)
                if path then
                    image_paths[#image_paths+1]=path
                    action_paths[#action_paths+1]=path
                end
            end
            local detail={}
            if port.dir=="" and port.claimed_dir~="" then detail[#detail+1]=L("Missing data: ","数据缺失：")[kit.get_state().ui_lang]..port.claimed_dir end
            if port.dir~="" and not data_path then
                detail[#detail+1]=L("Data folder kept: association is not unique",
                    "数据目录会保留：无法确认唯一关联")[kit.get_state().ui_lang]
            end
            if report.classification_uncertain==true and port.dir~="" then
                detail[#detail+1]=L("Data folder kept: some launchers could not be parsed",
                    "数据目录会保留：部分启动项无法解析")[kit.get_state().ui_lang]
            end
            local missing=model.missing_runtime(script)
            if missing~="" then detail[#detail+1]=(kit.get_state().ui_lang=="zh" and "缺少 Runtime: " or "Missing Runtime: ")..missing end
            if not script_path then detail[#detail+1]=L("Path unavailable","路径未验证")[kit.get_state().ui_lang] end
            local key=script_path and ("home:"..script_path) or ("home-unverified:"..script)
            if script_path then
                home_actions[key]={key=key,label=label,thumbnail=thumbnail({port=port}),script_path=script_path,data_path=data_path,
                    image_paths=image_paths,dir=port.dir or ""}
            end
            rows[#rows+1]=kit.checkbox(label,{
                id=key,thumbnail=thumbnail({port=port}),detail=#detail>0 and model.join(detail) or nil,checked=script_path and selected_home[key] or false,
                disabled=not script_path,sidebar_target="uninstall",meta={key=key},
                on_change=function(value,meta)
                    if meta and home_actions[meta.key] then selected_home[meta.key]=value end
                end,
                badge=missing~="" and kit.badge(L("Runtime missing","缺少 Runtime")) or nil,
            })
        end
        for _,app in ipairs(can_manage_apps and (report.apps or {}) or {}) do
            local folder=exact_path(app.folder)
            local label=model.app_label(app)
            local manageable=model.app_manageable(app)
            local detail=not manageable and L("Protected system APP","受保护的系统应用")[kit.get_state().ui_lang] or nil
            local key=folder and ("home:app:"..folder) or ("home:app-unverified:"..tostring(app.name))
            if folder and manageable then
                home_actions[key]={key=key,label=label,thumbnail=thumbnail({app=app}),script_path=folder,is_dir=true,data_path=nil,image_paths={},dir=""}
            end
            rows[#rows+1]=kit.checkbox(label,{id=key,thumbnail=thumbnail({app=app}),detail=detail,
                checked=folder and manageable and selected_home[key] or false,
                sidebar_target="uninstall",meta={key=key},
                on_change=function(value,meta)
                    if meta and home_actions[meta.key] then selected_home[meta.key]=value end
                end,disabled=not folder or not manageable})
        end
        for key in pairs(selected_home) do
            if not home_actions[key] then selected_home[key]=nil end
        end
        if #rows==0 then rows[1]=note(L("Status","状态"),can_manage_any and
            L("No installed items are available to manage.","没有可管理的已安装项目。") or
            L("Uninstall management is not available on this device.","当前设备暂不支持卸载管理。"),"home:empty") end
        local sidebar={}
        if can_trash then
            sidebar[#sidebar+1]=button(model.dynamic_count("Uninstall (%d)","卸载 (%d)",selected_home),uninstall_selected,
                {id="uninstall",disabled=empty(selected_home)})
        end
        if can_manage_any and next(home_actions) then
            sidebar[#sidebar+1]=button(L("Select all","全选"),function() select_all_home(true) end,{half=true,id="select-all"})
            sidebar[#sidebar+1]=button(L("Select none","全不选"),function() select_all_home(false) end,{half=true,id="select-none"})
        end
        sidebar[#sidebar+1]=button(L("Back","返回"),kit.back_page,{group="bottom"})
        shell.set_page(page.GAMES,L("Batch uninstall","批量卸载"),rows,{
            preserve_focus=preserve_focus,sidebar_title=L("Actions","操作"),
            sidebar=sidebar})
        local state=kit.get_state()
        if state.onboarding_games~="1" and not preserve_focus then
            kit.guide({
                title=L("Batch uninstall","批量卸载"),
                message=L("Select items, then review the exact files and folders before uninstalling permanently.",
                    "勾选项目后卸载，逐项查看实际删除的文件和目录，确认后永久删除。"),
                confirm=L("Got it","知道了"),
                callouts={
                    {target="uninstall",title=L("Review before uninstalling","查看清单后卸载"),
                        body=L("Use Up/Down to review every deletion path. Shared or uncertain data folders are kept.",
                            "上下逐项查看删除路径。共享或无法确认归属的数据目录会保留。")},
                },
                on_confirm=function() state.onboarding_games="1"; kit.persist_state() end,
                on_skip=function() state.onboarding_games="1"; kit.persist_state() end,
            })
        end    end

    local function select_all_runtime(value)
        for _,item in ipairs(model.required_runtimes()) do
            selected_runtime[item.name]=value
        end
        self.build_runtime(true)
    end

    local function repair_runtimes()
        local plan,labels={},{}
        for _,item in ipairs(model.required_runtimes()) do
            if selected_runtime[item.name] then
                plan[#plan+1]={kind="INSTALL_RUNTIME",arg=item.name}; labels[#labels+1]=item.name
            end
        end
        if #plan>0 then
            operations.show_confirm(L("Repair selected Runtimes","修复所选 Runtime"),plan,labels,page.RUNTIME,{
                confirm=L("Download and repair","下载并修复"),danger=false})
        end
    end

    function self.build_runtime(preserve_focus)
        model.load_runtime_metadata()
        if env.portmaster_health=="missing" and env.portmaster_management~="system" then
            -- Runtime files live under the PortMaster core; without it there is
            -- nowhere to put them. Tell the user instead of failing a repair.
            shell.set_page(page.RUNTIME,L("Repair game Runtimes","修复游戏 Runtime"),{
                note(L("Status","状态"),
                    L("PortMaster is not installed, so Runtime files have nowhere to go. Install PortMaster first; game management still works.",
                        "未安装 PortMaster，Runtime 没有可用的存放目录。请先安装 PortMaster；游戏管理不受影响。"),"runtime:needs-pm"),
                button(L("Install PortMaster","安装 PortMaster"),function() environment.repair_environment() end,{id="runtime:install-pm"}),
            },{sidebar={},row_layout={mode="flow",max_columns=1,min_width=420}})
            return
        end
        local rows,details,available_runtime={},{},{}
        local required=model.required_runtimes()
        local repair_needed,installed={},{}
        for _,item in ipairs(required) do
            available_runtime[item.name]=true
            if item.needs_repair then repair_needed[#repair_needed+1]=item else installed[#installed+1]=item end
        end
        for name in pairs(selected_runtime) do
            if not available_runtime[name] then selected_runtime[name]=nil end
        end
        for _,item in ipairs(repair_needed) do
            if selected_runtime[item.name]==nil then selected_runtime[item.name]=true end
        end

        local function add_runtime(item)
            local users={}
            for _,script in ipairs(item.users or {}) do users[#users+1]=model.display_name(script) end
            table.sort(users)
            local metadata=runtime_metadata[item.name]
            local count=#users
            local detail=L(string.format("Used by %d: %s",count,table.concat(users,", ")),
                string.format("%d 个游戏使用：%s",count,table.concat(users,"、")))
            local key="repair:"..item.name
            rows[#rows+1]=kit.checkbox(item.name,{
                id=key,icon="package",detail=detail,detail_max_lines=1,height=84,checked=selected_runtime[item.name],
                sidebar_target="runtime-repair",on_change=function(value) selected_runtime[item.name]=value end,
                badge=item.missing and kit.badge(L("Missing","缺失")) or
                    (item.damaged and kit.badge(L("Needs repair","需要修复"),{1,0.45,0.38}) or
                    kit.badge(L("Installed","已安装"),{0.48,0.90,0.62})),
            })
            local health
            if item.missing then health=L("Not installed.","尚未安装。")
            elseif item.health=="invalid_magic" then health=L("Needs to be downloaded again.","需要重新下载。")
            else
                health=L(string.format("Ready to use (%s). Select it to download again.",model.human(item.bytes)),
                    string.format("可正常使用（%s）。勾选后会重新下载。",model.human(item.bytes)))
            end
            local remote=metadata and L(string.format("\n\nDownload size: %s",model.human(metadata.bytes)),
                string.format("\n\n下载大小：%s",model.human(metadata.bytes))) or
                L("\n\nDownload information will be checked when repair starts.","\n\n开始修复时会获取下载信息。")
            details[key]={title=item.name,body=L(
                string.format("%s%s\n\nUsed by %d game%s:\n%s",health.en,remote.en,count,count==1 and "" or "s",table.concat(users,"\n")),
                string.format("%s%s\n\n%d 个游戏使用：\n%s",health.zh,remote.zh,count,table.concat(users,"\n")))}
        end

        if #required>0 then
            rows[#rows+1]=kit.section(L(string.format("Needs repair (%d)",#repair_needed),string.format("需要修复（%d）",#repair_needed)),{font_px=22})
            if #repair_needed==0 then rows[#rows+1]=note(L("Status","状态"),L("All required Runtimes are ready.","游戏所需的 Runtime 均可正常使用。"),"runtime:all-ready")
            else for _,item in ipairs(repair_needed) do add_runtime(item) end end
            rows[#rows+1]=kit.section(L(string.format("Installed (%d)",#installed),string.format("已安装（%d）",#installed)),{font_px=22})
            if #installed==0 then rows[#rows+1]=note(L("Status","状态"),L("No required Runtime is installed yet.","还没有安装游戏所需的 Runtime。"),"runtime:none-installed")
            else for _,item in ipairs(installed) do add_runtime(item) end end
        else
            rows[1]=note(L("Status","状态"),L("The current games do not need an additional Runtime.","所有游戏都正常，不需要额外安装。"),"runtime:not-required")
        end
        local actions={}
        if #required>0 then actions={
            button(model.dynamic_count("Repair (%d)","修复 (%d)",selected_runtime),repair_runtimes,
                {id="runtime-repair",disabled=empty(selected_runtime)}),
            button(L("Select all","全选"),function() select_all_runtime(true) end,{half=true,id="runtime-select-all"}),
            button(L("Select none","全不选"),function() select_all_runtime(false) end,{half=true,id="runtime-select-none"}),
        } end
        shell.set_page(page.RUNTIME,L("Repair game Runtimes","修复游戏 Runtime"),rows,{preserve_focus=preserve_focus,
            row_layout={mode="flow",min_width=360,max_columns=1},sidebar_details=details,
            sidebar=actions})
    end

    local function select_all_junk(value)
        for key in pairs(junk_actions) do selected_junk[key]=value end
        self.build_junk(true)
    end

    local function remove_junk()
        local chosen={}
        for key,action in pairs(junk_actions) do
            if selected_junk[key] then chosen[#chosen+1]=action end
        end
        table.sort(chosen,function(a,b)
            if a.label==b.label then return a.path<b.path end
            return a.label<b.label
        end)
        local plan,labels,paths={},{},{}
        for _,action in ipairs(chosen) do
            plan[#plan+1]={kind="DELETE_MANAGED",arg=action.path}
            labels[#labels+1]=action.label
            paths[#paths+1]=action.path
        end
        if #plan>0 then operations.show_confirm(L("Delete selected leftovers","删除所选残留"),plan,labels,page.JUNK,
            {items=paths,scroll_items=true,danger=true,
                message=L("These files and folders will be permanently deleted.","以下文件和目录将永久删除，无法恢复。"),
                confirm=L("Delete","确认删除")}) end
    end

    local function cleanup_appledouble(return_page)
        local plan={{kind="CLEAN_APPLEDOUBLE",arg="-"}}
        operations.show_confirm(L("Clean ._Files","清理 ._Files"),plan,{},return_page or page.JUNK,{
            message=L(
                "Delete macOS ._* files from Port folders. Deleted files cannot be restored.",
                "删除 Port 目录中的 macOS ._* 文件。删除后无法还原。"),
            confirm=L("Start cleanup","开始清理"),danger=true,
        })
    end

    function self.build_storage(preserve_focus)
        model.ensure_report()
        local rows={}
        local can_cleanup=enabled("capability_manage_ports") and enabled("capability_leftovers") and enabled("capability_trash")
        rows[#rows+1]=note(L("Available space","可用空间"),model.human(env.free_bytes),"storage:free")
        if can_cleanup then
            rows[#rows+1]=inline_button(L("Rescan","重新扫描"),function() operations.refresh_inventory(page.STORAGE) end,
                "storage:refresh","storage-actions",1)
            local count=#(report.orphan_dirs or {})+#(report.orphan_images or {})+#(report.dead_scripts or {})
            rows[#rows+1]=button(L("Leftover files","残留文件"),function()
                self.build_junk(); kit.push_page(page.JUNK)
            end,{id="storage:leftovers",badge=kit.badge(tostring(count),{0.68,0.64,0.74})})
        end
        if enabled("capability_cleanup_appledouble") then
            rows[#rows+1]=button(L("Clean ._ files","清理 ._ 文件"),function() cleanup_appledouble(page.STORAGE) end,
                {id="storage:appledouble"})
        end
        if not can_cleanup and not enabled("capability_cleanup_appledouble") then
            rows[#rows+1]=note(L("Not available","暂不可用"),L("Cleanup is not available on this device.","当前设备暂不支持清理。"),"storage:unavailable")
        end
        local trash_count=enabled("capability_trash") and #self.collect_trash() or 0
        if trash_count>0 then
            rows[#rows+1]=button(L("Trash","回收站"),function() self.build_trash(); kit.push_page(page.TRASH) end,
                {id="storage:trash",badge=kit.badge(tostring(trash_count),{0.68,0.64,0.74})})
        end
        set_root(page.STORAGE,L("Storage","存储清理"),rows,preserve_focus)
    end

    function self.build_system(preserve_focus)
        local rows={
            button(L("PortMaster maintenance","PortMaster 维护"),function() environment.build_manage(); kit.push_page(page.MANAGE) end,
                {id="system:portmaster",detail=model.health_label(),badge=portmaster_badge()}),
        }
        if enabled("capability_repair_runtimes") then
            local count=model.runtime_issue_count()
            rows[#rows+1]=button(L("Repair game Runtimes","修复游戏 Runtime"),function() self.build_runtime(); kit.push_page(page.RUNTIME) end,
                {id="system:runtimes",detail=count>0 and L(string.format("%d need repair",count),string.format("%d 项需要修复",count)) or
                    L("All required Runtimes are ready","游戏所需 Runtime 均已就绪")})
        end
        local diagnosis=model.environment_diagnostics()
        rows[#rows+1]=button(L("Environment diagnostics","环境诊断"),function() self.build_env(); kit.push_page(page.ENV) end,
            {id="system:details",badge=diagnosis.count>0 and kit.badge(tostring(diagnosis.count),
                #diagnosis.high>0 and {1,0.45,0.38} or {1,0.65,0.43}) or nil})
        set_root(page.SYSTEM,L("Environment","运行环境"),rows,preserve_focus)
    end

    function self.build_settings(preserve_focus)
        local function swap_changed(key)
            return function()
                local st=kit.get_state()
                local ok=kit.persist_state()
                if not ok then
                    st[key]=st[key]=="1" and "0" or "1"
                    kit.toast(L("Could not save button settings.","按键设置保存失败。"),{kind="error"})
                end
                require("app_native").input_layout(st.swap_ab=="1",st.swap_xy=="1")
            end
        end
        local rows={
            kit.select(L("Language","界面语言"),{"zh","en"},{zh="简体中文",en="English"},"ui_lang",{
                id="settings:language",icon="language",on_change=function() kit.persist_state(); self.build_settings(true) end}),
            kit.switch(L("Swap A/B","A/B 互换"),"swap_ab",{
                id="settings:swap-ab",icon="games",off_value="0",on_value="1",on_change=swap_changed("swap_ab")}),
            kit.switch(L("Swap X/Y","X/Y 互换"),"swap_xy",{
                id="settings:swap-xy",icon="games",off_value="0",on_value="1",on_change=swap_changed("swap_xy")}),
            button(L("Controller calibration","按键校准"),function() require("app_native").input_command(1) end,
                {id="settings:input"}),
            button(L("Usage guide","使用教程"),start_home_tour,{id="settings:tutorial"}),
            button(L("About","关于"),function() self.build_about(); kit.push_page(page.ABOUT) end,{id="settings:about"}),
        }
        set_root(page.SETTINGS,L("Settings","设置"),rows,preserve_focus)
    end

    function self.about_info()
        return {title="APP Manager",author=L("By Bilibili 解腻Jenny","哔哩哔哩 解腻Jenny 制作"),
            thumbnail="../share/appmanager.png",contact=kit.CONTACT,
            log_path=model.log_path()}
    end

    function self.build_about()
        local about=self.about_info()
        local rows={
            kit.textview(about.title,about.author,{
                id="about:developer",thumbnail=about.thumbnail,heading=true,focusable=true,expandable=false,surface=false}),
            note(L("Feedback","问题反馈"),about.contact,"about:contact"),
            kit.textview(L("Log file","日志文件"),about.log_path,{
                id="about:log",focusable=true,expandable=false,max_lines=3,surface=false}),
        }
        shell.set_page(page.ABOUT,L("About","关于"),rows,{sidebar={},row_layout={mode="flow",max_columns=1}})
    end

    function self.build_junk(preserve_focus)
        model.ensure_report()
        if not preserve_focus then clear(selected_junk) end
        clear(junk_actions)
        local rows,item_count={},0
        -- Generic / unknown-path profiles derive folders by best-effort guessing,
        -- so never pre-select leftover data folders there: a wrong guess could
        -- otherwise delete unrelated directories with one confirm.
        local guessed_layout=tostring(env.device_class or "")=="unsupported-known" or
            tostring(env.device_class or "")=="unknown-path"
        if guessed_layout then
            rows[#rows+1]=kit.textview(L("Generic layout warning","通用布局提醒"),L(
                "This device uses the generic profile, so folder paths are best-effort guesses. Nothing is selected by default; review each item before deleting it.",
                "当前设备使用通用配置，目录路径为估算值，默认不会勾选任何项目。请逐项确认后再删除。"),{
                id="leftovers:guess-warning",focusable=true,expandable=true,max_lines=3,expanded_lines=6,
                label_px=18,value_px=20,surface=false})
        end
        local function add(kind,label,detail,path,default_selected)
            path=exact_path(path)
            if not path then
                item_count=item_count+1
                rows[#rows+1]=kit.textview(label,L(
                    "The exact path could not be verified, so this item will not be changed.",
                    "无法验证准确路径，因此不会处理这个项目。"),{
                    id="leftovers:unverified:"..kind..":"..label,focusable=false,expandable=false,
                    max_lines=3,expanded_lines=3,label_px=18,value_px=20,surface=false})
                return
            end
            local key="leftovers:"..kind..":"..path
            item_count=item_count+1
            junk_actions[key]={key=key,path=path,label=label}
            if selected_junk[key]==nil then selected_junk[key]=default_selected==true end
            rows[#rows+1]=kit.checkbox(label,{
                id=key,detail=detail,checked=selected_junk[key],meta={key=key,path=path},
                on_change=function(value,meta)
                    if meta and junk_actions[meta.key] then selected_junk[meta.key]=value end
                end,
            })
        end
        for _,item in ipairs(report.orphan_dirs or {}) do add("dir",item.name.."/",L(
            "No launcher uses this data folder.",
            "没有启动项使用这个数据目录。"),item.path,not guessed_layout) end
        for _,image in ipairs(report.orphan_images or {}) do add("image",image.name,L(
            "No matching launcher was found.",
            "没有找到配套的启动项。"),image.path,false) end
        for _,item in ipairs(report.dead_scripts or {}) do
            add("script",item.script,L("Missing data folder: ",
                "缺少数据目录：")[kit.get_state().ui_lang]..item.missing_dir,
                item.path,not guessed_layout)
        end

        local shared,primary_counts={},primary_data_counts()
        for _,port in ipairs(report.ports or {}) do
            local path=exact_path(port.data_path)
            if path and (primary_counts[path] or 0)>1 then
                shared[path]=shared[path] or {}
                shared[path][#shared[path]+1]=port
            end
        end
        local shared_names={}
        for name in pairs(shared) do shared_names[#shared_names+1]=name end
        table.sort(shared_names)
        if #shared_names>0 then
            rows[#rows+1]=kit.section(L("Duplicate folder references","重复目录引用"),{font_px=22})
            for _,path in ipairs(shared_names) do
                table.sort(shared[path],function(a,b) return a.script<b.script end)
                local name=shared[path][1].dir
                rows[#rows+1]=kit.textview(name.."/",L(
                    string.format("%d launchers use this folder. None are selected by default.",#shared[path]),
                    string.format("%d 个启动项共用这个目录，默认不选。请确认后处理。",#shared[path])),{
                    id="leftovers:shared:"..path,focusable=false,expandable=false,max_lines=4,expanded_lines=4,
                    label_px=18,value_px=20,surface=false})
                for _,port in ipairs(shared[path]) do
                    add("shared-script",port.script,L(
                        "Only this launcher will be deleted. The shared folder will stay.",
                        "只会删除这个启动项，共用目录会保留。"),port.path,false)
                end
            end
        end
        for key in pairs(selected_junk) do
            if not junk_actions[key] then selected_junk[key]=nil end
        end
        if item_count==0 then rows[#rows+1]=note(L("Status","状态"),L("No removable leftovers were found.","没有发现可清理的残留内容。"),"leftovers:empty") end
        local sidebar={}
        if next(junk_actions) then sidebar={
            button(model.dynamic_count("Delete (%d)","删除 (%d)",selected_junk),remove_junk,{id="leftovers-remove",disabled=empty(selected_junk)}),
            button(L("Select all","全选"),function() select_all_junk(true) end,{half=true,id="leftovers-select-all"}),
            button(L("Select none","全不选"),function() select_all_junk(false) end,{half=true,id="leftovers-select-none"}),
        } end
        sidebar[#sidebar+1]=button(L("Back","返回"),kit.back_page,{group="bottom"})
        kit._junk_rows=rows
        shell.set_page(page.JUNK,L("Leftovers","残留清理"),rows,{preserve_focus=preserve_focus,
            sidebar_title=L("Actions","操作"),sidebar=sidebar})
    end

    function self.build_zip_install(preserve_focus)
        local rows={}
        if not enabled("capability_install_ports") and not enabled("capability_install_apps") then
            set_root(page.ZIP,L("Install games","安装游戏"),{
                note(L("Not available","暂不可用"),L("Package installation is not available on this device.",
                    "当前设备暂不支持安装压缩包。"),"zip:unavailable")},preserve_focus)
            return
        end
        model.selected_zip=model.selected_zip or {}
        local bundles=model.zip_bundles or {}
        local function zip_label(bundle)
            local name=bundle.path:match("([^/]+)$") or bundle.path
            return name
        end
        local function zip_detail(bundle)
            local parts={model.human(bundle.size)}
            if bundle.password_required then
                parts[#parts+1]=L("Password required","需要密码")[kit.get_state().ui_lang]
            end
            return table.concat(parts," · ")
        end
        if #bundles==0 then
            rows[#rows+1]=kit.empty(
                L("No install packages were found on the storage card roots. Put a .zip or .7z file in a card root and rescan.",
                    "将 .zip 或 .7z 安装包放到存储卡根目录。"),{id="zip:empty",title=L("No packages","暂无安装包")})
        end
        for index,bundle in ipairs(bundles) do
            local key="zip:"..bundle.path
            local installable=bundle.kind=="port" or bundle.kind=="trimui_app" or bundle.kind=="locked"
            if installable then
                rows[#rows+1]=kit.checkbox(zip_label(bundle),{
                    id=key,icon="install",default_focus=index==1,detail=zip_detail(bundle),checked=model.selected_zip and model.selected_zip[key] or false,
                    meta={key=key},
                    on_change=function(value,meta)
                        if meta and model.selected_zip then model.selected_zip[meta.key]=value end
                    end,
                })
            else
                rows[#rows+1]=button(zip_label(bundle),function()
                    local issue=type(bundle.issue)=="table" and bundle.issue or {}
                    local items={}
                    if tostring(issue.code or "")~="" then
                        items[#items+1]="code: "..tostring(issue.code)
                    end
                    if tostring(issue.format or "")~="" then
                        items[#items+1]="format: "..tostring(issue.format)
                    end
                    items[#items+1]=L(
                        "The Web installer can copy the complete feedback report.",
                        "可在网页安装端一键复制完整反馈信息。")
                    kit.dialog({
                        title=L("Package diagnostic","安装包诊断"),
                        message=tostring(bundle.diagnostic or L("Unsupported package","不支持的安装包")),
                        items=items,confirm=L("OK","知道了"),single_action=true,
                        danger=false,default_focus="confirm",
                    })
                end,{id=key,default_focus=index==1,icon="help",detail=zip_detail(bundle),
                    badge=kit.badge(L("Unsupported","不支持"),{0.85,0.55,0.60})})
            end
        end
        local function install_selected()
            local chosen={}
            for _,bundle in ipairs(model.zip_bundles or {}) do
                local key="zip:"..bundle.path
                if model.selected_zip and model.selected_zip[key] and
                    (bundle.kind=="port" or bundle.kind=="trimui_app" or bundle.kind=="locked") then
                    chosen[#chosen+1]=bundle
                end
            end
            if #chosen==0 then
                kit.toast(L("Select at least one bundle first.","请先勾选要安装的压缩包。"),{kind="info"})
                return
            end
            local labels={}
            for _,bundle in ipairs(chosen) do
                labels[#labels+1]=(bundle.path:match("([^/]+)$") or bundle.path)
            end
            kit.dialog({
                title=L("Install selected bundles","安装所选压缩包"),
                message=L("Install these bundles now? The archive files are moved to Trash on success.",
                    "安装完成后，安装包会移入回收站"),
                items=labels,confirm=L("Install","安装"),cancel=L("Back","返回"),danger=false,
                checkbox={label=L("Replace an existing APP or data folder with the same name",
                    "覆盖同名 APP 或游戏数据目录"),checked=false,danger=true},
                message_checked=L(
                    "Existing APP or data folders with the same name will be replaced. Duplicate SH launchers still receive a numeric suffix.",
                    "同名 APP 或游戏数据目录会被覆盖；重复的 SH 启动项仍会自动添加数字编号。"),
                on_confirm=function(_,replace_existing)
                    local install_bundles={}
                    for _,bundle in ipairs(chosen) do
                        local copy={}
                        for key,value in pairs(bundle) do copy[key]=value end
                        install_bundles[#install_bundles+1]=copy
                    end
                    local function continue_at(index)
                        if index>#install_bundles then
                            operations.install_zip_bundles(install_bundles,replace_existing)
                            return
                        end
                        local bundle=install_bundles[index]
                        if not bundle.password_required and bundle.kind~="locked" then
                            continue_at(index+1)
                            return
                        end
                        local name=bundle.path:match("([^/]+)$") or bundle.path
                        kit.password_dialog({
                            title=L("Archive password","压缩包密码"),
                            message=L("Enter the password for "..name..".","请输入 “"..name.."” 的密码。"),
                            max_length=1024,
                            on_confirm=function(password)
                                bundle._password=password
                                continue_at(index+1)
                            end,
                        })
                    end
                    continue_at(1)
                end,
            })
        end
        table.insert(rows,1,inline_button(L("Scan packages","扫描安装包"),function() operations.scan_zip_bundles(page.ZIP) end,
            "zip-rescan","install-actions"))
        if #bundles>0 then
            table.insert(rows,2,inline_button(model.dynamic_count("Install (%d)","安装 (%d)",model.selected_zip),install_selected,
                "zip-install","install-actions",2,{appearance="primary",disabled=empty(model.selected_zip)}))
        end
        set_root(page.ZIP,L("Install games","安装游戏"),rows,preserve_focus)
    end

    function self.collect_trash()
        local out={}
        for _,entry in ipairs(model.trash_items()) do
            local kind
            if entry.bucket=="scripts" then kind=L("Launcher","启动项")
            elseif entry.bucket=="data" then kind=L("Game data","游戏数据")
            elseif entry.bucket=="images" or entry.bucket=="script-images" then kind=L("Image","图片")
            elseif entry.bucket:match("^apps%-.+$") then kind=L("APP","APP")
            elseif entry.bucket=="legacy" then kind=L("Other file","其他文件")
            else kind=L("Trash item","回收站项目") end
            local port_bucket=entry.bucket=="scripts" or entry.bucket=="data" or
                entry.bucket=="images" or entry.bucket=="script-images"
            local app_bucket=entry.bucket:match("^apps%-.+$")~=nil
            local restorable=(port_bucket and enabled("capability_manage_ports")) or
                (app_bucket and enabled("capability_manage_apps"))
            local detail=kind
            if not restorable then
                detail=L("Old Trash item · Delete only","旧版回收站项目 · 仅可永久删除")
            elseif entry.restore_conflict then
                detail=L("Destination exists · confirmation required","目标已存在 · 还原前需确认覆盖")
            end
            out[#out+1]={title=entry.name..(entry.is_dir and "/" or ""),detail=detail,
                paths={entry.path},restorable=restorable,restore_conflict=entry.restore_conflict==true}
        end
        return out
    end

    local function select_all_trash(value)
        for _,item in ipairs(self.collect_trash()) do for _,path in ipairs(item.paths) do selected_trash[path]=value end end
        self.build_trash(true)
    end

    local function trash_action(kind,title)
        local plan,labels,has_conflict={},{},false
        for _,item in ipairs(self.collect_trash()) do
            local chosen=false
            if kind~="RESTORE_ITEM" or item.restorable then
                for _,path in ipairs(item.paths) do
                    if selected_trash[path] then
                        chosen=true
                        local action_kind=kind
                        if kind=="RESTORE_ITEM" and item.restore_conflict then
                            action_kind="RESTORE_REPLACE"; has_conflict=true
                        end
                        plan[#plan+1]={kind=action_kind,arg=path}
                    end
                end
            end
            if chosen then labels[#labels+1]=item.title end
        end
        if #plan>0 then operations.show_confirm(title,plan,labels,page.TRASH,{
            danger=kind~="RESTORE_ITEM" or has_conflict,
            message=has_conflict and L(
                "A destination with the same name already exists. Replace it and restore the selected item? The current destination will be moved to Trash.",
                "原目录已有同名项目。是否覆盖并还原？当前同名项目会先移入回收站。") or nil,
            confirm=kind=="RESTORE_ITEM" and
                (has_conflict and L("Replace and restore","覆盖并还原") or L("Restore","放回")) or
                L("Delete forever","永久删除")}) end
    end

    local function selected_trash_count(restorable_only)
        local count=0
        for _,item in ipairs(self.collect_trash()) do
            if not restorable_only or item.restorable then
                for _,path in ipairs(item.paths) do
                    if selected_trash[path] then count=count+1 end
                end
            end
        end
        return count
    end

    local function trash_count_label(en,zh,restorable_only)
        return function()
            return string.format(kit.get_state().ui_lang=="zh" and zh or en,
                selected_trash_count(restorable_only))
        end
    end

    function self.build_trash(preserve_focus)
        local rows,available_trash={},{}
        for _,item in ipairs(self.collect_trash()) do
            local key=item.paths[1]; local detail=item.detail
            for _,path in ipairs(item.paths) do available_trash[path]=true end
            rows[#rows+1]=kit.checkbox(item.title,{
                id=key,detail=detail,checked=selected_trash[key],meta={paths=item.paths},
                on_change=function(value) for _,path in ipairs(item.paths) do selected_trash[path]=value end end,
            })
        end
        for path in pairs(selected_trash) do
            if not available_trash[path] then selected_trash[path]=nil end
        end
        local actions={}
        if #rows>0 then actions={
            button(trash_count_label("Restore (%d)","放回 (%d)",true),function() trash_action("RESTORE_ITEM",L("Restore selected items","放回所选项目")) end,
                {id="trash-restore",disabled=function() return selected_trash_count(true)==0 end}),
            button(trash_count_label("Delete forever (%d)","永久删除 (%d)",false),function() trash_action("DELETE_ITEM",L("Permanently delete selected items","永久删除所选项目")) end,
                {id="trash-delete",danger=true,disabled=empty(selected_trash)}),
            button(L("Select all","全选"),function() select_all_trash(true) end,{half=true,id="trash-select-all"}),
            button(L("Select none","全不选"),function() select_all_trash(false) end,{half=true,id="trash-select-none"}),
        } else rows[1]=note(L("Status","状态"),L("Trash is empty.","回收站为空。"),"trash:empty") end
        shell.set_page(page.TRASH,L("Trash","回收站"),rows,{preserve_focus=preserve_focus,sidebar=actions})
    end

    function self.build_env()
        model.ensure_report()
        local rows,details={},{}
        local function section(label) rows[#rows+1]=kit.section(label,{font_px=22}) end
        local function info(key,label,value,title,body,badge)
            local row={id=key,label_px=18,value_px=20}
            if badge then row.badge=badge end
            rows[#rows+1]=kit.textview(label,model.provided(value),row)
            details[key]={title=title or label,body=body}
        end

        -- ── PortMaster readiness: can it be installed here, and will it run? ──
        local function install_status()
            if model.system_managed() then
                return L("Managed by system","由系统管理")
            end
            if not model.can_install() then
                return L("Not enabled on this device","当前设备配置未启用")
            end
            if env.target_confirmed~="1" or not env.portmaster_target or env.portmaster_target=="" then
                return L("Install location unknown","无法确定安装位置")
            end
            if tostring(env.device_class or "")=="unsupported-known" then
                return L("Possible after confirming the location","可安装（需确认安装位置）")
            end
            return L("Installable","可以安装")
        end
        local function library_status()
            local groups=env.library_groups
            if type(groups)~="table" or #groups==0 then
                return L("No special requirement","无特殊要求"),nil
            end
            local missing,ready={},{}
            for _,group in ipairs(groups) do
                if group.ok==true then ready[#ready+1]=group.name
                else
                    for _,name in ipairs(group.missing or {}) do missing[#missing+1]=name end
                end
            end
            if #missing>0 then
                return L("Missing: "..table.concat(missing," "),"缺少："..table.concat(missing," ")),
                    kit.badge(L("Missing","缺少"),{1,0.45,0.38})
            end
            return L("Ready: "..table.concat(ready," · "),"就绪："..table.concat(ready," · ")),
                kit.badge(L("Ready","就绪"),{0.48,0.90,0.62})
        end
        local function python_status()
            if tostring(env.portmaster_health or "")=="missing" then
                return L("Checked after install","安装后自动检查")
            end
            if env.portmaster_python_ok==false then
                return L("Import check failed (required: "..tostring(env.portmaster_python_imports or "?")..")",
                    "导入检查未通过（必需模块："..tostring(env.portmaster_python_imports or "?").."）")
            end
            return L("Available","可用")
        end
        local function state_status()
            local health=tostring(env.portmaster_health or "")
            if health=="missing" then return L("Not installed","未安装") end
            if health=="damaged" then return L("Needs repair","需要修复") end
            local version=tostring(env.portmaster_version or "")
            local label=model.health_label()
            if version~="" and type(label)=="table" then
                return L(label.en.." · "..version,label.zh.." · "..version)
            end
            return label
        end
        local function conclusion()
            local health=tostring(env.portmaster_health or "")
            local groups=env.library_groups
            local missing_libs=false
            if type(groups)=="table" then
                for _,group in ipairs(groups) do
                    if group.ok~=true then missing_libs=true break end
                end
            end
            if model.system_managed() then
                return L("PortMaster is managed by the system.","PortMaster 由系统管理。")
            end
            if health=="" then
                return L("PortMaster state could not be determined.","无法确定 PortMaster 状态。")
            end
            if health=="damaged" then
                return L("PortMaster is installed but needs repair.","PortMaster 已安装但需要修复。")
            end
            if health=="missing" then
                if not model.can_install() then
                    return L("PortMaster installation is not enabled on this device.",
                        "当前设备暂不支持安装 PortMaster。")
                end
                if missing_libs then
                    return L("PortMaster can be installed, but the system is missing required libraries and it may not run.",
                        "可以安装 PortMaster，但系统缺少必要运行库，可能无法运行。")
                end
                return L("PortMaster can be installed. A self-check runs when the install finishes.",
                    "可以安装 PortMaster，安装完成后会自动检查能否正常使用。")
            end
            if missing_libs then
                return L("PortMaster is installed, but some required system libraries were not found and it may not run.",
                    "PortMaster 已安装，但未检测到部分系统运行库，可能无法运行。")
            end
            if env.portmaster_python_ok==false then
                return L("PortMaster is installed and usable for game management, but the Python environment has issues.",
                    "PortMaster 已安装，游戏管理可用，但 Python 环境存在问题。")
            end
            return L("PortMaster is installed and usable.","PortMaster 已安装且可正常使用。")
        end

        local diagnosis=model.environment_diagnostics()
        rows[#rows+1]=kit.textview(L("Environment score","环境评分"),string.format("%d / 100",diagnosis.score),
            {id="diagnostic:score",max_lines=1,expandable=false,focusable=true,value_px=32})
        if diagnosis.count==0 then
            rows[#rows+1]=kit.empty(L("No known issues found.","未发现已知问题。"),{id="diagnostic:clear"})
        end
        for _,group in ipairs({
            {diagnosis.high,L("May affect gameplay","可能影响游玩")},
            {diagnosis.low,L("PortMaster management issues","PortMaster 管理问题")},
            {diagnosis.normal,L("Normal or no action needed","正常或无需处理")},
        }) do
            if #group[1]>0 then
                section(L(string.format("%s (%d)",group[2].en,#group[1]),string.format("%s（%d）",group[2].zh,#group[1])))
                for _,issue in ipairs(group[1]) do
                    local label=issue.deduction>0 and L(issue.label.en.." · -"..issue.deduction,
                        issue.label.zh.." · -"..issue.deduction) or issue.label
                    info(issue.id,label,issue.value)
                end
            end
        end
        section(L("All details","全部详情"))
        local device_name=env.device_name and tostring(env.device_name) or ""
        local platform_id=tostring(env.param_device or "")
        local device_value
        if device_name~="" and platform_id~="" then device_value=device_name.."（"..platform_id.."）"
        elseif device_name~="" then device_value=device_name
        else device_value=model.provided(platform_id) end
        info("readiness:device",L("Device detected","设备识别"),device_value,
            L("Device detected","设备识别"),
            L("The detected device platform. It decides every check below.",
                "当前识别到的设备平台，决定下面的各项检查。"))
        info("readiness:support",L("Device support","设备适配"),model.support_label(),
            L("Device support","设备适配"),
            L("How PortMaster is provided on this device: official release, our custom build, or an unknown device.",
                "当前设备获得 PortMaster 的方式：官方稳定版、我们维护的定制版，或未知设备。"))
        local official_class=tostring(env.device_class or "unknown-path")
        local channel=tostring(env.portmaster_release_channel or "")
        local official_label
        if model.system_managed() then official_label=L("Managed by system","由系统管理")
        elseif channel~="" and channel~="official" and channel~="system" then
            -- A custom release channel (MiniLoong) ships our own build; the
            -- official PortMaster release does not cover it.
            official_label=L("Not compatible with the official release","官方不兼容（使用定制版）")
        elseif official_class=="tested" then official_label=L("Supported by the official release","官方已支持（收录）")
        elseif official_class=="official-untested" then official_label=L("Not officially tested","官方未实测")
        elseif official_class=="unsupported-known" then official_label=L("Not in the official support list","未收录官方列表")
        else official_label=L("Cannot determine","无法确定") end
        info("readiness:official",L("Official compatibility","官方兼容性"),official_label,
            L("Official compatibility","官方兼容性"),
            L("Whether the official PortMaster release supports this device model.",
                "官方 PortMaster 版本是否支持这台设备。"))
        local fork_label
        if model.system_managed() then fork_label=L("System built-in","系统内置")
        elseif channel=="" or channel=="official" then fork_label=L("Official original","官方原版")
        else fork_label=L("Custom build ("..channel..")","定制版（"..channel.."）") end
        info("readiness:fork",L("Custom build","是否魔改"),fork_label,
            L("Custom build","是否魔改"),
            L("Whether this device uses a modified PortMaster build instead of the official one.",
                "当前设备是否使用修改版（非官方原版）PortMaster。"))
        info("readiness:install",L("Can install","能否安装"),install_status(),
            L("Can install","能否安装"),
            L("Whether the install location and device configuration allow installing PortMaster.",
                "安装位置与设备配置是否允许安装 PortMaster。"))
        local library_value,library_badge=library_status()
        info("readiness:libraries",L("System libraries","系统运行库"),library_value,
            L("System libraries","系统运行库"),
            L("Required GLES/SDL2 libraries detected on this system, using the same rule as the installer.",
                "系统是否具备所需的 GLES/SDL2 运行库，与安装时的校验规则一致。"),library_badge)
        info("readiness:python",L("Python environment","Python 环境"),python_status(),
            L("Python environment","Python 环境"),
            L("Python availability for PortMaster, either from the system or bundled with the install.",
                "PortMaster 所需的 Python 环境可用性，来自系统或随安装包提供。"))
        info("readiness:state",L("PortMaster state","PortMaster 状态"),state_status(),
            L("PortMaster state","PortMaster 状态"),
            L("The current install state of PortMaster on this device.",
                "PortMaster 在当前设备上的安装状态。"))
        rows[#rows+1]=note(L("Conclusion","结论"),conclusion(),"readiness:conclusion")

        local web_state=kit.get_state()
        if env.web_url and env.web_url~="" and web_state.web_enabled=="1" and web_state.web_port then
            local web_display=env.web_url:gsub("^http://",""):gsub("^https://","")..":"..web_state.web_port
            info("readiness:web",L("Remote management","远程管理"),web_display,
                L("Remote management","远程管理"),
                L("Open this address in a browser on the same network to manage games and upload zip bundles.",
                    "在同一个网络的电脑浏览器打开这个地址，可远程管理游戏和上传压缩包安装。"))
        end
        section(L("Key paths","关键路径"))
        info("path:scripts",L("SH path","SH 路径"),env.scripts_dir,
            L("Launcher script folder","SH 启动脚本目录"),
            L("Stores the game launchers shown in the menu.",
                "存放菜单里的游戏启动脚本。"))
        info("path:data",L("Data path","Data 路径"),env.gamedirs_dir,
            L("Game data folder","游戏数据目录"),
            L("Stores game files and settings, usually one folder per game.",
                "存放游戏文件和设置，通常每个游戏一个目录。"))
        info("path:portmaster",L("PortMaster path","PortMaster 路径"),env.controlfolder,
            L("PortMaster folder","PortMaster 目录"),
            L("Stores PortMaster and its shared settings.",
                "存放 PortMaster 程序和公共设置。"))
        info("path:runtimes",L("Runtime path","Runtime 路径"),env.libs_dir,
            L("Shared Runtime folder","共享 Runtime 目录"),
            L("Stores the Runtimes shared by Port games.",
                "存放 Port 游戏共用的 Runtime。"))

        section(L("Device information","设备信息"))
        info("device:name",L("Device","设备"),env.device_name or env.param_device,
            L("Device","设备"),
            L("The detected device name used by this app.",
                "当前识别到的设备名称。"))
        info("device:manufacturer",L("Manufacturer","设备厂商"),env.device_manufacturer,
            L("Manufacturer","设备厂商"),
            L("The detected device manufacturer.",
                "当前识别到的设备厂商。"))
        info("device:submodel",L("Model","具体型号"),env.device_submodel,
            L("Model","具体型号"),
            L("The detected device model or hardware variant.",
                "当前识别到的具体型号或硬件版本。"))
        info("device:system",L("System","系统"),env.system_name,
            L("System","系统"),
            L("The operating system currently running on this device.",
                "当前设备正在运行的系统。"))
        info("device:system-version",L("System version","系统版本"),env.system_version,
            L("System version","系统版本"),
            L("The detected operating system version.",
                "当前识别到的系统版本。"))

        local resolution=(env.display_width and env.display_width~="" and env.display_height and env.display_height~="")
            and tostring(env.display_width).."×"..tostring(env.display_height) or nil
        section(L("Environment values","环境变量"))
        local values={
            {"env:cfw",L("Firmware","固件"),env.cfw,L("Firmware","固件"),L("The current firmware. It selects compatible device settings.","当前固件，用于选择匹配的设备设置。")},
            {"env:resolution",L("Display resolution","显示分辨率"),resolution,L("Display resolution","显示分辨率"),L("The current screen size. It adjusts the layout and text size.","当前屏幕尺寸，用于调整布局和字号。")},
            {"env:arch",L("Architecture","设备架构"),env.device_arch,L("CPU architecture","CPU 架构"),L("The CPU type. It selects programs that can run on this device.","当前 CPU 类型，用于选择可以运行的程序。")},
            {"env:device",L("Controller ID","手柄 ID"),env.device,L("Controller ID","手柄标识"),L("The device and controller ID used to match controls.","用于匹配按键的设备与手柄标识。")},
            {"env:profile",L("Device profile","设备配置"),env.param_device,L("Device settings","设备设置"),L("The PortMaster settings selected for this device.","当前设备使用的 PortMaster 设置。")},
            {"env:sticks",L("Analog sticks","摇杆数量"),env.analog_sticks,L("Analog sticks","摇杆数量"),L("The number of analog sticks available on this device.","当前设备可用的模拟摇杆数量。")},
            {"env:lowres",L("Low resolution","低分辨率模式"),env.lowres,L("Low resolution mode","低分辨率模式"),L("Whether compact layouts and lighter graphics are preferred.","是否优先使用紧凑布局和轻量资源。")},
            {"env:tty",L("Display terminal","显示终端"),env.cur_tty,L("Display terminal","显示终端"),L("The terminal currently used by the system menu.","系统菜单当前使用的显示终端。")},
            {"env:controller_db",L("Controller mappings","手柄映射库"),env.sdl_controller_file,L("Controller database","手柄映射库"),L("The SDL file used to match physical buttons to game controls.","SDL 用来匹配实体按键和游戏控制的文件。")},
            {"env:esudo",L("Permission helper","权限工具"),env.esudo,L("Permission helper","权限工具"),L("The system command used when an operation needs extra permission.","文件操作需要更高权限时使用的系统命令。")},
            {"env:gptokeyb",L("Controller helper","手柄工具"),env.gptokeyb,L("Controller helper","手柄工具"),L("Converts gamepad input to keyboard or mouse input.","把手柄输入转换成键盘或鼠标输入。")},
            {"env:path",L("Command search path","命令搜索路径"),env.path,L("Command search path","命令搜索路径"),L("Folders searched when a program starts a command.","程序查找命令时使用的目录。")},
            {"env:ld_path",L("Library search path","动态库搜索路径"),env.ld_library_path,L("Library search path","动态库搜索路径"),L("Folders searched when a program loads shared libraries.","程序加载共享动态库时使用的目录。")},
            {"env:xdg_config",L("Config root (XDG_CONFIG_HOME)","配置目录（XDG_CONFIG_HOME）"),env.xdg_config_home,L("App settings folder","应用设置目录"),L("The default folder for app settings.","应用设置的默认保存目录。")},
            {"env:xdg_data",L("Data root (XDG_DATA_HOME)","数据目录（XDG_DATA_HOME）"),env.xdg_data_home,L("App data folder","应用数据目录"),L("The default folder for app data and saves.","应用数据和存档的默认保存目录。")},
            {"env:free",L("Free space","剩余空间"),model.human(env.free_bytes),L("Free space","剩余空间"),L("Storage currently available for games and Runtimes.","游戏和 Runtime 当前可用的存储空间。")},
        }
        for _,item in ipairs(values) do info(item[1],item[2],item[3],item[4],item[5]) end

        local runtimes=model.installed_runtimes()
        section({en=string.format("Installed Runtimes (%d)",#runtimes),zh=string.format("已安装 Runtime（%d）",#runtimes)})
        if #runtimes==0 then
            rows[#rows+1]=kit.list_item(L("None installed","未安装"),{id="runtime:none",font_px=19})
            details["runtime:none"]={title=L("Installed Runtimes","已安装 Runtime"),body=L("No shared Runtime is installed.","尚未安装共享 Runtime。")}
        else
            for _,name in ipairs(runtimes) do
                local key="runtime:"..name
                rows[#rows+1]=kit.list_item(name,{id=key,font_px=19})
                details[key]={title=name,body=L("Installed and available to games that need it.","已安装，需要它的游戏可以直接使用。")}
            end
        end
        shell.set_page(page.ENV,L("Environment diagnostics","环境诊断"),rows,{row_layout={mode="grid",columns=2},
            sidebar_title=L("Explanation","说明"),sidebar_details=details,sidebar={
            button(L("Back","返回"),kit.back_page,{group="bottom"})
        }})
    end

    return self
end

return Pages
