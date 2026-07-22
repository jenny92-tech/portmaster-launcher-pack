use parking_lot::{Mutex, RwLock};
use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use sprite_to_text::pixel_buffer::{PixelBuffer, StencilCompare};

/// RGBA color stored as [f32; 4], matches LÖVE's convention (0.0-1.0)
pub type LoveColor = [f32; 4];

/// LÖVE blend mode
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BlendMode {
    Alpha,    // Standard alpha blending (default)
    Replace,  // Direct write, no blending
    Multiply, // Multiplicative
    Add,      // Additive
    Screen,   // Screen blend
}

impl Default for BlendMode {
    fn default() -> Self {
        BlendMode::Alpha
    }
}

/// An event in the LÖVE event queue
#[derive(Debug, Clone)]
pub enum LoveEvent {
    Quit(i32),
    KeyPressed {
        key: String,
        scancode: String,
        is_repeat: bool,
    },
    KeyReleased {
        key: String,
        scancode: String,
    },
    MousePressed {
        x: f32,
        y: f32,
        button: u8,
        is_touch: bool,
    },
    MouseReleased {
        x: f32,
        y: f32,
        button: u8,
    },
    MouseMoved {
        x: f32,
        y: f32,
        dx: f32,
        dy: f32,
    },
    Resize {
        w: u32,
        h: u32,
    },
    TextInput {
        text: String,
    },
    Focus(bool),
    Visible(bool),
    GamepadPressed {
        joystick: i32,
        button: String,
    },
    GamepadReleased {
        joystick: i32,
        button: String,
    },
}

/// 2D affine transform stored as a 3x2 matrix:
///   [ a  b  tx ]
///   [ c  d  ty ]
/// Applies as: x' = a*x + b*y + tx, y' = c*x + d*y + ty
#[derive(Debug, Clone)]
pub struct Transform {
    pub a: f32,
    pub b: f32,
    pub c: f32,
    pub d: f32,
    pub tx: f32,
    pub ty: f32,
}

impl Default for Transform {
    fn default() -> Self {
        Transform {
            a: 1.0,
            b: 0.0,
            c: 0.0,
            d: 1.0,
            tx: 0.0,
            ty: 0.0,
        }
    }
}

impl Transform {
    /// Apply translation
    pub fn translate(&mut self, x: f32, y: f32) {
        self.tx += self.a * x + self.b * y;
        self.ty += self.c * x + self.d * y;
    }

    /// Apply scaling
    pub fn scale(&mut self, sx: f32, sy: f32) {
        self.a *= sx;
        self.b *= sy;
        self.c *= sx;
        self.d *= sy;
    }

    /// Apply rotation
    pub fn rotate(&mut self, angle: f32) {
        let cos = angle.cos();
        let sin = angle.sin();
        let na = self.a * cos + self.b * sin;
        let nb = self.a * -sin + self.b * cos;
        let nc = self.c * cos + self.d * sin;
        let nd = self.c * -sin + self.d * cos;
        self.a = na;
        self.b = nb;
        self.c = nc;
        self.d = nd;
    }

    /// Transform a point
    #[inline]
    pub fn apply(&self, x: f32, y: f32) -> (f32, f32) {
        (
            self.a * x + self.b * y + self.tx,
            self.c * x + self.d * y + self.ty,
        )
    }

    /// Get the approximate uniform scale factor (average of x/y scales)
    #[inline]
    pub fn scale_factor(&self) -> (f32, f32) {
        let sx = (self.a * self.a + self.c * self.c).sqrt();
        let sy = (self.b * self.b + self.d * self.d).sqrt();
        (sx, sy)
    }

    /// Compute the inverse transform
    pub fn inverse(&self) -> Option<Transform> {
        let det = self.a * self.d - self.b * self.c;
        if det.abs() < 1e-10 {
            return None;
        }
        let inv = 1.0 / det;
        Some(Transform {
            a: self.d * inv,
            b: -self.b * inv,
            c: -self.c * inv,
            d: self.a * inv,
            tx: (self.b * self.ty - self.d * self.tx) * inv,
            ty: (self.c * self.tx - self.a * self.ty) * inv,
        })
    }
}

