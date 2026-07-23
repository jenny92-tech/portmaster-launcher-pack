use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use appmanager_service::{EmbeddedAction, EmbeddedService};
use love_api::LoveRuntime;
pub use love_api::state::GpuCommand;
use love_api::state::{LoveEvent, SharedState};
use mlua::{
    Function as LuaFunction, IntoLuaMulti, LuaSerdeExt, Table as LuaTable, Value as LuaValue,
};

pub const DEFAULT_WIDTH: u32 = 960;
pub const DEFAULT_HEIGHT: u32 = 720;
const MAX_FRAME_PIXELS: u32 = 4096 * 4096;

pub struct Engine {
    pub runtime: LoveRuntime,
    source: PathBuf,
}

impl Engine {
    pub fn load(source: impl AsRef<Path>, width: u32, height: u32) -> Result<Self> {
        Self::load_with_lua_setup(source, width, height, |_| Ok(()))
    }

    pub fn load_appmanager(
        source: impl AsRef<Path>,
        width: u32,
        height: u32,
        service: EmbeddedService,
    ) -> Result<Self> {
        Self::load_with_lua_setup(source, width, height, move |lua| {
            install_appmanager_api(lua, service)
        })
    }

    pub fn load_with_lua_setup(
        source: impl AsRef<Path>,
        width: u32,
        height: u32,
        setup: impl FnOnce(&mlua::Lua) -> Result<()>,
    ) -> Result<Self> {
        let pixels = width
            .checked_mul(height)
            .context("LOVE frame dimensions overflow")?;
        anyhow::ensure!(
            width > 0 && height > 0,
            "LOVE frame dimensions must be positive"
        );
        anyhow::ensure!(
            pixels <= MAX_FRAME_PIXELS,
            "LOVE frame exceeds the supported 16-megapixel budget"
        );
        let source = source
            .as_ref()
            .canonicalize()
            .with_context(|| format!("resolve LOVE source {}", source.as_ref().display()))?;
        let state = Arc::new(SharedState::new(&source, width, height)?);
        let runtime = LoveRuntime::new(state)?;
        setup(&runtime.lua)?;
        let engine = Self { runtime, source };
        engine.load_lua_file_if_present("conf.lua")?;
        engine.load_lua_file("main.lua")?;
        engine.call_optional("load", ())?;
        Ok(engine)
    }

    pub fn source(&self) -> &Path {
        &self.source
    }

    pub fn key_pressed(&self, key: &str, is_repeat: bool) -> Result<()> {
        self.runtime.state.keys_down.write().insert(key.to_owned());
        self.call_optional("keypressed", (key, key, is_repeat))
    }

    pub fn key_released(&self, key: &str) -> Result<()> {
        self.runtime.state.keys_down.write().remove(key);
        self.call_optional("keyreleased", (key, key))
    }

    pub fn update_and_draw(&self, dt: f64) -> Result<()> {
        self.update(dt)?;
        self.draw()
    }

    pub fn update(&self, dt: f64) -> Result<()> {
        self.call_optional("update", dt)?;
        Ok(())
    }

    pub fn draw(&self) -> Result<()> {
        let background = *self.runtime.state.background_color.lock();
        self.runtime.state.pixel_buffer.lock().clear(
            background[0],
            background[1],
            background[2],
            background[3],
        );
        self.call_optional("draw", ())
    }

    pub fn draw_gpu(&self) -> Result<Option<Vec<GpuCommand>>> {
        let background = self.runtime.state.background_color.lock();
        let color = background.map(|component| (component.clamp(0.0, 1.0) * 255.0).round() as u8);
        drop(background);
        self.runtime.state.begin_gpu_frame(color);
        let draw_result = self.call_optional("draw", ());
        let commands = self.runtime.state.finish_gpu_frame();
        draw_result?;
        Ok(commands)
    }

    pub fn image_rgba(&self, image_id: u64) -> Option<(u32, u32, Vec<u8>)> {
        self.runtime
            .state
            .images
            .lock()
            .get(&image_id)
            .map(|image| (image.width, image.height, image.pixels.clone()))
    }

    pub fn active_image_ids(&self) -> HashSet<u64> {
        self.runtime.state.images.lock().keys().copied().collect()
    }

    pub fn is_animating(&self) -> Result<bool> {
        let love: LuaTable = self.runtime.lua.globals().get("love")?;
        let Ok(function) = love.get::<LuaFunction>("isAnimating") else {
            return Ok(false);
        };
        function.call::<bool>(()).context("love.isAnimating")
    }

    pub fn frame_rgba(&self) -> Vec<u8> {
        self.runtime.state.pixel_buffer.lock().pixels.clone()
    }

    pub fn with_frame_rgba<R>(&self, read: impl FnOnce(&[u8]) -> R) -> R {
        let frame = self.runtime.state.pixel_buffer.lock();
        read(&frame.pixels)
    }

    pub fn should_quit(&self) -> bool {
        *self.runtime.state.should_quit.lock()
    }

    pub fn take_quit_code(&self) -> Option<i32> {
        let mut events = self.runtime.state.event_queue.lock();
        events.drain(..).find_map(|event| match event {
            LoveEvent::Quit(value) => Some(value),
            _ => None,
        })
    }

    fn load_lua_file_if_present(&self, name: &str) -> Result<()> {
        let source = self.runtime.state.game_source.lock();
        let Ok(bytes) = source.read_file(name) else {
            return Ok(());
        };
        drop(source);
        self.execute_lua(name, &bytes)
    }

    fn load_lua_file(&self, name: &str) -> Result<()> {
        let bytes = self
            .runtime
            .state
            .game_source
            .lock()
            .read_file(name)
            .with_context(|| format!("read {name}"))?;
        self.execute_lua(name, &bytes)
    }

    fn execute_lua(&self, name: &str, bytes: &[u8]) -> Result<()> {
        let code = std::str::from_utf8(bytes).with_context(|| format!("decode {name}"))?;
        self.runtime
            .lua
            .load(code)
            .set_name(format!("@{name}"))
            .exec()
            .with_context(|| format!("execute {name}"))
    }

    fn call_optional<A>(&self, callback: &str, args: A) -> Result<()>
    where
        A: IntoLuaMulti,
    {
        let love: LuaTable = self.runtime.lua.globals().get("love")?;
        if let Ok(function) = love.get::<LuaFunction>(callback) {
            function
                .call::<()>(args)
                .with_context(|| format!("love.{callback}"))?;
        }
        Ok(())
    }
}

pub fn install_appmanager_api(lua: &mlua::Lua, service: EmbeddedService) -> Result<()> {
    let table = lua.create_table()?;
    let snapshot = service.clone();
    table.set(
        "snapshot",
        lua.create_function(move |lua, ()| {
            let value = snapshot.snapshot().map_err(mlua::Error::external)?;
            lua.to_value(&value)
        })?,
    )?;
    let start = service.clone();
    table.set(
        "start",
        lua.create_function(move |lua, (kind, payload): (String, Option<LuaValue>)| {
            let actions = payload
                .map(|value| lua.from_value::<Vec<EmbeddedAction>>(value))
                .transpose()?;
            start.start(&kind, actions).map_err(mlua::Error::external)
        })?,
    )?;
    let poll = service.clone();
    table.set(
        "poll",
        lua.create_function(move |lua, ()| lua.to_value(&poll.poll()))?,
    )?;
    table.set(
        "cancel",
        lua.create_function(move |_, ()| service.cancel().map_err(mlua::Error::external))?,
    )?;
    lua.globals().set("appmanager", table)?;
    Ok(())
}
