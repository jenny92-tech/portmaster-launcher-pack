// INPUT:  命令行/设备环境、EmbeddedService、Engine、GpuRenderer 与 SDL2 事件
// OUTPUT: love-lite 桌面/掌机窗口、事件驱动帧循环和 Lua 请求的退出码
// POS:    APP Manager 专用运行时入口，协调显示、输入、GPU 与软件回退
use std::collections::BTreeMap;
use std::env;
use std::process::ExitCode;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use appmanager_core::DEFAULT_LAUNCHER_SCRIPT_NAME;
use appmanager_service::{EmbeddedRequest, EmbeddedService};
use love_lite::{DEFAULT_HEIGHT, DEFAULT_WIDTH, Engine};
use sdl2::event::Event;
use sdl2::keyboard::Keycode;
use sdl2::pixels::{Color, PixelFormatEnum};
use sdl2::rect::Rect;
use sdl2::render::Canvas;
use sdl2::video::{FullscreenType, Window, WindowBuilder};

mod gpu;
use gpu::GpuRenderer;

const INPUT_POLL_INTERVAL_MS: u32 = 33;

const BUILD_REVISION: &str = match option_env!("LOVE_LITE_SOURCE_REVISION") {
    Some(revision) => revision,
    None => "development",
};

struct WebShutdownGuard(EmbeddedService);

