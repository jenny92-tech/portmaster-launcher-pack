use std::env;
use std::process::ExitCode;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use love_lite::{DEFAULT_HEIGHT, DEFAULT_WIDTH, Engine};
use sdl2::event::Event;
use sdl2::keyboard::Keycode;
use sdl2::pixels::PixelFormatEnum;
use sdl2::render::Canvas;
use sdl2::video::{Window, WindowBuilder};

mod gpu;
use gpu::GpuRenderer;

const BUILD_REVISION: &str = match option_env!("LOVE_LITE_SOURCE_REVISION") {
    Some(revision) => revision,
    None => "development",
};

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
    if matches!(args.next().as_deref(), Some("--version")) {
        println!("love-lite {BUILD_REVISION}");
        return Ok(0);
    }
    let mut args = env::args().skip(1);
    let source = args
        .next()
        .context("APP Manager UI directory argument is required")?;
    let width = parse_dimension(args.next(), DEFAULT_WIDTH, "width")?;
    let height = parse_dimension(args.next(), DEFAULT_HEIGHT, "height")?;
    let engine = Engine::load(&source, width, height)?;

    let sdl = sdl2::init().map_err(anyhow::Error::msg)?;
    let video = sdl.video().map_err(anyhow::Error::msg)?;
    let title = engine.runtime.state.window_title.lock().clone();
    let preference = RendererPreference::from_environment();
    let (mut canvas, mut gpu_enabled) = build_canvas(&video, &title, width, height, preference)?;
    eprintln!(
        "love-lite: renderer={}",
        if gpu_enabled { "gpu" } else { "cpu" }
    );
    let texture_creator = canvas.texture_creator();
    let mut gpu_renderer = GpuRenderer::new(&texture_creator);
    let mut texture = texture_creator
        .create_texture_streaming(PixelFormatEnum::RGBA32, width, height)
        .context("create SDL2 frame texture")?;
    let mut events = sdl.event_pump().map_err(anyhow::Error::msg)?;
    let update_interval = Duration::from_secs_f64(1.0 / animation_render_fps() as f64);
    let idle_render_interval = Duration::from_secs_f64(1.0 / idle_render_fps() as f64);
    let mut previous = Instant::now();
    let mut last_render = previous
        .checked_sub(idle_render_interval)
        .unwrap_or(previous);
    let mut exit_code = 0;
    let mut gpu_failures = 0_u8;

    'running: loop {
        let update_started = Instant::now();
        let mut redraw = last_render.elapsed() >= idle_render_interval;
        for event in events.poll_iter() {
            match event {
                Event::Quit { .. } => break 'running,
                Event::KeyDown {
                    keycode: Some(key),
                    repeat,
                    ..
                } => {
                    if let Some(key) = love_key(key) {
                        engine.key_pressed(key, repeat)?;
                        redraw = true;
                    }
                }
                Event::KeyUp {
                    keycode: Some(key), ..
                } => {
                    if let Some(key) = love_key(key) {
                        engine.key_released(key)?;
                        redraw = true;
                    }
                }
                Event::Window { .. } => redraw = true,
                _ => {}
            }
        }

        let now = Instant::now();
        let dt = now.duration_since(previous).as_secs_f64().min(0.25);
        previous = now;
        engine.update(dt)?;
        if !redraw && engine.is_animating()? {
            redraw = true;
        }
        if redraw {
            last_render = Instant::now();
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
                    .with_frame_rgba(|frame| texture.update(None, frame, width as usize * 4))
                    .context("upload frame")?;
                canvas.set_clip_rect(None);
                canvas.clear();
                canvas
                    .copy(&texture, None, None)
                    .map_err(anyhow::Error::msg)?;
            }
            canvas.present();
        }

        if let Some(code) = engine.take_quit_code() {
            exit_code = code;
        }
        if engine.should_quit() {
            break;
        }
        if let Some(remaining) = update_interval.checked_sub(update_started.elapsed()) {
            thread::sleep(remaining);
        }
    }

    Ok(exit_code)
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
    builder.position_centered().resizable();
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

fn idle_render_fps() -> u32 {
    render_fps("LOVE_LITE_FPS", 30)
}

fn animation_render_fps() -> u32 {
    render_fps("LOVE_LITE_ANIMATION_FPS", 30)
}

fn render_fps(name: &str, fallback: u32) -> u32 {
    env::var(name)
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(fallback)
        .clamp(1, 120)
}

fn love_key(key: Keycode) -> Option<&'static str> {
    match key {
        Keycode::Up => Some("up"),
        Keycode::Down => Some("down"),
        Keycode::Left => Some("left"),
        Keycode::Right => Some("right"),
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
