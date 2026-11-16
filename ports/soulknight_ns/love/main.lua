-- INPUT: Native backend preflights and the shared launcher components.
-- OUTPUT: Remembered Soul Knight NS graphics settings and literal Shell handoff.
-- POS: Title settings only; display ownership and runtime selection stay outside Lua.
local launcher = require("launcher")
local available = {vulkan=os.getenv("SOUL_NS_VULKAN_AVAILABLE")=="1", gles=os.getenv("SOUL_NS_GLES_AVAILABLE")=="1"}
local preferred = available.vulkan and "vulkan" or "gles"
local graphics = {}
function graphics.supports(api) return available[api] == true end
function graphics.resolve(state)
    return {api=state.graphics_api,available=available[state.graphics_api]==true,render_scale=state.render_scale,features={},controls={}}
end
function graphics.validate(state)
    return available[state.graphics_api]==true, {en="Selected graphics backend is unavailable.",zh="所选图形后端不可用。"}
end
launcher.define {
    id="soulknight_ns", title={en="Soul Knight NS",zh="元气骑士_ns"},
    credits={{"credit_dev","ChillyRoom"},{"credit_porter","Bili 解腻Jenny"}},
    fields={
        launcher.select {key="graphics_api",label={en="Graphics Backend:",zh="图形后端:"},default=preferred,env="SOUL_NS_BACKEND",graphics=graphics,
            disabled_values={vulkan=not available.vulkan,gles=not available.gles},
            options={{"vulkan","Vulkan"},{"gles","OpenGL ES"}}},
        launcher.render_scale {default="100",env="SOUL_NS_RENDER_SCALE",options={
            {"100","100%"}, {"75","75%"}, {"50","50%"}}},
        launcher.select {key="aspect",label={en="Screen Ratio:",zh="画面比例:"},default="auto",env="SOUL_NS_ASPECT",
            options={{"auto",{en="Match screen",zh="跟随屏幕"}},{"4:3","4:3"},{"16:9","16:9"}}},
    },
    pages={{title="title",rows={"graphics_api","render_scale","aspect"},actions={"start","quit"}}},
}
