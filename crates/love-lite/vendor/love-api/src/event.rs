use mlua::prelude::*;
use std::sync::Arc;

use crate::state::{LoveEvent, SharedState};

pub fn register(lua: &Lua, love: &LuaTable, state: Arc<SharedState>) -> LuaResult<()> {
    let event = lua.create_table()?;

    // Event collection belongs to the selected platform backend. The SDL2
    // APP Manager runtime injects keyboard/controller state itself; Lua code that uses
    // the normal love.run loop may still call pump safely.
    event.set("pump", lua.create_function(|_, ()| Ok(()))?)?;

    // love.event.poll() — returns iterator function
    {
        let s = Arc::clone(&state);
        event.set(
            "poll",
            lua.create_function(move |lua, ()| {
                let s2 = Arc::clone(&s);
                let iter = lua.create_function(move |lua, ()| {
                    let mut queue = s2.event_queue.lock();
                    match queue.pop_front() {
                        None => Ok(LuaMultiValue::new()),
                        Some(ev) => love_event_to_lua_values(lua, ev),
                    }
                })?;
                Ok(iter)
            })?,
        )?;
    }

    // love.event.quit([exitstatus])
    {
        let s = Arc::clone(&state);
        event.set(
            "quit",
            lua.create_function(move |_, code: Option<i32>| {
                *s.should_quit.lock() = true;
                s.event_queue
                    .lock()
                    .push_back(LoveEvent::Quit(code.unwrap_or(0)));
                Ok(())
            })?,
        )?;
    }

    // love.event.push(name, ...) — generic event push
    {
        let s = Arc::clone(&state);
        event.set(
            "push",
            lua.create_function(move |_, args: LuaMultiValue| {
                if let Some(LuaValue::String(name)) = args.get(0) {
                    let name_str = name.to_string_lossy();
                    if name_str == "quit" {
                        *s.should_quit.lock() = true;
                        s.event_queue.lock().push_back(LoveEvent::Quit(0));
                    }
                }
                Ok(())
            })?,
        )?;
    }

    love.set("event", event)?;

    // Fire initial focus/visible events so the game knows it has focus
    state.event_queue.lock().push_back(LoveEvent::Focus(true));
    state.event_queue.lock().push_back(LoveEvent::Visible(true));

    // Set up love.handlers table
    setup_handlers(lua)?;

    Ok(())
}

fn setup_handlers(lua: &Lua) -> LuaResult<()> {
    lua.load(
        r#"
        love.handlers = love.handlers or {}
        love.handlers.keypressed = function(a,b,c,d,e,f)
            if love.keypressed then love.keypressed(a,b,c) end
        end
        love.handlers.keyreleased = function(a,b,c,d,e,f)
            if love.keyreleased then love.keyreleased(a,b) end
        end
        love.handlers.mousepressed = function(a,b,c,d,e,f)
            if love.mousepressed then love.mousepressed(a,b,c,d) end
        end
        love.handlers.mousereleased = function(a,b,c,d,e,f)
            if love.mousereleased then love.mousereleased(a,b,c) end
        end
        love.handlers.mousemoved = function(a,b,c,d,e,f)
            if love.mousemoved then love.mousemoved(a,b,c,d) end
        end
        love.handlers.resize = function(a,b,c,d,e,f)
            if love.resize then love.resize(a,b) end
        end
        love.handlers.quit = function(a,b,c,d,e,f)
            if love.quit then return love.quit() end
        end
        love.handlers.focus = function(a)
            if love.focus then love.focus(a) end
        end
        love.handlers.visible = function(a)
            if love.visible then love.visible(a) end
        end
        love.handlers.gamepadpressed = function(a,b)
            if love.gamepadpressed then love.gamepadpressed(a,b) end
        end
        love.handlers.gamepadreleased = function(a,b)
            if love.gamepadreleased then love.gamepadreleased(a,b) end
        end
        love.handlers.joystickaxis = function(a,b,c)
            if love.joystickaxis then love.joystickaxis(a,b,c) end
        end
        love.handlers.textinput = function(a)
            if love.textinput then love.textinput(a) end
        end
    "#,
    )
    .exec()?;
    Ok(())
}

