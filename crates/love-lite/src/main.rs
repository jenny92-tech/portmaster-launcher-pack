use std::env;
use std::process::ExitCode;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use love_lite::{DEFAULT_HEIGHT, DEFAULT_WIDTH, Engine};
use sdl2::controller::{Button, GameController};
use sdl2::event::Event;
use sdl2::keyboard::Keycode;
use sdl2::pixels::PixelFormatEnum;

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
    let source = args.next().unwrap_or_else(|| "demo".to_owned());
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
    let _controllers = open_controllers(&sdl);
    let confirm_button = env::var("LOVE_LITE_CONFIRM_BUTTON").unwrap_or_else(|_| "a".to_owned());
    let target_frame_time = Duration::from_secs_f64(1.0 / target_fps() as f64);
    let mut previous = Instant::now();
    let mut exit_code = 0;

    'running: loop {
        let frame_started = Instant::now();
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
                    }
                }
                Event::KeyUp {
                    keycode: Some(key), ..
                } => {
                    if let Some(key) = love_key(key) {
                        engine.key_released(key)?;
                    }
                }
                Event::ControllerButtonDown { button, .. } => {
                    if let Some(key) = controller_key(button, &confirm_button) {
                        engine.key_pressed(key, false)?;
                    }
                }
                Event::ControllerButtonUp { button, .. } => {
                    if let Some(key) = controller_key(button, &confirm_button) {
                        engine.key_released(key)?;
                    }
                }
                _ => {}
            }
        }

        let now = Instant::now();
        let dt = now.duration_since(previous).as_secs_f64().min(0.25);
        previous = now;
        engine.update_and_draw(dt)?;
        engine
            .with_frame_rgba(|frame| texture.update(None, frame, width as usize * 4))
            .context("upload frame")?;
        canvas.clear();
        canvas
            .copy(&texture, None, None)
            .map_err(anyhow::Error::msg)?;
        canvas.present();

        if let Some(code) = engine.take_quit_code() {
            exit_code = code;
        }
        if engine.should_quit() {
            break;
        }
        if let Some(remaining) = target_frame_time.checked_sub(frame_started.elapsed()) {
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

fn open_controllers(sdl: &sdl2::Sdl) -> Vec<GameController> {
    let Ok(subsystem) = sdl.game_controller() else {
        return Vec::new();
    };
    if let Some(path) = env::var_os("SDL_GAMECONTROLLERCONFIG_FILE")
        && let Err(error) = subsystem.load_mappings(path)
    {
        eprintln!("love-lite: controller mappings were not loaded: {error}");
    }
    let count = subsystem.num_joysticks().unwrap_or(0);
    (0..count)
        .filter(|index| subsystem.is_game_controller(*index))
        .filter_map(|index| subsystem.open(index).ok())
        .collect()
}

fn target_fps() -> u32 {
    env::var("LOVE_LITE_FPS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(30)
        .clamp(1, 120)
}

fn controller_key(button: Button, confirm_button: &str) -> Option<&'static str> {
    match button {
        Button::DPadUp => Some("up"),
        Button::DPadDown => Some("down"),
        Button::DPadLeft => Some("left"),
        Button::DPadRight => Some("right"),
        Button::A if confirm_button.eq_ignore_ascii_case("a") => Some("confirm"),
        Button::B if confirm_button.eq_ignore_ascii_case("a") => Some("cancel"),
        Button::B => Some("confirm"),
        Button::A => Some("cancel"),
        _ => None,
    }
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
