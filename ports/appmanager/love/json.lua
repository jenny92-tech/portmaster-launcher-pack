-- Small JSON codec for APP Manager's shell-generated state files.
local json = {}

local function skip(s,i)
    while s:sub(i,i):match("%s") do i=i+1 end
    return i
end

local function decode_string(s,i)
    i=i+1; local out={}
    while i<=#s do
        local c=s:sub(i,i)
        if c=='"' then return table.concat(out),i+1 end
        if c=='\\' then
            local e=s:sub(i+1,i+1)
            local map={['"']='"',['\\']='\\',['/']='/',b='\b',f='\f',n='\n',r='\r',t='\t'}
            if map[e] then out[#out+1]=map[e]; i=i+2
            elseif e=='u' then
                local n=tonumber(s:sub(i+2,i+5),16) or 63
                if utf8 and utf8.char then out[#out+1]=utf8.char(n) else out[#out+1]='?' end
                i=i+6
            else error("bad JSON escape at "..i) end
        else out[#out+1]=c; i=i+1 end
    end
    error("unterminated JSON string")
end

local decode_value
local function decode_array(s,i)
    local out={}; i=skip(s,i+1)
    if s:sub(i,i)==']' then return out,i+1 end
    while true do
        local value; value,i=decode_value(s,i); out[#out+1]=value; i=skip(s,i)
        local c=s:sub(i,i)
        if c==']' then return out,i+1 end
        if c~=',' then error("expected , or ] at "..i) end
        i=skip(s,i+1)
    end
end

local function decode_object(s,i)
    local out={}; i=skip(s,i+1)
    if s:sub(i,i)=='}' then return out,i+1 end
    while true do
        if s:sub(i,i)~='"' then error("expected object key at "..i) end
        local key; key,i=decode_string(s,i); i=skip(s,i)
        if s:sub(i,i)~=':' then error("expected : at "..i) end
        local value; value,i=decode_value(s,skip(s,i+1)); out[key]=value; i=skip(s,i)
        local c=s:sub(i,i)
        if c=='}' then return out,i+1 end
        if c~=',' then error("expected , or } at "..i) end
        i=skip(s,i+1)
    end
end

decode_value=function(s,i)
    i=skip(s,i); local c=s:sub(i,i)
    if c=='"' then return decode_string(s,i) end
    if c=='{' then return decode_object(s,i) end
    if c=='[' then return decode_array(s,i) end
    local token=s:match("^[-+%d%.eE]+",i)
    if token then return tonumber(token),i+#token end
    if s:sub(i,i+3)=='true' then return true,i+4 end
    if s:sub(i,i+4)=='false' then return false,i+5 end
    if s:sub(i,i+3)=='null' then return nil,i+4 end
    error("invalid JSON at "..i)
end

function json.decode(s)
    local value,i=decode_value(s,1)
    if skip(s,i)<=#s then error("trailing JSON") end
    return value
end

local function quote(s)
    return '"'..tostring(s):gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n'):gsub('\r','\\r'):gsub('\t','\\t')..'"'
end

local function is_array(t)
    local n=0
    for k in pairs(t) do if type(k)~='number' then return false end; if k>n then n=k end end
    for i=1,n do if t[i]==nil then return false end end
    return true,n
end

local function encode(value,seen)
    local kind=type(value)
    if kind=='nil' then return 'null' end
    if kind=='boolean' or kind=='number' then return tostring(value) end
    if kind=='string' then return quote(value) end
    if kind~='table' then return quote(tostring(value)) end
    if seen[value] then error('JSON cycle') end
    seen[value]=true
    local array,n=is_array(value); local out={}
    if array then
        for i=1,n do out[#out+1]=encode(value[i],seen) end
        seen[value]=nil; return '['..table.concat(out,',')..']'
    end
    local keys={}; for k in pairs(value) do keys[#keys+1]=tostring(k) end; table.sort(keys)
    for _,k in ipairs(keys) do out[#out+1]=quote(k)..':'..encode(value[k],seen) end
    seen[value]=nil; return '{'..table.concat(out,',')..'}'
end

function json.encode(value) return encode(value,{}) end
return json
