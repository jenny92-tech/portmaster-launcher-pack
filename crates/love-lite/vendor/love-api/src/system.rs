use mlua::prelude::*;
use std::sync::Arc;

use crate::state::SharedState;

pub fn register(lua: &Lua, love: &LuaTable, _state: Arc<SharedState>) -> LuaResult<()> {
    let sys = lua.create_table()?;

    // Match LÖVE's public OS names without game-specific behavior.
    sys.set(
        "getOS",
        lua.create_function(|_, ()| {
            Ok(match std::env::consts::OS {
                "macos" => "OS X",
                "windows" => "Windows",
                "linux" => "Linux",
                other => other,
            })
        })?,
    )?;

    // love.system.getClipboardText()
    sys.set("getClipboardText", lua.create_function(|_, ()| Ok(""))?)?;

    // love.system.setClipboardText(text)
    sys.set(
        "setClipboardText",
        lua.create_function(|_, _text: String| Ok(()))?,
    )?;

    // love.system.openURL(url)
    sys.set("openURL", lua.create_function(|_, _url: String| Ok(false))?)?;

    love.set("system", sys)?;
    Ok(())
}
