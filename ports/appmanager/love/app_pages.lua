local Pages = {}

local function clear(values)
    for key in pairs(values) do values[key]=nil end
end

function Pages.new(model,operations)
    local kit,scanner,L=model.kit,model.scanner,model.L
    local env,report,runtime_metadata=model.env,model.report,model.runtime_metadata
    local page=model.pages
    local self={}
    local environment
    local selected_home,selected_junk,selected_trash,selected_runtime={},{},{},{}

    local function button(label,action,opts) return kit.button(label,action,opts) end
    local function note(label,value,id)
        return kit.textview(label,value,{id=id,focusable=false,expandable=false,max_lines=3,
            expanded_lines=3,label_px=16,value_px=19,surface=false})
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
            operations.show_confirm(L("Uninstall selected ports","卸载所选端口"),plan,labels,page.HOME,{
                message=L("By default, selected ports are moved to Trash and can be restored.",
                    "默认将所选端口移入回收站，之后仍可恢复。"),
                title_checked=L("Permanently delete selected ports","永久删除所选端口"),
                message_checked=L("Launcher, images and unshared game data will be deleted permanently. This cannot be undone.",
                    "启动项、图片和未被共用的游戏数据将被永久删除，无法恢复。"),
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
            L("No ports are available to manage.","没有可管理的游戏。") or
            L("Port management is unavailable on this device profile.","当前设备配置未启用 Port 游戏管理。"),"home:empty") end
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
                    "A maintenance tool for Port games. Use it to maintain PortMaster, manage Runtimes, and safely uninstall games.",
                    "这是一款 Port 游戏维护工具，可以维护 PortMaster、管理 Runtime，并安全卸载游戏。"),
                confirm=L("Start using","开始使用"),
                callouts={
                    {target="header",title=L("PortMaster environment","PortMaster 环境"),
                        body=env.portmaster_management=="system" and L(
                            "View the PortMaster version, device and path here. PortMaster is maintained by this system, so Port App Manager will not install, update, or replace its core.",
                            "在这里查看 PortMaster 的版本、设备和路径。当前系统负责维护 PortMaster，因此 Port App Manager 不会安装、更新或覆盖它的核心。") or L(
                            "View the PortMaster version, device and install path, and check for updates. If PortMaster is missing or damaged, install or repair it here.",
                            "查看 PortMaster 的版本、设备和安装路径，并检查更新。PortMaster 缺失或损坏时，可以在这里下载安装或修复。")},
                    {targets={"uninstall","trash"},title=L("Uninstall and Trash","卸载与回收站"),
                        body=L(
                            "When uninstalling, the game's launcher, images and exclusive data are moved to Trash by default instead of being deleted immediately. Restore them at any time, or delete them permanently after confirmation.",
                            "卸载时，游戏启动项、图片和独占数据默认移入回收站，不会立即删除。可以随时还原，确认后也可以彻底删除。")},
                    {target="leftovers",title=L("Leftover cleanup","残留清理"),
                        body=L(
                            "Find unmatched launchers and data folders; ordinary orphan SH files and folders are selected by default. SH launchers that point to the same folder are grouped as duplicate references. They are not preselected: review the warning and choose which launchers to remove.",
                            "查找不配套的 SH 和数据目录；普通的孤儿 SH 与孤儿目录会默认勾选。多个 SH 指向同一目录时，会按目录聚合为“重复引用”，默认不勾选；请阅读提示后自行选择要清理的启动器。")},
                    {target="runtime-repair-entry",title=L("Runtime management","Runtime 管理"),
                        body=L(
                            "Check the Runtimes required by installed Port games. Missing or damaged Runtimes can be downloaded, verified and repaired automatically.",
                            "检查已安装 Port 游戏需要的 Runtime。Runtime 缺失或损坏时，可以自动下载、校验并修复。")},
                    {target="footer",title=L("Maintainer and feedback","维护者与反馈"),
                        body=L(
                            "Maintainer: Bili 解腻Jenny. Adapted for restricted networks and handheld devices. If you encounter a problem, keep log.txt and report it through the QQ group.",
                            "维护者：Bili 解腻Jenny。针对受限网络和掌机环境进行了适配。遇到问题请保留 log.txt，并通过 QQ 群反馈。")},
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
            local detail=L(string.format("Required by %d: %s",count,table.concat(users,", ")),
                string.format("依赖 %d 个：%s",count,table.concat(users,"、")))
            local key="repair:"..item.name
            rows[#rows+1]=kit.checkbox(item.name,{
                id=key,detail=detail,detail_max_lines=3,height=96,checked=selected_runtime[item.name],
                sidebar_target="runtime-repair",on_change=function(value) selected_runtime[item.name]=value end,
                badge=item.missing and kit.badge(L("Missing","缺失")) or
                    (item.damaged and kit.badge(L("Damaged","损坏"),{1,0.45,0.38}) or
                    kit.badge(L("Installed","已安装"),{0.48,0.90,0.62})),
            })
            local health
            if item.missing then health=L("The Runtime is not installed.","尚未安装这个 Runtime。")
            elseif item.health=="invalid_magic" then health=L("The Runtime file is invalid.","Runtime 文件已损坏。")
            else
                health=L(string.format("Installed and ready (%s). Select it to download the latest official version again.",model.human(item.bytes)),
                    string.format("已安装并可正常使用（%s）。勾选后可以重新下载官方最新版。",model.human(item.bytes)))
            end
            local remote=metadata and L(string.format("\n\nCurrent official download: %s",model.human(metadata.bytes)),
                string.format("\n\n当前官方下载大小：%s",model.human(metadata.bytes))) or
                L("\n\nOfficial download information will be checked online when repair starts.","\n\n开始修复时会在线获取官方文件信息。")
            details[key]={title=item.name,body=L(
                string.format("%s%s\n\nRequired by %d managed port%s:\n%s",health.en,remote.en,count,count==1 and "" or "s",table.concat(users,"\n")),
                string.format("%s%s\n\n由 %d 个受管游戏依赖：\n%s",health.zh,remote.zh,count,table.concat(users,"\n")))}
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
            if value then plan[#plan+1]={kind="TRASH",arg=path}; labels[#labels+1]=scanner.basename(path) end
        end
        table.sort(labels)
        if #plan>0 then operations.show_confirm(L("Move leftovers to Trash","将残留项移入回收站"),plan,labels,page.JUNK,
            {confirm=L("Move to Trash","移入回收站")}) end
    end

    local function cleanup_appledouble()
        local plan={{kind="CLEAN_APPLEDOUBLE",arg="-"}}
        operations.show_confirm(L("Clean ._Files garbage files","清理 ._Files 垃圾文件"),plan,{},page.JUNK,{
            message=L(
                "Scan the managed Port launcher, data and image directories. Every macOS ._* metadata file found will be deleted immediately. This cannot be undone.",
                "将扫描受管的 Port 启动器、数据和图片目录。发现 macOS 生成的 ._* 元数据文件后会立即永久删除，此操作无法撤销。"),
            confirm=L("Start cleanup","开始清理"),danger=true,
        })
    end

    function self.build_junk(preserve_focus)
        model.ensure_report()
        if not preserve_focus then clear(selected_junk) end
        local rows,item_count={},0
        rows[#rows+1]=kit.textview(L("Cleanup rules","清理说明"),L(
            "Ordinary orphan SH files and data folders are selected by default. When several SH launchers reference the same folder, they are grouped below as duplicate references and left unselected. Choose the launchers yourself; cleanup moves only the selected items to Trash.",
            "普通的孤儿 SH 与孤儿数据目录会默认勾选。多个 SH 指向同一目录时，会在下方按目录聚合为“重复引用”，并默认不勾选。请自行选择要处理的启动器；清理只会把选中项移入回收站。"),{
            id="leftovers:rules",focusable=false,expandable=false,max_lines=5,expanded_lines=5,
            label_px=16,value_px=18,surface=false})
        local function add(label,detail,path,default_selected)
            item_count=item_count+1
            if selected_junk[path]==nil then selected_junk[path]=default_selected==true end
            rows[#rows+1]=kit.checkbox(label,{
                id=path,detail=detail,checked=selected_junk[path],meta={path=path},
                on_change=function(value) selected_junk[path]=value end,
            })
        end
        for _,name in ipairs(report.orphan_dirs or {}) do add(name.."/",L(
            "No SH launcher references this data folder; move it to Trash only after checking it.",
            "没有检测到 SH 引用这个数据目录；确认无用后再移入回收站。"),env.gamedirs_dir.."/"..name,true) end
        for _,image in ipairs(report.orphan_images or {}) do add(image.name,L(
            "No matching SH launcher was found for this image.",
            "没有检测到与这张图片配套的 SH 启动器。"),image.path,false) end
        for _,item in ipairs(report.dead_scripts or {}) do
            add(model.display_name(item.script),L("This SH launcher points to a missing data folder: ",
                "这个 SH 启动器引用的数据目录不存在：")[kit.get_state().ui_lang]..item.missing_dir,
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
                    string.format("%d SH launchers reference this same folder. This may be intentional or duplicated; review carefully and select the launcher files you want to remove.",#shared[name]),
                    string.format("有 %d 个 SH 启动器引用同一个目录，可能是有意共用，也可能是重复启动项。请谨慎核对，并自行选择要清理的 SH。",#shared[name])),{
                    id="leftovers:shared:"..name,focusable=false,expandable=false,max_lines=4,expanded_lines=4,
                    label_px=16,value_px=18,surface=false})
                for _,script in ipairs(shared[name]) do
                    local path=env.scripts_dir.."/"..script
                    add(model.display_name(script),L(
                        "Duplicate reference to "..name.."/; selecting this moves only this SH launcher to Trash.",
                        "重复引用 "..name.."/；勾选后只会把这个 SH 启动器移入回收站。"),path,false)
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
            sidebar[#sidebar+1]=button(L("Clean ._Files garbage files","清理 ._Files 垃圾文件"),cleanup_appledouble,{id="clean-appledouble"})
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
            elseif entry.bucket=="legacy" then kind=L("Legacy trash item","旧版回收站项目")
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
            rows[#rows+1]=kit.textview(label,model.provided(value),{id=key,label_px=16,value_px=18})
            details[key]={title=title or label,body=body}
        end
        section(L("Key paths","关键路径"))
        info("path:scripts",L("SH path","SH 路径"),env.scripts_dir,
            L("Launcher script folder","SH 启动脚本目录"),
            L("This is the folder containing the menu's .sh launchers, normally the folder of $0. A menu item runs one of these scripts first; it locates game data, prepares the Runtime, maps controls and starts the game. Removing or breaking a script makes that menu item unlaunchable.",
                "这里存放菜单中的 .sh 启动脚本，通常就是 $0 所在目录。点击游戏后会先执行对应脚本，由它定位数据、准备 Runtime、映射手柄并启动游戏。删除或改错脚本会让对应菜单项无法启动。"))
        info("path:data",L("Data path","Data 路径"),env.gamedirs_dir,
            L("Game data folder","游戏数据目录"),
            L("This is directory/ports: the root that holds each port's game data and configuration, usually one subfolder per port. APP Manager checks references in SH scripts before removing a data folder so shared data is not deleted while another launcher still uses it.",
                "这里是 directory/ports，保存各个移植的游戏数据和配置，通常一个端口对应一个子目录。APP Manager 删除数据前会检查 SH 脚本引用，避免仍被其他启动器共用的目录遭到误删。"))
        info("path:portmaster",L("PortMaster path","PortMaster 路径"),env.controlfolder,
            L("PortMaster core folder","PortMaster 核心目录"),
            L("This is controlfolder, the shared PortMaster installation. It contains control.txt, common resources, helper scripts and global configuration used by many ports. It is infrastructure, not one game's data, and should not be removed with a port.",
                "这里是 controlfolder，也就是 PortMaster 的公共核心目录，包含 control.txt、通用资源、辅助脚本和全局配置。它被许多端口共同使用，不属于某一个游戏，不能随单个游戏一起删除。"))
        info("path:runtimes",L("Runtime path","Runtime 路径"),env.libs_dir,
            L("Shared Runtime folder","共享 Runtime 目录"),
            L("This is controlfolder/libs. It stores shared Runtime packages such as love, frt and godot squashfs images. Several launchers may use the same Runtime; if one is missing, every dependent game can fail to start or require a new download.",
                "这里是 controlfolder/libs，保存 love、frt、godot 等共享 Runtime 的 squashfs 包。多个启动器可能共用同一个 Runtime；文件缺失时，所有依赖它的游戏都可能无法启动或需要重新下载。"))

        local resolution=(env.display_width and env.display_width~="" and env.display_height and env.display_height~="")
            and tostring(env.display_width).."×"..tostring(env.display_height) or nil
        section(L("Environment values","环境变量"))
        local values={
            {"env:cfw",L("Firmware (CFW_NAME)","固件（CFW_NAME）"),env.cfw,L("Firmware family","固件类型"),L("Identifies the current custom firmware. Launchers use it to select firmware-specific paths and compatibility behaviour.","标识当前掌机固件。启动器会据此选择对应的目录规则和兼容处理。")},
            {"env:resolution",L("Display resolution","显示分辨率"),resolution,L("Physical display size","物理显示分辨率"),L("The detected display width and height. The Kit uses it to choose layout density, columns and readable font sizes.","系统检测到的屏幕宽高。Kit 会据此决定布局密度、分栏数量和可读字号。")},
            {"env:arch",L("Architecture (DEVICE_ARCH)","设备架构（DEVICE_ARCH）"),env.device_arch,L("CPU architecture","CPU 架构"),L("Selects compatible executables and libraries, such as aarch64 or armhf. A mismatched binary cannot run on the device.","用于选择匹配的可执行文件和动态库，例如 aarch64 或 armhf。架构不匹配的程序无法在设备上运行。")},
            {"env:device",L("Controller ID (DEVICE)","手柄 ID（DEVICE）"),env.device,L("Controller identifier","手柄标识"),L("The PortMaster device/controller identifier used when choosing control mappings and device-specific defaults.","PortMaster 用来选择手柄映射和设备默认值的机型或控制器标识。")},
            {"env:profile",L("Device profile (param_device)","设备配置（param_device）"),env.param_device,L("Device profile","设备配置档"),L("Points to the active PortMaster device profile. It supplies hardware-specific settings that launchers should not hard-code.","指向当前 PortMaster 设备配置档，提供启动器不应硬编码的硬件差异参数。")},
            {"env:sticks",L("Analog sticks (ANALOGSTICKS)","摇杆数（ANALOGSTICKS）"),env.analog_sticks,L("Analog stick count","摇杆数量"),L("Reports how many analog sticks the device profile exposes. Control helpers use it when building game mappings.","表示设备配置提供几个模拟摇杆，手柄映射工具会据此生成游戏控制方案。")},
            {"env:lowres",L("Low resolution mode (LOWRES)","低分辨率（LOWRES）"),env.lowres,L("Low-resolution mode","低分辨率模式"),L("Signals that launchers should prefer compact UI, smaller render targets or lighter assets on low-resolution hardware.","提示启动器在低分辨率设备上使用更紧凑的界面、较小渲染尺寸或更轻量的资源。")},
            {"env:tty",L("Display terminal (CUR_TTY)","显示终端（CUR_TTY）"),env.cur_tty,L("Active display terminal","当前显示终端"),L("Names the terminal used by the frontend. Some launchers need it when switching away from and restoring the system menu.","表示前端正在使用的终端；部分启动器切换显示并返回系统菜单时需要它。")},
            {"env:controller_db",L("Controller database (SDL_GAMECONTROLLERCONFIG_FILE)","手柄库（SDL_GAMECONTROLLERCONFIG_FILE）"),env.sdl_controller_file,L("SDL controller database","SDL 手柄映射库"),L("Path to the SDL controller mapping database. It normalizes physical button layouts so SDL/LÖVE can expose consistent logical controls.","SDL 手柄映射数据库的路径，用来把不同掌机的实体按键布局规范成一致的逻辑控制。")},
            {"env:esudo",L("Privilege helper (ESUDO)","提权命令（ESUDO）"),env.esudo,L("Privilege helper","提权助手"),L("The firmware-approved command for operations that need elevated permissions. APP Manager uses its own validated helper rather than guessing a sudo command.","固件提供的提权命令，用于需要更高权限的文件操作。APP Manager 通过受校验的助手调用它，不自行猜测 sudo。")},
            {"env:gptokeyb",L("Controller helper (GPTOKEYB)","手柄映射（GPTOKEYB）"),env.gptokeyb,L("Gamepad-to-keyboard helper","手柄转键盘工具"),L("Path to gptokeyb, which translates gamepad input into keyboard or mouse events for software without native controller support.","gptokeyb 的路径。它为没有原生手柄支持的软件把手柄输入转换成键盘或鼠标事件。")},
            {"env:path",L("Command search path (PATH)","命令搜索（PATH）"),env.path,L("Command search path","命令搜索路径"),L("Ordered folders searched by the shell for commands. A missing entry can make a launcher report that an installed tool was not found.","Shell 查找命令时依次搜索的目录。缺少必要目录时，启动器可能找不到已经安装的工具。")},
            {"env:ld_path",L("Library search path (LD_LIBRARY_PATH)","动态库搜索（LD_LIBRARY_PATH）"),env.ld_library_path,L("Dynamic library search path","动态库搜索路径"),L("Ordered folders searched for shared libraries at program startup. Incorrect entries commonly cause missing .so errors or load an incompatible library.","程序启动时查找共享动态库的目录。配置错误通常会产生缺少 .so，或误加载不兼容库。")},
            {"env:xdg_config",L("Config root (XDG_CONFIG_HOME)","配置根（XDG_CONFIG_HOME）"),env.xdg_config_home,L("Application config root","应用配置根目录"),L("The standard root where applications store user configuration. Redirecting it keeps per-port settings on persistent storage.","应用保存用户配置的标准根目录。重定向到这里可让各端口设置保存在持久存储中。")},
            {"env:xdg_data",L("Data root (XDG_DATA_HOME)","数据根（XDG_DATA_HOME）"),env.xdg_data_home,L("Application data root","应用数据根目录"),L("The standard root for application-owned data such as saves, databases and downloaded resources, depending on the port.","应用保存存档、数据库或下载资源等自身数据的标准根目录，具体内容由端口决定。")},
            {"env:free",L("Free space","剩余空间"),model.human(env.free_bytes),L("Available storage","可用存储空间"),L("Free bytes on the storage used by ports. Uninstall, restore and Runtime operations may fail safely when there is not enough room.","端口所在存储空间的剩余容量。空间不足时，卸载、还原或 Runtime 操作可能会安全中止。")},
        }
        for _,item in ipairs(values) do info(item[1],item[2],item[3],item[4],item[5]) end

        local runtimes=model.installed_runtimes()
        section({en=string.format("Installed Runtimes (%d)",#runtimes),zh=string.format("已安装 Runtime（%d）",#runtimes)})
        if #runtimes==0 then
            rows[#rows+1]=kit.list_item(L("None installed","未安装"),{id="runtime:none",font_px=19})
            details["runtime:none"]={title=L("Installed Runtimes","已安装 Runtime"),body=L("No shared Runtime package was found in the Runtime folder.","Runtime 目录中没有检测到共享运行环境包。")}
        else
            for _,name in ipairs(runtimes) do
                local key="runtime:"..name
                rows[#rows+1]=kit.list_item(name,{id=key,font_px=19})
                details[key]={title=name,body=L("This Runtime is installed in the shared Runtime folder. Launchers that declare this exact name can mount and reuse it without bundling another engine copy.","这个 Runtime 已安装在共享目录中。声明相同名称的启动器可以直接挂载并复用它，不需要再打包一份运行引擎。")}
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
