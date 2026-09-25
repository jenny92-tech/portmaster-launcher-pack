// INPUT:  SDL2 控制器/原始输入、APP 私有 state 与 Lua 校准面板
// OUTPUT: 标准 UI 按键、本地 SDL 映射与校准状态
// POS:    APP 专用控制器输入与无映射时的交互式兜底
use anyhow::Result;
use love_lite::Engine;
use sdl2::{
    controller::{Button, GameController},
    joystick::Joystick,
};
use std::{
    collections::HashSet,
    path::PathBuf,
    sync::{
        Arc,
        atomic::{AtomicU8, Ordering},
    },
    time::{Duration, Instant},
};

const FIELDS: [&str; 12] = [
    "dpup",
    "dpdown",
    "dpleft",
    "dpright",
    "a",
    "b",
    "x",
    "y",
    "start",
    "back",
    "leftshoulder",
    "rightshoulder",
];

#[derive(Clone, Debug, PartialEq, Eq)]
enum Raw {
    Button(u32),
    Hat(u32, u8),
    Axis(u32, bool),
}
impl Raw {
    fn binding(&self) -> String {
        match self {
            Self::Button(n) => format!("b{n}"),
            Self::Hat(n, v) => format!("h{n}.{v}"),
            Self::Axis(n, positive) => format!("{}a{n}", if *positive { "+" } else { "-" }),
        }
    }
}

#[derive(Default)]
struct Calibration {
    bindings: Vec<Option<Raw>>,
    released: bool,
}
impl Calibration {
    fn sample(&mut self, raw: &[Raw]) -> bool {
        if raw.is_empty() {
            self.released = true;
            return false;
        }
        if raw.len() != 1 {
            self.released = false;
            return false;
        }
        if !self.released || self.bindings.len() >= FIELDS.len() {
            return false;
        }
        self.released = false;
        let candidate = &raw[0];
        // Axis directions are accepted only for the four direction steps.
        if self.bindings.len() >= 4 && matches!(candidate, Raw::Axis(..)) {
            return false;
        }
        if self.bindings.iter().flatten().any(|b| b == candidate) {
            return false;
        }
        self.bindings.push(Some(candidate.clone()));
        true
    }
    fn mapping(&self, guid: &str) -> String {
        let mut s = format!("{guid},APP calibrated,platform:{},", sdl2::get_platform());
        for (field, binding) in FIELDS.iter().zip(&self.bindings) {
            if let Some(binding) = binding {
                s.push_str(&format!("{field}:{},", binding.binding()));
            }
        }
        s
    }
}

pub struct Input {
    joystick: Option<sdl2::JoystickSubsystem>,
    controllers: Option<sdl2::GameControllerSubsystem>,
    device: Option<Joystick>,
    controller: Option<GameController>,
    state_dir: PathBuf,
    command: Arc<AtomicU8>,
    calibration: Option<Calibration>,
    active: bool,
    message: String,
    step_since: Instant,
    chord_since: Option<Instant>,
    suppress: bool,
    held: HashSet<&'static str>,
    repeat_at: Instant,
    next_probe: Instant,
    direction_axes: HashSet<u32>,
    axis_latched: Vec<i8>,
    bundled_guids: HashSet<String>,
    user_mapping: bool,
}