impl Drop for WebShutdownGuard {
    fn drop(&mut self) {
        if let Err(error) = self.0.disable_web() {
            eprintln!("love-lite: remote management is draining during exit: {error}");
        }
    }
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => ExitCode::from(code.clamp(0, u8::MAX as i32) as u8),
        Err(error) => {
            eprintln!("love-lite: {error:#}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<i32> {
    let mut args = env::args().skip(1);
    let source = args
        .next()
        .context("APP Manager UI directory argument is required")?;
    if source == "--version" {
        println!("love-lite {} {BUILD_REVISION}", env!("CARGO_PKG_VERSION"));
        return Ok(0);
    }
    let startup_started = Instant::now();
    let requested_width = parse_dimension(args.next(), DEFAULT_WIDTH, "width")?;
    let requested_height = parse_dimension(args.next(), DEFAULT_HEIGHT, "height")?;

    let source_path = std::path::PathBuf::from(&source);
    let app_root = env::var_os("PAM_APP_ROOT")
        .map(std::path::PathBuf::from)
        .or_else(|| source_path.parent().map(std::path::Path::to_path_buf))
        .context("resolve APP Manager root")?;
    eprintln!(
        "[PAM] runtime=LOVE-lite version={} revision={BUILD_REVISION}",
        env!("CARGO_PKG_VERSION")
    );
    let source_dir = env::var_os("PAM_SOURCE_DIR")
        .map(std::path::PathBuf::from)
        .or_else(|| app_root.parent().map(std::path::Path::to_path_buf))
        .context("resolve APP Manager launcher directory")?;
    let launcher = env::var_os("PAM_LAUNCHER")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| source_dir.join(DEFAULT_LAUNCHER_SCRIPT_NAME));
    let service_request = EmbeddedRequest {
        source_dir,
        launcher,
        config_dir: Some(app_root.join("config")),
        remote_config_dir: Some(app_root.join("state/device-config")),
        app_root,
    };
    let service_bootstrap =
        EmbeddedService::prepare(service_request).map_err(anyhow::Error::msg)?;
    eprintln!(
        "[PAM] startup.phase=prepared elapsed_ms={}",
        startup_started.elapsed().as_millis()
    );
    apply_process_environment(service_bootstrap.environment().clone());
    log_display_environment();

    // Establish the display before starting inventory, artwork, health or
    // update work. Some handheld frontends only keep the launch transition
    // alive when the application presents its first surface promptly.
    let sdl = sdl2::init().map_err(anyhow::Error::msg)?;
    let video = sdl.video().map_err(anyhow::Error::msg)?;
    let native_enabled = env::var("LOVE_LITE_NATIVE_RESOLUTION").as_deref() != Ok("0");
    let (window_width, window_height) = native_render_dimensions(
        requested_width,
        requested_height,
        video
            .current_display_mode(0)
            .ok()
            .and_then(|mode| positive_dimensions(mode.w, mode.h)),
        native_enabled,
    );
    let initial_title = env::var("LOVE_WINDOW_TITLE").unwrap_or_else(|_| "Port App Manager".into());
    let preference = RendererPreference::from_environment();
    let (mut canvas, mut gpu_enabled) = build_canvas(
        &video,
        &initial_title,
        window_width,
        window_height,
        preference,
    )?;
    // Match LÖVE's SDL lifecycle: create the renderer first, then request
    // desktop fullscreen.
    canvas
        .window_mut()
        .set_fullscreen(FullscreenType::Desktop)
        .map_err(anyhow::Error::msg)
        .context("set SDL2 desktop fullscreen")?;
    // Present a dependency-free splash before transaction recovery, inventory
    // scanning, Lua or the large CJK font are loaded. A slow SD card must show
    // visible progress instead of looking like a crashed black screen.
    canvas.set_draw_color(Color::RGB(14, 23, 40));
    canvas.clear();
    let splash_width = (window_width / 3).clamp(120, 420);
    let splash_x = ((window_width - splash_width) / 2) as i32;
    let splash_y = (window_height / 2).saturating_sub(3) as i32;
    canvas.set_draw_color(Color::RGB(74, 144, 226));
    canvas
        .fill_rect(Rect::new(splash_x, splash_y, splash_width, 6))
        .map_err(anyhow::Error::msg)
        .context("draw APP Manager startup splash")?;
    canvas.present();
    eprintln!(
        "[PAM] startup.phase=window-visible elapsed_ms={}",
        startup_started.elapsed().as_millis()
    );
    let (render_width, render_height) = canvas
        .output_size()
        .map_err(anyhow::Error::msg)
        .context("read SDL2 renderer output size")?;
    let service = EmbeddedService::activate(service_bootstrap)
        .map_err(anyhow::Error::msg)
        .context("initialize APP Manager service")?;
    eprintln!(
        "[PAM] startup.phase=service-ready elapsed_ms={}",
        startup_started.elapsed().as_millis()
    );
    let _web_shutdown = WebShutdownGuard(service.clone());
    // The web switch (top-left checkbox) turns the LAN admin UI on/off.
    let engine = Engine::load_appmanager(&source, render_width, render_height, service.clone())?;
    eprintln!(
        "[PAM] startup.phase=lua-ready elapsed_ms={}",
        startup_started.elapsed().as_millis()
    );
    let title = engine.runtime.state.window_title.lock().clone();
    canvas
        .window_mut()
        .set_title(&title)
        .context("set SDL2 window title")?;
    eprintln!(
        "love-lite: renderer={} requested={}x{} window={}x{} output={}x{}",
        if gpu_enabled { "gpu" } else { "cpu" },
        requested_width,
        requested_height,
        window_width,
        window_height,
        render_width,
        render_height,
    );
    let texture_creator = canvas.texture_creator();
    let mut gpu_renderer = GpuRenderer::new(&texture_creator);
    let mut texture = texture_creator
        .create_texture_streaming(PixelFormatEnum::RGBA32, render_width, render_height)
        .context("create SDL2 frame texture")?;
    let mut events = sdl.event_pump().map_err(anyhow::Error::msg)?;
    let animation_interval = Duration::from_secs_f64(1.0 / animation_render_fps() as f64);
    let mut previous = Instant::now();
    let mut exit_code = 0;
    let mut gpu_failures = 0_u8;
    let mut first_frame_presented = false;
    // First frame after load must present immediately for handheld frontend handoff.
    let mut wait_for_events = false;
    let process_name = env::current_exe()
        .ok()
        .and_then(|path| {
            path.file_name()
                .map(|name| name.to_string_lossy().into_owned())
        })
        .unwrap_or_else(|| "love.aarch64".into());
    service
        .start_input_helper(&process_name)
        .map_err(anyhow::Error::msg)
        .context("start controller input helper")?;
    let _input_helper = InputHelperGuard(service);

    'running: loop {
        let update_started = Instant::now();
        let mut redraw = false;

        if wait_for_events {
            let timeout_ms = event_wait_timeout_ms(&engine, animation_interval)?;
            if let Some(event) = events.wait_event_timeout(timeout_ms) {
                if handle_sdl_event(&engine, event, &mut redraw)? {
                    break 'running;
                }
            }
        }
        wait_for_events = true;

        for event in events.poll_iter() {
            if handle_sdl_event(&engine, event, &mut redraw)? {
                break 'running;
            }
        }

        let now = Instant::now();
        let dt = now.duration_since(previous).as_secs_f64().min(0.25);
        previous = now;
        engine.update(dt)?;
        if engine.take_dirty()? || engine.is_animating()? {
            redraw = true;
        }
        if redraw {
            let mut rendered_on_gpu = false;
            if gpu_enabled && let Some(commands) = engine.draw_gpu()? {
                match gpu_renderer.render(&mut canvas, &engine, &commands) {
                    Ok(()) => {
                        rendered_on_gpu = true;
                        gpu_failures = 0;
                    }
                    Err(error) => {
                        gpu_failures = gpu_failures.saturating_add(1);
                        eprintln!("love-lite: GPU frame failed: {error:#}");
                        if gpu_failures >= 3 {
                            gpu_enabled = false;
                            eprintln!("love-lite: renderer=cpu (GPU fallback)");
                        }
                    }
                }
            }
            if !rendered_on_gpu {
                engine.draw()?;
                engine
                    .with_frame_rgba(|frame| texture.update(None, frame, render_width as usize * 4))
                    .context("upload frame")?;
                canvas.set_clip_rect(None);
                canvas.clear();
                canvas
                    .copy(&texture, None, None)
                    .map_err(anyhow::Error::msg)?;
            }
            canvas.present();
            if !first_frame_presented {
                first_frame_presented = true;
                eprintln!(
                    "[PAM] startup.phase=first-frame elapsed_ms={}",
                    startup_started.elapsed().as_millis()
                );
            }
        }

        if let Some(code) = engine.take_quit_code() {
            exit_code = code;
        }
        if engine.should_quit() {
            break;
        }
        // Cap animation-frame spin so a busy spinner cannot peg a core.
        if engine.is_animating()?
            && let Some(remaining) = animation_interval.checked_sub(update_started.elapsed())
        {
            thread::sleep(remaining);
        }
    }