/// Saved graphics state for push("all")/pop()
pub struct SavedGraphicsState {
    pub color: LoveColor,
    pub scissor: Option<(i32, i32, u32, u32)>,
    pub stencil_compare: StencilCompare,
    pub stencil_ref: u8,
    pub line_width: f32,
    pub font_size: f32,
    pub font_id: u64,
    pub active_canvas: u64,
    pub blend_mode: BlendMode,
}

pub struct FpsCounter {
    pub frame_times: VecDeque<f32>,
    pub current_fps: f32,
}

impl FpsCounter {
    pub fn new() -> Self {
        FpsCounter {
            frame_times: VecDeque::with_capacity(64),
            current_fps: 0.0,
        }
    }

    pub fn update(&mut self, frame_time: f32) {
        self.frame_times.push_back(frame_time);
        if self.frame_times.len() > 60 {
            self.frame_times.pop_front();
        }
        let avg: f32 = self.frame_times.iter().sum::<f32>() / self.frame_times.len() as f32;
        self.current_fps = if avg > 0.0 { 1.0 / avg } else { 0.0 };
    }
}

/// Source of game files — either a directory or a zip archive
pub enum GameSource {
    Directory(PathBuf),
    Zip {
        base_dir: String,
        /// All file contents pre-loaded into memory for fast access
        files: HashMap<String, Vec<u8>>,
    },
}

impl GameSource {
    pub fn from_path(path: &Path) -> anyhow::Result<Self> {
        if path.is_dir() {
            return Ok(GameSource::Directory(path.to_owned()));
        }
        // Try opening as zip (handles Balatro.exe = zip-appended)
        let file = std::fs::File::open(path)?;
        let mut archive = zip::ZipArchive::new(file)?;
        let mut files = HashMap::new();
        let count = archive.len();
        eprintln!("[INFO] Loading {} files from archive...", count);
        for i in 0..count {
            if let Ok(mut entry) = archive.by_index(i) {
                let name = entry.name().replace('\\', "/");
                if !entry.is_dir() {
                    let mut buf = Vec::with_capacity(entry.size() as usize);
                    std::io::Read::read_to_end(&mut entry, &mut buf)?;
                    files.insert(name, buf);
                }
            }
        }
        eprintln!("[INFO] Loaded {} files into memory", files.len());
        let base_dir = path
            .parent()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_default();
        Ok(GameSource::Zip { base_dir, files })
    }

    pub fn read_file(&self, file_path: &str) -> anyhow::Result<Vec<u8>> {
        match self {
            GameSource::Directory(base) => {
                let full = base.join(file_path);
                Ok(std::fs::read(full)?)
            }
            GameSource::Zip { files, .. } => {
                let normalized = file_path.replace('\\', "/");
                if let Some(data) = files.get(&normalized) {
                    Ok(data.clone())
                } else if let Some(data) = files.get(file_path) {
                    Ok(data.clone())
                } else {
                    anyhow::bail!("file not found in archive: {}", file_path)
                }
            }
        }
    }

    pub fn file_exists(&self, file_path: &str) -> bool {
        match self {
            GameSource::Directory(base) => base.join(file_path).exists(),
            GameSource::Zip { files, .. } => {
                let normalized = file_path.replace('\\', "/");
                files.contains_key(&normalized) || files.contains_key(file_path)
            }
        }
    }

    pub fn is_directory(&self, dir_path: &str) -> bool {
        match self {
            GameSource::Directory(base) => base.join(dir_path).is_dir(),
            GameSource::Zip { files, .. } => {
                let prefix = if dir_path.ends_with('/') {
                    dir_path.replace('\\', "/")
                } else {
                    format!("{}/", dir_path.replace('\\', "/"))
                };
                files.keys().any(|k| k.starts_with(&prefix))
            }
        }
    }

