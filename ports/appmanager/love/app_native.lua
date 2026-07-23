local Native = {}

function Native.new()
    -- This module is the only Lua code allowed to cross the Rust boundary.
    -- Callers keep small business methods while response validation stays here.
    assert(type(appmanager)=="table","APP Manager Rust service is unavailable")
    assert(type(appmanager.request)=="function","APP Manager Rust request bridge is unavailable")
    local self={}

    local function fail(method,message)
        local text="[PAM bridge] "..tostring(method)..": "..tostring(message)
        print(text)
        error(text,0)
    end

    local function request(method,payload)
        local ok,response=pcall(appmanager.request,method,payload)
        if not ok then fail(method,"native call failed: "..tostring(response)) end
        if type(response)~="table" then
            fail(method,"invalid response type: "..type(response))
        end
        if response.ok~=true then
            local detail=response.error
            if type(detail)=="table" then
                detail=tostring(detail.code or "request_failed")..": "..tostring(detail.message or "")
            else detail="missing error details" end
            fail(method,detail)
        end
        return response.value
    end

    function self.snapshot()
        local value=request("snapshot")
        if type(value)~="table" then fail("snapshot","expected table, got "..type(value)) end
        return value
    end

    function self.start(kind,payload)
        local body={kind=kind}
        if kind=="apply" then body.actions=payload or {} end
        local value=request("start",body)
        if type(value)~="number" or value<1 or value%1~=0 then
            fail("start","expected positive integer task id, got "..type(value))
        end
        return value
    end

    function self.poll()
        local value=request("poll")
        if value==nil then return nil end
        if type(value)~="table" then fail("poll","expected event table or nil, got "..type(value)) end
        if type(value.task_id)~="number" or value.task_id<1 or value.task_id%1~=0 then
            fail("poll","event has invalid task id")
        end
        if type(value.kind)~="string" or type(value.status)~="string" then
            fail("poll","event kind or status is invalid")
        end
        if value.status~="progress" and value.status~="complete" and value.status~="error" then
            fail("poll","event has unsupported status: "..value.status)
        end
        if value.data~=nil and type(value.data)~="table" then
            fail("poll","event data must be a table")
        end
        return value
    end

    function self.cancel()
        local value=request("cancel")
        if value~=true then fail("cancel","expected true acknowledgement") end
        return true
    end

    return self
end

return Native
