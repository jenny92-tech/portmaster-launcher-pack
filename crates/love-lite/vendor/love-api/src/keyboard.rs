// INPUT:  mlua 与 SharedState 的宿主按键状态
// OUTPUT: register() 安装 love.keyboard 查询与兼容接口
// POS:    将外部输入后端维护的键盘状态提供给 Lua 前端
use mlua::prelude::*;
use std::sync::Arc;

use crate::state::SharedState;

pub fn register(lua: &Lua, love: &LuaTable, state: Arc<SharedState>) -> LuaResult<()> {
    let kb = lua.create_table()?;

    // love.keyboard.isDown(key, ...) -> bool
    {
        let s = Arc::clone(&state);
        kb.set(
            "isDown",
            lua.create_function(move |_, keys: LuaMultiValue| {
                let keys_down = s.keys_down.read();
                for key in keys.iter() {
                    if let LuaValue::String(k) = key {
                        if keys_down.contains(&*k.to_string_lossy()) {
                            return Ok(true);
                        }
                    }
                }
                Ok(false)
            })?,
        )?;
    }

    // love.keyboard.setKeyRepeat(enable)
    kb.set(
        "setKeyRepeat",
        lua.create_function(|_, _enable: bool| Ok(()))?,
    )?;

    // love.keyboard.hasKeyRepeat()
    kb.set("hasKeyRepeat", lua.create_function(|_, ()| Ok(false))?)?;

    // love.keyboard.isScancodeDown(scancode, ...) -> bool
    {
        let s = Arc::clone(&state);
        kb.set(
            "isScancodeDown",
            lua.create_function(move |_, keys: LuaMultiValue| {
                let keys_down = s.keys_down.read();
                for key in keys.iter() {
                    if let LuaValue::String(k) = key {
                        if keys_down.contains(&*k.to_string_lossy()) {
                            return Ok(true);
                        }
                    }
                }
                Ok(false)
            })?,
        )?;
    }

    love.set("keyboard", kb)?;
    Ok(())
}
