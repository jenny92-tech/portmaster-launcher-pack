// INPUT:  ConfigureRequest、结构化 TOML 编辑器与已有配置文件
// OUTPUT: ConfigureRequest、ConfiguredDimensions、configure()
// POS:    将显示、渲染、内存、图形后端和按键设置写到各自固定的 Unity 配置表
use std::io;
use std::path::PathBuf;

use serde_json::{Map, Value, json};
use toml_edit::{DocumentMut, Item};

#[derive(Default)]
pub struct ConfigureRequest {
    pub path: PathBuf,
    /// Optional legacy hint. Dimensions belong to device and buttons to
    /// input.remap; omitting the hint never writes those keys at root.
    pub section: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub buttons: Option<[String; 4]>,
    pub render_scale_percent: Option<u32>,
    pub memory_mode: Option<String>,
    /// Android API selection: gles preserves the GLES request; gles30/32 force it.
    pub graphics_api: Option<String>,
    /// config preserves the selected API's filter; Vulkan accepts linear only.
    pub render_filter: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub struct ConfiguredDimensions {
    pub output_width: u32,
    pub output_height: u32,
    pub render_width: u32,
    pub render_height: u32,
}

pub fn configure(request: &ConfigureRequest) -> io::Result<ConfiguredDimensions> {
    validate(request)?;
    let mut document = crate::toml::read_document(&request.path)?;
    let mut patch = Map::new();
    if let (Some(width), Some(height)) = (request.width, request.height) {
        patch.insert(
            "device".into(),
            json!({"displayWidth":width,"displayHeight":height}),
        );
    }
    if let Some(buttons) = &request.buttons {
        patch.insert(
            "input".into(),
            json!({"remap":{
                "a":buttons[0],"b":buttons[1],"x":buttons[2],"y":buttons[3]
            }}),
        );
    }
    if let Some(mode) = &request.memory_mode {
        patch.insert("runtime".into(), json!({"memory_mode":mode}));
    }
    if let Some(percent) = request.render_scale_percent {
        let native = native_backend(&document)?;
        let sharp = sharp_filter(&document)?;
        if native && sharp {
            return Err(invalid(
                "wayland_native needs an explicit linear filter; refusing to change image quality",
            ));
        }
        let (render_width, render_height) = if native {
            let width = output_dimension(request.width, &document, "displayWidth")?;
            let height = output_dimension(request.height, &document, "displayHeight")?;
            (
                (width * u64::from(percent) / 100).max(1),
                (height * u64::from(percent) / 100).max(1),
            )
        } else {
            (0, 0)
        };
        patch.insert(
            "gpu".into(),
            json!({
                "renderScalePercent":percent,"renderScaleSharp":sharp,
                "renderWidth":render_width,"renderHeight":render_height,
                "renderScaleDivisor":null,"renderScaleLinear":null
            }),
        );
    }
    crate::toml::apply_patch(&mut document, &Value::Object(patch))?;
    if let Some(api) = request.graphics_api.as_deref() {
        crate::unity_graphics::configure(&mut document, api)?;
    }
    if let Some(filter) = request.render_filter.as_deref() {
        crate::unity_graphics::configure_filter(&mut document, filter)?;
    }
    let dimensions = configured_dimensions(&document)?;
    crate::toml::write_document(&request.path, &document)?;
    Ok(dimensions)
}

fn validate(request: &ConfigureRequest) -> io::Result<()> {
    if request.width.is_some() != request.height.is_some() {
        return Err(invalid("width and height must be supplied together"));
    }
    for dimension in [request.width, request.height].into_iter().flatten() {
        if !(1..=32768).contains(&dimension) {
            return Err(invalid("dimensions must be in 1..=32768"));
        }
    }
    if request
        .render_scale_percent
        .is_some_and(|p| !matches!(p, 100 | 75 | 50))
    {
        return Err(invalid("render scale percent must be 100, 75 or 50"));
    }
    if let Some(mode) = request.memory_mode.as_deref() {
        if !matches!(mode, "low_memory" | "balanced" | "performance") {
            return Err(invalid(
                "memory mode must be low_memory, balanced or performance",
            ));
        }
    }
    if let Some(section) = request.section.as_deref() {
        if !matches!(section, "device" | "input.remap")
            || (request.width.is_some() && section != "device")
            || (request.buttons.is_some() && section != "input.remap")
        {
            return Err(invalid(
                "dimensions belong to device; button mappings belong to input.remap",
            ));
        }
    }
    if let Some(buttons) = &request.buttons {
        if buttons.iter().any(|value| {
            value.is_empty()
                || !value
                    .bytes()
                    .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
        }) {
            return Err(invalid(
                "button values may contain only A-Z, 0-9 and underscore",
            ));
        }
    }
    if request.width.is_none()
        && request.buttons.is_none()
        && request.render_scale_percent.is_none()
        && request.memory_mode.is_none()
        && request.graphics_api.is_none()
        && request.render_filter.is_none()
    {
        return Err(invalid(
            "unity configure requires dimensions, render scale, memory mode, graphics API or buttons",
        ));
    }
    Ok(())
}

fn setting<'a>(document: &'a DocumentMut, table: &str, key: &str) -> Option<&'a Item> {
    document.get(table)?.as_table_like()?.get(key)
}

