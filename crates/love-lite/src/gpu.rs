use std::collections::HashMap;

use anyhow::{Context, Result};
use love_lite::{Engine, GpuCommand};
use sdl2::pixels::{Color, PixelFormatEnum};
use sdl2::rect::{FPoint, FRect, Rect};
use sdl2::render::{BlendMode, Canvas, ScaleMode, Texture, TextureCreator};
use sdl2::video::{Window, WindowContext};

struct CachedTexture<'a> {
    texture: Texture<'a>,
    width: u32,
    height: u32,
}

pub struct GpuRenderer<'a> {
    creator: &'a TextureCreator<WindowContext>,
    textures: HashMap<u64, CachedTexture<'a>>,
}

impl<'a> GpuRenderer<'a> {
    pub fn new(creator: &'a TextureCreator<WindowContext>) -> Self {
        Self {
            creator,
            textures: HashMap::new(),
        }
    }

    pub fn render(
        &mut self,
        canvas: &mut Canvas<Window>,
        engine: &Engine,
        commands: &[GpuCommand],
    ) -> Result<()> {
        // Text images are evicted by the bounded LOVE-side cache. Mirror that
        // lifecycle here so changing progress/status strings cannot retain GPU
        // textures for the entire process lifetime.
        if self.textures.len() > 512 {
            let active_images = engine.active_image_ids();
            self.textures
                .retain(|image_id, _| active_images.contains(image_id));
        }
        canvas.set_blend_mode(BlendMode::Blend);
        for command in commands {
            match command {
                GpuCommand::Clear { color } => {
                    canvas.set_clip_rect(None);
                    canvas.set_draw_color(sdl_color(*color));
                    canvas.clear();
                }
                GpuCommand::Rectangle {
                    fill,
                    x,
                    y,
                    width,
                    height,
                    radius,
                    line_width,
                    color,
                    clip,
                } => {
                    set_clip(canvas, *clip);
                    canvas.set_draw_color(sdl_color(*color));
                    if *fill {
                        fill_rounded_rect(canvas, *x, *y, *width, *height, *radius)?;
                    } else {
                        stroke_rounded_rect(canvas, *x, *y, *width, *height, *radius, *line_width)?;
                    }
                }
                GpuCommand::Line {
                    points,
                    line_width,
                    color,
                    clip,
                } => {
                    set_clip(canvas, *clip);
                    canvas.set_draw_color(sdl_color(*color));
                    draw_polyline(canvas, points, *line_width, false)?;
                }
                GpuCommand::Polygon {
                    fill,
                    points,
                    line_width,
                    color,
                    clip,
                } => {
                    set_clip(canvas, *clip);
                    canvas.set_draw_color(sdl_color(*color));
                    if *fill {
                        fill_polygon(canvas, points)?;
                    } else {
                        draw_polyline(canvas, points, *line_width, true)?;
                    }
                }
                GpuCommand::Image {
                    image_id,
                    source,
                    destination,
                    color,
                    clip,
                } => {
                    set_clip(canvas, *clip);
                    if !self.textures.contains_key(image_id) {
                        let (width, height, pixels) = engine
                            .image_rgba(*image_id)
                            .with_context(|| format!("missing GPU image {image_id}"))?;
                        let mut texture = self
                            .creator
                            .create_texture_static(PixelFormatEnum::RGBA32, width, height)
                            .map_err(anyhow::Error::msg)?;
                        texture.set_blend_mode(BlendMode::Blend);
                        texture.set_scale_mode(ScaleMode::Nearest);
                        texture
                            .update(None, &pixels, width as usize * 4)
                            .map_err(anyhow::Error::msg)?;
                        self.textures.insert(
                            *image_id,
                            CachedTexture {
                                texture,
                                width,
                                height,
                            },
                        );
                    }
                    let cached = self.textures.get_mut(image_id).expect("inserted texture");
                    let (src_x, src_y, src_w, src_h) = *source;
                    anyhow::ensure!(
                        src_x >= 0
                            && src_y >= 0
                            && src_w > 0
                            && src_h > 0
                            && src_x as u32 + src_w <= cached.width
                            && src_y as u32 + src_h <= cached.height,
                        "GPU image source is outside texture {image_id}"
                    );
                    cached.texture.set_color_mod(color[0], color[1], color[2]);
                    cached.texture.set_alpha_mod(color[3]);
                    let src = Rect::new(src_x, src_y, src_w, src_h);
                    let dst = FRect::new(
                        destination.0,
                        destination.1,
                        destination.2.max(0.0),
                        destination.3.max(0.0),
                    );
                    canvas
                        .copy_f(&cached.texture, src, dst)
                        .map_err(anyhow::Error::msg)?;
                }
            }
        }
        canvas.set_clip_rect(None);
        Ok(())
    }
}

fn sdl_color(color: [u8; 4]) -> Color {
    Color::RGBA(color[0], color[1], color[2], color[3])
}

fn set_clip(canvas: &mut Canvas<Window>, clip: Option<(i32, i32, u32, u32)>) {
    canvas.set_clip_rect(clip.map(|(x, y, width, height)| Rect::new(x, y, width, height)));
}

