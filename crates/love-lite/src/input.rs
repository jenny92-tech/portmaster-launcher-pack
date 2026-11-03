// INPUT:  SDL2 输入、配置解析的 PortMaster 映射库、APP 私有 state 与 Lua 校准面板
// OUTPUT: prepare_mapping_hint()、可交换按键、本地 SDL 映射与校准状态
// POS:    APP 专用控制器输入与无映射时的交互式兜底
use anyhow::Result;
use love_lite::Engine;
use sdl2::{
    controller::{Button, GameController},
    joystick::Joystick,
};
use std::{
    collections::HashSet,
    path::{Path, PathBuf},
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

fn has_ui_mapping(mapping: &str) -> bool {
    FIELDS
        .iter()
        .filter(|field| !matches!(**field, "start" | "back"))
        .all(|field| {
            mapping.split(',').any(|entry| {
                entry
                    .strip_prefix(&format!("{field}:"))
                    .is_some_and(|value| !value.trim().is_empty())
            })
        })
}

/// Prepare before SDL joystick initialization so inherited USER hints cannot
/// override later APP-private mappings added through the SDL API.
pub fn prepare_mapping_hint() -> Result<Option<String>> {
    let mapping = sdl2::hint::get("SDL_GAMECONTROLLERCONFIG").filter(|mapping| !mapping.is_empty());
    if mapping.is_some() {
        anyhow::ensure!(
            sdl2::hint::set_with_priority(
                "SDL_GAMECONTROLLERCONFIG",
                "",
                &sdl2::hint::Hint::Override,
            ),
            "cannot prepare APP controller mapping priority"
        );
    }
    Ok(mapping)
}

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
    suppress: bool,
    held: HashSet<&'static str>,
    repeat_at: Instant,
    next_probe: Instant,
    direction_axes: HashSet<u32>,
    axis_latched: Vec<i8>,
    face_layout: (bool, bool),
}

