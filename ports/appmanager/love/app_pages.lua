local Pages = {}

local function clear(values)
    for key in pairs(values) do values[key]=nil end
end

function Pages.new(model,operations)
    local kit,L=model.kit,model.L
    local env,report,runtime_metadata=model.env,model.report,model.runtime_metadata
    local page=model.pages
    local self={}
    local environment
    local selected_home,selected_junk,selected_trash,selected_runtime={},{},{},{}

    local function button(label,action,opts) return kit.button(label,action,opts) end
    local function note(label,value,id)
        return kit.textview(label,value,{id=id,focusable=false,expandable=false,max_lines=3,
            expanded_lines=3,label_px=18,value_px=20,surface=false})
    end
    local function empty(values) return function() return model.selected_count(values)==0 end end
    local function enabled(name) return env[name]~=false end

    function self.bind_environment(value) environment=value end
    function self.reset_selection()
        clear(selected_home); clear(selected_junk); clear(selected_trash); clear(selected_runtime)
    end

    local function select_all_home(value)
        for _,port in ipairs(report.ports) do selected_home[port.script]=value end
        self.build_home(true)
    end

    local function uninstall_selected()
        local plan,labels,selected_ports,dir_counts,planned_dirs={},{},{},{},{}
        for _,port in ipairs(report.ports) do
            if selected_home[port.script] then
                selected_ports[#selected_ports+1]=port; labels[#labels+1]=model.display_name(port.script)
                if port.dir~="" then dir_counts[port.dir]=(dir_counts[port.dir] or 0)+1 end
            end
        end
        for _,port in ipairs(selected_ports) do
            plan[#plan+1]={kind="TRASH",arg=env.scripts_dir.."/"..port.script}
            for _,image in ipairs(port.images or {}) do
                if image.path and image.path~="" then plan[#plan+1]={kind="TRASH",arg=image.path} end
            end
            if port.dir~="" and dir_counts[port.dir]==(report.refcount[port.dir] or 0) and not planned_dirs[port.dir] then
                planned_dirs[port.dir]=true
                plan[#plan+1]={kind="TRASH",arg=env.gamedirs_dir.."/"..port.dir}
            end
        end
        if #plan>0 then
            operations.show_confirm(L("Uninstall selected games","卸载所选游戏"),plan,labels,page.HOME,{
                message=L("Selected games will be moved to Trash and can be restored.",
                    "所选游戏将移入回收站，之后可以还原。"),
                title_checked=L("Permanently delete selected games","永久删除所选游戏"),
                message_checked=L("The selected game files will be deleted and cannot be restored.",
                    "所选游戏文件将被永久删除，无法还原。"),
                confirm=L("Move to Trash","移入回收站"),confirm_checked=L("Delete forever","永久删除"),danger=false,
                checkbox={label=L("Delete permanently instead of using Trash","直接删除，不放入回收站"),danger=true},
                on_confirm=function(checked)
                    if checked then for _,item in ipairs(plan) do item.kind="DELETE_MANAGED" end end
                    operations.start_apply()
                end})
        end
    end

    function self.build_home(preserve_focus)
        local can_manage_ports=enabled("capability_manage_ports")
        local can_trash=can_manage_ports and enabled("capability_trash")
        local can_leftovers=can_manage_ports and enabled("capability_leftovers") and can_trash
        local can_runtimes=enabled("capability_repair_runtimes")
        if can_manage_ports then model.ensure_report() end
        local rows={}
        for _,port in ipairs(can_manage_ports and (report.ports or {}) or {}) do
            local script=port.script
            local paths={env.scripts_dir.."/"..script}
            if port.dir~="" then paths[#paths+1]=env.gamedirs_dir.."/"..port.dir end
            for _,image in ipairs(port.images or {}) do if image.path and image.path~="" then paths[#paths+1]=image.path end end
            local detail={}
            if port.dir~="" then detail[#detail+1]=port.dir.."/"
            elseif port.claimed_dir~="" then detail[#detail+1]=L("Missing data: ","数据缺失：")[kit.get_state().ui_lang]..port.claimed_dir end
            local missing=model.missing_runtime(script)
            if missing~="" then detail[#detail+1]=(kit.get_state().ui_lang=="zh" and "缺少 Runtime: " or "Missing Runtime: ")..missing end
            local bytes=model.path_size(paths); if bytes>0 then detail[#detail+1]=model.human(bytes) end
            rows[#rows+1]=kit.checkbox(model.display_name(script),{
                id=script,detail=model.join(detail),checked=selected_home[script],sidebar_target="uninstall",
                on_change=function(value) selected_home[script]=value end,
                badge=missing~="" and kit.badge(L("Runtime missing","缺少 Runtime")) or nil,
            })
        end
        if #rows==0 then rows[1]=note(L("Status","状态"),can_manage_ports and
            L("No Port games are available to manage.","没有可管理的 Port 游戏。") or
            L("Game management is not available on this device.","当前设备暂不支持游戏管理。"),"home:empty") end
        local junk_count=#(report.orphan_dirs or {})+#(report.orphan_images or {})+#(report.dead_scripts or {})
        for _,port in ipairs(report.ports or {}) do
            if port.dir~="" and ((report.refcount or {})[port.dir] or 0)>1 then
                junk_count=junk_count+1
            end
        end
        local trash_count=can_trash and #self.collect_trash() or 0
        local runtime_count=can_runtimes and model.runtime_issue_count() or 0
        local sidebar={}
        if can_trash then
            sidebar[#sidebar+1]=button(model.dynamic_count("Uninstall (%d)","卸载 (%d)",selected_home),uninstall_selected,
                {id="uninstall",disabled=empty(selected_home)})
            sidebar[#sidebar+1]=button(function() return kit.get_state().ui_lang=="zh" and string.format("回收站 (%d)",trash_count) or string.format("Trash (%d)",trash_count) end,
                function() self.build_trash(); kit.push_page(page.TRASH) end,{id="trash"})
        end
        if can_manage_ports then
            sidebar[#sidebar+1]=button(L("Select all","全选"),function() select_all_home(true) end,{half=true,id="select-all"})
            sidebar[#sidebar+1]=button(L("Select none","全不选"),function() select_all_home(false) end,{half=true,id="select-none"})
        end
        if can_leftovers then
            sidebar[#sidebar+1]=button(function() return kit.get_state().ui_lang=="zh" and string.format("残留清理 (%d)",junk_count) or string.format("Leftovers (%d)",junk_count) end,
                function() self.build_junk(); kit.push_page(page.JUNK) end,{id="leftovers"})
        end
        if can_runtimes then
            sidebar[#sidebar+1]=button(function() return kit.get_state().ui_lang=="zh" and string.format("Runtime 修复 (%d)",runtime_count) or string.format("Runtime repair (%d)",runtime_count) end,
                function() self.build_runtime(); kit.push_page(page.RUNTIME) end,{id="runtime-repair-entry"})
        end
        sidebar[#sidebar+1]=button(L("Quit","退出"),operations.show_exit_dialog,{group="bottom"})
        kit.set_page(page.HOME,{en="Port App Manager",zh="Port App Manager"},rows,{
            preserve_focus=preserve_focus,sidebar_title=L("Quick Tools","快捷工具"),
            sidebar_footer={lines={L("Developer: Bili 解腻Jenny","开发: Bili 解腻Jenny"),kit.CONTACT}},
            header_action=button(L("Environment","环境管理"),function() environment.build_manage(); kit.push_page(page.MANAGE) end,
                {badge=env.portmaster_management=="system" and kit.badge(L("System managed","系统管理"),{0.62,0.64,0.69}) or
                    (model.update_state()=="update" and kit.badge(L("Update","可升级"),{0.62,0.64,0.69}) or nil)}),
            sidebar=sidebar})
        local state=kit.get_state()
        if state.onboarding_seen~="1" then
            kit.guide({
                title=L("Welcome to Port App Manager","欢迎使用 Port App Manager"),
                message=L(
                    "A Port game maintenance tool for PortMaster, Runtimes, installed games, and Trash.",
                    "Port 游戏维护工具，可管理 PortMaster、Runtime、已安装游戏和回收站。"),
                confirm=L("Start using","开始使用"),
                callouts={
                    {target="header",title=L("PortMaster environment","PortMaster 环境"),
                        body=env.portmaster_management=="system" and L(
                            "View the version, device, system, and install path. PortMaster updates are handled by the system.",
                            "查看版本、设备、系统和安装路径。PortMaster 更新由系统负责。") or L(
                            "View device details, check for updates, and install or repair PortMaster.",
                            "查看设备信息、检查更新，以及安装或修复 PortMaster。")},
                    {targets={"uninstall","trash"},title=L("Uninstall and Trash","卸载与回收站"),
                        body=L(
                            "Uninstalled games go to Trash by default. Restore them later or delete them permanently.",
                            "游戏卸载后默认进入回收站，可以还原或彻底删除。")},
                    {target="leftovers",title=L("Leftover cleanup","残留清理"),
                        body=L(
                            "Find launchers, images, and data folders that no longer match. Shared folders are left unselected for review.",
                            "查找不再配套的启动项、图片和数据目录。共用目录默认不选，请确认后处理。")},
                    {target="runtime-repair-entry",title=L("Runtime management","Runtime 管理"),
                        body=L(
                            "Check and repair the Runtimes needed by installed games.",
                            "检查并修复已安装游戏需要的 Runtime。")},
                    {target="footer",title=L("Maintainer and feedback","维护者与反馈"),
                        body=L(
                            "Maintainer: Bili 解腻Jenny. Use the QQ group for help and feedback.",
                            "维护者：Bili 解腻Jenny。需要帮助或反馈时，请联系 QQ 群。")},
                },
                on_confirm=function()
                    state.onboarding_seen="1"
                    kit.persist_state()
                end,
            })
        end
    end

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
        local rows,details={},{}
        local required=model.required_runtimes()
        local repair_needed,installed={},{}
        for _,item in ipairs(required) do
            if item.needs_repair then repair_needed[#repair_needed+1]=item else installed[#installed+1]=item end
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
                id=key,detail=detail,detail_max_lines=3,height=96,checked=selected_runtime[item.name],
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
            rows[1]=note(L("Status","状态"),L("The current games do not need an additional Runtime.","当前游戏不需要额外安装 Runtime。"),"runtime:not-required")
        end
        kit.set_page(page.RUNTIME,L("Runtime repair","Runtime 修复"),rows,{preserve_focus=preserve_focus,
            row_layout={mode="flow",min_width=360,max_columns=1},sidebar_details=details,
            sidebar_title=L("Quick Tools","快捷工具"),sidebar={
            button(model.dynamic_count("Repair (%d)","修复 (%d)",selected_runtime),repair_runtimes,
                {id="runtime-repair",disabled=empty(selected_runtime)}),
            button(L("Select all","全选"),function() select_all_runtime(true) end,{half=true}),
            button(L("Select none","全不选"),function() select_all_runtime(false) end,{half=true}),
            button(L("Back","返回"),kit.back_page,{group="bottom"}),
        }})
    end

    local function select_all_junk(value)
        for _,row in ipairs((kit._junk_rows or {})) do
            if row.meta and row.meta.path then selected_junk[row.meta.path]=value end
        end
        self.build_junk(true)
    end

    local function remove_junk()
        local plan,labels={},{}
        for path,value in pairs(selected_junk) do
            if value then plan[#plan+1]={kind="TRASH",arg=path}; labels[#labels+1]=model.basename(path) end
        end
        table.sort(labels)
        if #plan>0 then operations.show_confirm(L("Move leftovers to Trash","将残留项移入回收站"),plan,labels,page.JUNK,
            {confirm=L("Move to Trash","移入回收站")}) end
    end

    local function cleanup_appledouble()
        local plan={{kind="CLEAN_APPLEDOUBLE",arg="-"}}
        operations.show_confirm(L("Clean ._Files","清理 ._Files"),plan,{},page.JUNK,{
            message=L(
                "Delete macOS ._* files from Port folders. Deleted files cannot be restored.",
                "删除 Port 目录中的 macOS ._* 文件。删除后无法还原。"),
            confirm=L("Start cleanup","开始清理"),danger=true,
        })
    end

    function self.build_junk(preserve_focus)
        model.ensure_report()
        if not preserve_focus then clear(selected_junk) end
        local rows,item_count={},0
        rows[#rows+1]=kit.textview(L("Cleanup rules","清理说明"),L(
            "Unmatched launchers and data folders are selected by default. Shared folders are not selected. Selected items are moved to Trash.",
            "未配套的启动项和数据目录会默认选中。多个启动项共用同一目录时不会默认选中，请确认后处理。选中内容会移入回收站。"),{
            id="leftovers:rules",focusable=false,expandable=false,max_lines=5,expanded_lines=5,
            label_px=18,value_px=20,surface=false})
        local function add(label,detail,path,default_selected)
            item_count=item_count+1
            if selected_junk[path]==nil then selected_junk[path]=default_selected==true end
            rows[#rows+1]=kit.checkbox(label,{
                id=path,detail=detail,checked=selected_junk[path],meta={path=path},
                on_change=function(value) selected_junk[path]=value end,
            })
        end
        for _,name in ipairs(report.orphan_dirs or {}) do add(name.."/",L(
            "No launcher uses this data folder.",
            "没有启动项使用这个数据目录。"),env.gamedirs_dir.."/"..name,true) end
        for _,image in ipairs(report.orphan_images or {}) do add(image.name,L(
            "No matching launcher was found.",
            "没有找到配套的启动项。"),image.path,false) end
        for _,item in ipairs(report.dead_scripts or {}) do
            add(model.display_name(item.script),L("Missing data folder: ",
                "缺少数据目录：")[kit.get_state().ui_lang]..item.missing_dir,
                env.scripts_dir.."/"..item.script,true)
        end

        local shared={}
        for _,port in ipairs(report.ports or {}) do
            if port.dir~="" and (report.refcount[port.dir] or 0)>1 then
                shared[port.dir]=shared[port.dir] or {}
                shared[port.dir][#shared[port.dir]+1]=port.script
            end
        end
        local shared_names={}
        for name in pairs(shared) do shared_names[#shared_names+1]=name end
        table.sort(shared_names)
        if #shared_names>0 then
            rows[#rows+1]=kit.section(L("Duplicate folder references","重复目录引用"),{font_px=22})
            for _,name in ipairs(shared_names) do
                table.sort(shared[name])
                rows[#rows+1]=kit.textview(name.."/",L(
                    string.format("%d launchers use this folder. None are selected by default.",#shared[name]),
                    string.format("%d 个启动项共用这个目录，默认不选。请确认后处理。",#shared[name])),{
                    id="leftovers:shared:"..name,focusable=false,expandable=false,max_lines=4,expanded_lines=4,
                    label_px=18,value_px=20,surface=false})
                for _,script in ipairs(shared[name]) do
                    local path=env.scripts_dir.."/"..script
                    add(model.display_name(script),L(
                        "Only this launcher will be moved to Trash. The shared folder will stay.",
                        "只会把这个启动项移入回收站，共用目录会保留。"),path,false)
                end
            end
        end
        if item_count==0 then rows[#rows+1]=note(L("Status","状态"),L("No removable leftovers were found.","没有发现可清理的残留内容。"),"leftovers:empty") end
        local sidebar={
            button(model.dynamic_count("Move to Trash (%d)","移入回收站 (%d)",selected_junk),remove_junk,{disabled=empty(selected_junk)}),
            button(L("Select all","全选"),function() select_all_junk(true) end,{half=true}),
            button(L("Select none","全不选"),function() select_all_junk(false) end,{half=true}),
        }
        if enabled("capability_cleanup_appledouble") then
            sidebar[#sidebar+1]=button(L("Clean ._Files","清理 ._Files"),cleanup_appledouble,{id="clean-appledouble"})
        end
        sidebar[#sidebar+1]=button(L("Back","返回"),kit.back_page,{group="bottom"})
        kit._junk_rows=rows
        kit.set_page(page.JUNK,L("Leftover cleanup","残留清理"),rows,{preserve_focus=preserve_focus,
            sidebar_title=L("Quick Tools","快捷工具"),sidebar=sidebar})
    end

    function self.collect_trash()
        local out={}
        for _,entry in ipairs(model.trash_items()) do
            local kind
            if entry.bucket=="scripts" then kind=L("Launcher","启动项")
            elseif entry.bucket=="data" then kind=L("Game data","游戏数据")
            elseif entry.bucket=="images" or entry.bucket=="script-images" then kind=L("Image","图片")
            elseif entry.bucket=="legacy" then kind=L("Other file","其他文件")
            else kind=L("Trash item","回收站项目") end
            out[#out+1]={title=entry.name..(entry.is_dir and "/" or ""),detail=kind,paths={entry.path}}
        end
        return out
    end

    local function select_all_trash(value)
        for _,item in ipairs(self.collect_trash()) do for _,path in ipairs(item.paths) do selected_trash[path]=value end end
        self.build_trash(true)
    end

    local function trash_action(kind,title)
        local plan,labels={},{}
        for _,item in ipairs(self.collect_trash()) do
            local chosen=false
            for _,path in ipairs(item.paths) do
                if selected_trash[path] then chosen=true; plan[#plan+1]={kind=kind,arg=path} end
            end
            if chosen then labels[#labels+1]=item.title end
        end
        if #plan>0 then operations.show_confirm(title,plan,labels,page.TRASH,{danger=kind~="RESTORE_ITEM",
            confirm=kind=="RESTORE_ITEM" and L("Restore","放回") or L("Delete forever","永久删除")}) end
    end

    function self.build_trash(preserve_focus)
        local rows={}
        for _,item in ipairs(self.collect_trash()) do
            local key=item.paths[1]; local bytes=model.path_size(item.paths); local detail=item.detail
            if bytes>0 then detail=function() return kit.translate(item.detail).." · "..model.human(bytes) end end
            rows[#rows+1]=kit.checkbox(item.title,{
                id=key,detail=detail,checked=selected_trash[key],meta={paths=item.paths},
                on_change=function(value) for _,path in ipairs(item.paths) do selected_trash[path]=value end end,
            })
        end
        if #rows==0 then rows[1]=note(L("Status","状态"),L("Trash is empty.","回收站为空。"),"trash:empty") end
        kit.set_page(page.TRASH,L("Trash","回收站"),rows,{preserve_focus=preserve_focus,
            sidebar_title=L("Quick Tools","快捷工具"),sidebar={
            button(model.dynamic_count("Restore (%d)","放回 (%d)",selected_trash),function() trash_action("RESTORE_ITEM",L("Restore selected items","放回所选项目")) end,{disabled=empty(selected_trash)}),
            button(model.dynamic_count("Delete forever (%d)","永久删除 (%d)",selected_trash),function() trash_action("DELETE_ITEM",L("Permanently delete selected items","永久删除所选项目")) end,{disabled=empty(selected_trash)}),
            button(L("Select all","全选"),function() select_all_trash(true) end,{half=true}),
            button(L("Select none","全不选"),function() select_all_trash(false) end,{half=true}),
            button(L("Back","返回"),kit.back_page,{group="bottom"}),
        }})
    end

    function self.build_env()
        model.ensure_report()
        local rows,details={},{}
        local function section(label) rows[#rows+1]=kit.section(label,{font_px=22}) end
        local function info(key,label,value,title,body)
            rows[#rows+1]=kit.textview(label,model.provided(value),{id=key,label_px=18,value_px=20})
            details[key]={title=title or label,body=body}
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

        local resolution=(env.display_width and env.display_width~="" and env.display_height and env.display_height~="")
            and tostring(env.display_width).."×"..tostring(env.display_height) or nil
        section(L("Environment values","环境变量"))
        local values={
            {"env:cfw",L("Firmware (CFW_NAME)","固件（CFW_NAME）"),env.cfw,L("Firmware","固件"),L("The current firmware. It selects compatible device settings.","当前固件，用于选择匹配的设备设置。")},
            {"env:resolution",L("Display resolution","显示分辨率"),resolution,L("Display resolution","显示分辨率"),L("The current screen size. It adjusts the layout and text size.","当前屏幕尺寸，用于调整布局和字号。")},
            {"env:arch",L("Architecture (DEVICE_ARCH)","设备架构（DEVICE_ARCH）"),env.device_arch,L("CPU architecture","CPU 架构"),L("The CPU type. It selects programs that can run on this device.","当前 CPU 类型，用于选择可以运行的程序。")},
            {"env:device",L("Controller ID (DEVICE)","手柄 ID（DEVICE）"),env.device,L("Controller ID","手柄标识"),L("The device and controller ID used to match controls.","用于匹配按键的设备与手柄标识。")},
            {"env:profile",L("Device settings (param_device)","设备设置（param_device）"),env.param_device,L("Device settings","设备设置"),L("The PortMaster settings selected for this device.","当前设备使用的 PortMaster 设置。")},
            {"env:sticks",L("Analog sticks (ANALOGSTICKS)","摇杆数（ANALOGSTICKS）"),env.analog_sticks,L("Analog sticks","摇杆数量"),L("The number of analog sticks available on this device.","当前设备可用的模拟摇杆数量。")},
            {"env:lowres",L("Low resolution mode (LOWRES)","低分辨率（LOWRES）"),env.lowres,L("Low resolution mode","低分辨率模式"),L("Whether compact layouts and lighter graphics are preferred.","是否优先使用紧凑布局和轻量资源。")},
            {"env:tty",L("Display terminal (CUR_TTY)","显示终端（CUR_TTY）"),env.cur_tty,L("Display terminal","显示终端"),L("The terminal currently used by the system menu.","系统菜单当前使用的显示终端。")},
            {"env:controller_db",L("Controller database (SDL_GAMECONTROLLERCONFIG_FILE)","手柄库（SDL_GAMECONTROLLERCONFIG_FILE）"),env.sdl_controller_file,L("Controller database","手柄映射库"),L("The SDL file used to match physical buttons to game controls.","SDL 用来匹配实体按键和游戏控制的文件。")},
            {"env:esudo",L("Privilege helper (ESUDO)","权限命令（ESUDO）"),env.esudo,L("Permission helper","权限工具"),L("The system command used when an operation needs extra permission.","文件操作需要更高权限时使用的系统命令。")},
            {"env:gptokeyb",L("Controller helper (GPTOKEYB)","手柄映射（GPTOKEYB）"),env.gptokeyb,L("Controller helper","手柄工具"),L("Converts gamepad input to keyboard or mouse input.","把手柄输入转换成键盘或鼠标输入。")},
            {"env:path",L("Command search path (PATH)","命令搜索（PATH）"),env.path,L("Command search path","命令搜索路径"),L("Folders searched when a program starts a command.","程序查找命令时使用的目录。")},
            {"env:ld_path",L("Library search path (LD_LIBRARY_PATH)","动态库搜索（LD_LIBRARY_PATH）"),env.ld_library_path,L("Library search path","动态库搜索路径"),L("Folders searched when a program loads shared libraries.","程序加载共享动态库时使用的目录。")},
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
        kit.set_page(page.ENV,L("Environment details","环境详情"),rows,{row_layout={mode="grid",columns=2},
            sidebar_title=L("Explanation","说明"),sidebar_details=details,sidebar={
            button(L("Back","返回"),kit.back_page,{group="bottom"})
        }})
    end

    return self
end

return Pages
