-- Read-only PortMaster scanner. Destructive actions are deliberately absent;
-- launcher.sh validates and applies every selected path.
local scan = {}
local list_provider
local list_cache,read_cache={},{ }

local WORD_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-"

local function shquote(s) return "'"..tostring(s):gsub("'", "'\\''").."'" end
local function basename(path) return path:match("([^/]+)/*$") or path end
local function trim(s) return (s:gsub("^%s+",""):gsub("%s+$","")) end
local function contains(list,value) for _,v in ipairs(list or {}) do if v==value then return true end end return false end

local function list_all(path)
    local key=tostring(path or "")
    if list_cache[key] then return list_cache[key] end
    if list_provider then
        local provided=list_provider(path,nil) or {}
        list_cache[key]=provided
        return provided
    end
    local out={}; if not path or path=="" then return out end
    -- Enumerate each SD-card directory once. Three shell globs include normal
    -- and hidden entries; classification happens in the same pass. Symlinks
    -- to directories remain managed as files and are never traversed.
    local root=shquote(path)
    local command="for item in "..root.."/* "..root.."/.[!.]* "..root.."/..?*; do "..
        "[ -e \"$item\" ] || [ -L \"$item\" ] || continue; "..
        "if [ -d \"$item\" ] && [ ! -L \"$item\" ]; then "..
        "printf 'd\\000%s\\000' \"$item\"; else printf 'f\\000%s\\000' \"$item\"; fi; done"
    local p=io.popen(command.." 2>/dev/null","r")
    if not p then return out end
    local data=p:read("*a") or ""; p:close()
    for kind,full in data:gmatch("([df])%z([^%z]+)%z") do
        out[#out+1]={name=basename(full),path=full,is_dir=kind=="d"}
    end
    table.sort(out,function(a,b) return a.name:lower()<b.name:lower() end)
    list_cache[key]=out
    return out
end

local function list(path,want_dirs)
    local out={}
    for _,entry in ipairs(list_all(path)) do
        if want_dirs==nil or entry.is_dir==want_dirs then out[#out+1]=entry end
    end
    return out
end

function scan.set_list_provider(provider)
    list_provider=provider
    list_cache={}; read_cache={}
end

function scan.invalidate(...)
    local count=select("#",...)
    if count==0 then list_cache={}; read_cache={}; return end
    local roots={}
    for i=1,count do
        local root=select(i,...)
        if root and root~="" then roots[#roots+1]=tostring(root):gsub("/+$","") end
    end
    local function affected(path)
        for _,root in ipairs(roots) do
            if path==root or path:sub(1,#root+1)==root.."/" then return true end
        end
        return false
    end
    for path in pairs(list_cache) do
        if affected(path) then list_cache[path]=nil end
    end
    for path in pairs(read_cache) do if affected(path) then read_cache[path]=nil end end
end

function scan.entries(path)
    local dirs=list(path,true); local files=list(path,false)
    local out={}
    for _,v in ipairs(dirs) do out[#out+1]=v end
    for _,v in ipairs(files) do out[#out+1]=v end
    table.sort(out,function(a,b) return a.name:lower()<b.name:lower() end)
    return out
end

local function read(path)
    if read_cache[path]~=nil then return read_cache[path] end
    local f=io.open(path,"rb"); if not f then return "" end
    local text=f:read("*a") or ""; f:close(); read_cache[path]=text; return text
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
local function is_image(name)
    local lower=(name or ""):lower()
    return lower:match("%.png$") or lower:match("%.jpe?g$") or lower:match("%.webp$")
end

function scan.run(env)
    local real_dirs={}; for _,entry in ipairs(list(env.gamedirs_dir,true)) do if not contains(env.ignore_dirs,entry.name) then real_dirs[entry.name]=true end end
    local images,scripts,texts,all_script_stems,seen_images={},{},{},{},{}
    local script_entries=list(env.scripts_dir,false)
    for _,entry in ipairs(script_entries) do
        if entry.name:lower():match("%.sh$") then
            all_script_stems[stem(entry.name)]=true
            if not contains(env.ignore_scripts,entry.name) then scripts[#scripts+1]=entry.name end
        elseif env.scan_script_images==true and is_image(entry.name) then
            images[#images+1]=entry; seen_images[entry.path]=true
        end
    end
    if env.images_dir and env.images_dir~="" and env.images_dir~=env.scripts_dir then
        for _,entry in ipairs(list(env.images_dir,false)) do
            if is_image(entry.name) and not seen_images[entry.path] then
                images[#images+1]=entry; seen_images[entry.path]=true
            end
        end
    end
    table.sort(images,function(a,b) return a.path:lower()<b.path:lower() end)
    table.sort(scripts)
    for _,name in ipairs(scripts) do texts[name]=read(env.scripts_dir.."/"..name) end
    if env.self_port and env.self_port~="" then
        local keep={}; for _,name in ipairs(scripts) do if not mentions(texts[name],env.self_port) then keep[#keep+1]=name end end; scripts=keep
    end

    local images_by_stem={}
    for _,img in ipairs(images) do
        local key=stem(img.name)
        images_by_stem[key]=images_by_stem[key] or {}
        images_by_stem[key][#images_by_stem[key]+1]=img
    end
    local image_of={}; for _,name in ipairs(scripts) do
        image_of[name]=images_by_stem[stem(name)] or {}
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
    -- Build the conservative reference index once. The old nested loop read
    -- every SH string once per data directory (O(directories × scripts)).
    local referenced_dirs={}
    for _,script in ipairs(scripts) do
        for token in texts[script]:gmatch("[A-Za-z0-9_.%-]+") do
            if real_dirs[token] then referenced_dirs[token]=true end
        end
    end
    local orphan_dirs={}
    for name in pairs(real_dirs) do
        local seen=referenced_dirs[name]==true
        -- Preserve exact support for unusual Unicode/space directory names;
        -- normal Port names stay on the linear token-index path above.
        if not seen and name:find("[^A-Za-z0-9_.%-]") then
            for _,script in ipairs(scripts) do if mentions(texts[script],name) then seen=true; break end end
        end
        if not seen then orphan_dirs[#orphan_dirs+1]=name end
    end
    table.sort(orphan_dirs)
    local orphan_images={}; for _,img in ipairs(images) do if not all_script_stems[stem(img.name)] then orphan_images[#orphan_images+1]=img end end
    table.sort(orphan_images,function(a,b) return a.path:lower()<b.path:lower() end)
    local need={}; for _,p in ipairs(ports) do
        for _,runtime in ipairs(p.runtimes or {}) do
            need[runtime]=need[runtime] or {}; need[runtime][#need[runtime]+1]=p.script
        end
    end
    return {ports=ports,refcount=refcount,orphan_dirs=orphan_dirs,orphan_images=orphan_images,
        dead_scripts=dead,runtimes={need=need}}
end

scan.read=read
scan.basename=basename
scan.runtime_file_health=runtime_file_health
scan._test={port_dir_of=port_dir_of,mentions=mentions,runtime_of=runtime_of,runtimes_of=runtimes_of,
    runtime_file_health=runtime_file_health,collect_vars=collect_vars,expand=expand}
return scan
