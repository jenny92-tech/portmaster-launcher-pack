local kit = require("kit")
local json = require("json")
local scanner = require("scan")

local function L(en,zh) return {en=en,zh=zh} end
local function join(parts,sep) return table.concat(parts,sep or " · ") end
local function stem(name) return (name:gsub("%.[^.]+$","")) end
local function shquote(value) return "'"..tostring(value):gsub("'","'\\''").."'" end

local HOME,JUNK,TRASH,ENV,RUNTIME = 1,2,3,4,5
local env,report,size_map,runtime_catalog = {},nil,{},{}
local selected_home,selected_junk,selected_trash,selected_runtime = {},{},{},{}
local confirm_plan,confirm_return = nil,HOME
local task,status_message = nil,nil

local function file_exists(path)
    local f=path and io.open(path,"rb")
    if f then f:close(); return true end
    return false
end

local function read_all(path)
    local f=path and io.open(path,"rb"); if not f then return nil end
    local text=f:read("*a"); f:close(); return text
end

local function load_env()
    local path=os.getenv("PAM_ENV") or ""
    local text=read_all(path)
    if not text then return false,"PAM_ENV is unavailable" end
    local ok,value=pcall(json.decode,text)
    if not ok or type(value)~="table" then return false,tostring(value) end
    env=value; return true
end

local function load_sizes()
    size_map={}; local f=io.open(env.size_file or "","rb"); if not f then return end
    for line in f:lines() do
        local bytes,path=line:match("^(%d+)\t(.+)$")
        if bytes and path then size_map[path]=tonumber(bytes) or 0 end
    end
    f:close()
end

local function runtime_arch(value)
    value=tostring(value or ""):lower()
    if value=="arm64" or value=="armv8" then return "aarch64" end
    if value=="armv7" or value=="armv7l" then return "armhf" end
    if value=="amd64" then return "x86_64" end
    return value
end

local function load_runtime_catalog()
    runtime_catalog={}
    local f=io.open(env.runtime_catalog_file or "","rb")
    if not f then return end
    local arch=runtime_arch(env.device_arch)
    for line in f:lines() do
        if not line:match("^%s*#") then
            local name,row_arch,sources,bytes,source_bytes=line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t(%d+)\t([%d,]+)$")
            if name and row_arch==arch then runtime_catalog[name]={sources=sources,arch=row_arch,bytes=tonumber(bytes),source_bytes=source_bytes} end
        end
    end
    f:close()
end

local function human(bytes)
    bytes=tonumber(bytes) or 0
    if bytes>=1024^3 then return string.format("%.1f GB",bytes/1024^3) end
    if bytes>=1024^2 then return string.format("%.1f MB",bytes/1024^2) end
    if bytes>=1024 then return string.format("%.1f KB",bytes/1024) end
    return tostring(bytes).." B"
end

local function provided(value)
    if type(value)=="table" or type(value)=="function" then return value end
    if value==nil or tostring(value)=="" then return L("Not provided","未提供") end
    return tostring(value)
end

local function path_size(paths)
    local total=0; for _,path in ipairs(paths or {}) do total=total+(size_map[path] or 0) end; return total
end

local function display_name(name)
    return stem(name):gsub("^%[[^]]+%]",""):gsub("^[A-Z]_","")
end

local function selected_count(values)
    local n=0; for _,value in pairs(values) do if value then n=n+1 end end; return n
end

local function dynamic_count(en,zh,values)
    return function()
        local n=selected_count(values)
        return kit.get_state().ui_lang=="zh" and string.format(zh,n) or string.format(en,n)
    end
end

local function button(label,action,opts) return kit.button(label,action,opts) end
local function empty(values) return function() return selected_count(values)==0 end end

local function dump_debug()
    if not report or not env.gamedir then return end
    local path=env.gamedir.."/conf/scan_debug.json"
    local f=io.open(path,"wb"); if not f then return end
    f:write(json.encode(report)); f:close()