impl Input {
    pub fn new(
        sdl: &sdl2::Sdl,
        app_root: PathBuf,
        engine: &Engine,
        portmaster_database: Option<&Path>,
        inherited_mapping: Option<&str>,
    ) -> Result<Self> {
        let controllers = sdl
            .game_controller()
            .map_err(|e| eprintln!("[PAM] input.controller.error={e}"))
            .ok();
        let joystick = sdl
            .joystick()
            .map_err(|e| eprintln!("[PAM] input.joystick.error={e}"))
            .ok();
        let database = app_root.join("share/gamecontrollerdb.txt");
        if let Some(controllers) = &controllers {
            if let Some(mapping) = inherited_mapping {
                for line in mapping.lines().filter(|line| !line.trim().is_empty()) {
                    if let Err(error) = controllers.add_mapping(line) {
                        eprintln!("[PAM] input.inherited_mapping.error={error}");
                    }
                }
            }
            // Shared firmware/PortMaster mappings override the generic bundle;
            // a per-GUID APP calibration is still loaded last in probe().
            for database in std::iter::once(database.as_path())
                .chain(portmaster_database.filter(|path| path.is_file()))
            {
                match controllers.load_mappings(database) {
                    Ok(count) => {
                        eprintln!("[PAM] input.database={} loaded={count}", database.display())
                    }
                    Err(error) => eprintln!("[PAM] input.database.error={error}"),
                }
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
            suppress: false,
            held: HashSet::new(),
            repeat_at: Instant::now(),
            next_probe: Instant::now(),
            direction_axes: HashSet::new(),
            axis_latched: Vec::new(),
            face_layout: (false, false),
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
                                eprintln!("[PAM] input.mapping=user path={}", path.display());
                            }
                        }
                    }
                }
            }
            // SDL may already know this controller through the firmware,
            // PortMaster's exported mapping or its built-in database. Absence
            // from the APP's own DB is not evidence that input is broken.
            self.controller = controllers
                .open(index)
                .ok()
                .filter(|controller| has_ui_mapping(&controller.mapping()));
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
            if self.controller.is_none() {
                self.begin();
            } else {
                // A known controller reconnecting clears the disconnect panel;
                // it must not start a fresh calibration just because it was open.
                self.active = false;
                self.calibration = None;
                self.message.clear();
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
        self.calibration = None;
        self.suppress = true;
        Ok(())
    }

    pub fn tick(&mut self, engine: &Engine) -> Result<bool> {
        let was_active = self.active;
        self.probe();
        let raw = self.raw();
        let layout = engine
            .runtime
            .lua
            .globals()
            .get::<Option<mlua::Table>>("pam_input_layout")?;
        let (swap_ab, swap_xy) = if let Some(layout) = layout {
            (
                layout.get::<bool>("swap_ab")?,
                layout.get::<bool>("swap_xy")?,
            )
        } else {
            (false, false)
        };
        if self.face_layout != (swap_ab, swap_xy) {
            self.face_layout = (swap_ab, swap_xy);
            // A setting changed during a press: wait for release before
            // interpreting the same physical button with its new meaning.
            self.suppress = true;
            eprintln!("[PAM] input.layout swap_ab={swap_ab} swap_xy={swap_xy}");
        }
        match self.command.swap(0, Ordering::Relaxed) {
            1 | 2 => self.begin(),
            4 => {
                if let Err(e) = self.save() {
                    self.message = format!("保存失败：{e}");
                    eprintln!("[PAM] input.save.error={e}");
                }
            }
            5 if self.controller.is_some() => {
                self.active = false;
                self.calibration = None;
                self.suppress = true;
            }
            _ => (),
        }
        // Read the OLD controller mapping before considering new calibration samples.
        if self.active
            && self.controller.as_ref().is_some_and(|c| {
                c.button(Button::A) && (c.button(Button::B) || c.button(Button::Start))
            })
        {
            self.active = false;
            self.calibration = None;
            self.suppress = true;
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
                (if swap_ab { Button::B } else { Button::A }, "return"),
                (if swap_ab { Button::A } else { Button::B }, "escape"),
                (if swap_xy { Button::Y } else { Button::X }, "x"),
                (if swap_xy { Button::X } else { Button::Y }, "y"),
                (Button::Guide, "escape"),
                (Button::LeftShoulder, "pageup"),
                (Button::RightShoulder, "pagedown"),
            ] {
                if c.button(button) {
                    pressed.insert(key);
                }
            }
        }
        let mut changed = pressed != self.held || self.active != was_active;
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
        status.set("can_cancel", self.controller.is_some())?;
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

    fn attach_virtual() -> i32 {
        let index = unsafe {
            sdl2::sys::SDL_JoystickAttachVirtual(
                sdl2::sys::SDL_JoystickType::SDL_JOYSTICK_TYPE_UNKNOWN,
                2,
                12,
                1,
            )
        };
        assert!(index >= 0, "{}", sdl2::get_error());
        index
    }

    #[test]
    fn virtual_controller_calibration_save_reload_and_disconnect() {
        // Discover the virtual GUID in a separate SDL lifecycle; parent hints
        // must be injected before the first joystick initialization.
        let guid = {
            let sdl = sdl2::init().unwrap();
            let joystick = sdl.joystick().unwrap();
            let index = attach_virtual();
            let guid = joystick.open(index as u32).unwrap().guid().to_string();
            assert_eq!(unsafe { sdl2::sys::SDL_JoystickDetachVirtual(index) }, 0);
            guid
        };
        let parent_mapping = format!(
            "{guid},Parent partial,a:b1,platform:{},",
            sdl2::get_platform()
        );
        #[cfg(target_os = "linux")]
        {
            // Negative control with target SDL2: USER priority really blocks
            // a later API mapping unless we prepare the hint first.
            assert!(sdl2::hint::set_with_priority(
                "SDL_GAMECONTROLLERCONFIG",
                &parent_mapping,
                &sdl2::hint::Hint::Override,
            ));
            let sdl = sdl2::init().unwrap();
            let joystick = sdl.joystick().unwrap();
            let index = attach_virtual();
            let controllers = sdl.game_controller().unwrap();
            controllers
                .add_mapping(&parent_mapping.replace("a:b1,", "a:b4,"))
                .unwrap();
            assert!(
                controllers
                    .open(index as u32)
                    .unwrap()
                    .mapping()
                    .contains("a:b1,")
            );
            assert_eq!(
                joystick.open(index as u32).unwrap().guid().to_string(),
                guid
            );
            assert_eq!(unsafe { sdl2::sys::SDL_JoystickDetachVirtual(index) }, 0);
        }
        assert!(sdl2::hint::set_with_priority(
            "SDL_GAMECONTROLLERCONFIG",
            &parent_mapping,
            &sdl2::hint::Hint::Override,
        ));
        let inherited_mapping = prepare_mapping_hint().unwrap();
        let sdl = sdl2::init().unwrap();
        let joystick = sdl.joystick().unwrap();
        let index = attach_virtual();
        let raw_device = unsafe { sdl2::sys::SDL_JoystickOpen(index) };
        assert!(!raw_device.is_null());
        assert_eq!(
            joystick.open(index as u32).unwrap().guid().to_string(),
            guid
        );
        let root = tempfile::tempdir().unwrap();
        std::fs::write(
            root.path().join("main.lua"),
            "keys={} function love.keypressed(k) keys[#keys+1]=k end",
        )
        .unwrap();
        let engine = Engine::load(root.path(), 320, 240).unwrap();
        let mut input = Input::new(
            &sdl,
            root.path().to_path_buf(),
            &engine,
            None,
            inherited_mapping.as_deref(),
        )
        .unwrap();
        input.tick(&engine).unwrap();
        assert!(input.device.is_some());
        assert!(input.active(), "no usable SDL mapping must calibrate");
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
        assert!(
            input
                .controller
                .as_ref()
                .unwrap()
                .mapping()
                .contains("a:b4,"),
            "APP calibration must override the inherited SDL mapping"
        );
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
        let mut from_db =
            Input::new(&sdl, db_only.path().to_path_buf(), &engine, None, None).unwrap();
        from_db.tick(&engine).unwrap();
        assert!(
            !from_db.active(),
            "bundled DB hit must not force calibration"
        );
        drop(from_db);
        // The installed PortMaster DB may know a handheld absent from the APP
        // bundle. Load it read-only, with higher priority than a generic bundle.
        let pm = tempfile::tempdir().unwrap();
        let pm_database = pm.path().join("gamecontrollerdb.txt");
        std::fs::write(&pm_database, &database).unwrap();
        let pm_app = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(pm_app.path().join("share")).unwrap();
        std::fs::write(pm_app.path().join("share/gamecontrollerdb.txt"), &saved).unwrap();
        let mut from_pm = Input::new(
            &sdl,
            pm_app.path().to_path_buf(),
            &engine,
            Some(&pm_database),
            None,
        )
        .unwrap();
        from_pm.tick(&engine).unwrap();
        assert!(
            !from_pm.active(),
            "PortMaster mapping must avoid calibration"
        );
        unsafe {
            sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, 5, 1);
        }
        joystick.update();
        from_pm.tick(&engine).unwrap();
        assert_eq!(
            engine
                .runtime
                .lua
                .load("return keys[#keys]")
                .eval::<String>()
                .unwrap(),
            "return",
            "PortMaster's A mapping must override the bundled B binding"
        );
        unsafe {
            sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, 5, 0);
        }
        joystick.update();
        from_pm.tick(&engine).unwrap();
        assert_eq!(std::fs::read_to_string(&pm_database).unwrap(), database);
        assert!(!pm_app.path().join("state/controller-mappings").exists());
        drop(from_pm);
        // A mapping known to SDL remains usable even when this APP has neither
        // a bundled GUID entry nor a private calibration file (firmware/PM case).
        // Start/Select are not required by the APP and may be absent here.
        sdl.game_controller()
            .unwrap()
            .add_mapping(&database.replace("start:b8,back:b9,", ""))
            .unwrap();
        let sdl_only = tempfile::tempdir().unwrap();
        let mut from_sdl =
            Input::new(&sdl, sdl_only.path().to_path_buf(), &engine, None, None).unwrap();
        from_sdl.tick(&engine).unwrap();
        assert!(
            !from_sdl.active(),
            "an existing SDL mapping must not calibrate"
        );
        assert!(from_sdl.controller.is_some());
        from_sdl.command(1);
        from_sdl.tick(&engine).unwrap();
        assert!(from_sdl.active());
        unsafe {
            sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, 4, 1);
            sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, 5, 1);
        }
        joystick.update();
        assert!(
            from_sdl.tick(&engine).unwrap(),
            "closing calibration must redraw"
        );
        assert!(
            !from_sdl.active(),
            "A + B cancels manual calibration without a mapped Start button"
        );
        assert!(!sdl_only.path().join("state/controller-mappings").exists());
        unsafe {
            sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, 4, 0);
            sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, 5, 0);
        }
        joystick.update();
        from_sdl.tick(&engine).unwrap();
        // The disconnect panel is informational; a mapped reconnect dismisses
        // it rather than treating its active flag as a calibration request.
        from_sdl.device = None;
        from_sdl.controller = None;
        from_sdl.active = true;
        from_sdl.message = "控制器已断开，请重新连接。".into();
        from_sdl.next_probe = Instant::now();
        assert!(
            from_sdl.tick(&engine).unwrap(),
            "mapped reconnect must redraw"
        );
        assert!(!from_sdl.active());
        assert!(from_sdl.calibration.is_none());
        drop(from_sdl);
        // A saved APP calibration wins even when the installed PortMaster DB
        // supplies a different mapping for this same GUID.
        let mut input = Input::new(
            &sdl,
            root.path().to_path_buf(),
            &engine,
            Some(&pm_database),
            None,
        )
        .unwrap();
        input.tick(&engine).unwrap();
        assert!(!input.active());
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
        // Face-button meaning stays distinct after calibration and reload:
        // A confirms, B returns, and X/Y keep separate semantic events.
        unsafe {
            sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, 4, 0);
        }
        joystick.update();
        input.tick(&engine).unwrap();
        for (button, expected) in [(5, Some("escape")), (6, Some("x")), (7, Some("y"))] {
            let before = engine
                .runtime
                .lua
                .load("return #keys")
                .eval::<usize>()
                .unwrap();
            unsafe {
                sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, button, 1);
            }
            joystick.update();
            input.tick(&engine).unwrap();
            let count = engine
                .runtime
                .lua
                .load("return #keys")
                .eval::<usize>()
                .unwrap();
            assert_eq!(count, before + usize::from(expected.is_some()));
            if let Some(key) = expected {
                assert_eq!(
                    engine
                        .runtime
                        .lua
                        .load("return keys[#keys]")
                        .eval::<String>()
                        .unwrap(),
                    key
                );
            }
            unsafe {
                sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, button, 0);
            }
            joystick.update();
            input.tick(&engine).unwrap();
        }
        // Changing layout while a button is held must not synthesize its new action.
        unsafe {
            sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, 4, 1);
        }
        joystick.update();
        input.tick(&engine).unwrap();
        let before = engine
            .runtime
            .lua
            .load("return #keys")
            .eval::<usize>()
            .unwrap();
        engine
            .runtime
            .lua
            .load("pam_input_layout={swap_ab=true,swap_xy=true}")
            .exec()
            .unwrap();
        for _ in 0..3 {
            input.tick(&engine).unwrap();
        }
        assert_eq!(
            engine
                .runtime
                .lua
                .load("return #keys")
                .eval::<usize>()
                .unwrap(),
            before
        );
        unsafe {
            sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, 4, 0);
        }
        joystick.update();
        input.tick(&engine).unwrap();
        // Exercise every combination through SDL, independently of stored calibration.
        for (swap_ab, swap_xy) in [(false, false), (true, false), (false, true), (true, true)] {
            let layout = engine.runtime.lua.create_table().unwrap();
            layout.set("swap_ab", swap_ab).unwrap();
            layout.set("swap_xy", swap_xy).unwrap();
            engine
                .runtime
                .lua
                .globals()
                .set("pam_input_layout", layout)
                .unwrap();
            input.tick(&engine).unwrap();
            for (button, key) in [
                (4, if swap_ab { "escape" } else { "return" }),
                (5, if swap_ab { "return" } else { "escape" }),
                (6, if swap_xy { "y" } else { "x" }),
                (7, if swap_xy { "x" } else { "y" }),
            ] {
                unsafe {
                    sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, button, 1);
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
                    key
                );
                unsafe {
                    sdl2::sys::SDL_JoystickSetVirtualButton(raw_device, button, 0);
                }
                joystick.update();
                input.tick(&engine).unwrap();
            }
            assert_eq!(
                std::fs::read_to_string(
                    root.path()
                        .join(format!("state/controller-mappings/{guid}.txt"))
                )
                .unwrap(),
                saved,
                "layout preferences must never rewrite the calibrated or system mapping"
            );
        }
        engine
            .runtime
            .lua
            .load("pam_input_layout=nil")
            .exec()
            .unwrap();
        input.tick(&engine).unwrap();
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

    #[test]
    fn ui_mapping_requires_actions_and_directions_but_not_unused_start_select() {
        let mapping = "guid,controller,dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,a:b0,b:b1,x:b2,y:b3,leftshoulder:b4,rightshoulder:b5,";
        assert!(has_ui_mapping(mapping));
        assert!(!has_ui_mapping(&mapping.replace("dpup:h0.1,", "")));
        assert!(!has_ui_mapping(&mapping.replace("a:b0,", "a:,")));
    }
}