fn love_event_to_lua_values(lua: &Lua, ev: LoveEvent) -> LuaResult<LuaMultiValue> {
    match ev {
        LoveEvent::Quit(code) => Ok(LuaMultiValue::from_vec(vec![
            LuaValue::String(lua.create_string("quit")?),
            LuaValue::Integer(code as i64),
        ])),
        LoveEvent::KeyPressed {
            key,
            scancode,
            is_repeat,
        } => Ok(LuaMultiValue::from_vec(vec![
            LuaValue::String(lua.create_string("keypressed")?),
            LuaValue::String(lua.create_string(&key)?),
            LuaValue::String(lua.create_string(&scancode)?),
            LuaValue::Boolean(is_repeat),
        ])),
        LoveEvent::KeyReleased { key, scancode } => Ok(LuaMultiValue::from_vec(vec![
            LuaValue::String(lua.create_string("keyreleased")?),
            LuaValue::String(lua.create_string(&key)?),
            LuaValue::String(lua.create_string(&scancode)?),
        ])),
        LoveEvent::MousePressed {
            x,
            y,
            button,
            is_touch,
        } => Ok(LuaMultiValue::from_vec(vec![
            LuaValue::String(lua.create_string("mousepressed")?),
            LuaValue::Number(x as f64),
            LuaValue::Number(y as f64),
            LuaValue::Integer(button as i64),
            LuaValue::Boolean(is_touch),
        ])),
        LoveEvent::MouseReleased { x, y, button } => Ok(LuaMultiValue::from_vec(vec![
            LuaValue::String(lua.create_string("mousereleased")?),
            LuaValue::Number(x as f64),
            LuaValue::Number(y as f64),
            LuaValue::Integer(button as i64),
        ])),
        LoveEvent::MouseMoved { x, y, dx, dy } => Ok(LuaMultiValue::from_vec(vec![
            LuaValue::String(lua.create_string("mousemoved")?),
            LuaValue::Number(x as f64),
            LuaValue::Number(y as f64),
            LuaValue::Number(dx as f64),
            LuaValue::Number(dy as f64),
        ])),
        LoveEvent::Resize { w, h } => Ok(LuaMultiValue::from_vec(vec![
            LuaValue::String(lua.create_string("resize")?),
            LuaValue::Integer(w as i64),
            LuaValue::Integer(h as i64),
        ])),
        LoveEvent::TextInput { text } => Ok(LuaMultiValue::from_vec(vec![
            LuaValue::String(lua.create_string("textinput")?),
            LuaValue::String(lua.create_string(&text)?),
        ])),
        LoveEvent::Focus(focused) => Ok(LuaMultiValue::from_vec(vec![
            LuaValue::String(lua.create_string("focus")?),
            LuaValue::Boolean(focused),
        ])),
        LoveEvent::Visible(visible) => Ok(LuaMultiValue::from_vec(vec![
            LuaValue::String(lua.create_string("visible")?),
            LuaValue::Boolean(visible),
        ])),
        LoveEvent::GamepadPressed { joystick, button } => Ok(LuaMultiValue::from_vec(vec![
            LuaValue::String(lua.create_string("gamepadpressed")?),
            LuaValue::Integer(joystick as i64),
            LuaValue::String(lua.create_string(&button)?),
        ])),
        LoveEvent::GamepadReleased { joystick, button } => Ok(LuaMultiValue::from_vec(vec![
            LuaValue::String(lua.create_string("gamepadreleased")?),
            LuaValue::Integer(joystick as i64),
            LuaValue::String(lua.create_string(&button)?),
        ])),
    }
}