end

local function refresh_scan()
    load_sizes()
    load_runtime_catalog()
    report=scanner.run(env)
    selected_home,selected_junk,selected_trash,selected_runtime={},{},{},{}
    dump_debug()
end

local function missing_runtime(script)
    local out={}
    for _,item in ipairs(report.runtimes.missing or {}) do
        for _,user in ipairs(item.users or {}) do if user==script then out[#out+1]=item.name end end
    end
    table.sort(out); return table.concat(out,", ")
end

local function required_runtimes()
    local out={}
    for name,users in pairs(report.runtimes.need or {}) do
        local catalog=runtime_catalog[name]
        local health,bytes=scanner.runtime_file_health(
            (env.libs_dir or "").."/"..name..".squashfs",catalog and catalog.bytes)
        out[#out+1]={name=name,users=users,health=health,bytes=bytes,
            missing=health=="missing",damaged=health=="invalid_magic",different=health=="size_mismatch",
            needs_repair=health=="missing" or health=="invalid_magic"}
    end
    table.sort(out,function(a,b) return a.name<b.name end)
    return out
end

local function runtime_issue_count()
    local count=0
    for _,item in ipairs(required_runtimes()) do if item.needs_repair then count=count+1 end end
    return count
end

local build_home,build_junk,build_trash,build_env,build_runtime,collect_trash

local function show_exit_dialog()
    kit.dialog({
        title=L("Exit Port App Manager?","退出 Port App Manager？"),
        message=L("Return to the system menu?","将返回系统菜单。"),
        confirm=L("Exit","退出"),
        cancel=L("Stay","暂不退出"),
        danger=false,
        on_confirm=kit.quit,
    })
end

local function write_plan(items)
    local path=env.plan_file or ""; local f=io.open(path,"wb")
    if not f then return false end
    f:write("# APP Manager plan — validated and applied by launcher.sh\n")
    for _,item in ipairs(items) do
        if tostring(item.arg):find("[\t\r\n]") then f:close(); os.remove(path); return false end
        f:write(item.kind,"\t",item.arg,"\n")
    end
    f:close(); return true
end

local function finish_task()
    kit.set_busy(false)
    task=nil
    local result=read_all(env.result_file or "")
    if result and result:match("FAIL") then status_message=L("The last operation reported a failure. See log.txt.","上次操作有项目失败，请查看 log.txt。")
    else status_message=L("Operation completed.","操作已完成。") end
    -- The helper removes plan_file only after completing its env refresh, so
    -- reloading here cannot race a half-written env.json.
    load_env(); refresh_scan()
    if confirm_return==RUNTIME then build_runtime(); kit.goto_page(RUNTIME)
    else
        build_home()
        if confirm_return==TRASH then build_trash(); kit.goto_page(TRASH)
        elseif confirm_return==JUNK then build_junk(); kit.goto_page(JUNK)
        else kit.goto_page(HOME) end
    end
end

local function start_apply()
    if not confirm_plan or #confirm_plan==0 then return end
    if not write_plan(confirm_plan) or not env.apply_script or env.apply_script=="" then
        status_message=L("Cannot start the privileged helper.","无法启动提权操作助手。")
        kit.goto_page(confirm_return); return
    end
    kit.set_busy(true,confirm_return==RUNTIME and L("Repairing Runtimes…","正在修复 Runtime…") or L("Working…","处理中…"))
    os.execute(shquote(env.apply_script).." --apply-plan >/dev/null 2>&1 &")
    task={elapsed=0,poll=0,timeout=confirm_return==RUNTIME and 1800 or 45}
end

local function show_confirm(title,plan,labels,return_page,opts)
    opts=opts or {}
    confirm_plan,confirm_return=plan,return_page or HOME
    local count=#(labels or {})
    kit.dialog({
        title=title,
        message=L(string.format("Review %d selected item%s before continuing.",count,count==1 and "" or "s"),
            string.format("即将处理 %d 个所选项目，请确认后继续。",count)),
        items=labels,
        confirm=opts.confirm or L("Confirm","确认"),
        cancel=L("Cancel","取消"),
        danger=opts.danger~=false,
        on_confirm=start_apply,
    })
end

local function select_all_home(value)
    for _,p in ipairs(report.ports) do selected_home[p.script]=value end
    build_home(true)
end

local function uninstall_selected()
    local plan,labels,selected_ports,dir_counts,planned_dirs={},{},{},{},{}
    for _,p in ipairs(report.ports) do
        if selected_home[p.script] then
            selected_ports[#selected_ports+1]=p; labels[#labels+1]=display_name(p.script)
            if p.dir~="" then dir_counts[p.dir]=(dir_counts[p.dir] or 0)+1 end
        end
    end
    for _,p in ipairs(selected_ports) do
        plan[#plan+1]={kind="TRASH",arg=env.scripts_dir.."/"..p.script}
        for _,image in ipairs(p.images or {}) do
            if env.images_dir and env.images_dir~="" then plan[#plan+1]={kind="TRASH",arg=env.images_dir.."/"..image} end
        end
        if p.dir~="" and dir_counts[p.dir]==(report.refcount[p.dir] or 0) and not planned_dirs[p.dir] then
            planned_dirs[p.dir]=true
            plan[#plan+1]={kind="TRASH",arg=env.gamedirs_dir.."/"..p.dir}
        end
    end
    if #plan>0 then show_confirm(L("Move selected ports to Trash","将所选端口移入回收站"),plan,labels,HOME,
        {confirm=L("Move to Trash","移入回收站")}) end
end

build_home=function(preserve_focus)
    local rows={}
    if status_message then rows[#rows+1]=kit.info(L("Status","状态"),status_message); status_message=nil end
    for _,p in ipairs(report.ports or {}) do
        local script=p.script
        local paths={env.scripts_dir.."/"..script}
        if p.dir~="" then paths[#paths+1]=env.gamedirs_dir.."/"..p.dir end
        for _,image in ipairs(p.images or {}) do if env.images_dir~="" then paths[#paths+1]=env.images_dir.."/"..image end end
        local detail={}
        if p.dir~="" then detail[#detail+1]=p.dir.."/" elseif p.claimed_dir~="" then detail[#detail+1]=L("Missing data: ","数据缺失：")[kit.get_state().ui_lang]..p.claimed_dir end
        local missing=missing_runtime(script); if missing~="" then detail[#detail+1]=(kit.get_state().ui_lang=="zh" and "缺少 Runtime: " or "Missing Runtime: ")..missing end
        local bytes=path_size(paths); if bytes>0 then detail[#detail+1]=human(bytes) end
        rows[#rows+1]=kit.checkbox(display_name(script),{
            id=script,detail=join(detail),checked=selected_home[script],
            on_change=function(value) selected_home[script]=value end,
            badge=missing~="" and kit.badge(L("Runtime missing","缺少 Runtime")) or nil,
        })
    end
    if #rows==0 then rows[1]=kit.info(L("Ports","端口"),L("No managed ports found.","没有找到可管理的端口。")) end
    local junk_count=#(report.orphan_dirs or {})+#(report.orphan_images or {})+#(report.dead_scripts or {})
    local trash_count=collect_trash and #collect_trash() or 0
    local runtime_count=runtime_issue_count()
    kit.set_page(HOME,{en="Port App Manager",zh="Port App Manager"},rows,{
        preserve_focus=preserve_focus,
        sidebar_title=L("Quick Tools","快捷工具"),
        sidebar_footer={lines={L("Developer: Bili 解腻Jenny","开发: Bili 解腻Jenny"),kit.CONTACT}},
        header_action=button(L("Details","详情"),function() build_env(); kit.goto_page(ENV) end),
        sidebar={
        button(dynamic_count("Uninstall (%d)","卸载 (%d)",selected_home),uninstall_selected,{disabled=empty(selected_home)}),
        button(L("Select all","全选"),function() select_all_home(true) end,{half=true}),
        button(L("Select none","全不选"),function() select_all_home(false) end,{half=true}),
        button(function() return kit.get_state().ui_lang=="zh" and string.format("残留清理 (%d)",junk_count) or string.format("Leftovers (%d)",junk_count) end,
            function() build_junk(); kit.goto_page(JUNK) end),
        button(function() return kit.get_state().ui_lang=="zh" and string.format("Runtime 修复 (%d)",runtime_count) or string.format("Runtime repair (%d)",runtime_count) end,
            function() build_runtime(); kit.goto_page(RUNTIME) end),
        button(function() return kit.get_state().ui_lang=="zh" and string.format("回收站 (%d)",trash_count) or string.format("Trash (%d)",trash_count) end,
            function() build_trash(); kit.goto_page(TRASH) end),
        button(L("Quit","退出"),show_exit_dialog,{group="bottom"}),
    }})
end

local function select_all_runtime(value)
    for _,item in ipairs(required_runtimes()) do
        if runtime_catalog[item.name] then selected_runtime[item.name]=value end
    end
    build_runtime(true)
end

local function repair_runtimes()
    local plan,labels={},{}
    for _,item in ipairs(required_runtimes()) do
        if selected_runtime[item.name] and runtime_catalog[item.name] then
            plan[#plan+1]={kind="INSTALL_RUNTIME",arg=item.name}
            labels[#labels+1]=item.name
        end
    end
    if #plan>0 then
        show_confirm(L("Repair selected Runtimes","修复所选 Runtime"),plan,labels,RUNTIME,{
            confirm=L("Download and repair","下载并修复"),danger=false})
    end
end

build_runtime=function(preserve_focus)
    local rows,details={},{}
    if status_message then rows[#rows+1]=kit.info(L("Status","状态"),status_message); status_message=nil end
    local required=required_runtimes()
    local repair_needed,installed={},{}
    for _,item in ipairs(required) do
        if item.needs_repair then repair_needed[#repair_needed+1]=item else installed[#installed+1]=item end
    end
    for _,item in ipairs(repair_needed) do
        if selected_runtime[item.name]==nil and runtime_catalog[item.name] then selected_runtime[item.name]=true end
    end

    local function add_runtime(item)
        local users={}
        for _,script in ipairs(item.users or {}) do users[#users+1]=display_name(script) end
        table.sort(users)
        local available=runtime_catalog[item.name]~=nil
        local detail
        if available then
            local count=#users
            detail=L(string.format("Required by %d: %s",count,table.concat(users,", ")),
                string.format("依赖 %d 个：%s",count,table.concat(users,"、")))
            local key="repair:"..item.name
            rows[#rows+1]=kit.checkbox(item.name,{
                id=key,detail=detail,detail_max_lines=3,height=96,checked=selected_runtime[item.name],
                sidebar_target="runtime-repair",
                on_change=function(value) selected_runtime[item.name]=value end,
                badge=item.missing and kit.badge(L("Missing","缺失")) or
                    (item.damaged and kit.badge(L("Damaged","损坏"),{1,0.45,0.38}) or
                    (item.different and kit.badge(L("Different","版本不同"),{1,0.78,0.35}) or
                    kit.badge(L("Verified","已校验"),{0.48,0.90,0.62}))),
            })
            local health
            if item.missing then health=L("Local file is missing.","本地文件不存在。")
            elseif item.health=="invalid_magic" then health=L("Validation failed: not a SquashFS image.","校验失败：不是有效的 SquashFS 镜像。")
            elseif item.health=="size_mismatch" then
                health=L(string.format("The SquashFS header is valid, but the local size is %s; the current official version is %s. Select it to update or replace it.",human(item.bytes),human(runtime_catalog[item.name].bytes)),
                    string.format("SquashFS 文件头有效，但本地体积为 %s，当前官方版本为 %s。可勾选后更新或替换。",human(item.bytes),human(runtime_catalog[item.name].bytes)))
            else
                health=L(string.format("Verified: SquashFS header and exact size (%s). Select it to force a fresh download.",human(item.bytes)),
                    string.format("已校验 SquashFS 文件头和精确体积（%s）。如怀疑内容异常，可勾选后强制重新下载。",human(item.bytes)))
            end
            details[key]={title=item.name,body=L(
                string.format("%s\n\nRequired by %d managed port%s:\n%s",health.en,count,count==1 and "" or "s",table.concat(users,"\n")),
                string.format("%s\n\n由 %d 个受管游戏依赖：\n%s",health.zh,count,table.concat(users,"\n")))}
        else
            detail=L("No official download is available for this device architecture.","官方目录没有适用于当前设备架构的下载。")
            rows[#rows+1]=kit.info(item.name,detail,{id="repair:"..item.name})
        end
    end

    if #required>0 then
        rows[#rows+1]=kit.section(L(string.format("Needs repair (%d)",#repair_needed),string.format("需要修复（%d）",#repair_needed)),{font_px=22})
        if #repair_needed==0 then
            rows[#rows+1]=kit.info(L("Status","状态"),L("All required Runtimes passed validation.","所有必需 Runtime 均已通过校验。"))
        else
            for _,item in ipairs(repair_needed) do add_runtime(item) end
        end
        rows[#rows+1]=kit.section(L(string.format("Installed (%d)",#installed),string.format("已安装（%d）",#installed)),{font_px=22})
        if #installed==0 then
            rows[#rows+1]=kit.info(L("Runtimes","运行环境"),L("No required Runtime is currently installed.","当前没有已安装的必需 Runtime。"))
        else
            for _,item in ipairs(installed) do add_runtime(item) end
        end
    end
    if #required==0 then
        rows[1]=kit.info(L("Runtimes","运行环境"),L("No managed port declares a shared Runtime.","当前游戏没有声明共享 Runtime。"))
    end
    kit.set_page(RUNTIME,L("Runtime repair","Runtime 修复"),rows,{preserve_focus=preserve_focus,
        row_layout={mode="flow",min_width=360,max_columns=1},sidebar_details=details,
        sidebar_title=L("Quick Tools","快捷工具"),sidebar={
        button(dynamic_count("Repair (%d)","修复 (%d)",selected_runtime),repair_runtimes,
            {id="runtime-repair",disabled=empty(selected_runtime)}),
        button(L("Select all","全选"),function() select_all_runtime(true) end,{half=true}),
        button(L("Select none","全不选"),function() select_all_runtime(false) end,{half=true}),
        button(L("Back","返回"),function() kit.goto_page(HOME) end,{group="bottom"}),
    }})
end

local function select_all_junk(value)
    for _,row in ipairs((kit._junk_rows or {})) do
        if row.meta and row.meta.path then selected_junk[row.meta.path]=value end
    end
    build_junk(true)
end

local function remove_junk()
    local plan,labels={},{}
    for path,value in pairs(selected_junk) do if value then plan[#plan+1]={kind="TRASH",arg=path}; labels[#labels+1]=scanner.basename(path) end end
    table.sort(labels)
    if #plan>0 then show_confirm(L("Move leftovers to Trash","将残留项移入回收站"),plan,labels,JUNK,
        {confirm=L("Move to Trash","移入回收站")}) end
end

build_junk=function(preserve_focus)
    local rows={}
    local function add(label,detail,path)
        local row=kit.checkbox(label,{
            id=path,detail=detail,checked=selected_junk[path],meta={path=path},
            on_change=function(value) selected_junk[path]=value end,
        })
        rows[#rows+1]=row
    end
    for _,name in ipairs(report.orphan_dirs or {}) do add(name.."/",L("Orphan data folder","孤立数据目录"),env.gamedirs_dir.."/"..name) end
    for _,name in ipairs(report.orphan_images or {}) do if env.images_dir~="" then add(name,L("Orphan image","孤立图片"),env.images_dir.."/"..name) end end
    for _,item in ipairs(report.dead_scripts or {}) do add(display_name(item.script),L("Missing data: ","数据目录缺失：")[kit.get_state().ui_lang]..item.missing_dir,env.scripts_dir.."/"..item.script) end
    if #rows==0 then rows[1]=kit.info(L("Leftovers","残留"),L("No leftovers found.","没有发现残留项。")) end
    kit._junk_rows=rows
    kit.set_page(JUNK,L("Leftover cleanup","残留清理"),rows,{preserve_focus=preserve_focus,
        sidebar_title=L("Quick Tools","快捷工具"),sidebar={
        button(dynamic_count("Move to Trash (%d)","移入回收站 (%d)",selected_junk),remove_junk,{disabled=empty(selected_junk)}),
        button(L("Select all","全选"),function() select_all_junk(true) end,{half=true}),
        button(L("Select none","全不选"),function() select_all_junk(false) end,{half=true}),
        button(L("Back","返回"),function() kit.goto_page(HOME) end,{group="bottom"}),
    }})
end

collect_trash=function()
    local out={}; local root=(env.gamedir or "").."/trash"
    local function append(entry,kind)
        out[#out+1]={title=entry.name..(entry.is_dir and "/" or ""),detail=kind,paths={entry.path}}
    end
    for _,top in ipairs(scanner.entries(root)) do
        if not top.is_dir then append(top,L("Trash item","回收站项目"))
        else
            for _,bucket in ipairs({"scripts","data","images"}) do
                local bucket_entries=scanner.entries(top.path.."/"..bucket)
                for _,entry in ipairs(bucket_entries) do append(entry,L(bucket=="scripts" and "Launcher" or bucket=="data" and "Game data" or "Image",bucket=="scripts" and "启动项" or bucket=="data" and "游戏数据" or "图片")) end
            end
            -- Mixed/legacy batches may also have direct items next to the
            -- structured buckets. Never hide those; only skip the containers.
            for _,entry in ipairs(scanner.entries(top.path)) do
                if entry.name~="scripts" and entry.name~="data" and entry.name~="images" then
                    append(entry,L("Legacy trash item","旧版回收站项目"))
                end
            end
        end
    end
    return out
end

local function select_all_trash(value)
    for _,item in ipairs(collect_trash()) do for _,path in ipairs(item.paths) do selected_trash[path]=value end end
    build_trash(true)
end

local function trash_action(kind,title)
    local plan,labels={},{}
    for _,item in ipairs(collect_trash()) do
        local chosen=false; for _,path in ipairs(item.paths) do if selected_trash[path] then chosen=true; plan[#plan+1]={kind=kind,arg=path} end end
        if chosen then labels[#labels+1]=item.title end
    end
    if #plan>0 then show_confirm(title,plan,labels,TRASH,{danger=kind~="RESTORE_ITEM",
        confirm=kind=="RESTORE_ITEM" and L("Restore","放回") or L("Delete forever","永久删除")}) end
end

build_trash=function(preserve_focus)
    local rows={}
    for _,item in ipairs(collect_trash()) do
        local key=item.paths[1]; local bytes=path_size(item.paths); local detail=item.detail
        if bytes>0 then detail=function() return kit.translate(item.detail).." · "..human(bytes) end end
        rows[#rows+1]=kit.checkbox(item.title,{
            id=key,detail=detail,checked=selected_trash[key],meta={paths=item.paths},
            on_change=function(value)
                for _,path in ipairs(item.paths) do selected_trash[path]=value end
            end,
        })
    end
    if #rows==0 then rows[1]=kit.info(L("Trash","回收站"),L("Trash is empty.","回收站是空的。")) end
    kit.set_page(TRASH,L("Trash","回收站"),rows,{preserve_focus=preserve_focus,
        sidebar_title=L("Quick Tools","快捷工具"),sidebar={
        button(dynamic_count("Restore (%d)","放回 (%d)",selected_trash),function() trash_action("RESTORE_ITEM",L("Restore selected items","放回所选项目")) end,{disabled=empty(selected_trash)}),
        button(dynamic_count("Delete forever (%d)","永久删除 (%d)",selected_trash),function() trash_action("DELETE_ITEM",L("Permanently delete selected items","永久删除所选项目")) end,{disabled=empty(selected_trash)}),
        button(L("Select all","全选"),function() select_all_trash(true) end,{half=true}),
        button(L("Select none","全不选"),function() select_all_trash(false) end,{half=true}),
        button(L("Back","返回"),function() kit.goto_page(HOME) end,{group="bottom"}),
    }})
end

build_env=function()
    local rows,details={},{}
    local function section(label) rows[#rows+1]=kit.section(label,{font_px=22}) end
    local function info(key,label,value,title,body)
        rows[#rows+1]=kit.textview(label,provided(value),{id=key,label_px=16,value_px=18})
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
        {"env:free",L("Free space","剩余空间"),human(env.free_bytes),L("Available storage","可用存储空间"),L("Free bytes on the storage used by ports. Uninstall, restore and Runtime operations may fail safely when there is not enough room.","端口所在存储空间的剩余容量。空间不足时，卸载、还原或 Runtime 操作可能会安全中止。")},
    }
    for _,item in ipairs(values) do info(item[1],item[2],item[3],item[4],item[5]) end

    local runtimes=report.runtimes.have or {}
    section({
        en=string.format("Installed Runtimes (%d)",#runtimes),
        zh=string.format("已安装 Runtime（%d）",#runtimes),
    })
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
    kit.set_page(ENV,L("Environment details","环境详情"),rows,{row_layout={mode="grid",columns=2},
        sidebar_title=L("Explanation","说明"),sidebar_details=details,sidebar={
        button(L("Back","返回"),function() kit.goto_page(HOME) end,{group="bottom"})
    }})
end

local port={
    theme={kind="app",background_dim=0.94},
    state={ui_lang="zh"},
    strings={working=L("Working…","处理中…")},
    on_home_cancel=show_exit_dialog,
    build_pages=function(k)
        for i=1,5 do k.add_page(L("Loading…","正在加载…"),{k.info("Port App Manager",L("Scanning…","正在扫描…"))}) end
    end,
    on_load=function()
        local ok,err=load_env()
        if not ok then
            kit.set_page(HOME,{en="Port App Manager",zh="Port App Manager"},{kit.info(L("Startup error","启动失败"),err)},
                {sidebar_title=L("Quick Tools","快捷工具"),
                sidebar_footer={lines={L("Developer: Bili 解腻Jenny","开发: Bili 解腻Jenny"),kit.CONTACT}},
                sidebar={button(L("Quit","退出"),show_exit_dialog,{group="bottom"})}})
            return
        end
        refresh_scan(); build_home()
        if env.apply_script and env.apply_script~="" then os.execute(shquote(env.apply_script).." --scan-sizes >/dev/null 2>&1 &") end
    end,
    update=function(dt)
        if not task then return end
        task.elapsed=task.elapsed+dt; task.poll=task.poll+dt
        if task.poll<0.25 then return end
        task.poll=0
        if not file_exists(env.plan_file) then finish_task()
        elseif task.elapsed>(task.timeout or 45) then
            kit.set_busy(false); task=nil
            status_message=L("Operation timed out; no further action was taken by the UI.","操作超时；界面未继续执行其他动作。")
            if confirm_return==RUNTIME then build_runtime(); kit.goto_page(RUNTIME)
            else build_home(); kit.goto_page(HOME) end
        end
    end,
}

kit.run(port)