impl Input {
    pub fn new(sdl: &sdl2::Sdl, app_root: PathBuf, engine: &Engine) -> Result<Self> {
        let controllers = sdl
            .game_controller()
            .map_err(|e| eprintln!("[PAM] input.controller.error={e}"))
            .ok();
        let joystick = sdl
            .joystick()
            .map_err(|e| eprintln!("[PAM] input.joystick.error={e}"))
            .ok();
        let database = app_root.join("share/gamecontrollerdb.txt");
        let bundled_guids = std::fs::read_to_string(&database)
            .unwrap_or_default()
            .lines()
            .filter_map(|line| {
                let guid = line.split(',').next()?;
                (guid.len() == 32 && guid.bytes().all(|b| b.is_ascii_hexdigit()))
                    .then(|| guid.to_ascii_lowercase())
            })
            .collect();
        if let Some(controllers) = &controllers {
            match controllers.load_mappings(&database) {
                Ok(count) => {
                    eprintln!("[PAM] input.database={} loaded={count}", database.display())
                }
                Err(error) => eprintln!("[PAM] input.database.error={error}"),
            }
        }
        let command = Arc::new(AtomicU8::new(0));
        let api = engine.runtime.lua.create_table()?;
        let target = Arc::clone(&command);
        api.set(
            "command",
            engine.runtime.lua.create_function(move |_, value: u8| {
                target.store(value, Ordering::Relaxed);
                Ok(())
            })?,
        )?;
        engine.runtime.lua.globals().set("pam_input", api)?;
        Ok(Self {
            joystick,
            controllers,
            device: None,
            controller: None,
            state_dir: app_root.join("state/controller-mappings"),
            command,
            calibration: None,
            active: false,
            message: String::new(),
            step_since: Instant::now(),
            chord_since: None,
            suppress: false,
            held: HashSet::new(),
            repeat_at: Instant::now(),
            next_probe: Instant::now(),
            direction_axes: HashSet::new(),
            axis_latched: Vec::new(),
            bundled_guids,
            user_mapping: false,
        })
    }

    pub fn active(&self) -> bool {
        self.active
    }
    pub fn command(&self, command: u8) {
        self.command.store(command, Ordering::Relaxed);
    }

    fn begin(&mut self) {
        self.active = true;
        self.calibration = self.device.as_ref().map(|_| Calibration::default());
        self.message = if self.device.is_some() {
            String::new()
        } else {
            "未检测到控制器；请检查连接或输入权限。".into()
        };
        self.step_since = Instant::now();
        self.chord_since = None;
        eprintln!(
            "[PAM] input.calibration=begin device={}",
            self.device.is_some()
        );
    }

    fn raw(&mut self) -> Vec<Raw> {
        let Some(d) = &self.device else {
            return Vec::new();
        };
        let mut raw = Vec::new();
        for n in 0..d.num_buttons() {
            if d.button(n).unwrap_or(false) {
                raw.push(Raw::Button(n));
            }
        }
        for n in 0..d.num_hats() {
            let v = d.hat(n).map(|h| h as u8).unwrap_or(0);
            if [1, 2, 4, 8].contains(&v) {
                raw.push(Raw::Hat(n, v));
            } else if v != 0 {
                raw.push(Raw::Hat(n, v));
                raw.push(Raw::Hat(n, v));
            }
        }
        for n in 0..d.num_axes() {
            if !self.direction_axes.contains(&n) {
                continue;
            }
            // Unbound sticks/triggers must not block normal input or action steps.
            let capture = self.calibration.as_ref().is_some_and(|c| {
                c.bindings.len() < 4
                    || c.bindings
                        .iter()
                        .flatten()
                        .any(|b| matches!(b, Raw::Axis(axis, _) if *axis == n))
            });
            if !capture {
                continue;
            }
            let value = d.axis(n).unwrap_or(0);
            let state = &mut self.axis_latched[n as usize];
            if value > 24000 {
                *state = 1;
            } else if value < -24000 {
                *state = -1;
            } else if value.unsigned_abs() < 8000 {
                *state = 0;
            }
            if *state != 0 {
                raw.push(Raw::Axis(n, *state > 0));
            }
        }
        raw
    }