    Ok(exit_code)
}

fn handle_sdl_event(engine: &Engine, event: Event, redraw: &mut bool) -> Result<bool> {
    match event {
        Event::Quit { .. } => Ok(true),
        Event::KeyDown {
            keycode: Some(key),
            repeat,
            ..
        } => {
            if let Some(key) = love_key(key) {
                engine.key_pressed(key, repeat)?;
                *redraw = true;
            }
            Ok(false)
        }
        Event::KeyUp {
            keycode: Some(key), ..
        } => {
            if let Some(key) = love_key(key) {
                engine.key_released(key)?;
            }
            Ok(false)
        }
        Event::Window { .. } => {
            *redraw = true;
            Ok(false)
        }
        _ => Ok(false),
    }
}

fn event_wait_timeout_ms(engine: &Engine, animation_interval: Duration) -> Result<u32> {
    if engine.is_animating()? {
        return Ok(duration_to_timeout_ms(animation_interval));
    }
    Ok(idle_event_wait_timeout_ms(
        engine.wake_interval()?,
        animation_interval,
    ))
}

fn idle_event_wait_timeout_ms(wake_interval: Option<f64>, animation_interval: Duration) -> u32 {
    match wake_interval {
        Some(seconds) if seconds <= 0.0 => duration_to_timeout_ms(animation_interval),
        Some(seconds) => {
            let millis = (seconds * 1000.0).ceil();
            (millis.clamp(1.0, 600_000.0) as u32).min(INPUT_POLL_INTERVAL_MS)
        }
        // Some handheld SDL backends do not wake for gptokeyb's uinput events.
        // Poll input at a low fixed rate; unchanged frames still are not drawn.
        None => INPUT_POLL_INTERVAL_MS,
    }
}

fn duration_to_timeout_ms(duration: Duration) -> u32 {
    duration.as_millis().clamp(1, 600_000) as u32
}

struct InputHelperGuard(EmbeddedService);

impl Drop for InputHelperGuard {
    fn drop(&mut self) {
        self.0.stop_input_helper();
    }
}

fn apply_process_environment(resolved: BTreeMap<String, String>) {
    // This runs before SDL or worker threads exist. Rust 2024 marks process
    // environment mutation unsafe because concurrent readers would race.
    unsafe {
        for (name, _) in env::vars_os() {
            if !resolved.contains_key(name.to_string_lossy().as_ref()) {
                env::remove_var(name);
            }
        }
        for (name, value) in resolved {
            env::set_var(name, value);
        }
    }
}

fn log_display_environment() {
    const NAMES: &[&str] = &[
        "DISPLAY_WIDTH",
        "DISPLAY_HEIGHT",
        "SDL_VIDEODRIVER",
        "WAYLAND_DISPLAY",
        "XDG_RUNTIME_DIR",
        "LIBGL_FB",
        "SDL_GAMECONTROLLERCONFIG_FILE",
    ];
    for name in NAMES {
        eprintln!("[PAM] env.{name}={}", env::var(name).unwrap_or_default());
    }
}

fn positive_dimensions(width: i32, height: i32) -> Option<(u32, u32)> {
    (width > 0 && height > 0).then_some((width as u32, height as u32))
}

