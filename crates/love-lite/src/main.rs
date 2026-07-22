use std::env;
use std::process::ExitCode;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use love_lite::{DEFAULT_HEIGHT, DEFAULT_WIDTH, Engine};
use sdl2::event::Event;
use sdl2::keyboard::Keycode;
use sdl2::pixels::PixelFormatEnum;

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
    let mut window_builder = video.window(&title, width, height);
    window_builder.position_centered().resizable();
    let window = window_builder.build().context("create SDL2 window")?;
    let canvas_builder = window.into_canvas();
    let mut canvas = if env::var_os("LOVE_LITE_SOFTWARE").is_some() {
        canvas_builder.software().build()
    } else {
        canvas_builder.accelerated().present_vsync().build()
    }
    .context("create SDL2 renderer")?;
    let texture_creator = canvas.texture_creator();
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
            engine.draw()?;
            engine
                .with_frame_rgba(|frame| texture.update(None, frame, width as usize * 4))
                .context("upload frame")?;
            canvas.clear();
            canvas
                .copy(&texture, None, None)
                .map_err(anyhow::Error::msg)?;
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