fn output_dimension(explicit: Option<u32>, document: &DocumentMut, key: &str) -> io::Result<u64> {
    let value = explicit
        .map(i64::from)
        .or_else(|| setting(document, "device", key).and_then(dimension_integer))
        .ok_or_else(|| invalid("wayland_native render scale needs device output dimensions"))?;
    if !(1..=32768).contains(&value) {
        return Err(invalid("invalid output dimensions for wayland_native"));
    }
    Ok(value as u64)
}

// Rudroid accepts TOML integers, booleans and lossless integral floats here.
// Geometry is bounded to 0..32768 below, so larger floats can be rejected
// before conversion without risking a lossy cast.
fn dimension_integer(item: &Item) -> Option<i64> {
    item.as_integer()
        .or_else(|| item.as_bool().map(i64::from))
        .or_else(|| {
            item.as_float()
                .filter(|n| (0.0..=32768.0).contains(n) && n.fract() == 0.0)
                .map(|n| n as i64)
        })
}

fn native_backend(document: &DocumentMut) -> io::Result<bool> {
    match setting(document, "gpu", "presentationBackend") {
        None => Ok(false),
        Some(item) => match item.as_str() {
            Some("internal") => Ok(false),
            Some("wayland_native") => Ok(true),
            _ => Err(invalid(
                "gpu.presentationBackend must be internal or wayland_native",
            )),
        },
    }
}

fn sharp_filter(document: &DocumentMut) -> io::Result<bool> {
    match setting(document, "gpu", "renderScaleSharp") {
        None => Ok(true),
        Some(item) => item
            .as_bool()
            .or_else(|| item.as_integer().map(|n| n != 0))
            .ok_or_else(|| invalid("gpu.renderScaleSharp must be a boolean or integer")),
    }
}

fn configured_dimensions(document: &DocumentMut) -> io::Result<ConfiguredDimensions> {
    for table in ["device", "gpu"] {
        if document
            .get(table)
            .is_some_and(|item| item.as_table_like().is_none())
        {
            return Err(invalid("device and gpu must be TOML tables"));
        }
    }
    let integer = |table, key, default| -> io::Result<i64> {
        match setting(document, table, key) {
            None => Ok(default),
            Some(item) => dimension_integer(item)
                .ok_or_else(|| invalid("display and render dimensions must be integers")),
        }
    };
    let output_width = integer("device", "displayWidth", 640)?;
    let output_height = integer("device", "displayHeight", 480)?;
    let width = integer("gpu", "renderWidth", 0)?;
    let height = integer("gpu", "renderHeight", 0)?;
    let percent = integer("gpu", "renderScalePercent", 100)?;
    if !(1..=32768).contains(&output_width)
        || !(1..=32768).contains(&output_height)
        || !(0..=32768).contains(&width)
        || !(0..=32768).contains(&height)
        || (width == 0) != (height == 0)
        || !matches!(percent, 50 | 75 | 100)
    {
        return Err(invalid("invalid Unity output/render dimensions"));
    }
    let sharp = sharp_filter(document)?;
    if native_backend(document)? && (width == 0 || height == 0 || sharp) {
        return Err(invalid(
            "wayland_native requires exact render dimensions and renderScaleSharp=false",
        ));
    }
    let scaled = |output: i64, exact: i64| if exact > 0 { exact } else { (output * percent / 100).max(1) } as u32;
    Ok(ConfiguredDimensions {
        output_width: output_width as u32,
        output_height: output_height as u32,
        render_width: scaled(output_width, width),
        render_height: scaled(output_height, height),
    })
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}