    pub fn list_directory(&self, dir_path: &str) -> Vec<String> {
        match self {
            GameSource::Directory(base) => {
                let full = base.join(dir_path);
                std::fs::read_dir(full)
                    .map(|entries| {
                        entries
                            .filter_map(|e| e.ok())
                            .map(|e| e.file_name().to_string_lossy().into_owned())
                            .collect()
                    })
                    .unwrap_or_default()
            }
            GameSource::Zip { files, .. } => {
                let prefix = if dir_path.is_empty() {
                    String::new()
                } else if dir_path.ends_with('/') {
                    dir_path.replace('\\', "/")
                } else {
                    format!("{}/", dir_path.replace('\\', "/"))
                };
                let mut items = HashSet::new();
                for key in files.keys() {
                    if key.starts_with(&prefix) {
                        let rest = &key[prefix.len()..];
                        if let Some(slash) = rest.find('/') {
                            items.insert(rest[..slash].to_string());
                        } else if !rest.is_empty() {
                            items.insert(rest.to_string());
                        }
                    }
                }
                items.into_iter().collect()
            }
        }
    }

    pub fn source_base_directory(&self) -> String {
        match self {
            GameSource::Directory(base) => base.to_string_lossy().into_owned(),
            GameSource::Zip { base_dir, .. } => base_dir.clone(),
        }
    }
}

/// A loaded TTF font for text rendering
pub struct FontData {
    pub font: fontdue::Font,
}

impl FontData {
    /// Measure the width of a text string at a given size in pixels
    pub fn text_width_at(&self, text: &str, size: f32) -> f32 {
        let mut width = 0.0f32;
        for ch in text.chars() {
            let metrics = self.font.metrics(ch, size);
            width += metrics.advance_width;
        }
        width
    }

    /// Get the line height at the stored size
    pub fn line_height_at(&self, size: f32) -> f32 {
        let metrics = self.font.horizontal_line_metrics(size);
        match metrics {
            Some(m) => m.ascent - m.descent + m.line_gap,
            None => size,
        }
    }

    /// Rasterize text into RGBA pixels (white on transparent) at a given size
    /// Returns (width, height, pixels)
    pub fn rasterize_text_at(&self, text: &str, size: f32) -> (u32, u32, Vec<u8>) {
        if text.is_empty() {
            return (0, 0, vec![]);
        }

        let metrics = self.font.horizontal_line_metrics(size);
        let (ascent, height) = match metrics {
            Some(m) => (m.ascent.ceil() as i32, (m.ascent - m.descent).ceil() as u32),
            None => (size as i32, size.ceil() as u32),
        };

        // First pass: measure total width
        let mut total_width = 0.0f32;
        for ch in text.chars() {
            let m = self.font.metrics(ch, size);
            total_width += m.advance_width;
        }

        let width = total_width.ceil() as u32;
        if width == 0 || height == 0 {
            return (0, 0, vec![]);
        }

        let mut pixels = vec![0u8; (width * height * 4) as usize];

        // Second pass: render glyphs
        let mut cursor_x = 0.0f32;
        for ch in text.chars() {
            let (m, bitmap) = self.font.rasterize(ch, size);
            let bw = m.width;
            let bh = m.height;
            let bmp = &bitmap;

            let glyph_x = cursor_x as i32 + m.xmin;
            let glyph_y = ascent - bh as i32 - m.ymin;

            for gy in 0..bh {
                for gx in 0..bw {
                    let px = glyph_x + gx as i32;
                    let py = glyph_y + gy as i32;
                    if px >= 0 && (px as u32) < width && py >= 0 && (py as u32) < height {
                        let alpha = bmp[gy * bw + gx];
                        if alpha > 0 {
                            let idx = ((py as u32 * width + px as u32) * 4) as usize;
                            pixels[idx] = 255;
                            pixels[idx + 1] = 255;
                            pixels[idx + 2] = 255;
                            pixels[idx + 3] = alpha;
                        }
                    }
                }
            }
            cursor_x += m.advance_width;
        }

        (width, height, pixels)
    }
}

/// A loaded image's RGBA pixel data
pub struct ImageData {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>, // RGBA, row-major, 4 bytes per pixel
}

/// A single sprite entry in a SpriteBatch
#[derive(Clone)]
pub struct SpriteBatchEntry {
    pub quad_x: f32,
    pub quad_y: f32,
    pub quad_w: f32,
    pub quad_h: f32,
    pub x: f32,
    pub y: f32,
    pub r: f32,
    pub sx: f32,
    pub sy: f32,
    pub ox: f32,
    pub oy: f32,
    pub color: Option<[f32; 4]>, // per-sprite color override
}