    fn probe(&mut self) {
        if self.device.as_ref().is_some_and(|d| !d.attached()) {
            self.device = None;
            self.controller = None;
            self.calibration = None;
            self.user_mapping = false;
            self.active = true;
            self.message = "控制器已断开，请重新连接。".into();
            self.suppress = true;
            eprintln!("[PAM] input.device=disconnected");
        }
        if self.device.is_some() || Instant::now() < self.next_probe {
            return;
        }
        self.next_probe = Instant::now() + Duration::from_secs(1);
        let (Some(joystick), Some(controllers)) = (&self.joystick, &self.controllers) else {
            return;
        };
        for index in 0..joystick.num_joysticks().unwrap_or(0) {
            let Ok(device) = joystick.open(index) else {
                continue;
            };
            let guid = device.guid().to_string();
            let path = self.state_dir.join(format!("{guid}.txt"));
            self.user_mapping = false;
            // Only our per-GUID plain file; never source scripts or touch system data.
            if let Ok(meta) = std::fs::symlink_metadata(&path) {
                if meta.is_file() && meta.len() < 4096 {
                    if let Ok(mapping) = std::fs::read_to_string(&path) {
                        if mapping.starts_with(&format!("{guid},"))
                            && FIELDS.iter().all(|field| {
                                mapping.split(',').any(|entry| {
                                    entry
                                        .strip_prefix(&format!("{field}:"))
                                        .is_some_and(|value| !value.trim().is_empty())
                                })
                            })
                        {
                            if let Err(error) = controllers.add_mapping(mapping.trim()) {
                                eprintln!("[PAM] input.user_mapping.error={error}");
                            } else {
                                self.user_mapping = true;
                                eprintln!("[PAM] input.mapping=user path={}", path.display());
                            }
                        }
                    }
                }
            }
            self.controller = if self.user_mapping || self.bundled_guids.contains(&guid) {
                controllers.open(index).ok()
            } else {
                None
            };
            eprintln!(
                "[PAM] input.device name={:?} guid={guid} mapped={}",
                device.name(),
                self.controller.is_some()
            );
            // Centered axes only: triggers resting at an endpoint are not d-pads.
            self.direction_axes = (0..device.num_axes())
                .filter(|n| device.axis(*n).is_ok_and(|v| v.unsigned_abs() < 8000))
                .collect();
            self.axis_latched = vec![0; device.num_axes() as usize];
            self.device = Some(device);
            if self.controller.is_none() || self.active {
                self.begin();
            }
            self.suppress = true;
            break;
        }
    }

