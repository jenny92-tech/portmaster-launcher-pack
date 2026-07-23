use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use appmanager_service::{EmbeddedAction, EmbeddedService, ServiceEvent};
use love_api::LoveRuntime;
pub use love_api::state::GpuCommand;
use love_api::state::{LoveEvent, SharedState};
use mlua::{
    Function as LuaFunction, IntoLuaMulti, LuaSerdeExt, SerializeOptions, Table as LuaTable,
    Value as LuaValue,
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
    table.set(
        "request",
        lua.create_function(move |lua, (method, payload): (String, Option<LuaValue>)| {
            appmanager_request(lua, &service, &method, payload)
        })?,
    )?;
    lua.globals().set("appmanager", table)?;
    Ok(())
}

fn appmanager_request(
    lua: &mlua::Lua,
    service: &EmbeddedService,
    method: &str,
    payload: Option<LuaValue>,
) -> mlua::Result<LuaTable> {
    match appmanager_request_value(lua, service, method, payload) {
        Ok(value) => bridge_ok(lua, value),
        Err(error) => bridge_error(lua, method, error.code, &error.message),
    }
}

struct BridgeFailure {
    code: &'static str,
    message: String,
}

impl BridgeFailure {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

fn appmanager_request_value(
    lua: &mlua::Lua,
    service: &EmbeddedService,
    method: &str,
    payload: Option<LuaValue>,
) -> std::result::Result<LuaValue, BridgeFailure> {
    match method {
        "snapshot" => {
            let snapshot = service
                .snapshot()
                .map_err(|message| BridgeFailure::new("snapshot_failed", message))?;
            lua.to_value_with(&snapshot, bridge_serialize_options())
                .map_err(|error| BridgeFailure::new("encode_failed", error.to_string()))
        }
        "start" => {
            let request = match payload {
                Some(LuaValue::Table(request)) => request,
                _ => {
                    return Err(BridgeFailure::new(
                        "invalid_request",
                        "start requires a request table",
                    ));
                }
            };
            let kind = request.get::<String>("kind").map_err(|error| {
                BridgeFailure::new("invalid_request", format!("invalid start kind: {error}"))
            })?;
            if kind.is_empty() {
                return Err(BridgeFailure::new("invalid_request", "start kind is empty"));
            }
            let actions = match request.get::<LuaValue>("actions").map_err(|error| {
                BridgeFailure::new("invalid_request", format!("invalid start actions: {error}"))
            })? {
                LuaValue::Nil => None,
                value => Some(
                    lua.from_value::<Vec<EmbeddedAction>>(value)
                        .map_err(|error| {
                            BridgeFailure::new(
                                "invalid_request",
                                format!("invalid start actions: {error}"),
                            )
                        })?,
                ),
            };
            let task_id = service
                .start(&kind, actions)
                .map_err(|message| BridgeFailure::new("start_failed", message))?;
            i64::try_from(task_id).map(LuaValue::Integer).map_err(|_| {
                BridgeFailure::new("invalid_response", "task id exceeds the Lua integer range")
            })
        }
        "poll" => service_event_to_lua(lua, service.poll())
            .map_err(|error| BridgeFailure::new("encode_failed", error.to_string())),
        "cancel" => service
            .cancel()
            .map(|()| LuaValue::Boolean(true))
            .map_err(|message| BridgeFailure::new("cancel_failed", message)),
        _ => Err(BridgeFailure::new(
            "unsupported_method",
            "unsupported APP Manager bridge method",
        )),
    }
}

fn bridge_ok(lua: &mlua::Lua, value: LuaValue) -> mlua::Result<LuaTable> {
    let response = lua.create_table()?;
    response.set("ok", true)?;
    if !matches!(value, LuaValue::Nil) {
        response.set("value", value)?;
    }
    Ok(response)
}

fn bridge_error(
    lua: &mlua::Lua,
    method: &str,
    code: &str,
    message: &str,
) -> mlua::Result<LuaTable> {
    eprintln!("[PAM bridge] {method}: {code}: {message}");
    let error = lua.create_table()?;
    error.set("code", code)?;
    error.set("message", message)?;
    let response = lua.create_table()?;
    response.set("ok", false)?;
    response.set("error", error)?;
    Ok(response)
}

fn service_event_to_lua(lua: &mlua::Lua, event: Option<ServiceEvent>) -> mlua::Result<LuaValue> {
    match event {
        Some(event) => lua.to_value_with(&event, bridge_serialize_options()),
        None => Ok(LuaValue::Nil),
    }
}

fn bridge_serialize_options() -> SerializeOptions {
    SerializeOptions::new()
        .serialize_none_to_null(false)
        .serialize_unit_to_null(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_appmanager_poll_is_lua_nil() {
        let lua = mlua::Lua::new();
        assert!(matches!(
            service_event_to_lua(&lua, None).expect("serialize idle poll"),
            LuaValue::Nil
        ));
    }

    #[test]
    fn bridge_envelopes_keep_empty_values_and_errors_unambiguous() {
        let lua = mlua::Lua::new();
        let idle = bridge_ok(&lua, LuaValue::Nil).expect("encode idle response");
        assert!(idle.get::<bool>("ok").expect("read response status"));
        assert!(matches!(
            idle.get::<LuaValue>("value").expect("read idle value"),
            LuaValue::Nil
        ));

        let failed =
            bridge_error(&lua, "start", "invalid_request", "missing kind").expect("encode error");
        assert!(!failed.get::<bool>("ok").expect("read failure status"));
        let error = failed.get::<LuaTable>("error").expect("read failure");
        assert_eq!(
            error.get::<String>("code").expect("read failure code"),
            "invalid_request"
        );
    }

    #[test]
    fn bridge_serialization_never_exposes_null_userdata_to_lua() {
        let lua = mlua::Lua::new();
        assert!(matches!(
            lua.to_value_with(&Option::<String>::None, bridge_serialize_options())
                .expect("serialize none"),
            LuaValue::Nil
        ));
        assert!(matches!(
            lua.to_value_with(&(), bridge_serialize_options())
                .expect("serialize unit"),
            LuaValue::Nil
        ));
    }
}