/// SpriteBatch data
pub struct SpriteBatchData {
    pub image_id: u64,
    pub entries: Vec<SpriteBatchEntry>,
    pub color: Option<[f32; 4]>,
}

#[derive(Clone, Copy)]
pub struct CachedTextImage {
    pub image_id: u64,
    pub width: i32,
    pub height: i32,
    pub bytes: usize,
}

#[derive(Default)]
pub struct TextImageCache {
    pub entries: HashMap<Vec<u8>, CachedTextImage>,
    pub order: VecDeque<Vec<u8>>,
    pub bytes: usize,
}

/// Central state shared across all LÖVE subsystems via Arc
pub struct SharedState {
    // Graphics
    pub pixel_buffer: Mutex<PixelBuffer>,
    pub current_color: Mutex<LoveColor>,
    pub background_color: Mutex<LoveColor>,
    pub transform_stack: Mutex<Vec<Transform>>,
    pub line_width: Mutex<f32>,
    pub active_font_size: Mutex<f32>,
    pub canvas_width: Mutex<u32>,
    pub canvas_height: Mutex<u32>,

    // Image registry
    pub images: Mutex<HashMap<u64, ImageData>>,
    pub next_image_id: Mutex<u64>,
    pub text_image_cache: Mutex<TextImageCache>,

    // Canvas registry
    pub canvases: Mutex<HashMap<u64, PixelBuffer>>,
    pub next_canvas_id: Mutex<u64>,
    /// Currently active canvas ID (0 = screen)
    pub active_canvas: Mutex<u64>,

    // SpriteBatch registry
    pub sprite_batches: Mutex<HashMap<u64, SpriteBatchData>>,
    pub next_spritebatch_id: Mutex<u64>,

    // Font registry
    pub fonts: Mutex<HashMap<u64, Arc<FontData>>>,
    pub font_source_cache: Mutex<HashMap<String, u64>>,
    pub next_font_id: Mutex<u64>,
    pub active_font_id: Mutex<u64>,

    // Scissor (clip region)
    pub scissor: Mutex<Option<(i32, i32, u32, u32)>>,

    // Stencil test settings (global, like scissor — synced to active buffer)
    pub stencil_compare: Mutex<StencilCompare>,
    pub stencil_ref: Mutex<u8>,

    // Graphics state stack for push("all")/pop()
    pub state_stack: Mutex<Vec<Option<SavedGraphicsState>>>,

    // Timer
    pub start_time: Instant,
    pub last_step_time: Mutex<Instant>,
    pub last_dt: Mutex<f32>,
    pub fps_counter: Mutex<FpsCounter>,

    // Input
    pub keys_down: RwLock<HashSet<String>>,
    pub mouse_buttons_down: RwLock<HashSet<u8>>,
    pub mouse_x: Mutex<f32>,
    pub mouse_y: Mutex<f32>,

    // Events
    pub event_queue: Mutex<VecDeque<LoveEvent>>,
    pub should_quit: Mutex<bool>,

    // Filesystem
    pub game_source: Mutex<GameSource>,
    pub save_dir: PathBuf,
    pub identity: Mutex<String>,
    pub window_title: Mutex<String>,