fn fill_rounded_rect(
    canvas: &mut Canvas<Window>,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    radius: f32,
) -> Result<()> {
    if width <= 0.0 || height <= 0.0 {
        return Ok(());
    }
    let radius = radius.max(0.0).min(width / 2.0).min(height / 2.0);
    if radius < 1.0 {
        return canvas
            .fill_frect(FRect::new(x, y, width, height))
            .map_err(anyhow::Error::msg);
    }
    canvas
        .fill_frect(FRect::new(x, y + radius, width, height - radius * 2.0))
        .map_err(anyhow::Error::msg)?;
    let rows = radius.ceil() as i32;
    for row in 0..rows {
        let dy = radius - row as f32 - 0.5;
        let dx = (radius * radius - dy * dy).max(0.0).sqrt();
        let left = x + radius - dx;
        let right = x + width - radius + dx;
        canvas
            .draw_fline(
                FPoint::new(left, y + row as f32),
                FPoint::new(right, y + row as f32),
            )
            .map_err(anyhow::Error::msg)?;
        canvas
            .draw_fline(
                FPoint::new(left, y + height - row as f32 - 1.0),
                FPoint::new(right, y + height - row as f32 - 1.0),
            )
            .map_err(anyhow::Error::msg)?;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn stroke_rounded_rect(
    canvas: &mut Canvas<Window>,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    radius: f32,
    line_width: f32,
) -> Result<()> {
    if width <= 0.0 || height <= 0.0 {
        return Ok(());
    }
    let radius = radius.max(0.0).min(width / 2.0).min(height / 2.0);
    let layers = line_width.max(1.0).round() as i32;
    for layer in 0..layers {
        let inset = layer as f32;
        let left = x + inset;
        let top = y + inset;
        let right = x + width - inset - 1.0;
        let bottom = y + height - inset - 1.0;
        let r = (radius - inset).max(0.0);
        if r < 1.0 {
            canvas
                .draw_frect(FRect::new(
                    left,
                    top,
                    right - left + 1.0,
                    bottom - top + 1.0,
                ))
                .map_err(anyhow::Error::msg)?;
            continue;
        }
        canvas
            .draw_fline(FPoint::new(left + r, top), FPoint::new(right - r, top))
            .map_err(anyhow::Error::msg)?;
        canvas
            .draw_fline(
                FPoint::new(left + r, bottom),
                FPoint::new(right - r, bottom),
            )
            .map_err(anyhow::Error::msg)?;
        canvas
            .draw_fline(FPoint::new(left, top + r), FPoint::new(left, bottom - r))
            .map_err(anyhow::Error::msg)?;
        canvas
            .draw_fline(FPoint::new(right, top + r), FPoint::new(right, bottom - r))
            .map_err(anyhow::Error::msg)?;
        let segments = (r * 1.6).ceil().max(8.0) as i32;
        for segment in 0..=segments {
            let angle = std::f32::consts::FRAC_PI_2 * segment as f32 / segments as f32;
            let dx = angle.cos() * r;
            let dy = angle.sin() * r;
            for point in [
                FPoint::new(right - r + dx, top + r - dy),
                FPoint::new(left + r - dx, top + r - dy),
                FPoint::new(left + r - dx, bottom - r + dy),
                FPoint::new(right - r + dx, bottom - r + dy),
            ] {
                canvas.draw_fpoint(point).map_err(anyhow::Error::msg)?;
            }
        }
    }
    Ok(())
}

fn draw_polyline(
    canvas: &mut Canvas<Window>,
    points: &[(f32, f32)],
    line_width: f32,
    close: bool,
) -> Result<()> {
    if points.len() < 2 {
        return Ok(());
    }
    let count = if close {
        points.len()
    } else {
        points.len() - 1
    };
    for index in 0..count {
        let start = points[index];
        let end = points[(index + 1) % points.len()];
        draw_thick_line(canvas, start, end, line_width)?;
    }
    Ok(())
}

fn draw_thick_line(
    canvas: &mut Canvas<Window>,
    start: (f32, f32),
    end: (f32, f32),
    width: f32,
) -> Result<()> {
    let layers = width.max(1.0).round() as i32;
    let dx = end.0 - start.0;
    let dy = end.1 - start.1;
    let length = (dx * dx + dy * dy).sqrt().max(1.0);
    let nx = -dy / length;
    let ny = dx / length;
    let center = (layers - 1) as f32 / 2.0;
    for layer in 0..layers {
        let offset = layer as f32 - center;
        canvas
            .draw_fline(
                FPoint::new(start.0 + nx * offset, start.1 + ny * offset),
                FPoint::new(end.0 + nx * offset, end.1 + ny * offset),
            )
            .map_err(anyhow::Error::msg)?;
    }
    Ok(())
}

fn fill_polygon(canvas: &mut Canvas<Window>, points: &[(f32, f32)]) -> Result<()> {
    if points.len() < 3 {
        return Ok(());
    }
    let min_y = points
        .iter()
        .map(|point| point.1)
        .fold(f32::INFINITY, f32::min)
        .floor() as i32;
    let max_y = points
        .iter()
        .map(|point| point.1)
        .fold(f32::NEG_INFINITY, f32::max)
        .ceil() as i32;
    let mut intersections = Vec::with_capacity(points.len());
    for y in min_y..=max_y {
        let scan_y = y as f32 + 0.5;
        intersections.clear();
        for index in 0..points.len() {
            let a = points[index];
            let b = points[(index + 1) % points.len()];
            if (a.1 <= scan_y && b.1 > scan_y) || (b.1 <= scan_y && a.1 > scan_y) {
                let ratio = (scan_y - a.1) / (b.1 - a.1);
                intersections.push(a.0 + ratio * (b.0 - a.0));
            }
        }
        intersections.sort_by(f32::total_cmp);
        for pair in intersections.chunks_exact(2) {
            canvas
                .draw_fline(FPoint::new(pair[0], scan_y), FPoint::new(pair[1], scan_y))
                .map_err(anyhow::Error::msg)?;
        }
    }
    Ok(())
}
