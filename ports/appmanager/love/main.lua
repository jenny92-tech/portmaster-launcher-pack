local kit = require("kit")
local json = require("json")
local scanner = require("scan")

local function L(en,zh) return {en=en,zh=zh} end
local function join(parts,sep) return table.concat(parts,sep or " · ") end
local function stem(name) return (name:gsub("%.[^.]+$","")) end
local function shquote(value) return "'"..tostring(value):gsub("'","'\\''").."'" end

local HOME,JUNK,TRASH,ENV = 1,2,3,4
local env,report,size_map = {},nil,{}
local selected_home,selected_junk,selected_trash = {},{},{}
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
    report=scanner.run(env)
    selected_home,selected_junk,selected_trash={},{},{}
    dump_debug()
end

local function missing_runtime(script)
    local out={}
    for _,item in ipairs(report.runtimes.missing or {}) do
        for _,user in ipairs(item.users or {}) do if user==script then out[#out+1]=item.name end end
    end
    table.sort(out); return table.concat(out,", ")
end

local build_home,build_junk,build_trash,build_env,collect_trash

local function show_exit_dialog()
    kit.dialog({
        title=L("Exit APP Manager?","退出 APP Manager？"),
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
    load_env(); refresh_scan(); build_home()
    if confirm_return==TRASH then build_trash(); kit.goto_page(TRASH)
    elseif confirm_return==JUNK then build_junk(); kit.goto_page(JUNK)
    else kit.goto_page(HOME) end
end

local function start_apply()
    if not confirm_plan or #confirm_plan==0 then return end
    if not write_plan(confirm_plan) or not env.apply_script or env.apply_script=="" then
        status_message=L("Cannot start the privileged helper.","无法启动提权操作助手。")
        kit.goto_page(confirm_return); return
    end
    kit.set_busy(true,L("Working…","处理中…"))
    os.execute(shquote(env.apply_script).." --apply-plan >/dev/null 2>&1 &")
    task={elapsed=0,poll=0}
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
    kit.set_page(HOME,{en="APP Manager",zh="APP Manager"},rows,{
        preserve_focus=preserve_focus,
        sidebar_title=L("Quick Tools","快捷工具"),
        header_action=button(L("Details","详情"),function() build_env(); kit.goto_page(ENV) end),
        sidebar={
        button(dynamic_count("Uninstall (%d)","卸载 (%d)",selected_home),uninstall_selected,{disabled=empty(selected_home)}),
        button(L("Select all","全选"),function() select_all_home(true) end,{half=true}),
        button(L("Select none","全不选"),function() select_all_home(false) end,{half=true}),
        button(function() return kit.get_state().ui_lang=="zh" and string.format("残留清理 (%d)",junk_count) or string.format("Leftovers (%d)",junk_count) end,
            function() build_junk(); kit.goto_page(JUNK) end),
        button(function() return kit.get_state().ui_lang=="zh" and string.format("回收站 (%d)",trash_count) or string.format("Trash (%d)",trash_count) end,
            function() build_trash(); kit.goto_page(TRASH) end),
        button(L("Quit","退出"),show_exit_dialog,{group="bottom"}),
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
    local rows={}
    local function section(label) rows[#rows+1]=kit.section(label) end
    local function info(label,value) rows[#rows+1]=kit.textview(label,provided(value)) end
    section(L("Key paths","关键路径"))
    info(L("SH folder ($0 folder)","SH 目录（$0 目录）"),env.scripts_dir)
    info(L("Data folder (directory/ports)","Data 目录（directory/ports）"),env.gamedirs_dir)
    info(L("PortMaster folder (controlfolder)","PortMaster 目录（controlfolder）"),env.controlfolder)
    info(L("Runtime folder (controlfolder/libs)","Runtime 目录（controlfolder/libs）"),env.libs_dir)

    local resolution=(env.display_width and env.display_width~="" and env.display_height and env.display_height~="")
        and tostring(env.display_width).."×"..tostring(env.display_height) or nil
    section(L("Environment values","环境变量"))
    local values={
        {L("Firmware (CFW_NAME)","固件（CFW_NAME）"),env.cfw},
        {L("Display resolution","显示分辨率"),resolution},
        {L("Architecture (DEVICE_ARCH)","设备架构（DEVICE_ARCH）"),env.device_arch},
        {L("Controller ID (DEVICE)","手柄 ID（DEVICE）"),env.device},
        {L("Device profile (param_device)","设备配置（param_device）"),env.param_device},
        {L("Analog sticks (ANALOGSTICKS)","摇杆数（ANALOGSTICKS）"),env.analog_sticks},
        {L("Low resolution mode (LOWRES)","低分辨率（LOWRES）"),env.lowres},
        {L("Display terminal (CUR_TTY)","显示终端（CUR_TTY）"),env.cur_tty},
        {L("Controller database (SDL_GAMECONTROLLERCONFIG_FILE)","手柄库（SDL_GAMECONTROLLERCONFIG_FILE）"),env.sdl_controller_file},
        {L("Privilege helper (ESUDO)","提权命令（ESUDO）"),env.esudo},
        {L("Controller helper (GPTOKEYB)","手柄映射（GPTOKEYB）"),env.gptokeyb},
        {L("Command search path (PATH)","命令搜索（PATH）"),env.path},
        {L("Library search path (LD_LIBRARY_PATH)","动态库搜索（LD_LIBRARY_PATH）"),env.ld_library_path},
        {L("Config root (XDG_CONFIG_HOME)","配置根（XDG_CONFIG_HOME）"),env.xdg_config_home},
        {L("Data root (XDG_DATA_HOME)","数据根（XDG_DATA_HOME）"),env.xdg_data_home},
        {L("Free space","剩余空间"),human(env.free_bytes)},
    }
    for _,item in ipairs(values) do info(item[1],item[2]) end

    section(L("Installed Runtimes","已安装 Runtime"))
    local runtimes=report.runtimes.have or {}
    if #runtimes==0 then info("Runtime",L("None installed","未安装"))
    else for index,name in ipairs(runtimes) do info("Runtime "..index.."/"..#runtimes,name) end end
    kit.set_page(ENV,L("Environment details","环境详情"),rows,{row_layout={mode="grid",columns=2},
        sidebar_title=L("Details","详情"),sidebar={
        button(L("Back","返回"),function() kit.goto_page(HOME) end,{group="bottom"})
    }})
end

local port={
    theme={kind="app",background_dim=0.94},
    state={ui_lang="zh"},
    strings={working=L("Working…","处理中…")},
    on_home_cancel=show_exit_dialog,
    build_pages=function(k)
        for i=1,4 do k.add_page(L("Loading…","正在加载…"),{k.info(L("APP Manager","APP 管理器"),L("Scanning…","正在扫描…"))}) end
    end,
    on_load=function()
        local ok,err=load_env()
        if not ok then
            kit.set_page(HOME,{en="APP Manager",zh="APP Manager"},{kit.info(L("Startup error","启动失败"),err)},
                {sidebar_title=L("Quick Tools","快捷工具"),sidebar={button(L("Quit","退出"),show_exit_dialog,{group="bottom"})}})
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
        elseif task.elapsed>45 then
            kit.set_busy(false); task=nil
            status_message=L("Operation timed out; no further action was taken by the UI.","操作超时；界面未继续执行其他动作。")
            build_home(); kit.goto_page(HOME)
        end
    end,
}

kit.run(port)