    // Active shader state (for dissolve emulation)
    pub active_shader_dissolve: Mutex<f32>,
    pub active_shader_shadow: Mutex<bool>,
    /// True when a fullscreen post-processing shader (CRT, etc.) is active.
    /// Drawing a canvas with this flag auto-clears the target first.
    pub active_shader_fullscreen: Mutex<bool>,
    /// True when the procedural background shader is active.
    /// Draw calls should fill with procedural colors instead of sampling texture.
    pub active_shader_background: Mutex<bool>,
    /// The three background colors sent via shader:send(), stored as [r,g,b,a] f32.
    /// [0]=colour_1 (center), [1]=colour_2 (light), [2]=colour_3 (dark)
    pub background_shader_colours: Mutex<[[f32; 4]; 3]>,
    /// Background shader uniforms: [time, spin_time, spin_amount, contrast]
    pub background_shader_params: Mutex<[f32; 4]>,
    /// True when the active shader ignores texture pixels (procedural output only).
    /// Image draws should be skipped since raw texture pixels are always wrong.
    pub active_shader_no_texture: Mutex<bool>,
    /// Dissolve burn edge colors: [r,g,b,a] f32 for the dissolve shader.
    /// burn_colour_1 = inner edge color, burn_colour_2 = outer edge color.
    pub dissolve_burn_colour_1: Mutex<[f32; 4]>,
    pub dissolve_burn_colour_2: Mutex<[f32; 4]>,
    /// Active card effect shader (for tint modifications).
    /// 0 = none, 1 = played, 2 = debuff, 3 = foil, 4 = holo, 5 = polychrome, 6 = negative
    pub active_card_shader: Mutex<u8>,
    /// Flame shader params: [amount, c1_r, c1_g, c1_b, c2_r, c2_g, c2_b, id, time]
    pub flame_shader_params: Mutex<[f32; 9]>,
    /// True when the active shader is the flame shader
    pub active_shader_flame: Mutex<bool>,
    /// Flash shader alpha (mid_flash uniform)
    pub flash_shader_alpha: Mutex<f32>,
    /// True when the active shader is the flash shader
    pub active_shader_flash: Mutex<bool>,

    // Blend mode
    pub blend_mode: Mutex<BlendMode>,

    // Filter mode: true = linear (bilinear interpolation), false = nearest
    pub default_filter_linear: Mutex<bool>,

    // CRT post-processing parameters
    /// [bloom_fac, crt_intensity] — captured from CRT shader:send() calls
    pub crt_params: Mutex<[f32; 2]>,

    // Canvas auto-clear tracking: set of canvas IDs activated this frame.
    // On first setCanvas(c) per frame, canvas is auto-cleared to transparent.
    pub canvases_activated_this_frame: Mutex<HashSet<u64>>,
    // Text overlays — collected each frame, rendered as terminal characters
}

impl SharedState {
    pub fn new(game_path: &Path, canvas_width: u32, canvas_height: u32) -> anyhow::Result<Self> {
        let game_source = GameSource::from_path(game_path)?;
        let identity = std::env::var("LOVE_IDENTITY")
            .unwrap_or_else(|_| "love-lite".to_owned())
            .chars()
            .map(|value| {
                if value.is_ascii_alphanumeric() || matches!(value, '_' | '-' | '.') {
                    value
                } else {
                    '_'
                }
            })
            .collect::<String>();
        let save_dir = dirs::data_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("love-lite")
            .join(&identity);
        std::fs::create_dir_all(&save_dir).ok();
        let window_title =
            std::env::var("LOVE_WINDOW_TITLE").unwrap_or_else(|_| "LOVE-lite".to_owned());

        let now = Instant::now();
        Ok(SharedState {
            pixel_buffer: Mutex::new(PixelBuffer::new(canvas_width, canvas_height)),
            current_color: Mutex::new([1.0, 1.0, 1.0, 1.0]),
            background_color: Mutex::new([0.0, 0.0, 0.0, 1.0]),
            transform_stack: Mutex::new(vec![Transform::default()]),
            line_width: Mutex::new(1.0),
            active_font_size: Mutex::new(12.0),
            canvas_width: Mutex::new(canvas_width),
            canvas_height: Mutex::new(canvas_height),
            images: Mutex::new(HashMap::new()),
            next_image_id: Mutex::new(1),
            text_image_cache: Mutex::new(TextImageCache::default()),
            canvases: Mutex::new(HashMap::new()),
            next_canvas_id: Mutex::new(1),
            active_canvas: Mutex::new(0),
            sprite_batches: Mutex::new(HashMap::new()),
            next_spritebatch_id: Mutex::new(1),
            fonts: Mutex::new(HashMap::new()),
            font_source_cache: Mutex::new(HashMap::new()),
            next_font_id: Mutex::new(1),
            active_font_id: Mutex::new(0),
            scissor: Mutex::new(None),
            stencil_compare: Mutex::new(StencilCompare::Disabled),
            stencil_ref: Mutex::new(0),
            state_stack: Mutex::new(Vec::new()),
            start_time: now,
            last_step_time: Mutex::new(now),
            last_dt: Mutex::new(0.0),
            fps_counter: Mutex::new(FpsCounter::new()),
            keys_down: RwLock::new(HashSet::new()),
            mouse_buttons_down: RwLock::new(HashSet::new()),
            mouse_x: Mutex::new(canvas_width as f32 / 2.0),
            mouse_y: Mutex::new(canvas_height as f32 / 2.0),
            event_queue: Mutex::new(VecDeque::new()),
            should_quit: Mutex::new(false),
            game_source: Mutex::new(game_source),
            save_dir,
            identity: Mutex::new(identity),
            window_title: Mutex::new(window_title),
            active_shader_dissolve: Mutex::new(0.0),
            active_shader_shadow: Mutex::new(false),
            active_shader_fullscreen: Mutex::new(false),
            active_shader_background: Mutex::new(false),
            background_shader_colours: Mutex::new([
                [0.216, 0.259, 0.267, 1.0], // colour_1 = HEX("374244")
                [1.0, 1.0, 0.0, 1.0],       // colour_2 = yellow
                [0.216, 0.259, 0.267, 1.0], // colour_3 = HEX("374244")
            ]),
            background_shader_params: Mutex::new([0.0, 0.0, 0.0, 1.5]),
            active_shader_no_texture: Mutex::new(false),
            dissolve_burn_colour_1: Mutex::new([0.0; 4]),
            dissolve_burn_colour_2: Mutex::new([0.0; 4]),
            active_card_shader: Mutex::new(0),
            flame_shader_params: Mutex::new([0.0; 9]),
            active_shader_flame: Mutex::new(false),
            flash_shader_alpha: Mutex::new(0.0),
            active_shader_flash: Mutex::new(false),
            blend_mode: Mutex::new(BlendMode::default()),
            default_filter_linear: Mutex::new(false),
            crt_params: Mutex::new([0.0, 0.0]),
            canvases_activated_this_frame: Mutex::new(HashSet::new()),
        })
    }