    fn save(&mut self) -> Result<()> {
        let Some(device) = &self.device else {
            return Ok(());
        };
        let Some(calibration) = &self.calibration else {
            return Ok(());
        };
        let (Some(joystick), Some(controllers)) = (&self.joystick, &self.controllers) else {
            return Ok(());
        };
        if calibration.bindings.len() != FIELDS.len()
            || calibration.bindings.iter().any(Option::is_none)
        {
            return Ok(());
        }
        let guid = device.guid().to_string();
        let mapping = calibration.mapping(&guid);
        if let Some(parent) = self.state_dir.parent() {
            if let Ok(meta) = std::fs::symlink_metadata(parent) {
                anyhow::ensure!(
                    !meta.file_type().is_symlink(),
                    "APP state directory is a symlink"
                );
            }
        }
        if let Ok(meta) = std::fs::symlink_metadata(&self.state_dir) {
            anyhow::ensure!(
                !meta.file_type().is_symlink(),
                "calibration directory is a symlink"
            );
        }
        std::fs::create_dir_all(&self.state_dir)?;
        anyhow::ensure!(
            !std::fs::symlink_metadata(&self.state_dir)?
                .file_type()
                .is_symlink(),
            "calibration directory is a symlink"
        );
        let path = self.state_dir.join(format!("{guid}.txt"));
        let nonce = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)?
            .as_nanos();
        let temp = self.state_dir.join(format!("{guid}.{nonce}.pending"));
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)?;
        file.write_all(mapping.as_bytes())?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&temp, &path)?;
        controllers
            .add_mapping(&mapping)
            .map_err(anyhow::Error::msg)?;
        let instance = device.instance_id();
        self.controller = (0..joystick.num_joysticks().unwrap_or(0)).find_map(|i| {
            controllers
                .open(i)
                .ok()
                .filter(|d| d.instance_id() == instance)
        });
        anyhow::ensure!(
            self.controller.is_some(),
            "无法启用映射，请检查控制器连接后重试"
        );
        eprintln!(
            "[PAM] input.calibration=saved guid={guid} path={}",
            path.display()
        );
        self.active = false;
        self.user_mapping = true;
        self.calibration = None;
        self.suppress = true;
        Ok(())
    }

    pub fn tick(&mut self, engine: &Engine) -> Result<bool> {
        self.probe();
        let raw = self.raw();
        match self.command.swap(0, Ordering::Relaxed) {
            1 | 2 => self.begin(),
            4 => {
                if let Err(e) = self.save() {
                    self.message = format!("保存失败：{e}");
                    eprintln!("[PAM] input.save.error={e}");
                }
            }
            5 if self.user_mapping => {
                self.active = false;
                self.calibration = None;
                self.suppress = true;
            }
            _ => (),
        }
        // Read the OLD controller mapping before considering new calibration samples.
        if self.active
            && self.user_mapping
            && self
                .controller
                .as_ref()
                .is_some_and(|c| c.button(Button::Start) && c.button(Button::A))
        {
            self.active = false;
            self.calibration = None;
            self.suppress = true;
            self.chord_since = None;
        }
        let buttons = raw.iter().filter(|r| matches!(r, Raw::Button(_))).count();
        if !self.active && buttons >= 2 && (!self.suppress || self.chord_since.is_some()) {
            let since = self.chord_since.get_or_insert_with(Instant::now);
            if since.elapsed() >= Duration::from_secs(3) {
                self.begin();
            }
            self.suppress = true;
        } else if buttons < 2 {
            self.chord_since = None;
        }

        let mut pressed = HashSet::new();
        if self.active {
            if let Some(c) = &mut self.calibration {
                if c.bindings.len() < FIELDS.len() {
                    if c.sample(&raw) {
                        self.step_since = Instant::now();
                        self.message.clear();
                    }
                    if self.step_since.elapsed() > Duration::from_secs(30) {
                        self.message =
                            "未收到可用的新按键，请松开所有按键后重试，或检查控制器连接。".into();
                    }
                } else if raw.is_empty() {
                    c.released = true;
                } else if c.released && raw.len() == 1 {
                    c.released = false;
                    if c.bindings[4].as_ref() == raw.first() {
                        self.command.store(4, Ordering::Relaxed);
                    } else if c.bindings[6].as_ref() == raw.first() {
                        self.command.store(2, Ordering::Relaxed);
                    }
                }
            }
        } else if self.suppress {
            if raw.is_empty() {
                self.suppress = false;
            }
        } else if let Some(c) = &self.controller {
            for (button, key) in [
                (Button::DPadUp, "up"),
                (Button::DPadDown, "down"),
                (Button::DPadLeft, "left"),
                (Button::DPadRight, "right"),
                (Button::A, "return"),
                (Button::B, "return"),
                (Button::X, "escape"),
                (Button::Y, "escape"),
                (Button::Guide, "escape"),
                (Button::LeftShoulder, "pageup"),
                (Button::RightShoulder, "pagedown"),
            ] {
                if c.button(button) {
                    pressed.insert(key);
                }
            }
        }
        let mut changed = pressed != self.held;
        for key in self.held.difference(&pressed) {
            engine.key_released(key)?;
        }
        for key in pressed.difference(&self.held) {
            engine.key_pressed(key, false)?;
            self.repeat_at = Instant::now() + Duration::from_millis(360);
        }
        if Instant::now() >= self.repeat_at {
            for key in pressed.intersection(&self.held) {
                if ["up", "down", "left", "right"].contains(key) {
                    engine.key_pressed(key, true)?;
                    changed = true;
                }
            }
            self.repeat_at = Instant::now() + Duration::from_millis(90);
        }
        self.held = pressed;
        let status = engine.runtime.lua.create_table()?;
        status.set("active", self.active)?;
        status.set("can_cancel", self.user_mapping)?;
        status.set(
            "step",
            self.calibration
                .as_ref()
                .map_or(0, |c| c.bindings.len() + 1),
        )?;
        status.set("message", self.message.as_str())?;
        status.set("elapsed", self.step_since.elapsed().as_secs_f64())?;
        status.set("pressed", format!("{raw:?}"))?;
        engine
            .runtime
            .lua
            .globals()
            .set("pam_input_status", status)?;
        Ok(changed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn virtual_controller_calibration_save_reload_and_disconnect() {
        let sdl = sdl2::init().unwrap();
        let joystick = sdl.joystick().unwrap();
        // Test-only SDL virtual device, never touches hardware or system mappings.
        let index = unsafe {
            sdl2::sys::SDL_JoystickAttachVirtual(
                sdl2::sys::SDL_JoystickType::SDL_JOYSTICK_TYPE_UNKNOWN,
                2,
                12,
                1,
            )
        };
        assert!(index >= 0, "{}", sdl2::get_error());
        let raw_device = unsafe { sdl2::sys::SDL_JoystickOpen(index) };
        assert!(!raw_device.is_null());
        let root = tempfile::tempdir().unwrap();
        std::fs::write(
            root.path().join("main.lua"),
            "keys={} function love.keypressed(k) keys[#keys+1]=k end",
        )
        .unwrap();
        let engine = Engine::load(root.path(), 320, 240).unwrap();
        let mut input = Input::new(&sdl, root.path().to_path_buf(), &engine).unwrap();
        input.tick(&engine).unwrap();
        assert!(input.device.is_some());
        assert!(
            input.active(),
            "no APP mapping or bundled DB must calibrate"
        );
        input.command(1);
        input.tick(&engine).unwrap();
        input.command(5);
        input.tick(&engine).unwrap();
        assert!(input.active(), "first calibration cannot be cancelled");
        for button in 0..12 {
            assert_eq!(
                unsafe { sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, button, 1) },
                0
            );
            joystick.update();
            input.tick(&engine).unwrap();
            assert_eq!(
                input.calibration.as_ref().unwrap().bindings.len(),
                button as usize + 1
            );
            // A held button cannot fill the next step.
            input.tick(&engine).unwrap();
            assert_eq!(
                input.calibration.as_ref().unwrap().bindings.len(),
                button as usize + 1
            );
            unsafe {
                sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, button, 0);
            }
            joystick.update();
            input.tick(&engine).unwrap();
            if button == 5 {
                input.command(3);
                input.tick(&engine).unwrap();
                assert_eq!(
                    input.calibration.as_ref().unwrap().bindings.len(),
                    6,
                    "X/Y cannot be skipped as optional shoulders"
                );
            }
        }
        input.command(4);
        input.tick(&engine).unwrap();
        assert!(!input.active());
        assert!(input.controller.is_some());
        let guid = input.device.as_ref().unwrap().guid().to_string();
        let path = root
            .path()
            .join(format!("state/controller-mappings/{guid}.txt"));
        let saved = std::fs::read_to_string(path).unwrap();
        assert!(saved.contains("dpup:b0,"));
        assert!(
            saved.contains(
                "a:b4,b:b5,x:b6,y:b7,start:b8,back:b9,leftshoulder:b10,rightshoulder:b11,"
            )
        );
        drop(input);
        let database = saved.replace("a:b4,b:b5,", "a:b5,b:b4,");
        std::fs::create_dir_all(root.path().join("share")).unwrap();
        std::fs::write(root.path().join("share/gamecontrollerdb.txt"), &database).unwrap();
        let db_only = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(db_only.path().join("share")).unwrap();
        std::fs::write(db_only.path().join("share/gamecontrollerdb.txt"), &database).unwrap();
        let mut from_db = Input::new(&sdl, db_only.path().to_path_buf(), &engine).unwrap();
        from_db.tick(&engine).unwrap();
        assert!(
            !from_db.active(),
            "bundled DB hit must not force calibration"
        );
        assert!(!from_db.user_mapping);
        drop(from_db);
        let mut input = Input::new(&sdl, root.path().to_path_buf(), &engine).unwrap();
        input.tick(&engine).unwrap();
        assert!(!input.active());
        assert!(input.user_mapping);
        input.command(1);
        input.tick(&engine).unwrap();
        unsafe {
            sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, 8, 1);
            sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, 4, 1);
        }
        joystick.update();
        input.tick(&engine).unwrap();
        assert!(!input.active(), "saved Start + A cancels recalibration");
        assert!(input.calibration.is_none());
        assert_eq!(
            std::fs::read_to_string(
                root.path()
                    .join(format!("state/controller-mappings/{guid}.txt"))
            )
            .unwrap(),
            saved
        );
        unsafe {
            sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, 8, 0);
            sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, 4, 0);
        }
        joystick.update();
        input.tick(&engine).unwrap();
        unsafe {
            sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, 4, 1);
        }
        joystick.update();
        assert!(input.tick(&engine).unwrap());
        assert_eq!(
            engine
                .runtime
                .lua
                .load("return keys[#keys]")
                .eval::<String>()
                .unwrap(),
            "return"
        );
        // Axis-backed d-pad and hat directions must also work through SDL,
        // not just produce a plausible mapping string.
        unsafe {
            sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, 4, 0);
        }
        joystick.update();
        input.calibration = Some(Calibration {
            bindings: vec![
                Some(Raw::Axis(1, false)),
                Some(Raw::Axis(1, true)),
                Some(Raw::Hat(0, 8)),
                Some(Raw::Hat(0, 2)),
                Some(Raw::Button(0)),
                Some(Raw::Button(1)),
                Some(Raw::Button(2)),
                Some(Raw::Button(3)),
                Some(Raw::Button(4)),
                Some(Raw::Button(5)),
                Some(Raw::Button(6)),
                Some(Raw::Button(7)),
            ],
            released: true,
        });
        input.save().unwrap();
        input.tick(&engine).unwrap();
        unsafe {
            sdl2::sys::SDL_JoystickSetVirtualAxis(raw_device, 1, -32767);
        }
        joystick.update();
        input.tick(&engine).unwrap();
        assert_eq!(
            engine
                .runtime
                .lua
                .load("return keys[#keys]")
                .eval::<String>()
                .unwrap(),
            "up"
        );
        unsafe {
            sdl2::sys::SDL_JoystickSetVirtualAxis(raw_device, 1, 0);
            sdl2::sys::SDL_JoystickSetVirtualHat(raw_device, 0, 8);
        }
        joystick.update();
        input.tick(&engine).unwrap();
        assert_eq!(
            engine
                .runtime
                .lua
                .load("return keys[#keys]")
                .eval::<String>()
                .unwrap(),
            "left"
        );
        unsafe {
            sdl2::sys::SDL_JoystickDetachVirtual(index);
        }
        joystick.update();
        input.tick(&engine).unwrap();
        assert!(input.active());
        assert!(input.held.is_empty());
        assert!(input.device.is_none());
        unsafe {
            sdl2::sys::SDL_JoystickClose(raw_device);
        }
    }
    #[test]
    fn chords_require_full_release_and_actions_reject_axes() {
        let mut c = Calibration::default();
        c.sample(&[]);
        assert!(!c.sample(&[Raw::Button(0), Raw::Button(1)]));
        assert!(!c.sample(&[Raw::Button(1)]));
        c.sample(&[]);
        assert!(c.sample(&[Raw::Button(1)]));
        c.bindings = vec![Some(Raw::Button(1)); 4];
        c.sample(&[]);
        assert!(!c.sample(&[Raw::Axis(0, true)]));
        c.sample(&[]);
        assert!(c.sample(&[Raw::Button(2)]));
    }
    #[test]
    fn waits_for_release_and_rejects_duplicates() {
        let mut c = Calibration::default();
        assert!(!c.sample(&[Raw::Button(1)]));
        c.sample(&[]);
        assert!(c.sample(&[Raw::Button(1)]));
        assert!(!c.sample(&[Raw::Button(2)]));
        c.sample(&[]);
        assert!(!c.sample(&[Raw::Button(1)]));
        c.sample(&[]);
        assert!(c.sample(&[Raw::Hat(0, 4)]));
    }
    #[test]
    fn preserves_axis_polarity_and_all_required_buttons() {
        let c = Calibration {
            bindings: vec![
                Some(Raw::Axis(1, false)),
                Some(Raw::Axis(1, true)),
                Some(Raw::Hat(0, 8)),
                Some(Raw::Hat(0, 2)),
                Some(Raw::Button(0)),
                Some(Raw::Button(1)),
                Some(Raw::Button(2)),
                Some(Raw::Button(3)),
                Some(Raw::Button(4)),
                Some(Raw::Button(5)),
                Some(Raw::Button(6)),
                Some(Raw::Button(7)),
            ],
            released: false,
        };
        let s = c.mapping("190000004b4800000011000000010000");
        assert!(s.contains("dpup:-a1,dpdown:+a1,"));
        assert!(s.contains("a:b0,b:b1,x:b2,y:b3,"));
        assert!(s.contains("start:b4,back:b5,leftshoulder:b6,rightshoulder:b7,"));
    }
}
