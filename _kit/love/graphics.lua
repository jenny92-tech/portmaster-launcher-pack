-- INPUT:  compiled runtime tokens, a completed environment probe and per-title defaults
-- OUTPUT: supported selections, disabled controls and validated launch values
-- POS:    cold capability resolver shared by Unity menus; never probes in the draw loop
local graphics = {}
local known = {sdl2=true,gles=true,["gles-scale"]=true,["gles-sharp"]=true,
    ["gles-shader"]=true,["gles-texture"]=true,vulkan=true,["vulkan-scale"]=true,["vulkan-linear"]=true}
local function text(zh,en) return {zh=zh,en=en} end

function graphics.detect(allow_vulkan,preferred)
    local raw=os.getenv("PORTKIT_GRAPHICS_FEATURES")
    local model={features={},allow_vulkan=allow_vulkan==true,preferred=preferred or "gles"}
    assert(model.preferred=="gles" or model.preferred=="vulkan","invalid title backend")
    if raw==nil then raw="sdl2,gles,gles-scale,gles-sharp" end
    if #raw<=2048 and not raw:find("[^a-z0-9,%-]") then
        for token in raw:gmatch("[^,]+") do if known[token] then model.features[token]=true end end
    end
    if not model.features.sdl2 then model.features={} end
    local vulkan_environment=os.getenv("PORTKIT_VULKAN_AVAILABLE")=="1"
        and os.getenv("PORTKIT_VULKAN_PLATFORM_SUPPORTED")=="1"
    function model.supports(api)
        if api=="gles" then return model.features.gles==true end
        return api=="vulkan" and model.allow_vulkan and model.features.vulkan==true
            and model.features["vulkan-linear"]==true and vulkan_environment
    end
    function model.default_api()
        if model.supports(model.preferred) then return model.preferred end
        if model.supports("gles") then return "gles" end
        if model.supports("vulkan") then return "vulkan" end
        return model.preferred
    end
    function model.resolve(state)
        local api=state.graphics_api or model.default_api()
        local result={api=api,available=model.supports(api)}
        local scale=model.features[api.."-scale"]==true
        result.render_scale=scale and (state.render_scale or "config") or "100"
        result.controls={
            render_scale={disabled=not scale},
        }
        result.features={texture_limits=api=="gles" and model.features["gles-texture"]==true,
            shader_policy=api=="gles" and model.features["gles-shader"]==true}
        return result
    end
    function model.validate(state)
        if not model.resolve(state).available then
            return false,text("所选图形后端不可用，请重新选择。","The selected graphics backend is unavailable; choose another backend.")
        end
        return true
    end
    return model
end
return graphics