fn native_render_dimensions(
    requested_width: u32,
    requested_height: u32,
    native: Option<(u32, u32)>,
    enabled: bool,
) -> (u32, u32) {
    let Some((width, height)) = native.filter(|_| enabled) else {
        return (requested_width, requested_height);
    };
    // The configured size describes a platform fallback, not a device model.
    // SDL is the authority once the active display is available: one OS can
    // run on 4:3, square, portrait and widescreen handhelds.
    (width, height)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum RendererPreference {
    Auto,
    Gpu,
    Cpu,
}

impl RendererPreference {
    fn from_environment() -> Self {
        if env::var_os("LOVE_LITE_SOFTWARE").is_some() {
            return Self::Cpu;
        }
        match env::var("LOVE_LITE_RENDERER")
            .unwrap_or_else(|_| "auto".to_owned())
            .to_ascii_lowercase()
            .as_str()
        {
            "gpu" => Self::Gpu,
            "cpu" => Self::Cpu,
            _ => Self::Auto,
        }
    }
}

fn window_builder(
    video: &sdl2::VideoSubsystem,
    title: &str,
    width: u32,
    height: u32,
) -> WindowBuilder {
    let mut builder = video.window(title, width, height);
    builder.position_centered();
    builder
}

fn build_canvas(
    video: &sdl2::VideoSubsystem,
    title: &str,
    width: u32,
    height: u32,
    preference: RendererPreference,
) -> Result<(Canvas<Window>, bool)> {
    if env::var_os("LOVE_LITE_SOFTWARE").is_some() {
        let window = window_builder(video, title, width, height)
            .build()
            .context("create SDL2 window")?;
        return Ok((
            window
                .into_canvas()
                .software()
                .build()
                .context("create SDL2 software renderer")?,
            false,
        ));
    }

    let window = window_builder(video, title, width, height)
        .build()
        .context("create SDL2 window")?;
    match window.into_canvas().accelerated().present_vsync().build() {
        Ok(canvas) => Ok((canvas, preference != RendererPreference::Cpu)),
        Err(error) if preference == RendererPreference::Gpu => {
            Err(error).context("create required SDL2 GPU renderer")
        }
        Err(_) => {
            let window = window_builder(video, title, width, height)
                .build()
                .context("recreate SDL2 window for CPU fallback")?;
            Ok((
                window
                    .into_canvas()
                    .software()
                    .build()
                    .context("create SDL2 CPU fallback renderer")?,
                false,
            ))
        }
    }
}

fn parse_dimension(value: Option<String>, fallback: u32, name: &str) -> Result<u32> {
    let Some(value) = value else {
        return Ok(fallback);
    };
    let parsed = value
        .parse::<u32>()
        .with_context(|| format!("invalid {name}: {value}"))?;
    anyhow::ensure!(parsed > 0, "{name} must be greater than zero");
    Ok(parsed)
}

fn animation_render_fps() -> u32 {
    env::var("LOVE_LITE_ANIMATION_FPS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(30)
        .clamp(1, 120)
}

fn love_key(key: Keycode) -> Option<&'static str> {
    match key {
        Keycode::Up => Some("up"),
        Keycode::Down => Some("down"),
        Keycode::Left => Some("left"),
        Keycode::Right => Some("right"),
        Keycode::PageUp => Some("pageup"),
        Keycode::PageDown => Some("pagedown"),
        Keycode::Return => Some("return"),
        Keycode::KpEnter => Some("kpenter"),
        Keycode::Space => Some("space"),
        Keycode::Escape => Some("escape"),
        Keycode::Backspace => Some("backspace"),
        Keycode::Tab => Some("tab"),
        Keycode::A => Some("a"),
        Keycode::B => Some("b"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::{idle_event_wait_timeout_ms, love_key, native_render_dimensions};
    use sdl2::keyboard::Keycode;

    #[test]
    fn shoulder_page_keys_reach_lua() {
        assert_eq!(love_key(Keycode::PageUp), Some("pageup"));
        assert_eq!(love_key(Keycode::PageDown), Some("pagedown"));
    }

    #[test]
    fn idle_input_polling_is_capped_without_shortening_earlier_wakes() {
        let frame = Duration::from_millis(33);
        assert_eq!(idle_event_wait_timeout_ms(None, frame), 33);
        assert_eq!(idle_event_wait_timeout_ms(Some(10.0), frame), 33);
        assert_eq!(idle_event_wait_timeout_ms(Some(0.02), frame), 20);
        assert_eq!(idle_event_wait_timeout_ms(Some(0.0), frame), 33);
    }

    #[test]
    fn native_resolution_wins_over_platform_fallback() {
        assert_eq!(
            native_render_dimensions(960, 720, Some((720, 960)), true),
            (720, 960)
        );
        assert_eq!(
            native_render_dimensions(1280, 720, Some((640, 480)), true),
            (640, 480)
        );
    }

    #[test]
    fn configured_resolution_is_only_a_fallback() {
        assert_eq!(
            native_render_dimensions(960, 720, Some((720, 960)), false),
            (960, 720)
        );
        assert_eq!(native_render_dimensions(960, 720, None, true), (960, 720));
    }
}
