// Preserve imported upstream code as-is; local adapter code is linted strictly.
#![allow(clippy::all)]

pub mod event;
pub mod filesystem;
pub mod graphics;
pub mod keyboard;
pub mod lua_util;
pub mod state;
pub mod stubs;
pub mod system;
pub mod timer;
pub mod window;

use mlua::prelude::*;
use std::sync::Arc;

use state::SharedState;

pub struct LoveRuntime {
    pub lua: Lua,
    pub state: Arc<SharedState>,
}

impl LoveRuntime {
    pub fn new(state: Arc<SharedState>) -> anyhow::Result<Self> {
        let lua = Lua::new();

        let rt = LoveRuntime { lua, state };
        rt.setup_love_table()?;
        rt.setup_require()?;
        rt.setup_preloads()?;
        Ok(rt)
    }

    fn setup_love_table(&self) -> anyhow::Result<()> {
        let lua = &self.lua;
        let love = lua.create_table()?;

        // Set love table globally first so sub-module registration can access it
        lua.globals().set("love", love.clone())?;

        // Register all sub-modules
        filesystem::register(lua, &love, Arc::clone(&self.state))?;
        timer::register(lua, &love, Arc::clone(&self.state))?;
        window::register(lua, &love, Arc::clone(&self.state))?;
        graphics::register(lua, &love, Arc::clone(&self.state))?;
        keyboard::register(lua, &love, Arc::clone(&self.state))?;
        event::register(lua, &love, Arc::clone(&self.state))?;
        system::register(lua, &love, Arc::clone(&self.state))?;
        stubs::register(lua, &love, Arc::clone(&self.state))?;

        // Update the global
        lua.globals().set("love", love)?;

        Ok(())
    }

    fn setup_require(&self) -> anyhow::Result<()> {
        filesystem::setup_require(&self.lua, Arc::clone(&self.state))?;
        Ok(())
    }

    fn setup_preloads(&self) -> anyhow::Result<()> {
        filesystem::setup_preloads(&self.lua)?;
        Ok(())
    }
}
