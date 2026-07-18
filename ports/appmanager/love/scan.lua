-- Read-only PortMaster scanner. Destructive actions are deliberately absent;
-- launcher.sh validates and applies every selected path.
local scan = {}
local list_provider

local WORD_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"

local function shquote(s) return "'"..tostring(s):gsub("'", "'\\''").."'" end
local function basename(path) return path:match("([^/]+)/*$") or path end
local function trim(s) return (s:gsub("^%s+",""):gsub("%s+$","")) end
local function contains(list,value) for _,v in ipairs(list or {}) do if v==value then return true end end return false end

local function list(path,want_dirs)
    if list_provider then return list_provider(path,want_dirs) or {} end
    local out={}; if not path or path=="" then return out end
    -- Do not follow symlinks: a symlink to a directory is managed as one file,
    -- never traversed. `! -type d` also keeps other direct non-directory items.
    local kind=want_dirs==nil and "" or (want_dirs and " -type d" or " ! -type d")
    local p=io.popen("find "..shquote(path).." -mindepth 1 -maxdepth 1"..kind.." -print0 2>/dev/null","r")
    if not p then return out end
    local data=p:read("*a") or ""; p:close()
    for full in data:gmatch("([^%z]+)%z") do
        out[#out+1]={name=basename(full),path=full,is_dir=want_dirs==true}
    end
    table.sort(out,function(a,b) return a.name:lower()<b.name:lower() end)
    return out
end

function scan.set_list_provider(provider)
    list_provider=provider
end

function scan.entries(path)
    local dirs=list(path,true); local files=list(path,false)
    for _,v in ipairs(files) do dirs[#dirs+1]=v end
    table.sort(dirs,function(a,b) return a.name:lower()<b.name:lower() end)
    return dirs
end

local function read(path)
    local f=io.open(path,"rb"); if not f then return "" end
    local text=f:read("*a") or ""; f:close(); return text
end

local function unquote(s)
    s=trim(s)
    if #s>=2 then
        local a,b=s:sub(1,1),s:sub(-1)
        if (a=='"' and b=='"') or (a=="'" and b=="'") then return s:sub(2,-2) end
    end
    return s
end

local function collect_vars(text,seed)
    local vars={}; for k,v in pairs(seed or {}) do vars[k]=v end
    for line in (text.."\n"):gmatch("(.-)\n") do
        local name,val=line:match("^%s*export%s+([A-Za-z_][A-Za-z0-9_]*)=(.+)$")
        if not name then name,val=line:match("^%s*([A-Za-z_][A-Za-z0-9_]*)=(.+)$") end
        if name and not vars[name] then
            val=trim((val:gsub("%s+#.*$","")):match("^(.-);%s*") or val:gsub("%s+#.*$",""))
            if not val:match("^%$%(") and not val:match("^`") then vars[name]=unquote(val) end
        end
    end
    return vars
end

local function expand(value,vars)
    local out=value
    for _=1,6 do
        local previous=out
        out=out:gsub("%${([A-Za-z_][A-Za-z0-9_]*)}",function(name) return vars[name] or " " end)
        out=out:gsub("%$([A-Za-z_][A-Za-z0-9_]*)",function(name) return vars[name] or " " end)
        if out==previous then break end
    end
    return out
end

local function dir_from_path(path)
    path=path:gsub("\\","/"):gsub("/+$","")
    local parts={}
    for part in path:gmatch("[^/]+") do if not part:find(" ",1,true) then parts[#parts+1]=part end end
    for i,part in ipairs(parts) do if part=="ports" and parts[i+1] then return parts[i+1] end end
    return parts[#parts] or ""
end

local function plain_name(name)
    return not name:find("[$()`*?'\" |;&=]")
end

local function tokens(value)
    local out={}; local i=1
    while i<=#value do
        while value:sub(i,i):match("%s") do i=i+1 end
        if i>#value then break end
        local q=value:sub(i,i)
        if q=='"' or q=="'" then
            local j=value:find(q,i+1,true) or (#value+1); out[#out+1]=value:sub(i+1,j-1); i=j+1
        else
            local j=value:find("%s",i) or (#value+1); out[#out+1]=value:sub(i,j-1); i=j
        end
    end
    return out
end

local function port_dir_of(text,real_dirs,seed,ignore_dirs)
    local vars=collect_vars(text,seed); local candidates={}
    for _,key in ipairs({"GAMEDIR","gamedir","rundir","game_dir"}) do if vars[key] then candidates[#candidates+1]=vars[key] end end
    for line in (text.."\n"):gmatch("(.-)\n") do
        local cd=line:match("^%s*cd%s+(.+)$")
        if cd then candidates[#candidates+1]=unquote(trim(cd:gsub("%s*||.*$",""))) end
        local values=line:match("^%s*for%s+[A-Za-z_][A-Za-z0-9_]*%s+in%s+(.+)%s*;?%s*do?%s*$")
        if values then for _,value in ipairs(tokens(values)) do candidates[#candidates+1]=value end end
    end
    local claimed=""
    for _,candidate in ipairs(candidates) do
        local path=expand(candidate,vars); local name=dir_from_path(path)
        if name~="" and not contains(ignore_dirs,name) then
            if real_dirs[name] then return {dir=name,exists=true} end
            if claimed=="" and path:find("/ports/",1,true) and plain_name(name) then claimed=name end
        end
    end
    return {dir=claimed,exists=false}
end

local function mentions(text,name)
    local from=1
    while true do
        local i,j=text:find(name,from,true); if not i then return false end
        local before=i==1 or not WORD_CHARS:find(text:sub(i-1,i-1),1,true)
        local after=j==#text or not WORD_CHARS:find(text:sub(j+1,j+1),1,true)
        if before and after then return true end
        from=i+1
    end
end

local function runtimes_of(text)
    local out,seen={},{}
    for line in (text.."\n"):gmatch("(.-)\n") do
        if not trim(line):match("^#") then
            local name,value=line:match("^%s*export%s+([A-Za-z_][A-Za-z0-9_]*)=[\"']?([A-Za-z0-9_.+%-]+)")
            if not name then name,value=line:match("^%s*([A-Za-z_][A-Za-z0-9_]*)=[\"']?([A-Za-z0-9_.+%-]+)") end
            if name and (name=="runtime" or name:match("_runtime$")) and not seen[value] then
                seen[value]=true; out[#out+1]=value
            end
        end
    end
    return out
end

local function runtime_of(text)
    return runtimes_of(text)[1] or ""
end

-- Runtime presence alone is not enough: an interrupted/manual copy can leave a
-- file with the canonical name that PortMaster will still try to mount.  The
-- The SquashFS magic is a cheap local sanity check. Current size and checksum
-- come from online PortMaster release metadata only when a repair starts, so a
-- stale APP build cannot label a newer official Runtime as outdated.
local function runtime_file_health(path,expected_bytes)
    local f=path and io.open(path,"rb")
    if not f then return "missing",0 end
    local magic=f:read(4) or ""
    local bytes=f:seek("end") or 0
    f:close()
    if magic~="hsqs" then return "invalid_magic",bytes end
    expected_bytes=tonumber(expected_bytes)
    if expected_bytes and expected_bytes>0 and bytes~=expected_bytes then
        return "size_mismatch",bytes
    end
    return "healthy",bytes
end

local function stem(name) return (name:gsub("%.[^.]+$","")) end

function scan.run(env)
    local real_dirs={}; for _,entry in ipairs(list(env.gamedirs_dir,true)) do if not contains(env.ignore_dirs,entry.name) then real_dirs[entry.name]=true end end
    local images=list(env.images_dir,false); local scripts={}; local texts={}
    for _,entry in ipairs(list(env.scripts_dir,false)) do
        if entry.name:lower():match("%.sh$") and not contains(env.ignore_scripts,entry.name) then scripts[#scripts+1]=entry.name end
    end
    table.sort(scripts)
    for _,name in ipairs(scripts) do texts[name]=read(env.scripts_dir.."/"..name) end
    if env.self_port and env.self_port~="" then
        local keep={}; for _,name in ipairs(scripts) do if not mentions(texts[name],env.self_port) then keep[#keep+1]=name end end; scripts=keep
    end

    local image_of={}; for _,name in ipairs(scripts) do
        image_of[name]={}; local wanted=stem(name):lower()
        for _,img in ipairs(images) do if stem(img.name):lower()==wanted then image_of[name][#image_of[name]+1]=img.name end end
    end
    local seed={directory=env.directory or "",controlfolder=env.controlfolder or "",HOME=env.home or "/root"}
    local ports,refcount,dead={},{},{}
    for _,name in ipairs(scripts) do
        local result=port_dir_of(texts[name],real_dirs,seed,env.ignore_dirs)
        if result.dir~="" and result.exists then refcount[result.dir]=(refcount[result.dir] or 0)+1
        elseif result.dir~="" then dead[#dead+1]={script=name,missing_dir=result.dir} end
        local runtimes=runtimes_of(texts[name])
        ports[#ports+1]={script=name,dir=result.exists and result.dir or "",claimed_dir=result.dir,dir_exists=result.exists,
            images=image_of[name],runtime=runtimes[1] or "",runtimes=runtimes}
    end
    local orphan_dirs={}
    for name in pairs(real_dirs) do
        local seen=false; for _,script in ipairs(scripts) do if mentions(texts[script],name) then seen=true; break end end
        if not seen then orphan_dirs[#orphan_dirs+1]=name end
    end
    table.sort(orphan_dirs)
    local script_stems={}; for _,name in ipairs(scripts) do script_stems[stem(name):lower()]=true end
    local orphan_images={}; for _,img in ipairs(images) do if not script_stems[stem(img.name):lower()] then orphan_images[#orphan_images+1]=img.name end end
    table.sort(orphan_images)
    local have={}; for _,entry in ipairs(list(env.libs_dir,false)) do local name=entry.name:match("^(.-)%.squashfs$"); if name then have[name]=true end end
    local need={}; for _,p in ipairs(ports) do
        for _,runtime in ipairs(p.runtimes or {}) do
            need[runtime]=need[runtime] or {}; need[runtime][#need[runtime]+1]=p.script
        end
    end
    local missing={}; for name,users in pairs(need) do if not have[name] then missing[#missing+1]={name=name,users=users} end end
    table.sort(missing,function(a,b) return a.name<b.name end)
    local have_list={}; for name in pairs(have) do have_list[#have_list+1]=name end; table.sort(have_list)
    return {ports=ports,refcount=refcount,orphan_dirs=orphan_dirs,orphan_images=orphan_images,
        dead_scripts=dead,runtimes={have=have_list,need=need,missing=missing}}
end

scan.read=read
scan.basename=basename
scan.runtime_file_health=runtime_file_health
scan._test={port_dir_of=port_dir_of,mentions=mentions,runtime_of=runtime_of,runtimes_of=runtimes_of,
    runtime_file_health=runtime_file_health,collect_vars=collect_vars,expand=expand}
return scan