    /// Map BlendMode to pixel buffer blend code (0=alpha, 1=replace, 2=add, 3=multiply).
    pub fn blend_code(&self) -> u8 {
        match *self.blend_mode.lock() {
            BlendMode::Replace => 1,
            BlendMode::Add => 2,
            BlendMode::Multiply => 3,
            BlendMode::Screen => 5,
            BlendMode::Alpha => 0,
        }
    }

    /// Execute a closure with a mutable reference to the active drawing target.
    /// If a canvas is active, operates on that canvas's PixelBuffer.
    /// Otherwise operates on the screen pixel_buffer.
    /// Syncs blend mode, filter, scissor, and stencil test to the pixel buffer.
    pub fn with_active_buffer<F, R>(&self, f: F) -> R
    where
        F: FnOnce(&mut PixelBuffer) -> R,
    {
        let blend = self.blend_code();
        let filter = *self.default_filter_linear.lock();
        let scissor = *self.scissor.lock();
        let st_cmp = *self.stencil_compare.lock();
        let st_ref = *self.stencil_ref.lock();
        let active = *self.active_canvas.lock();
        if active == 0 {
            let mut pb = self.pixel_buffer.lock();
            pb.blend = blend;
            pb.filter_linear = filter;
            pb.scissor = scissor;
            pb.stencil_compare = st_cmp;
            pb.stencil_ref = st_ref;
            f(&mut pb)
        } else {
            let mut canvases = self.canvases.lock();
            if let Some(canvas_buf) = canvases.get_mut(&active) {
                canvas_buf.blend = blend;
                canvas_buf.filter_linear = filter;
                canvas_buf.scissor = scissor;
                canvas_buf.stencil_compare = st_cmp;
                canvas_buf.stencil_ref = st_ref;
                f(canvas_buf)
            } else {
                let mut pb = self.pixel_buffer.lock();
                pb.blend = blend;
                pb.filter_linear = filter;
                pb.scissor = scissor;
                pb.stencil_compare = st_cmp;
                pb.stencil_ref = st_ref;
                f(&mut pb)
            }
        }
    }
}
