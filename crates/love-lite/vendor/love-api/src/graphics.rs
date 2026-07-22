use mlua::prelude::*;
use parking_lot::Mutex;
use std::sync::Arc;

use crate::lua_util::{color_f32_to_u8, parse_color};
use crate::state::{
    BlendMode, CachedTextImage, FontData, GpuCommand, ImageData, SavedGraphicsState, SharedState,
    Transform,
};
use sprite_to_text::pixel_buffer::{DissolveParams, PixelBuffer, StencilCompare};

/// Kind of resource tracked by a ResourceGuard.
#[derive(Clone, Copy)]
enum ResourceKind {
    Image,
    Canvas,
    SpriteBatch,
}

/// Guard that removes a resource from SharedState when Lua GC collects it.
/// Attached as userdata inside image/canvas/spritebatch tables.
struct ResourceGuard {
    id: u64,
    kind: ResourceKind,
    state: Arc<SharedState>,
}

impl Drop for ResourceGuard {
    fn drop(&mut self) {
        match self.kind {
            ResourceKind::Image => {
                self.state.images.lock().remove(&self.id);
            }
            ResourceKind::Canvas => {
                self.state.canvases.lock().remove(&self.id);
            }
            ResourceKind::SpriteBatch => {
                self.state.sprite_batches.lock().remove(&self.id);
            }
        }
    }
}

impl LuaUserData for ResourceGuard {}
pub fn register(lua: &Lua, love: &LuaTable, state: Arc<SharedState>) -> LuaResult<()> {
    let g = lua.create_table()?;

    // love.graphics.clear([r, g, b, a])
    {
        let s = Arc::clone(&state);
        g.set(
            "clear",
            lua.create_function(move |_, args: LuaMultiValue| {
                let color = if args.is_empty() {
                    *s.background_color.lock()
                } else {
                    parse_color(&args)
                };
                if s.is_gpu_recording() {
                    s.record_gpu(GpuCommand::Clear {
                        color: color_f32_to_u8(color),
                    });
                    return Ok(());
                }
                s.with_active_buffer(|pb| {
                    pb.clear(color[0], color[1], color[2], color[3]);
                    pb.clear_stencil();
                });
                Ok(())
            })?,
        )?;
    }

    // love.graphics.setColor(r, g, b [, a]) or setColor({r, g, b, a})
    {
        let s = Arc::clone(&state);
        g.set(
            "setColor",
            lua.create_function(move |_, args: LuaMultiValue| {
                let c = parse_color(&args);
                *s.current_color.lock() = c;
                Ok(())
            })?,
        )?;
    }

    // love.graphics.getColor()
    {
        let s = Arc::clone(&state);
        g.set(
            "getColor",
            lua.create_function(move |_, ()| {
                let c = *s.current_color.lock();
                Ok((c[0] as f64, c[1] as f64, c[2] as f64, c[3] as f64))
            })?,
        )?;
    }

    // love.graphics.setBackgroundColor(r, g, b [, a])
    {
        let s = Arc::clone(&state);
        g.set(
            "setBackgroundColor",
            lua.create_function(move |_, args: LuaMultiValue| {
                *s.background_color.lock() = parse_color(&args);
                Ok(())
            })?,
        )?;
    }

    // love.graphics.rectangle(mode, x, y, w, h [, rx, ry])
    {
        let s = Arc::clone(&state);
        g.set(
            "rectangle",
            lua.create_function(
                move |_,
                      (mode, x, y, w, h, rx, ry): (
                    String,
                    f32,
                    f32,
                    f32,
                    f32,
                    Option<f32>,
                    Option<f32>,
                )| {
                    let color = color_f32_to_u8(*s.current_color.lock());
                    let t = current_transform(&s);

                    // Detect rotation in transform (b/c non-zero means shear/rotation)
                    let has_rotation = t.b.abs() > 0.001 || t.c.abs() > 0.001;

                    if has_rotation && mode == "fill" {
                        // Rotated rectangle: transform all 4 corners and fill as polygon
                        let corners = [
                            t.apply(x, y),
                            t.apply(x + w, y),
                            t.apply(x + w, y + h),
                            t.apply(x, y + h),
                        ];
                        s.with_active_buffer(|pb| {
                            fill_polygon(pb, &corners, color);
                        });
                        return Ok(());
                    }

                    let (p0x, p0y) = t.apply(x, y);
                    let (p1x, p1y) = t.apply(x + w, y + h);
                    let px = p0x.min(p1x) as i32;
                    let py = p0y.min(p1y) as i32;
                    let pw = (p1x - p0x).abs() as i32;
                    let ph = (p1y - p0y).abs() as i32;

                    let (scale_x, scale_y) = t.scale_factor();
                    let lw = ((*s.line_width.lock()) * scale_x.max(scale_y)).max(1.0) as u32;
                    let rrx = (rx.unwrap_or(0.0) * scale_x) as i32;
                    let rry = (ry.unwrap_or_else(|| rx.unwrap_or(0.0)) * scale_y) as i32;

                    if s.is_gpu_recording() {
                        if has_rotation {
                            s.reject_gpu_frame();
                        } else {
                            s.record_gpu(GpuCommand::Rectangle {
                                fill: mode == "fill",
                                x: px as f32,
                                y: py as f32,
                                width: pw as f32,
                                height: ph as f32,
                                radius: rrx.max(rry) as f32,
                                line_width: lw as f32,
                                color,
                                clip: *s.scissor.lock(),
                            });
                        }
                        return Ok(());
                    }

                    s.with_active_buffer(|pb| {
                        if mode == "fill" {
                            if rrx > 0 || rry > 0 {
                                pb.fill_rounded_rect(px, py, pw, ph, rrx, rry, color);
                            } else {
                                pb.fill_rect(px, py, pw, ph, color);
                            }
                        } else if rrx > 0 || rry > 0 {
                            pb.stroke_rounded_rect(px, py, pw, ph, rrx, rry, lw, color);
                        } else {
                            pb.stroke_rect(px, py, pw, ph, lw, color);
                        }
                    });
                    Ok(())
                },
            )?,
        )?;
    }

    // love.graphics.print(text, x, y [, r, sx, sy, ox, oy])
    {
        let s = Arc::clone(&state);
        g.set(
            "print",
            lua.create_function(move |_, args: LuaMultiValue| {
                let Some(value) = args.front() else {
                    return Ok(());
                };
                let font_size = *s.active_font_size.lock();
                let font_id = *s.active_font_id.lock();
                let (image_id, width, height, cached) =
                    if let Some(segments) = parse_colored_text(value) {
                        let key = colored_text_cache_key(font_id, font_size, &segments);
                        cached_text_image(&s, key, || {
                            render_colored_text_to_image(&s, &segments, font_size)
                        })
                    } else {
                        let text = extract_text_from_lua(value);
                        let key = plain_text_cache_key(b'p', font_id, font_size, &text, &[]);
                        cached_text_image(&s, key, || render_text_to_image(&s, &text, font_size))
                    };
                draw_transient_text(
                    &s,
                    image_id,
                    width,
                    height,
                    parse_num_arg(args.get(1), 0.0),
                    parse_num_arg(args.get(2), 0.0),
                    parse_num_arg(args.get(3), 0.0),
                    parse_num_arg(args.get(4), 1.0),
                    parse_num_arg(args.get(5), parse_num_arg(args.get(4), 1.0)),
                    parse_num_arg(args.get(6), 0.0),
                    parse_num_arg(args.get(7), 0.0),
                    cached,
                );
                Ok(())
            })?,
        )?;
    }

    // love.graphics.printf(text, x, y, limit [, align, r, sx, sy, ox, oy])
    {
        let s = Arc::clone(&state);
        g.set(
            "printf",
            lua.create_function(move |_, args: LuaMultiValue| {
                let Some(value) = args.front() else {
                    return Ok(());
                };
                let text = extract_text_from_lua(value);
                let limit = parse_num_arg(args.get(3), 0.0);
                if text.is_empty() || limit <= 0.0 {
                    return Ok(());
                }
                let align = match args.get(4) {
                    Some(LuaValue::String(value)) => value.to_string_lossy(),
                    _ => "left".into(),
                };
                let font_size = *s.active_font_size.lock();
                let font_id = *s.active_font_id.lock();
                let mut extra = Vec::with_capacity(4 + align.len());
                extra.extend_from_slice(&limit.to_bits().to_le_bytes());
                extra.extend_from_slice(align.as_bytes());
                let key = plain_text_cache_key(b'w', font_id, font_size, &text, &extra);
                let (image_id, width, height, cached) = cached_text_image(&s, key, || {
                    render_text_to_image_wrapped(&s, &text, font_size, limit, &align)
                });
                draw_transient_text(
                    &s,
                    image_id,
                    width,
                    height,
                    parse_num_arg(args.get(1), 0.0),
                    parse_num_arg(args.get(2), 0.0),
                    parse_num_arg(args.get(5), 0.0),
                    parse_num_arg(args.get(6), 1.0),
                    parse_num_arg(args.get(7), parse_num_arg(args.get(6), 1.0)),
                    parse_num_arg(args.get(8), 0.0),
                    parse_num_arg(args.get(9), 0.0),
                    cached,
                );
                Ok(())
            })?,
        )?;
    }

    // love.graphics.push()
    {
        let s = Arc::clone(&state);
        g.set(
            "push",
            lua.create_function(move |_, args: LuaMultiValue| {
                let is_all = match args.get(0) {
                    Some(LuaValue::String(s)) => s.to_string_lossy() == "all",
                    _ => false,
                };
                let mut stack = s.transform_stack.lock();
                let top = stack.last().cloned().unwrap_or_default();
                stack.push(top);
                drop(stack);
                if is_all {
                    s.state_stack.lock().push(Some(SavedGraphicsState {
                        color: *s.current_color.lock(),
                        scissor: *s.scissor.lock(),
                        stencil_compare: *s.stencil_compare.lock(),
                        stencil_ref: *s.stencil_ref.lock(),
                        line_width: *s.line_width.lock(),
                        font_size: *s.active_font_size.lock(),
                        font_id: *s.active_font_id.lock(),
                        active_canvas: *s.active_canvas.lock(),
                        blend_mode: *s.blend_mode.lock(),
                    }));
                } else {
                    s.state_stack.lock().push(None);
                }
                Ok(())
            })?,
        )?;
    }

    // love.graphics.pop()
    {
        let s = Arc::clone(&state);
        g.set(
            "pop",
            lua.create_function(move |_, ()| {
                let mut stack = s.transform_stack.lock();
                if stack.len() > 1 {
                    stack.pop();
                }
                drop(stack);
                if let Some(saved_opt) = s.state_stack.lock().pop() {
                    if let Some(saved) = saved_opt {
                        *s.current_color.lock() = saved.color;
                        *s.scissor.lock() = saved.scissor;
                        *s.stencil_compare.lock() = saved.stencil_compare;
                        *s.stencil_ref.lock() = saved.stencil_ref;
                        *s.line_width.lock() = saved.line_width;
                        *s.active_font_size.lock() = saved.font_size;
                        *s.active_font_id.lock() = saved.font_id;
                        // Restore canvas first so subsequent syncs target the right buffer
                        *s.active_canvas.lock() = saved.active_canvas;
                        *s.blend_mode.lock() = saved.blend_mode;
                    }
                }
                Ok(())
            })?,
        )?;
    }

    // love.graphics.translate(x, y)
    {
        let s = Arc::clone(&state);
        g.set(
            "translate",
            lua.create_function(move |_, (x, y): (f32, f32)| {
                let mut stack = s.transform_stack.lock();
                if let Some(t) = stack.last_mut() {
                    t.translate(x, y);
                }
                Ok(())
            })?,
        )?;
    }

    // love.graphics.scale(sx [, sy])
    {
        let s = Arc::clone(&state);
        g.set(
            "scale",
            lua.create_function(move |_, (sx, sy): (f32, Option<f32>)| {
                let sy = sy.unwrap_or(sx);
                let mut stack = s.transform_stack.lock();
                if let Some(t) = stack.last_mut() {
                    t.scale(sx, sy);
                }
                Ok(())
            })?,
        )?;
    }

    // love.graphics.rotate(r)
    {
        let s = Arc::clone(&state);
        g.set(
            "rotate",
            lua.create_function(move |_, r: f32| {
                let mut stack = s.transform_stack.lock();
                if let Some(t) = stack.last_mut() {
                    t.rotate(r);
                }
                Ok(())
            })?,
        )?;
    }

    // love.graphics.origin()
    {
        let s = Arc::clone(&state);
        g.set(
            "origin",
            lua.create_function(move |_, ()| {
                let mut stack = s.transform_stack.lock();
                if let Some(t) = stack.last_mut() {
                    *t = Transform::default();
                }
                Ok(())
            })?,
        )?;
    }

    // love.graphics.reset()
    {
        let s = Arc::clone(&state);
        g.set(
            "reset",
            lua.create_function(move |_, ()| {
                *s.transform_stack.lock() = vec![Transform::default()];
                *s.current_color.lock() = [1.0, 1.0, 1.0, 1.0];
                *s.line_width.lock() = 1.0;
                *s.active_font_size.lock() = 12.0;
                *s.active_font_id.lock() = 0;
                *s.scissor.lock() = None;
                *s.stencil_compare.lock() = StencilCompare::Disabled;
                *s.stencil_ref.lock() = 0;
                *s.active_canvas.lock() = 0;
                *s.blend_mode.lock() = BlendMode::default();
                Ok(())
            })?,
        )?;
    }

    // love.graphics.getWidth()
    {
        let s = Arc::clone(&state);
        g.set(
            "getWidth",
            lua.create_function(move |_, ()| Ok(*s.canvas_width.lock()))?,
        )?;
    }

    // love.graphics.getHeight()
    {
        let s = Arc::clone(&state);
        g.set(
            "getHeight",
            lua.create_function(move |_, ()| Ok(*s.canvas_height.lock()))?,
        )?;
    }

    // love.graphics.getDimensions()
    {
        let s = Arc::clone(&state);
        g.set(
            "getDimensions",
            lua.create_function(move |_, ()| {
                Ok((*s.canvas_width.lock(), *s.canvas_height.lock()))
            })?,
        )?;
    }

    // love.graphics.getPixelWidth() — alias for getWidth
    {
        let s = Arc::clone(&state);
        g.set(
            "getPixelWidth",
            lua.create_function(move |_, ()| Ok(*s.canvas_width.lock()))?,
        )?;
    }

    // love.graphics.getPixelHeight() — alias for getHeight
    {
        let s = Arc::clone(&state);
        g.set(
            "getPixelHeight",
            lua.create_function(move |_, ()| Ok(*s.canvas_height.lock()))?,
        )?;
    }

    // love.graphics.isActive()
    g.set("isActive", lua.create_function(|_, ()| Ok(true))?)?;

    // love.graphics.isCreated()
    g.set("isCreated", lua.create_function(|_, ()| Ok(true))?)?;

    // love.graphics.present() — noop, rendering happens in Rust main loop
    g.set("present", lua.create_function(|_, ()| Ok(()))?)?;

    // love.graphics.setLineWidth(width)
    {
        let s = Arc::clone(&state);
        g.set(
            "setLineWidth",
            lua.create_function(move |_, w: f32| {
                *s.line_width.lock() = w;
                Ok(())
            })?,
        )?;
    }

    // love.graphics.getLineWidth()
    {
        let s = Arc::clone(&state);
        g.set(
            "getLineWidth",
            lua.create_function(move |_, ()| Ok(*s.line_width.lock()))?,
        )?;
    }

    // love.graphics.draw(drawable, [quad], x, y, r, sx, sy, ox, oy)
    {
        let s = Arc::clone(&state);
        g.set(
            "draw",
            lua.create_function(move |_, args: LuaMultiValue| {
                if args.is_empty() {
                    return Ok(());
                }

                let drawable = match args.get(0) {
                    Some(LuaValue::Table(t)) => t.clone(),
                    _ => return Ok(()),
                };

                // Check if this drawable has an _image_id (Image), _canvas_id (Canvas), or _spritebatch_id
                let image_id: Option<u64> = drawable.get("_image_id").ok();
                let canvas_id: Option<u64> = drawable.get("_canvas_id").ok();
                let spritebatch_id: Option<u64> = drawable.get("_spritebatch_id").ok();

                if image_id.is_none() && canvas_id.is_none() && spritebatch_id.is_none() {
                    return Ok(());
                }

                // Parse remaining args: could be (quad, x, y, ...) or (x, y, ...)
                let mut arg_idx = 1;
                let (quad_x, quad_y, quad_w, quad_h, has_quad) = match args.get(1) {
                    Some(LuaValue::Table(t)) => {
                        // Could be a Quad if it has _x/_y/_w/_h
                        match (
                            t.get::<f32>("_x"),
                            t.get::<f32>("_y"),
                            t.get::<f32>("_w"),
                            t.get::<f32>("_h"),
                        ) {
                            (Ok(qx), Ok(qy), Ok(qw), Ok(qh)) => {
                                arg_idx = 2;
                                (qx, qy, qw, qh, true)
                            }
                            _ => (0.0, 0.0, 0.0, 0.0, false),
                        }
                    }
                    _ => (0.0, 0.0, 0.0, 0.0, false),
                };

                let get_f32 = |idx: usize| -> f32 {
                    match args.get(idx) {
                        Some(LuaValue::Number(n)) => *n as f32,
                        Some(LuaValue::Integer(n)) => *n as f32,
                        _ => 0.0,
                    }
                };

                let x = get_f32(arg_idx);
                let y = get_f32(arg_idx + 1);
                let r = get_f32(arg_idx + 2);
                let sx = match args.get(arg_idx + 3) {
                    Some(LuaValue::Number(n)) => *n as f32,
                    Some(LuaValue::Integer(n)) => *n as f32,
                    _ => 1.0,
                };
                let sy = match args.get(arg_idx + 4) {
                    Some(LuaValue::Number(n)) => *n as f32,
                    Some(LuaValue::Integer(n)) => *n as f32,
                    _ => sx,
                };
                let ox = get_f32(arg_idx + 5);
                let oy = get_f32(arg_idx + 6);

                let t = current_transform(&s);
                let mut color = color_f32_to_u8(*s.current_color.lock());
                let replace = *s.blend_mode.lock() == BlendMode::Replace;
                let is_fullscreen_shader = *s.active_shader_fullscreen.lock();

                if s.is_gpu_recording() {
                    let gpu_image = image_id.and_then(|id| {
                        s.images
                            .lock()
                            .get(&id)
                            .map(|image| (id, image.width, image.height))
                    });
                    if canvas_id.is_some()
                        || spritebatch_id.is_some()
                        || r.abs() > 0.001
                        || sx <= 0.0
                        || sy <= 0.0
                        || t.b.abs() > 0.001
                        || t.c.abs() > 0.001
                    {
                        s.reject_gpu_frame();
                        return Ok(());
                    }
                    if let Some((id, image_width, image_height)) = gpu_image {
                        let (src_x, src_y, src_w, src_h) = if has_quad {
                            (quad_x, quad_y, quad_w, quad_h)
                        } else {
                            (0.0, 0.0, image_width as f32, image_height as f32)
                        };
                        let (scale_tx, scale_ty) = t.scale_factor();
                        let (tx, ty) = t.apply(x - ox * sx, y - oy * sy);
                        s.record_gpu(GpuCommand::Image {
                            image_id: id,
                            source: (
                                src_x.round() as i32,
                                src_y.round() as i32,
                                src_w.max(0.0).round() as u32,
                                src_h.max(0.0).round() as u32,
                            ),
                            destination: (tx, ty, src_w * sx * scale_tx, src_h * sy * scale_ty),
                            color,
                            clip: *s.scissor.lock(),
                        });
                    } else {
                        s.reject_gpu_frame();
                    }
                    return Ok(());
                }

                // Dissolve shader emulation — build DissolveParams for per-pixel noise
                let dissolve = *s.active_shader_dissolve.lock();
                let is_shadow = *s.active_shader_shadow.lock();

                if dissolve > 0.6 {
                    // Fully dissolved — skip draw entirely
                    return Ok(());
                }

                if is_shadow {
                    // Shadow pass: skip entirely in TUI mode.
                    // Terminal's 2-color-per-cell quantizer makes semi-transparent
                    // shadows visible as "ghost copies" of every element.
                    return Ok(());
                }

                // Card shader effects
                let card_shader = *s.active_card_shader.lock();
                // Spatial shaders: per-pixel effects applied during blit
                let has_spatial_shader = card_shader >= 1 && card_shader <= 11;
                let shader_time = if !is_shadow && (has_spatial_shader || dissolve > 0.01) {
                    s.start_time.elapsed().as_secs_f32()
                } else {
                    0.0
                };

                let dp = if (dissolve > 0.01 && !is_shadow) || (!is_shadow && has_spatial_shader) {
                    let (b1_arr, b2_arr) = if dissolve > 0.01 {
                        let b1 = *s.dissolve_burn_colour_1.lock();
                        let b2 = *s.dissolve_burn_colour_2.lock();
                        (
                            [
                                (b1[0] * 255.0) as u8,
                                (b1[1] * 255.0) as u8,
                                (b1[2] * 255.0) as u8,
                                (b1[3] * 255.0) as u8,
                            ],
                            [
                                (b2[0] * 255.0) as u8,
                                (b2[1] * 255.0) as u8,
                                (b2[2] * 255.0) as u8,
                                (b2[3] * 255.0) as u8,
                            ],
                        )
                    } else {
                        ([0, 0, 0, 0], [0, 0, 0, 0])
                    };
                    DissolveParams {
                        dissolve,
                        burn1: b1_arr,
                        burn2: b2_arr,
                        shader_effect: card_shader,
                        shader_time,
                        sprite_w: if has_quad { quad_w } else { 71.0 },
                        sprite_h: if has_quad { quad_h } else { 95.0 },
                    }
                } else {
                    DissolveParams::NONE
                };

                // Uniform card shader effects (non-spatial: hologram only)
                if !is_shadow && card_shader == 9 {
                    // Hologram: translucent cyan-blue ghost effect
                    let avg = ((color[0] as u16 + color[1] as u16 + color[2] as u16) / 3) as u8;
                    color[0] = (avg as u16 * 77 / 255).min(255) as u8;
                    color[1] = (avg as u16 * 200 / 255).min(255) as u8;
                    color[2] = (avg as u16 * 240 / 255).min(255) as u8;
                    color[3] = (color[3] as u16 * 180 / 255) as u8;
                }

                if let Some(canvas_id) = canvas_id {
                    // When a fullscreen post-processing shader is active (CRT),
                    // use replace mode since the shader would fully overwrite the target
                    let use_replace = replace || is_fullscreen_shader;

                    // Canvas pixels are premultiplied alpha in LÖVE2D.
                    // Use premultiplied blend (mode 4) unless replace is requested.
                    let canvas_blend: u8 = if use_replace { 1 } else { 4 };

                    // Optimize: avoid cloning canvas pixels when drawing to screen
                    let active = *s.active_canvas.lock();
                    if active == 0 {
                        // Canvas → screen: hold both locks, no clone needed
                        let canvases = s.canvases.lock();
                        if let Some(cb) = canvases.get(&canvas_id) {
                            let (src_x, src_y, src_w, src_h) = if has_quad {
                                (quad_x, quad_y, quad_w, quad_h)
                            } else {
                                (0.0, 0.0, cb.width as f32, cb.height as f32)
                            };
                            let mut pb = s.pixel_buffer.lock();
                            pb.blend = canvas_blend;
                            pb.scissor = *s.scissor.lock();
                            pb.stencil_compare = *s.stencil_compare.lock();
                            pb.stencil_ref = *s.stencil_ref.lock();
                            draw_region_to_buf(
                                &mut pb,
                                &cb.pixels,
                                cb.width,
                                cb.height,
                                src_x,
                                src_y,
                                src_w,
                                src_h,
                                x,
                                y,
                                r,
                                sx,
                                sy,
                                ox,
                                oy,
                                &t,
                                color,
                                use_replace,
                                dp,
                            );
                        }
                    } else {
                        // Canvas → canvas: clone to avoid potential self-reference
                        let canvas_snapshot = {
                            let canvases = s.canvases.lock();
                            canvases
                                .get(&canvas_id)
                                .map(|cb| (cb.width, cb.height, cb.pixels.clone()))
                        };
                        if let Some((cw, ch, ref pixels)) = canvas_snapshot {
                            let (src_x, src_y, src_w, src_h) = if has_quad {
                                (quad_x, quad_y, quad_w, quad_h)
                            } else {
                                (0.0, 0.0, cw as f32, ch as f32)
                            };
                            // Draw in single with_active_buffer call to keep canvas_blend
                            // (with_active_buffer resets blend from global state)
                            s.with_active_buffer(|pb| {
                                pb.blend = canvas_blend;
                                draw_region_to_buf(
                                    pb,
                                    pixels,
                                    cw,
                                    ch,
                                    src_x,
                                    src_y,
                                    src_w,
                                    src_h,
                                    x,
                                    y,
                                    r,
                                    sx,
                                    sy,
                                    ox,
                                    oy,
                                    &t,
                                    color,
                                    use_replace,
                                    dp,
                                );
                            });
                        }
                    }
                } else if let Some(image_id) = image_id {
                    // Skip draws when a no-texture shader is active (procedural output only).
                    // Background, flame, and flash shaders are handled specially.
                    let is_bg_shader = *s.active_shader_background.lock();
                    let is_no_tex = *s.active_shader_no_texture.lock();
                    let is_flame = *s.active_shader_flame.lock();
                    let is_flash = *s.active_shader_flash.lock();
                    if !is_bg_shader && !is_flame && !is_flash && is_no_tex {
                        return Ok(());
                    }
                    if is_flash {
                        // Flash shader: white overlay with mid_flash alpha
                        let mid_flash = *s.flash_shader_alpha.lock();
                        if mid_flash > 0.01 {
                            let (scale_x, scale_y) = t.scale_factor();
                            let images = s.images.lock();
                            if let Some(img) = images.get(&image_id) {
                                let (src_w, src_h) = if has_quad {
                                    (quad_w, quad_h)
                                } else {
                                    (img.width as f32, img.height as f32)
                                };
                                let dst_w = (src_w * sx.abs() * scale_x) as i32;
                                let dst_h = (src_h * sy.abs() * scale_y) as i32;
                                let (tx, ty) = t.apply(x - ox * sx, y - oy * sy);
                                drop(images);
                                let alpha_u8 = (mid_flash.min(1.0) * 255.0) as u8;
                                s.with_active_buffer(|pb| {
                                    let x0 = (tx as i32).max(0) as usize;
                                    let y0 = (ty as i32).max(0) as usize;
                                    let x1 = ((tx as i32 + dst_w) as usize).min(pb.width as usize);
                                    let y1 = ((ty as i32 + dst_h) as usize).min(pb.height as usize);
                                    for py in y0..y1 {
                                        for px in x0..x1 {
                                            let idx = (py * pb.width as usize + px) * 4;
                                            if idx + 3 < pb.pixels.len() {
                                                pb.blend_at(idx, 255, 255, 255, alpha_u8);
                                            }
                                        }
                                    }
                                });
                            }
                        }
                        return Ok(());
                    }
                    if is_flame {
                        // Flame shader: per-pixel turbulent fire effect matching flame.fs GLSL
                        let fp = *s.flame_shader_params.lock();
                        let amount = fp[0];
                        let intensity = amount.min(10.0);
                        if intensity > 0.1 {
                            let (scale_x, scale_y) = t.scale_factor();
                            let images = s.images.lock();
                            if let Some(img) = images.get(&image_id) {
                                let (src_w, src_h) = if has_quad {
                                    (quad_w, quad_h)
                                } else {
                                    (img.width as f32, img.height as f32)
                                };
                                let dst_w = (src_w * sx.abs() * scale_x) as i32;
                                let dst_h = (src_h * sy.abs() * scale_y) as i32;
                                let (tx, ty) = t.apply(x - ox * sx, y - oy * sy);
                                drop(images);
                                let c1 = [fp[1], fp[2], fp[3]];
                                let c2 = [fp[4], fp[5], fp[6]];
                                let flame_id = fp[7];
                                let time = fp[8]; // custom timer from Lua (advances at variable speed)
                                s.with_active_buffer(|pb| {
                                    let x0 = (tx as i32).max(0) as usize;
                                    let y0 = (ty as i32).max(0) as usize;
                                    let x1 = ((tx as i32 + dst_w) as usize).min(pb.width as usize);
                                    let y1 = ((ty as i32 + dst_h) as usize).min(pb.height as usize);
                                    let w_range = if x1 > x0 { x1 - x0 } else { 1 };
                                    let h_range = if y1 > y0 { y1 - y0 } else { 1 };
                                    for py in y0..y1 {
                                        // UV y: 0=top → 1=bottom, then center → -0.5..0.5
                                        let uy = (py - y0) as f32 / h_range as f32 - 0.5;
                                        for px in x0..x1 {
                                            let ux = (px - x0) as f32 / w_range as f32 - 0.5;
                                            let [r, g, b, a] = flame_pixel(
                                                ux, uy, time, intensity, flame_id, c1, c2,
                                            );
                                            if a > 0 {
                                                let idx = (py * pb.width as usize + px) * 4;
                                                if idx + 3 < pb.pixels.len() {
                                                    pb.blend_at(idx, r, g, b, a);
                                                }
                                            }
                                        }
                                    }
                                });
                            }
                        }
                        return Ok(());
                    }
                    if is_bg_shader {
                        let colours = *s.background_shader_colours.lock();
                        let bg_params = *s.background_shader_params.lock();
                        let (scale_x, scale_y) = t.scale_factor();
                        let images = s.images.lock();
                        if let Some(img) = images.get(&image_id) {
                            let (src_w, src_h) = if has_quad {
                                (quad_w, quad_h)
                            } else {
                                (img.width as f32, img.height as f32)
                            };
                            let dst_w = (src_w * sx.abs() * scale_x) as i32;
                            let dst_h = (src_h * sy.abs() * scale_y) as i32;
                            let (tx, ty) = t.apply(x - ox * sx, y - oy * sy);
                            drop(images);
                            s.with_active_buffer(|pb| {
                                pb.fill_procedural_background(
                                    tx as i32, ty as i32, dst_w, dst_h, &colours, bg_params,
                                );
                            });
                        }
                    } else {
                        let images = s.images.lock();
                        if let Some(img) = images.get(&image_id) {
                            let (src_x, src_y, src_w, src_h) = if has_quad {
                                (quad_x, quad_y, quad_w, quad_h)
                            } else {
                                (0.0, 0.0, img.width as f32, img.height as f32)
                            };
                            draw_region(
                                &s,
                                &img.pixels,
                                img.width,
                                img.height,
                                src_x,
                                src_y,
                                src_w,
                                src_h,
                                x,
                                y,
                                r,
                                sx,
                                sy,
                                ox,
                                oy,
                                &t,
                                color,
                                replace,
                                dp,
                            );
                        }
                    }
                } else if let Some(sb_id) = spritebatch_id {
                    // Skip SpriteBatch draws with no-texture or background shaders
                    if *s.active_shader_no_texture.lock() || *s.active_shader_background.lock() {
                        return Ok(());
                    }
                    // SpriteBatch: hold locks, avoid cloning entries
                    let sbs = s.sprite_batches.lock();
                    if let Some(data) = sbs.get(&sb_id) {
                        let images = s.images.lock();
                        if let Some(img) = images.get(&data.image_id) {
                            let mut batch_t = t.clone();
                            batch_t.translate(x, y);
                            if r.abs() > 0.001 {
                                batch_t.rotate(r);
                            }
                            batch_t.scale(sx, sy);
                            batch_t.translate(-ox, -oy);

                            let batch_tint = match data.color {
                                Some(c) => color_f32_to_u8(c),
                                None => color,
                            };

                            for entry in &data.entries {
                                let (src_x, src_y, src_w, src_h) = if entry.quad_w > 0.0 {
                                    (entry.quad_x, entry.quad_y, entry.quad_w, entry.quad_h)
                                } else {
                                    (0.0, 0.0, img.width as f32, img.height as f32)
                                };
                                draw_region(
                                    &s,
                                    &img.pixels,
                                    img.width,
                                    img.height,
                                    src_x,
                                    src_y,
                                    src_w,
                                    src_h,
                                    entry.x,
                                    entry.y,
                                    entry.r,
                                    entry.sx,
                                    entry.sy,
                                    entry.ox,
                                    entry.oy,
                                    &batch_t,
                                    batch_tint,
                                    replace,
                                    dp,
                                );
                            }
                        }
                    }
                }

                Ok(())
            })?,
        )?;
    }

    // love.graphics.line(x1, y1, x2, y2, ...)
    {
        let s = Arc::clone(&state);
        g.set(
            "line",
            lua.create_function(move |_, args: LuaMultiValue| {
                // Collect all coordinates as f32
                let mut coords: Vec<f32> = Vec::with_capacity(args.len());
                for arg in args.iter() {
                    match arg {
                        LuaValue::Number(n) => coords.push(*n as f32),
                        LuaValue::Integer(n) => coords.push(*n as f32),
                        _ => break,
                    }
                }
                if coords.len() < 4 || coords.len() % 2 != 0 {
                    return Ok(());
                }

                let color = color_f32_to_u8(*s.current_color.lock());
                let t = current_transform(&s);
                let lw = *s.line_width.lock();
                let (sfx, _) = t.scale_factor();
                let scaled_lw = (lw * sfx).max(1.0);

                if s.is_gpu_recording() {
                    let points = coords
                        .chunks_exact(2)
                        .map(|pair| t.apply(pair[0], pair[1]))
                        .collect();
                    s.record_gpu(GpuCommand::Line {
                        points,
                        line_width: scaled_lw,
                        color,
                        clip: *s.scissor.lock(),
                    });
                    return Ok(());
                }

                s.with_active_buffer(|pb| {
                    let mut i = 0;
                    while i + 3 < coords.len() {
                        let (x0, y0) = t.apply(coords[i], coords[i + 1]);
                        let (x1, y1) = t.apply(coords[i + 2], coords[i + 3]);
                        draw_thick_line(pb, x0, y0, x1, y1, scaled_lw, color);
                        i += 2;
                    }
                });
                Ok(())
            })?,
        )?;
    }

    // love.graphics.circle(mode, x, y, radius [, segments])
    {
        let s = Arc::clone(&state);
        g.set(
            "circle",
            lua.create_function(move |_, (mode, cx, cy, radius, _segments): (String, f32, f32, f32, Option<u32>)| {
                let color = color_f32_to_u8(*s.current_color.lock());
                let t = current_transform(&s);
                let (px_f, py_f) = t.apply(cx, cy);
                let px = px_f as i32;
                let py = py_f as i32;
                let (sfx, sfy) = t.scale_factor();
                let rx = (radius * sfx) as i32;
                let ry = (radius * sfy) as i32;

                s.with_active_buffer(|pb| {
                    if mode == "fill" {
                        draw_filled_ellipse(pb, px, py, rx, ry, color);
                    } else {
                        draw_stroke_ellipse(pb, px, py, rx, ry, color);
                    }
                });
                Ok(())
            })?,
        )?;
    }

    // love.graphics.ellipse(mode, x, y, radiusx, radiusy [, segments])
    {
        let s = Arc::clone(&state);
        g.set(
            "ellipse",
            lua.create_function(move |_, (mode, cx, cy, rx, ry, _seg): (String, f32, f32, f32, f32, Option<u32>)| {
                let color = color_f32_to_u8(*s.current_color.lock());
                let t = current_transform(&s);
                let (px, py) = t.apply(cx, cy);
                let (sfx, sfy) = t.scale_factor();
                let irx = (rx * sfx) as i32;
                let iry = (ry * sfy) as i32;
                s.with_active_buffer(|pb| {
                    if mode == "fill" {
                        draw_filled_ellipse(pb, px as i32, py as i32, irx, iry, color);
                    } else {
                        draw_stroke_ellipse(pb, px as i32, py as i32, irx, iry, color);
                    }
                });
                Ok(())
            })?,
        )?;
    }

    // love.graphics.arc(mode, x, y, radius, angle1, angle2 [, segments])
    {
        let s = Arc::clone(&state);
        g.set(
            "arc",
            lua.create_function(
                move |_,
                      (mode, cx, cy, radius, a1, a2, _seg): (
                    String,
                    f32,
                    f32,
                    f32,
                    f32,
                    f32,
                    Option<u32>,
                )| {
                    let color = color_f32_to_u8(*s.current_color.lock());
                    let t = current_transform(&s);
                    let (px, py) = t.apply(cx, cy);
                    let (sfx, sfy) = t.scale_factor();
                    let irx = (radius * sfx) as i32;
                    let iry = (radius * sfy) as i32;
                    // Approximate arc by drawing full ellipse (acceptable for terminal resolution)
                    s.with_active_buffer(|pb| {
                        if mode == "fill" {
                            draw_filled_ellipse(pb, px as i32, py as i32, irx, iry, color);
                        } else {
                            draw_stroke_ellipse(pb, px as i32, py as i32, irx, iry, color);
                        }
                    });
                    let _ = (a1, a2); // angles ignored in terminal approximation
                    Ok(())
                },
            )?,
        )?;
    }

    // love.graphics.points(...)
    {
        let s = Arc::clone(&state);
        g.set(
            "points",
            lua.create_function(move |_, args: LuaMultiValue| {
                let color = color_f32_to_u8(*s.current_color.lock());
                let t = current_transform(&s);
                let mut coords: Vec<f32> = Vec::new();
                for arg in args.iter() {
                    match arg {
                        LuaValue::Number(n) => coords.push(*n as f32),
                        LuaValue::Integer(n) => coords.push(*n as f32),
                        _ => break,
                    }
                }
                s.with_active_buffer(|pb| {
                    for pair in coords.chunks_exact(2) {
                        let (px, py) = t.apply(pair[0], pair[1]);
                        pb.set_pixel(px as u32, py as u32, color[0], color[1], color[2], color[3]);
                    }
                });
                Ok(())
            })?,
        )?;
    }

    // Stubs for functions that return objects
    register_graphics_object_stubs(lua, &g, &state)?;

    love.set("graphics", g)?;
    Ok(())
}

fn register_graphics_object_stubs(
    lua: &Lua,
    g: &LuaTable,
    state: &Arc<SharedState>,
) -> LuaResult<()> {
    // love.graphics.newImage(path_or_imagedata [, settings]) -> Image
    {
        let s = Arc::clone(state);
        g.set(
            "newImage",
            lua.create_function(move |lua, args: LuaMultiValue| {
                // Handle newImage(ImageData) — create Image from existing ImageData
                if let Some(LuaValue::Table(t)) = args.get(0) {
                    if let Ok(img_id) = t.get::<u64>("_image_id") {
                        let images = s.images.lock();
                        if let Some(img) = images.get(&img_id) {
                            let w = img.width;
                            let h = img.height;
                            drop(images);
                            return new_image_table(lua, &s, img_id, w, h);
                        }
                    }
                }
                let path = match args.get(0) {
                    Some(LuaValue::String(s)) => s.to_string_lossy().to_string(),
                    _ => return new_image_stub(lua, 1, 1),
                };

                // Load image data from game source
                let bytes = {
                    let source = s.game_source.lock();
                    source.read_file(&path).ok()
                };

                let (w, h, image_id) = match bytes {
                    Some(data) => {
                        match image::load_from_memory(&data) {
                            Ok(img) => {
                                let rgba = img.to_rgba8();
                                let w = rgba.width();
                                let h = rgba.height();
                                let pixels = rgba.into_raw();

                                // Store in image registry
                                let mut id_lock = s.next_image_id.lock();
                                let id = *id_lock;
                                *id_lock += 1;
                                drop(id_lock);

                                s.images.lock().insert(
                                    id,
                                    ImageData {
                                        width: w,
                                        height: h,
                                        pixels,
                                    },
                                );
                                (w, h, id)
                            }
                            Err(e) => {
                                eprintln!("[WARN] Failed to decode image '{}': {}", path, e);
                                return new_image_stub(lua, 1, 1);
                            }
                        }
                    }
                    None => {
                        eprintln!("[WARN] Image not found: '{}'", path);
                        return new_image_stub(lua, 1, 1);
                    }
                };

                new_image_table(lua, &s, image_id, w, h)
            })?,
        )?;
    }

    // love.graphics.newFont(path_or_size [, size]) -> Font
    {
        let s = Arc::clone(state);
        g.set(
            "newFont",
            lua.create_function(move |lua, args: LuaMultiValue| {
                let (source, size) = parse_font_args(&args);
                let font_id = load_font(&s, source);
                new_font_table(lua, &s, font_id, size)
            })?,
        )?;
    }

    // love.graphics.setNewFont(path_or_size [, size]) -> Font
    {
        let s = Arc::clone(state);
        g.set(
            "setNewFont",
            lua.create_function(move |lua, args: LuaMultiValue| {
                let (source, size) = parse_font_args(&args);
                let font_id = load_font(&s, source);
                *s.active_font_size.lock() = size;
                *s.active_font_id.lock() = font_id;
                new_font_table(lua, &s, font_id, size)
            })?,
        )?;
    }

    // love.graphics.setFont(font)
    {
        let s = Arc::clone(state);
        g.set(
            "setFont",
            lua.create_function(move |_, font: LuaValue| {
                if let LuaValue::Table(t) = font {
                    if let Ok(size) = t.get::<f32>("_size") {
                        *s.active_font_size.lock() = size;
                    }
                    if let Ok(fid) = t.get::<u64>("_font_id") {
                        *s.active_font_id.lock() = fid;
                    }
                }
                Ok(())
            })?,
        )?;
    }

    // love.graphics.getFont() -> Font
    {
        let s = Arc::clone(state);
        g.set(
            "getFont",
            lua.create_function(move |lua, ()| {
                let size = *s.active_font_size.lock();
                let font_id = *s.active_font_id.lock();
                new_font_table(lua, &s, font_id, size)
            })?,
        )?;
    }

    // love.graphics.newQuad(x, y, w, h, sw, sh) -> Quad
    // Also: newQuad(x, y, w, h, image) where image has getDimensions
    g.set(
        "newQuad",
        lua.create_function(
            |lua, (x, y, w, h, sw, sh): (f32, f32, f32, f32, LuaValue, LuaValue)| {
                let (sw_val, sh_val) = match (&sw, &sh) {
                    (LuaValue::Number(sw), LuaValue::Number(sh)) => (*sw as f32, *sh as f32),
                    (LuaValue::Integer(sw), LuaValue::Integer(sh)) => (*sw as f32, *sh as f32),
                    (LuaValue::Table(t), _) => {
                        // Image or texture passed — call getDimensions
                        let dims: Option<(u32, u32)> = t
                            .get::<LuaFunction>("getDimensions")
                            .ok()
                            .and_then(|f| f.call::<(u32, u32)>(LuaValue::Table(t.clone())).ok());
                        dims.map(|(w, h)| (w as f32, h as f32))
                            .unwrap_or((256.0, 256.0))
                    }
                    _ => (256.0, 256.0),
                };
                let quad = lua.create_table()?;
                quad.set("_is_quad", true)?;
                quad.set("_x", x)?;
                quad.set("_y", y)?;
                quad.set("_w", w)?;
                quad.set("_h", h)?;
                quad.set("_sw", sw_val)?;
                quad.set("_sh", sh_val)?;
                quad.set(
                    "getViewport",
                    lua.create_function(move |_, _self: LuaValue| Ok((x, y, w, h)))?,
                )?;
                quad.set(
                    "setViewport",
                    lua.create_function(
                        |_, (this, nx, ny, nw, nh): (LuaTable, f32, f32, f32, f32)| {
                            this.set("_x", nx)?;
                            this.set("_y", ny)?;
                            this.set("_w", nw)?;
                            this.set("_h", nh)?;
                            Ok(())
                        },
                    )?,
                )?;
                quad.set(
                    "type",
                    lua.create_function(|_, _self: LuaValue| Ok("Quad"))?,
                )?;
                quad.set(
                    "typeOf",
                    lua.create_function(|_, (_self, t): (LuaValue, String)| {
                        Ok(t == "Quad" || t == "Object")
                    })?,
                )?;
                Ok(LuaValue::Table(quad))
            },
        )?,
    )?;

    // love.graphics.newCanvas([w, h, settings]) -> Canvas
    {
        let s = Arc::clone(state);
        g.set(
            "newCanvas",
            lua.create_function(move |lua, args: LuaMultiValue| {
                let w = match args.get(0) {
                    Some(LuaValue::Number(n)) => *n as u32,
                    Some(LuaValue::Integer(n)) => *n as u32,
                    _ => *s.canvas_width.lock(),
                };
                let h = match args.get(1) {
                    Some(LuaValue::Number(n)) => *n as u32,
                    Some(LuaValue::Integer(n)) => *n as u32,
                    _ => *s.canvas_height.lock(),
                };

                // Allocate a canvas ID and create the PixelBuffer
                let canvas_id = {
                    let mut id_lock = s.next_canvas_id.lock();
                    let id = *id_lock;
                    *id_lock += 1;
                    id
                };
                s.canvases.lock().insert(canvas_id, PixelBuffer::new(w, h));

                let c = lua.create_table()?;
                c.set("_canvas_id", canvas_id)?;
                c.set(
                    "setFilter",
                    lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
                )?;
                c.set(
                    "getFilter",
                    lua.create_function(|_, _self: LuaValue| Ok(("nearest", "nearest")))?,
                )?;
                c.set(
                    "getDimensions",
                    lua.create_function(move |_, _self: LuaValue| Ok((w, h)))?,
                )?;
                c.set(
                    "getWidth",
                    lua.create_function(move |_, _self: LuaValue| Ok(w))?,
                )?;
                c.set(
                    "getHeight",
                    lua.create_function(move |_, _self: LuaValue| Ok(h))?,
                )?;
                c.set(
                    "getPixelWidth",
                    lua.create_function(move |_, _self: LuaValue| Ok(w))?,
                )?;
                c.set(
                    "getPixelHeight",
                    lua.create_function(move |_, _self: LuaValue| Ok(h))?,
                )?;

                // renderTo: set canvas active, call function, restore
                {
                    let sr = Arc::clone(&s);
                    c.set(
                        "renderTo",
                        lua.create_function(
                            move |_, (self_tbl, func): (LuaTable, LuaFunction)| {
                                let cid: u64 = self_tbl.get("_canvas_id").unwrap_or(0);
                                let prev = *sr.active_canvas.lock();
                                *sr.active_canvas.lock() = cid;
                                let result = func.call::<()>(());
                                *sr.active_canvas.lock() = prev;
                                result?;
                                Ok(())
                            },
                        )?,
                    )?;
                }

                {
                    let sr = Arc::clone(&s);
                    c.set(
                        "release",
                        lua.create_function(move |_, self_tbl: LuaTable| {
                            let cid: u64 = self_tbl.get("_canvas_id").unwrap_or(0);
                            sr.canvases.lock().remove(&cid);
                            Ok(())
                        })?,
                    )?;
                }

                c.set(
                    "type",
                    lua.create_function(|_, _self: LuaValue| Ok("Canvas"))?,
                )?;
                c.set(
                    "typeOf",
                    lua.create_function(|_, (_self, t): (LuaValue, String)| {
                        Ok(t == "Canvas" || t == "Texture" || t == "Drawable" || t == "Object")
                    })?,
                )?;

                // Attach GC guard
                let guard = lua.create_userdata(ResourceGuard {
                    id: canvas_id,
                    kind: ResourceKind::Canvas,
                    state: Arc::clone(&s),
                })?;
                c.set("_gc_guard", guard)?;

                Ok(LuaValue::Table(c))
            })?,
        )?;
    }

    // love.graphics.newShader(code) -> Shader
    {
        let s = Arc::clone(state);
        g.set(
            "newShader",
            lua.create_function(move |lua, args: LuaMultiValue| {
                let shader_tbl = lua.create_table()?;
                // Store a uniforms table to track sent values
                let uniforms = lua.create_table()?;
                shader_tbl.set("_uniforms", uniforms)?;

                shader_tbl.set("_is_background", false)?;

                // Detect shaders that don't sample the texture (procedural output only).
                // Drawing raw texture pixels for these shaders is always wrong.
                let source_str = match args.get(0) {
                    Some(LuaValue::String(s)) => s.to_string_lossy().to_string(),
                    _ => String::new(),
                };
                // Detect card effect shaders by their unique uniform names
                let card_shader: u8 = if source_str.contains("extern")
                    && source_str.contains("played")
                    && !source_str.contains("polychrome")
                {
                    1 // played
                } else if source_str.contains("extern") && source_str.contains("debuff") {
                    2 // debuff
                } else if source_str.contains("extern") && source_str.contains("foil") {
                    3 // foil
                } else if source_str.contains("extern")
                    && source_str.contains("holo")
                    && !source_str.contains("hologram")
                {
                    4 // holo
                } else if source_str.contains("extern") && source_str.contains("polychrome") {
                    5 // polychrome
                } else if source_str.contains("extern")
                    && source_str.contains("negative")
                    && !source_str.contains("negative_shine")
                {
                    6 // negative
                } else if source_str.contains("extern") && source_str.contains("voucher") {
                    7 // voucher
                } else if source_str.contains("extern") && source_str.contains("booster") {
                    8 // booster
                } else if source_str.contains("extern") && source_str.contains("hologram") {
                    9 // hologram
                } else if source_str.contains("extern") && source_str.contains("negative_shine") {
                    10 // negative_shine
                } else if source_str.contains("extern") && source_str.contains("gold_seal") {
                    11 // gold_seal
                } else {
                    0
                };
                shader_tbl.set("_card_shader", card_shader)?;

                let is_flame = source_str.contains("flame");
                let is_flash = source_str.contains("flash") && source_str.contains("mid_flash");
                let no_texture = source_str.contains("background")
                    || source_str.contains("splash")
                    || source_str.contains("skew")
                    || source_str.contains("vortex")
                    || is_flame
                    || is_flash;
                shader_tbl.set("_no_texture", no_texture)?;
                shader_tbl.set("_is_flame", is_flame)?;
                shader_tbl.set("_is_flash", is_flash)?;

                let sr = Arc::clone(&s);
                shader_tbl.set(
                    "send",
                    lua.create_function(
                        move |_, (self_tbl, name, value): (LuaTable, String, LuaMultiValue)| {
                            // Store the value in _uniforms table for potential future use
                            if let Ok(u) = self_tbl.get::<LuaTable>("_uniforms") {
                                if let Some(val) = value.get(0) {
                                    u.set(name.as_str(), val.clone()).ok();
                                }
                            }
                            // Auto-detect background shader by uniform names and capture colours.
                            // Only mark the shader table; setShader() reads _is_background.
                            match name.as_str() {
                                "colour_1" | "colour_2" | "colour_3" => {
                                    let is_flame =
                                        self_tbl.get::<bool>("_is_flame").unwrap_or(false);
                                    if is_flame {
                                        // Flame shader: capture colors into flame params
                                        if let Some(LuaValue::Table(ref ct)) = value.get(0) {
                                            let r: f32 = ct.get(1).unwrap_or(0.0);
                                            let g: f32 = ct.get(2).unwrap_or(0.0);
                                            let b: f32 = ct.get(3).unwrap_or(0.0);
                                            let mut fp = sr.flame_shader_params.lock();
                                            match name.as_str() {
                                                "colour_1" => {
                                                    fp[1] = r;
                                                    fp[2] = g;
                                                    fp[3] = b;
                                                }
                                                "colour_2" => {
                                                    fp[4] = r;
                                                    fp[5] = g;
                                                    fp[6] = b;
                                                }
                                                _ => {}
                                            }
                                        }
                                    } else {
                                        self_tbl.set("_is_background", true).ok();
                                        if let Some(LuaValue::Table(ref ct)) = value.get(0) {
                                            let r: f32 = ct.get(1).unwrap_or(0.0);
                                            let g: f32 = ct.get(2).unwrap_or(0.0);
                                            let b: f32 = ct.get(3).unwrap_or(0.0);
                                            let a: f32 = ct.get(4).unwrap_or(1.0);
                                            let mut colours = sr.background_shader_colours.lock();
                                            match name.as_str() {
                                                "colour_1" => colours[0] = [r, g, b, a],
                                                "colour_2" => colours[1] = [r, g, b, a],
                                                "colour_3" => colours[2] = [r, g, b, a],
                                                _ => {}
                                            }
                                        }
                                    }
                                }
                                "amount" => {
                                    // Flame shader intensity
                                    if let Some(val) = value.get(0) {
                                        let v = match val {
                                            LuaValue::Number(n) => *n as f32,
                                            LuaValue::Integer(n) => *n as f32,
                                            _ => 0.0,
                                        };
                                        sr.flame_shader_params.lock()[0] = v;
                                    }
                                }
                                "id" => {
                                    // Flame shader: per-instance id for variation
                                    if let Some(val) = value.get(0) {
                                        let v = match val {
                                            LuaValue::Number(n) => *n as f32,
                                            LuaValue::Integer(n) => *n as f32,
                                            _ => 0.0,
                                        };
                                        sr.flame_shader_params.lock()[7] = v;
                                    }
                                }
                                "mid_flash" => {
                                    // Flash shader alpha
                                    if let Some(val) = value.get(0) {
                                        let v = match val {
                                            LuaValue::Number(n) => *n as f32,
                                            LuaValue::Integer(n) => *n as f32,
                                            _ => 0.0,
                                        };
                                        *sr.flash_shader_alpha.lock() = v;
                                    }
                                }
                                // Live-update dissolve/shadow so mid-frame sends take effect
                                "dissolve" => {
                                    if let Some(val) = value.get(0) {
                                        let d = match val {
                                            LuaValue::Number(n) => *n as f32,
                                            LuaValue::Integer(n) => *n as f32,
                                            _ => 0.0,
                                        };
                                        *sr.active_shader_dissolve.lock() = d;
                                    }
                                }
                                "shadow" => {
                                    if let Some(val) = value.get(0) {
                                        let b = match val {
                                            LuaValue::Boolean(b) => *b,
                                            _ => false,
                                        };
                                        *sr.active_shader_shadow.lock() = b;
                                    }
                                }
                                "burn_colour_1" | "burn_colour_2" => {
                                    if let Some(LuaValue::Table(ref ct)) = value.get(0) {
                                        let r: f32 = ct.get(1).unwrap_or(0.0);
                                        let g: f32 = ct.get(2).unwrap_or(0.0);
                                        let b: f32 = ct.get(3).unwrap_or(0.0);
                                        let a: f32 = ct.get(4).unwrap_or(1.0);
                                        let target = if name == "burn_colour_1" {
                                            &sr.dissolve_burn_colour_1
                                        } else {
                                            &sr.dissolve_burn_colour_2
                                        };
                                        *target.lock() = [r, g, b, a];
                                    }
                                }
                                "time" | "spin_time" | "spin_amount" | "contrast" => {
                                    if let Some(val) = value.get(0) {
                                        let v = match val {
                                            LuaValue::Number(n) => *n as f32,
                                            LuaValue::Integer(n) => *n as f32,
                                            _ => 0.0,
                                        };
                                        if name == "time" {
                                            // Flame shader has its own custom timer
                                            let is_flame =
                                                self_tbl.get::<bool>("_is_flame").unwrap_or(false);
                                            if is_flame {
                                                sr.flame_shader_params.lock()[8] = v;
                                            }
                                        }
                                        let mut params = sr.background_shader_params.lock();
                                        match name.as_str() {
                                            "time" => params[0] = v,
                                            "spin_time" => params[1] = v,
                                            "spin_amount" => params[2] = v,
                                            "contrast" => params[3] = v,
                                            _ => {}
                                        }
                                    }
                                }
                                "bloom_fac" | "crt_intensity" => {
                                    if let Some(val) = value.get(0) {
                                        let v = match val {
                                            LuaValue::Number(n) => *n as f32,
                                            LuaValue::Integer(n) => *n as f32,
                                            _ => 0.0,
                                        };
                                        let mut params = sr.crt_params.lock();
                                        match name.as_str() {
                                            "bloom_fac" => params[0] = v,
                                            "crt_intensity" => params[1] = v,
                                            _ => {}
                                        }
                                    }
                                }
                                _ => {}
                            }
                            Ok(())
                        },
                    )?,
                )?;
                shader_tbl.set(
                    "hasUniform",
                    lua.create_function(|_, (_self, _name): (LuaValue, String)| Ok(true))?,
                )?;
                shader_tbl.set("release", lua.create_function(|_, _self: LuaValue| Ok(()))?)?;
                shader_tbl.set(
                    "type",
                    lua.create_function(|_, _self: LuaValue| Ok("Shader"))?,
                )?;
                shader_tbl.set(
                    "typeOf",
                    lua.create_function(|_, (_self, t): (LuaValue, String)| {
                        Ok(t == "Shader" || t == "Object")
                    })?,
                )?;
                Ok(LuaValue::Table(shader_tbl))
            })?,
        )?;
    }

    // love.graphics.newMesh(vertices, mode, usage) -> Mesh
    g.set(
        "newMesh",
        lua.create_function(|lua, _args: LuaMultiValue| {
            let m = lua.create_table()?;
            m.set(
                "setVertices",
                lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
            )?;
            m.set(
                "setVertex",
                lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
            )?;
            m.set(
                "setDrawRange",
                lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
            )?;
            m.set(
                "setTexture",
                lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
            )?;
            m.set(
                "getVertexCount",
                lua.create_function(|_, _self: LuaValue| Ok(0i32))?,
            )?;
            m.set(
                "setVertexMap",
                lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
            )?;
            m.set(
                "attachAttribute",
                lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
            )?;
            m.set("release", lua.create_function(|_, _self: LuaValue| Ok(()))?)?;
            m.set(
                "type",
                lua.create_function(|_, _self: LuaValue| Ok("Mesh"))?,
            )?;
            m.set(
                "typeOf",
                lua.create_function(|_, (_self, t): (LuaValue, String)| {
                    Ok(t == "Mesh" || t == "Drawable" || t == "Object")
                })?,
            )?;
            Ok(LuaValue::Table(m))
        })?,
    )?;

    // love.graphics.newSpriteBatch(image [, maxsprites, usage]) -> SpriteBatch
    {
        let s = Arc::clone(state);
        g.set(
            "newSpriteBatch",
            lua.create_function(move |lua, args: LuaMultiValue| {
                let image_id = match args.get(0) {
                    Some(LuaValue::Table(t)) => t.get::<u64>("_image_id").unwrap_or(0),
                    _ => 0,
                };
                let img_tbl = match args.get(0) {
                    Some(LuaValue::Table(t)) => t.clone(),
                    _ => lua.create_table()?,
                };

                // Create SpriteBatch in registry
                let sb_id = {
                    let mut next = s.next_spritebatch_id.lock();
                    let id = *next;
                    *next += 1;
                    id
                };
                s.sprite_batches.lock().insert(
                    sb_id,
                    crate::state::SpriteBatchData {
                        image_id,
                        entries: Vec::new(),
                        color: None,
                    },
                );

                let sb = lua.create_table()?;
                sb.set("_spritebatch_id", sb_id)?;
                sb.set("_image", img_tbl)?;

                // SpriteBatch:add([quad], x, y, r, sx, sy, ox, oy) -> id
                {
                    let sr = Arc::clone(&s);
                    sb.set(
                        "add",
                        lua.create_function(move |_, args: LuaMultiValue| {
                            let self_tbl = match args.get(0) {
                                Some(LuaValue::Table(t)) => t,
                                _ => return Ok(0i64),
                            };
                            let sb_id = self_tbl.get::<u64>("_spritebatch_id").unwrap_or(0);

                            let mut arg_idx = 1;
                            let (qx, qy, qw, qh) = match args.get(1) {
                                Some(LuaValue::Table(t)) => {
                                    match (
                                        t.get::<f32>("_x"),
                                        t.get::<f32>("_y"),
                                        t.get::<f32>("_w"),
                                        t.get::<f32>("_h"),
                                    ) {
                                        (Ok(x), Ok(y), Ok(w), Ok(h)) => {
                                            arg_idx = 2;
                                            (x, y, w, h)
                                        }
                                        _ => (0.0, 0.0, 0.0, 0.0),
                                    }
                                }
                                _ => (0.0, 0.0, 0.0, 0.0),
                            };

                            let gf = |idx: usize, def: f32| -> f32 {
                                match args.get(idx) {
                                    Some(LuaValue::Number(n)) => *n as f32,
                                    Some(LuaValue::Integer(n)) => *n as f32,
                                    _ => def,
                                }
                            };

                            let entry = crate::state::SpriteBatchEntry {
                                quad_x: qx,
                                quad_y: qy,
                                quad_w: qw,
                                quad_h: qh,
                                x: gf(arg_idx, 0.0),
                                y: gf(arg_idx + 1, 0.0),
                                r: gf(arg_idx + 2, 0.0),
                                sx: gf(arg_idx + 3, 1.0),
                                sy: gf(arg_idx + 4, gf(arg_idx + 3, 1.0)),
                                ox: gf(arg_idx + 5, 0.0),
                                oy: gf(arg_idx + 6, 0.0),
                                color: None,
                            };

                            let mut sbs = sr.sprite_batches.lock();
                            if let Some(data) = sbs.get_mut(&sb_id) {
                                data.entries.push(entry);
                                Ok(data.entries.len() as i64)
                            } else {
                                Ok(0i64)
                            }
                        })?,
                    )?;
                }

                // SpriteBatch:set(id, [quad], x, y, r, sx, sy, ox, oy)
                {
                    let sr = Arc::clone(&s);
                    sb.set(
                        "set",
                        lua.create_function(move |_, args: LuaMultiValue| {
                            let self_tbl = match args.get(0) {
                                Some(LuaValue::Table(t)) => t,
                                _ => return Ok(()),
                            };
                            let sb_id = self_tbl.get::<u64>("_spritebatch_id").unwrap_or(0);
                            let entry_id = match args.get(1) {
                                Some(LuaValue::Integer(n)) => (*n as usize).saturating_sub(1),
                                Some(LuaValue::Number(n)) => (*n as usize).saturating_sub(1),
                                _ => return Ok(()),
                            };

                            let mut arg_idx = 2;
                            let (qx, qy, qw, qh) = match args.get(2) {
                                Some(LuaValue::Table(t)) => {
                                    match (
                                        t.get::<f32>("_x"),
                                        t.get::<f32>("_y"),
                                        t.get::<f32>("_w"),
                                        t.get::<f32>("_h"),
                                    ) {
                                        (Ok(x), Ok(y), Ok(w), Ok(h)) => {
                                            arg_idx = 3;
                                            (x, y, w, h)
                                        }
                                        _ => (0.0, 0.0, 0.0, 0.0),
                                    }
                                }
                                _ => (0.0, 0.0, 0.0, 0.0),
                            };

                            let gf = |idx: usize, def: f32| -> f32 {
                                match args.get(idx) {
                                    Some(LuaValue::Number(n)) => *n as f32,
                                    Some(LuaValue::Integer(n)) => *n as f32,
                                    _ => def,
                                }
                            };

                            let entry = crate::state::SpriteBatchEntry {
                                quad_x: qx,
                                quad_y: qy,
                                quad_w: qw,
                                quad_h: qh,
                                x: gf(arg_idx, 0.0),
                                y: gf(arg_idx + 1, 0.0),
                                r: gf(arg_idx + 2, 0.0),
                                sx: gf(arg_idx + 3, 1.0),
                                sy: gf(arg_idx + 4, gf(arg_idx + 3, 1.0)),
                                ox: gf(arg_idx + 5, 0.0),
                                oy: gf(arg_idx + 6, 0.0),
                                color: None,
                            };

                            let mut sbs = sr.sprite_batches.lock();
                            if let Some(data) = sbs.get_mut(&sb_id) {
                                if entry_id < data.entries.len() {
                                    data.entries[entry_id] = entry;
                                }
                            }
                            Ok(())
                        })?,
                    )?;
                }

                // SpriteBatch:clear()
                {
                    let sr = Arc::clone(&s);
                    sb.set(
                        "clear",
                        lua.create_function(move |_, self_tbl: LuaTable| {
                            let sb_id = self_tbl.get::<u64>("_spritebatch_id").unwrap_or(0);
                            let mut sbs = sr.sprite_batches.lock();
                            if let Some(data) = sbs.get_mut(&sb_id) {
                                data.entries.clear();
                            }
                            Ok(())
                        })?,
                    )?;
                }

                // SpriteBatch:flush() — noop for software renderer
                sb.set("flush", lua.create_function(|_, _self: LuaValue| Ok(()))?)?;

                // SpriteBatch:getCount()
                {
                    let sr = Arc::clone(&s);
                    sb.set(
                        "getCount",
                        lua.create_function(move |_, self_tbl: LuaTable| {
                            let sb_id = self_tbl.get::<u64>("_spritebatch_id").unwrap_or(0);
                            let sbs = sr.sprite_batches.lock();
                            Ok(sbs.get(&sb_id).map(|d| d.entries.len() as i32).unwrap_or(0))
                        })?,
                    )?;
                }

                // SpriteBatch:setColor(r, g, b, a)
                {
                    let sr = Arc::clone(&s);
                    sb.set(
                        "setColor",
                        lua.create_function(move |_, args: LuaMultiValue| {
                            let self_tbl = match args.get(0) {
                                Some(LuaValue::Table(t)) => t,
                                _ => return Ok(()),
                            };
                            let sb_id = self_tbl.get::<u64>("_spritebatch_id").unwrap_or(0);
                            let color = if args.len() > 1 {
                                let c = crate::lua_util::parse_color_offset(&args, 1);
                                Some(c)
                            } else {
                                None
                            };
                            let mut sbs = sr.sprite_batches.lock();
                            if let Some(data) = sbs.get_mut(&sb_id) {
                                data.color = color;
                            }
                            Ok(())
                        })?,
                    )?;
                }

                {
                    let sr = Arc::clone(&s);
                    sb.set(
                        "release",
                        lua.create_function(move |_, self_tbl: LuaTable| {
                            if let Ok(id) = self_tbl.get::<u64>("_spritebatch_id") {
                                sr.sprite_batches.lock().remove(&id);
                            }
                            Ok(())
                        })?,
                    )?;
                }
                sb.set(
                    "type",
                    lua.create_function(|_, _self: LuaValue| Ok("SpriteBatch"))?,
                )?;
                sb.set(
                    "typeOf",
                    lua.create_function(|_, (_self, t): (LuaValue, String)| {
                        Ok(t == "SpriteBatch" || t == "Drawable" || t == "Object")
                    })?,
                )?;

                // Attach GC guard
                let guard = lua.create_userdata(ResourceGuard {
                    id: sb_id,
                    kind: ResourceKind::SpriteBatch,
                    state: Arc::clone(&s),
                })?;
                sb.set("_gc_guard", guard)?;

                Ok(LuaValue::Table(sb))
            })?,
        )?;
    }

    // love.graphics.newText(font, text) -> Text
    {
        let s = Arc::clone(state);
        g.set(
            "newText",
            lua.create_function(move |lua, args: LuaMultiValue| {
                let (font_size, text_font_id) = match args.get(0) {
                    Some(LuaValue::Table(t)) => {
                        let sz = t.get::<f32>("_size").unwrap_or(12.0);
                        let fid = t.get::<u64>("_font_id").unwrap_or(0);
                        (sz, fid)
                    }
                    _ => (12.0, 0u64),
                };
                let t = lua.create_table()?;
                // Temporarily set font for rendering
                let prev_font = *s.active_font_id.lock();
                *s.active_font_id.lock() = text_font_id;
                let (image_id, tw, th) = match args.get(1) {
                    Some(v) => {
                        if let Some(segments) = parse_colored_text(v) {
                            render_colored_text_to_image(&s, &segments, font_size)
                        } else {
                            let plain = extract_text_from_lua(v);
                            render_text_to_image(&s, &plain, font_size)
                        }
                    }
                    _ => (0, 0, 0),
                };
                *s.active_font_id.lock() = prev_font;

                t.set("_image_id", image_id)?;
                t.set("_text_w", tw)?;
                t.set("_text_h", th)?;
                t.set("_font_id", text_font_id)?;
                t.set("_font_size", font_size)?;
                t.set("_is_text", true)?;

                {
                    let sr = Arc::clone(&s);
                    t.set(
                        "set",
                        lua.create_function(move |_, args: LuaMultiValue| {
                            let self_tbl = match args.get(0) {
                                Some(LuaValue::Table(t)) => t.clone(),
                                _ => return Ok(()),
                            };
                            let fs = self_tbl.get::<f32>("_font_size").unwrap_or(12.0);
                            let fid = self_tbl.get::<u64>("_font_id").unwrap_or(0);
                            let prev = *sr.active_font_id.lock();
                            *sr.active_font_id.lock() = fid;
                            // Try colored text first, fall back to plain
                            let (new_id, nw, nh) = match args.get(1) {
                                Some(v) => {
                                    if let Some(segments) = parse_colored_text(v) {
                                        render_colored_text_to_image(&sr, &segments, fs)
                                    } else {
                                        let plain = extract_text_from_lua(v);
                                        render_text_to_image(&sr, &plain, fs)
                                    }
                                }
                                _ => (0, 0, 0),
                            };
                            *sr.active_font_id.lock() = prev;
                            if let Ok(old_id) = self_tbl.get::<u64>("_image_id") {
                                sr.images.lock().remove(&old_id);
                            }
                            self_tbl.set("_image_id", new_id).ok();
                            self_tbl.set("_text_w", nw).ok();
                            self_tbl.set("_text_h", nh).ok();
                            Ok(())
                        })?,
                    )?;
                }
                {
                    let sr2 = Arc::clone(&s);
                    t.set(
                        "setf",
                        lua.create_function(move |_, args: LuaMultiValue| {
                            let self_tbl = match args.get(0) {
                                Some(LuaValue::Table(t)) => t.clone(),
                                _ => return Ok(()),
                            };
                            let text = match args.get(1) {
                                Some(LuaValue::String(s)) => s.to_string_lossy().to_string(),
                                Some(LuaValue::Table(t)) => {
                                    let mut result = String::new();
                                    let len = t.raw_len();
                                    for i in 1..=len {
                                        if let Ok(LuaValue::String(s)) = t.get::<LuaValue>(i) {
                                            result.push_str(&s.to_string_lossy());
                                        }
                                    }
                                    result
                                }
                                _ => String::new(),
                            };
                            let wrap_limit = parse_num_arg(args.get(2), 400.0);
                            let align = match args.get(3) {
                                Some(LuaValue::String(s)) => s.to_string_lossy().to_string(),
                                _ => "left".to_string(),
                            };
                            let fs = self_tbl.get::<f32>("_font_size").unwrap_or(12.0);
                            let fid = self_tbl.get::<u64>("_font_id").unwrap_or(0);
                            let prev = *sr2.active_font_id.lock();
                            *sr2.active_font_id.lock() = fid;
                            let (new_id, nw, nh) =
                                render_text_to_image_wrapped(&sr2, &text, fs, wrap_limit, &align);
                            *sr2.active_font_id.lock() = prev;
                            if let Ok(old_id) = self_tbl.get::<u64>("_image_id") {
                                if old_id != 0 {
                                    sr2.images.lock().remove(&old_id);
                                }
                            }
                            self_tbl.set("_image_id", new_id).ok();
                            self_tbl.set("_text_w", nw).ok();
                            self_tbl.set("_text_h", nh).ok();
                            Ok(())
                        })?,
                    )?;
                }
                t.set(
                    "getWidth",
                    lua.create_function(|_, self_tbl: LuaTable| {
                        Ok(self_tbl.get::<i32>("_text_w").unwrap_or(0))
                    })?,
                )?;
                t.set(
                    "getHeight",
                    lua.create_function(|_, self_tbl: LuaTable| {
                        Ok(self_tbl.get::<i32>("_text_h").unwrap_or(0))
                    })?,
                )?;
                t.set(
                    "getDimensions",
                    lua.create_function(|_, self_tbl: LuaTable| {
                        Ok((
                            self_tbl.get::<i32>("_text_w").unwrap_or(0),
                            self_tbl.get::<i32>("_text_h").unwrap_or(0),
                        ))
                    })?,
                )?;
                t.set("_font_size", font_size)?;
                t.set(
                    "type",
                    lua.create_function(|_, _self: LuaValue| Ok("Text"))?,
                )?;
                t.set(
                    "typeOf",
                    lua.create_function(|_, (_self, t): (LuaValue, String)| {
                        Ok(t == "Text" || t == "Drawable" || t == "Object")
                    })?,
                )?;
                Ok(LuaValue::Table(t))
            })?,
        )?;
    }

    // love.graphics.newVideo(path) -> Video
    g.set(
        "newVideo",
        lua.create_function(|lua, _args: LuaMultiValue| {
            let v = lua.create_table()?;
            v.set("play", lua.create_function(|_, _self: LuaValue| Ok(()))?)?;
            v.set(
                "isPlaying",
                lua.create_function(|_, _self: LuaValue| Ok(false))?,
            )?;
            v.set("pause", lua.create_function(|_, _self: LuaValue| Ok(()))?)?;
            Ok(LuaValue::Table(v))
        })?,
    )?;

    // love.graphics.setCanvas([canvas])
    {
        let s = Arc::clone(state);
        let registry_key = lua.create_registry_value(LuaNil)?;
        let key = Arc::new(Mutex::new(registry_key));
        let key2 = Arc::clone(&key);

        g.set(
            "setCanvas",
            lua.create_function(move |lua, args: LuaMultiValue| {
                match args.get(0) {
                    Some(LuaValue::Table(t)) => {
                        // Check for direct canvas (has _canvas_id)
                        let canvas_id = t.get::<u64>("_canvas_id").unwrap_or(0);
                        if canvas_id != 0 {
                            *s.active_canvas.lock() = canvas_id;
                            // Auto-clear on first activation this frame
                            if s.canvases_activated_this_frame.lock().insert(canvas_id) {
                                if let Some(cb) = s.canvases.lock().get_mut(&canvas_id) {
                                    cb.clear(0.0, 0.0, 0.0, 0.0);
                                    cb.clear_stencil();
                                }
                            }
                            let new_key = lua.create_registry_value(LuaValue::Table(t.clone()))?;
                            *key.lock() = new_key;
                        } else {
                            // Handle setCanvas{canvas} — table wrapping (LÖVE convention)
                            if let Ok(LuaValue::Table(inner)) = t.get::<LuaValue>(1) {
                                let inner_id = inner.get::<u64>("_canvas_id").unwrap_or(0);
                                if inner_id != 0 {
                                    *s.active_canvas.lock() = inner_id;
                                    // Auto-clear on first activation this frame
                                    if s.canvases_activated_this_frame.lock().insert(inner_id) {
                                        if let Some(cb) = s.canvases.lock().get_mut(&inner_id) {
                                            cb.clear(0.0, 0.0, 0.0, 0.0);
                                            cb.clear_stencil();
                                        }
                                    }
                                    let new_key =
                                        lua.create_registry_value(LuaValue::Table(inner.clone()))?;
                                    *key.lock() = new_key;
                                } else {
                                    *s.active_canvas.lock() = 0;
                                    let new_key = lua.create_registry_value(LuaNil)?;
                                    *key.lock() = new_key;
                                }
                            } else {
                                *s.active_canvas.lock() = 0;
                                let new_key = lua.create_registry_value(LuaNil)?;
                                *key.lock() = new_key;
                            }
                        }
                    }
                    _ => {
                        *s.active_canvas.lock() = 0;
                        let new_key = lua.create_registry_value(LuaNil)?;
                        *key.lock() = new_key;
                    }
                }
                Ok(())
            })?,
        )?;

        // love.graphics.getCanvas()
        g.set(
            "getCanvas",
            lua.create_function(move |lua, ()| {
                let val: LuaValue = lua.registry_value(&key2.lock())?;
                Ok(val)
            })?,
        )?;
    }

    // love.graphics.polygon(mode, vertices...)
    {
        let s = Arc::clone(state);
        g.set(
            "polygon",
            lua.create_function(move |_, args: LuaMultiValue| {
                if args.len() < 2 {
                    return Ok(());
                }
                let mode = match args.get(0) {
                    Some(LuaValue::String(s)) => s.to_string_lossy().to_string(),
                    _ => return Ok(()),
                };

                // Collect coordinates — can be individual numbers or a table
                let mut coords: Vec<f32> = Vec::new();
                match args.get(1) {
                    Some(LuaValue::Table(t)) => {
                        // Table of vertices
                        let len = t.raw_len();
                        for i in 1..=len {
                            if let Ok(v) = t.get::<f32>(i) {
                                coords.push(v);
                            }
                        }
                    }
                    _ => {
                        // Individual number args
                        for i in 1..args.len() {
                            match args.get(i) {
                                Some(LuaValue::Number(n)) => coords.push(*n as f32),
                                Some(LuaValue::Integer(n)) => coords.push(*n as f32),
                                _ => break,
                            }
                        }
                    }
                }

                if coords.len() < 6 || coords.len() % 2 != 0 {
                    return Ok(());
                }

                let color = color_f32_to_u8(*s.current_color.lock());
                let t = current_transform(&s);

                // Transform all vertices
                let mut transformed: Vec<(f32, f32)> = Vec::with_capacity(coords.len() / 2);
                for i in (0..coords.len()).step_by(2) {
                    let (px, py) = t.apply(coords[i], coords[i + 1]);
                    transformed.push((px, py));
                }

                let lw = *s.line_width.lock();
                let (sfx, _) = t.scale_factor();
                let scaled_lw = (lw * sfx).max(1.0);

                if s.is_gpu_recording() {
                    s.record_gpu(GpuCommand::Polygon {
                        fill: mode == "fill",
                        points: transformed,
                        line_width: scaled_lw,
                        color,
                        clip: *s.scissor.lock(),
                    });
                    return Ok(());
                }

                s.with_active_buffer(|pb| {
                    if mode == "fill" {
                        fill_polygon(pb, &transformed, color);
                    } else {
                        for i in 0..transformed.len() {
                            let j = (i + 1) % transformed.len();
                            draw_thick_line(
                                pb,
                                transformed[i].0,
                                transformed[i].1,
                                transformed[j].0,
                                transformed[j].1,
                                scaled_lw,
                                color,
                            );
                        }
                    }
                });
                Ok(())
            })?,
        )?;
    }

    // love.graphics.setScissor([x, y, w, h])
    {
        let s = Arc::clone(state);
        g.set(
            "setScissor",
            lua.create_function(move |_, args: LuaMultiValue| {
                if args.len() >= 4 {
                    let x = match args.get(0) {
                        Some(LuaValue::Number(n)) => *n as i32,
                        Some(LuaValue::Integer(n)) => *n as i32,
                        _ => 0,
                    };
                    let y = match args.get(1) {
                        Some(LuaValue::Number(n)) => *n as i32,
                        Some(LuaValue::Integer(n)) => *n as i32,
                        _ => 0,
                    };
                    let w = match args.get(2) {
                        Some(LuaValue::Number(n)) => *n as u32,
                        Some(LuaValue::Integer(n)) => *n as u32,
                        _ => 0,
                    };
                    let h = match args.get(3) {
                        Some(LuaValue::Number(n)) => *n as u32,
                        Some(LuaValue::Integer(n)) => *n as u32,
                        _ => 0,
                    };
                    *s.scissor.lock() = Some((x, y, w, h));
                    s.with_active_buffer(|pb| {
                        pb.scissor = Some((x, y, w, h));
                    });
                } else {
                    *s.scissor.lock() = None;
                    s.with_active_buffer(|pb| {
                        pb.scissor = None;
                    });
                }
                Ok(())
            })?,
        )?;
    }

    // love.graphics.setShader([shader]) — track active shader for dissolve emulation
    {
        let s = Arc::clone(state);
        g.set(
            "setShader",
            lua.create_function(move |_, args: LuaMultiValue| {
                match args.get(0) {
                    Some(LuaValue::Table(shader_tbl)) => {
                        *s.active_shader_no_texture.lock() =
                            shader_tbl.get::<bool>("_no_texture").unwrap_or(false);
                        *s.active_card_shader.lock() =
                            shader_tbl.get::<u8>("_card_shader").unwrap_or(0);
                        // Read dissolve/shadow uniforms from shader's _uniforms table
                        if let Ok(uniforms) = shader_tbl.get::<LuaTable>("_uniforms") {
                            let dissolve: f32 = uniforms.get("dissolve").unwrap_or(0.0);
                            let shadow: bool = uniforms.get("shadow").unwrap_or(false);
                            *s.active_shader_dissolve.lock() = dissolve;
                            *s.active_shader_shadow.lock() = shadow;
                        }
                        // Detect fullscreen post-processing shaders (CRT, etc.)
                        if let Ok(uniforms) = shader_tbl.get::<LuaTable>("_uniforms") {
                            let is_fullscreen =
                                uniforms.get::<LuaValue>("scanlines").unwrap_or(LuaNil) != LuaNil
                                    || uniforms.get::<LuaValue>("crt_intensity").unwrap_or(LuaNil)
                                        != LuaNil;
                            *s.active_shader_fullscreen.lock() = is_fullscreen;
                        } else {
                            *s.active_shader_fullscreen.lock() = false;
                        }
                        // Detect background procedural shader
                        *s.active_shader_background.lock() =
                            shader_tbl.get::<bool>("_is_background").unwrap_or(false);
                        // Detect flame shader
                        *s.active_shader_flame.lock() =
                            shader_tbl.get::<bool>("_is_flame").unwrap_or(false);
                        // Detect flash shader
                        *s.active_shader_flash.lock() =
                            shader_tbl.get::<bool>("_is_flash").unwrap_or(false);
                    }
                    _ => {
                        // setShader() with no args = clear shader
                        *s.active_shader_no_texture.lock() = false;
                        *s.active_shader_dissolve.lock() = 0.0;
                        *s.active_shader_shadow.lock() = false;
                        *s.active_shader_fullscreen.lock() = false;
                        *s.active_shader_background.lock() = false;
                        *s.active_card_shader.lock() = 0;
                        *s.active_shader_flame.lock() = false;
                        *s.active_shader_flash.lock() = false;
                    }
                }
                Ok(())
            })?,
        )?;
    }

    // love.graphics.setDefaultFilter(min [, mag, anisotropy])
    {
        let s = Arc::clone(&state);
        g.set(
            "setDefaultFilter",
            lua.create_function(move |_, args: LuaMultiValue| {
                let mode = match args.get(0) {
                    Some(LuaValue::String(s)) => s.to_string_lossy().to_string(),
                    _ => "nearest".to_string(),
                };
                *s.default_filter_linear.lock() = mode == "linear";
                Ok(())
            })?,
        )?;
    }

    // Noop stubs for features that don't affect pixel output
    for name in &["setLineStyle", "setLineJoin", "setColorMask"] {
        g.set(
            *name,
            lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
        )?;
    }

    // love.graphics.stencil(func [, action, value, keepvalues])
    // Executes the drawing function with stencil write mode enabled,
    // so shapes drawn inside become the stencil mask.
    {
        let s = Arc::clone(&state);
        g.set(
            "stencil",
            lua.create_function(
                move |_,
                      (func, _action, _value, _keep): (
                    LuaFunction,
                    Option<String>,
                    Option<u8>,
                    Option<bool>,
                )| {
                    if s.is_gpu_recording() {
                        s.reject_gpu_frame();
                        return Ok(());
                    }
                    // Clear stencil buffer and enter stencil write mode
                    s.with_active_buffer(|pb| {
                        pb.clear_stencil();
                        pb.stencil_write_mode = true;
                    });

                    // Execute the stencil drawing function — all draw calls
                    // will write to the stencil buffer instead of pixels
                    let result = func.call::<()>(());

                    // Exit stencil write mode
                    s.with_active_buffer(|pb| {
                        pb.stencil_write_mode = false;
                    });

                    if let Err(e) = result {
                        eprintln!("[STENCIL] error in stencil function: {}", e);
                    }
                    Ok(())
                },
            )?,
        )?;
    }

    // love.graphics.setStencilTest([comparemode, comparevalue])
    {
        let s = Arc::clone(&state);
        g.set(
            "setStencilTest",
            lua.create_function(move |_, args: LuaMultiValue| {
                if args.is_empty() {
                    // Disable stencil test
                    *s.stencil_compare.lock() = StencilCompare::Disabled;
                    *s.stencil_ref.lock() = 0;
                } else {
                    let mode_str = match args.get(0) {
                        Some(LuaValue::String(s)) => s.to_string_lossy().to_string(),
                        _ => "always".to_string(),
                    };
                    let ref_val = match args.get(1) {
                        Some(LuaValue::Integer(n)) => *n as u8,
                        Some(LuaValue::Number(n)) => *n as u8,
                        _ => 0,
                    };
                    let compare = match mode_str.as_str() {
                        "greater" => StencilCompare::Greater,
                        "gequal" => StencilCompare::GEqual,
                        "equal" => StencilCompare::Equal,
                        "lequal" => StencilCompare::LEqual,
                        "less" => StencilCompare::Less,
                        "notequal" => StencilCompare::NotEqual,
                        "always" => StencilCompare::Always,
                        "never" => StencilCompare::Never,
                        _ => StencilCompare::Disabled,
                    };
                    *s.stencil_compare.lock() = compare;
                    *s.stencil_ref.lock() = ref_val;
                }
                Ok(())
            })?,
        )?;
    }

    // love.graphics.setBlendMode(mode [, alphamode])
    {
        let s = Arc::clone(&state);
        g.set(
            "setBlendMode",
            lua.create_function(move |_, args: LuaMultiValue| {
                let mode_str = match args.get(0) {
                    Some(LuaValue::String(s)) => s.to_string_lossy().to_string(),
                    _ => "alpha".to_string(),
                };
                let mode = match mode_str.as_str() {
                    "replace" => BlendMode::Replace,
                    "multiply" | "multiplicative" => BlendMode::Multiply,
                    "add" | "additive" => BlendMode::Add,
                    "screen" => BlendMode::Screen,
                    _ => BlendMode::Alpha,
                };
                *s.blend_mode.lock() = mode;
                Ok(())
            })?,
        )?;
    }

    // love.graphics.applyTransform(transform) — apply a Transform object
    {
        let s = Arc::clone(state);
        g.set(
            "applyTransform",
            lua.create_function(move |_, t_obj: LuaTable| {
                // Read 6 transform coefficients from the Transform userdata/table
                let a: f32 = t_obj.get("a").unwrap_or(1.0);
                let b: f32 = t_obj.get("b").unwrap_or(0.0);
                let c: f32 = t_obj.get("c").unwrap_or(0.0);
                let d: f32 = t_obj.get("d").unwrap_or(1.0);
                let tx: f32 = t_obj.get("tx").unwrap_or(0.0);
                let ty: f32 = t_obj.get("ty").unwrap_or(0.0);

                let mut stack = s.transform_stack.lock();
                if let Some(current) = stack.last_mut() {
                    // Multiply current transform by the applied transform
                    let na = current.a * a + current.b * c;
                    let nb = current.a * b + current.b * d;
                    let nc = current.c * a + current.d * c;
                    let nd = current.c * b + current.d * d;
                    let ntx = current.a * tx + current.b * ty + current.tx;
                    let nty = current.c * tx + current.d * ty + current.ty;
                    current.a = na;
                    current.b = nb;
                    current.c = nc;
                    current.d = nd;
                    current.tx = ntx;
                    current.ty = nty;
                }
                Ok(())
            })?,
        )?;
    }

    // love.graphics.replaceTransform(transform) — replace current transform
    {
        let s = Arc::clone(state);
        g.set(
            "replaceTransform",
            lua.create_function(move |_, t_obj: LuaTable| {
                let a: f32 = t_obj.get("a").unwrap_or(1.0);
                let b: f32 = t_obj.get("b").unwrap_or(0.0);
                let c: f32 = t_obj.get("c").unwrap_or(0.0);
                let d: f32 = t_obj.get("d").unwrap_or(1.0);
                let tx: f32 = t_obj.get("tx").unwrap_or(0.0);
                let ty: f32 = t_obj.get("ty").unwrap_or(0.0);

                let mut stack = s.transform_stack.lock();
                if let Some(current) = stack.last_mut() {
                    current.a = a;
                    current.b = b;
                    current.c = c;
                    current.d = d;
                    current.tx = tx;
                    current.ty = ty;
                }
                Ok(())
            })?,
        )?;
    }

    // love.graphics.transformPoint(x, y) — apply current transform to point
    {
        let s = Arc::clone(state);
        g.set(
            "transformPoint",
            lua.create_function(move |_, (x, y): (f32, f32)| {
                let t = current_transform(&s);
                let (px, py) = t.apply(x, y);
                Ok((px as f64, py as f64))
            })?,
        )?;
    }

    // love.graphics.inverseTransformPoint(x, y) — apply inverse transform to point
    {
        let s = Arc::clone(state);
        g.set(
            "inverseTransformPoint",
            lua.create_function(move |_, (x, y): (f32, f32)| {
                let t = current_transform(&s);
                if let Some(inv) = t.inverse() {
                    let (px, py) = inv.apply(x, y);
                    Ok((px as f64, py as f64))
                } else {
                    Ok((x as f64, y as f64))
                }
            })?,
        )?;
    }

    // love.graphics.getBackgroundColor()
    {
        let s = Arc::clone(state);
        g.set(
            "getBackgroundColor",
            lua.create_function(move |_, ()| {
                let c = *s.background_color.lock();
                Ok((c[0] as f64, c[1] as f64, c[2] as f64, c[3] as f64))
            })?,
        )?;
    }

    // love.graphics.getBlendMode()
    {
        let s = Arc::clone(state);
        g.set(
            "getBlendMode",
            lua.create_function(move |_, ()| {
                let mode_str = match *s.blend_mode.lock() {
                    BlendMode::Alpha => "alpha",
                    BlendMode::Replace => "replace",
                    BlendMode::Multiply => "multiply",
                    BlendMode::Add => "add",
                    BlendMode::Screen => "screen",
                };
                Ok((mode_str, "alphamultiply"))
            })?,
        )?;
    }

    // love.graphics.getColorMask()
    g.set(
        "getColorMask",
        lua.create_function(|_, ()| Ok((true, true, true, true)))?,
    )?;

    // love.graphics.getShader()
    g.set("getShader", lua.create_function(|_, ()| Ok(LuaNil))?)?;

    // love.graphics.getDPIScale()
    g.set("getDPIScale", lua.create_function(|_, ()| Ok(1.0f64))?)?;

    // love.graphics.getScissor()
    {
        let s = Arc::clone(state);
        g.set(
            "getScissor",
            lua.create_function(move |_, ()| match *s.scissor.lock() {
                Some((x, y, w, h)) => Ok((
                    LuaValue::Integer(x as i64),
                    LuaValue::Integer(y as i64),
                    LuaValue::Integer(w as i64),
                    LuaValue::Integer(h as i64),
                )),
                None => Ok((LuaNil, LuaNil, LuaNil, LuaNil)),
            })?,
        )?;
    }

    // love.graphics.getLineStyle()
    g.set("getLineStyle", lua.create_function(|_, ()| Ok("smooth"))?)?;

    // love.graphics.getLineJoin()
    g.set("getLineJoin", lua.create_function(|_, ()| Ok("miter"))?)?;

    // love.graphics.getRendererInfo()
    g.set(
        "getRendererInfo",
        lua.create_function(|_, ()| Ok(("love-lite", "0.1", "Software", "SDL2")))?,
    )?;

    // love.graphics.getSupported()
    g.set(
        "getSupported",
        lua.create_function(|lua, ()| {
            let t = lua.create_table()?;
            t.set("canvas", true)?;
            t.set("multicanvas", false)?;
            t.set("shader", true)?;
            Ok(t)
        })?,
    )?;

    // love.graphics.captureScreenshot(filename)
    g.set(
        "captureScreenshot",
        lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
    )?;

    // love.graphics.newImageData — some games create ImageData via graphics module
    {
        let s = Arc::clone(state);
        g.set(
            "newImageData",
            lua.create_function(move |lua, args: LuaMultiValue| {
                let w = match args.get(0) {
                    Some(LuaValue::Number(n)) => *n as u32,
                    Some(LuaValue::Integer(n)) => *n as u32,
                    _ => 1,
                };
                let h = match args.get(1) {
                    Some(LuaValue::Number(n)) => *n as u32,
                    Some(LuaValue::Integer(n)) => *n as u32,
                    _ => 1,
                };
                create_image_data_table(lua, &s, w, h)
            })?,
        )?;
    }

    // love.graphics.getDefaultFilter()
    {
        let s = Arc::clone(&state);
        g.set(
            "getDefaultFilter",
            lua.create_function(move |_, ()| {
                let mode = if *s.default_filter_linear.lock() {
                    "linear"
                } else {
                    "nearest"
                };
                Ok((mode, mode, 1i32))
            })?,
        )?;
    }

    // love.graphics.getStencilTest()
    g.set(
        "getStencilTest",
        lua.create_function(|_, ()| Ok((false, "always")))?,
    )?;

    Ok(())
}

/// Create an ImageData table (love.image.newImageData compatible)
fn create_image_data_table(
    lua: &Lua,
    state: &Arc<SharedState>,
    w: u32,
    h: u32,
) -> LuaResult<LuaValue> {
    // Create pixel data (RGBA, initialized to transparent black)
    let pixels = vec![0u8; (w * h * 4) as usize];
    let id = {
        let mut next = state.next_image_id.lock();
        let id = *next;
        *next += 1;
        id
    };
    state.images.lock().insert(
        id,
        ImageData {
            width: w,
            height: h,
            pixels,
        },
    );

    let idata = lua.create_table()?;
    idata.set("_image_id", id)?;
    idata.set(
        "getWidth",
        lua.create_function(move |_, _self: LuaValue| Ok(w))?,
    )?;
    idata.set(
        "getHeight",
        lua.create_function(move |_, _self: LuaValue| Ok(h))?,
    )?;
    idata.set(
        "getDimensions",
        lua.create_function(move |_, _self: LuaValue| Ok((w, h)))?,
    )?;
    idata.set(
        "getPixel",
        lua.create_function(move |_, (_self, _x, _y): (LuaValue, u32, u32)| {
            Ok((0.0f64, 0.0f64, 0.0f64, 0.0f64))
        })?,
    )?;
    idata.set(
        "setPixel",
        lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
    )?;
    idata.set(
        "paste",
        lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
    )?;
    idata.set("release", lua.create_function(|_, _self: LuaValue| Ok(()))?)?;
    idata.set(
        "type",
        lua.create_function(|_, _self: LuaValue| Ok("ImageData"))?,
    )?;
    idata.set(
        "typeOf",
        lua.create_function(|_, (_self, t): (LuaValue, String)| {
            Ok(t == "ImageData" || t == "Data" || t == "Object")
        })?,
    )?;
    Ok(LuaValue::Table(idata))
}

fn new_image_table(
    lua: &Lua,
    state: &Arc<SharedState>,
    image_id: u64,
    w: u32,
    h: u32,
) -> LuaResult<LuaValue> {
    let img = lua.create_table()?;
    img.set("_image_id", image_id)?;
    img.set(
        "getDimensions",
        lua.create_function(move |_, _self: LuaValue| Ok((w, h)))?,
    )?;
    img.set(
        "getWidth",
        lua.create_function(move |_, _self: LuaValue| Ok(w))?,
    )?;
    img.set(
        "getHeight",
        lua.create_function(move |_, _self: LuaValue| Ok(h))?,
    )?;
    img.set(
        "getPixelWidth",
        lua.create_function(move |_, _self: LuaValue| Ok(w))?,
    )?;
    img.set(
        "getPixelHeight",
        lua.create_function(move |_, _self: LuaValue| Ok(h))?,
    )?;
    img.set(
        "setFilter",
        lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
    )?;
    img.set(
        "getFilter",
        lua.create_function(|_, _self: LuaValue| Ok(("nearest", "nearest")))?,
    )?;
    img.set(
        "setWrap",
        lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
    )?;
    img.set(
        "getWrap",
        lua.create_function(|_, _self: LuaValue| Ok(("clamp", "clamp")))?,
    )?;
    {
        let sr = Arc::clone(state);
        img.set(
            "release",
            lua.create_function(move |_, self_tbl: LuaTable| {
                if let Ok(id) = self_tbl.get::<u64>("_image_id") {
                    sr.images.lock().remove(&id);
                }
                // Remove the GC guard so it doesn't double-free
                self_tbl.set("_gc_guard", LuaValue::Nil).ok();
                Ok(())
            })?,
        )?;
    }
    img.set(
        "type",
        lua.create_function(|_, _self: LuaValue| Ok("Image"))?,
    )?;
    img.set(
        "typeOf",
        lua.create_function(|_, (_self, t): (LuaValue, String)| {
            Ok(t == "Image" || t == "Texture" || t == "Drawable" || t == "Object")
        })?,
    )?;

    // Attach GC guard — when Lua GC collects this table, the userdata's Drop frees the image
    let guard = lua.create_userdata(ResourceGuard {
        id: image_id,
        kind: ResourceKind::Image,
        state: Arc::clone(state),
    })?;
    img.set("_gc_guard", guard)?;

    Ok(LuaValue::Table(img))
}

fn new_image_stub(lua: &Lua, w: u32, h: u32) -> LuaResult<LuaValue> {
    let img = lua.create_table()?;
    img.set(
        "getDimensions",
        lua.create_function(move |_, _self: LuaValue| Ok((w, h)))?,
    )?;
    img.set(
        "getWidth",
        lua.create_function(move |_, _self: LuaValue| Ok(w))?,
    )?;
    img.set(
        "getHeight",
        lua.create_function(move |_, _self: LuaValue| Ok(h))?,
    )?;
    img.set(
        "getPixelWidth",
        lua.create_function(move |_, _self: LuaValue| Ok(w))?,
    )?;
    img.set(
        "getPixelHeight",
        lua.create_function(move |_, _self: LuaValue| Ok(h))?,
    )?;
    img.set(
        "setFilter",
        lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
    )?;
    img.set(
        "getFilter",
        lua.create_function(|_, _self: LuaValue| Ok(("nearest", "nearest")))?,
    )?;
    img.set(
        "setWrap",
        lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
    )?;
    img.set(
        "getWrap",
        lua.create_function(|_, _self: LuaValue| Ok(("clamp", "clamp")))?,
    )?;
    img.set("release", lua.create_function(|_, _self: LuaValue| Ok(()))?)?;
    img.set(
        "type",
        lua.create_function(|_, _self: LuaValue| Ok("Image"))?,
    )?;
    img.set(
        "typeOf",
        lua.create_function(|_, (_self, t): (LuaValue, String)| {
            Ok(t == "Image" || t == "Texture" || t == "Drawable" || t == "Object")
        })?,
    )?;
    Ok(LuaValue::Table(img))
}

enum FontSource {
    Path(String),
    Data { table: LuaTable, cache_key: String },
}

/// Parse newFont(size), newFont(path, size), or newFont(FileData, size).
fn parse_font_args(args: &LuaMultiValue) -> (Option<FontSource>, f32) {
    let mut iter = args.iter();
    match iter.next() {
        Some(LuaValue::Number(n)) => (None, *n as f32),
        Some(LuaValue::Integer(n)) => (None, *n as f32),
        Some(LuaValue::String(s)) => {
            let path = s.to_string_lossy().to_string();
            let size = match iter.next() {
                Some(LuaValue::Number(n)) => *n as f32,
                Some(LuaValue::Integer(n)) => *n as f32,
                _ => 12.0,
            };
            (Some(FontSource::Path(path)), size)
        }
        Some(LuaValue::Table(data)) => {
            let size = match iter.next() {
                Some(LuaValue::Number(n)) => *n as f32,
                Some(LuaValue::Integer(n)) => *n as f32,
                _ => 12.0,
            };
            let source = data.get::<mlua::String>("_file_data").ok().map(|value| {
                let cache_key = data
                    .get::<u64>("_file_data_id")
                    .map(|id| format!("data:{id}"))
                    .unwrap_or_else(|_| {
                        let filename = data
                            .get::<String>("_filename")
                            .unwrap_or_else(|_| "font".to_owned());
                        format!("data:{filename}:{}", value.as_bytes().len())
                    });
                FontSource::Data {
                    table: data.clone(),
                    cache_key,
                }
            });
            (source, size)
        }
        _ => (None, 12.0),
    }
}

/// Load a font from the game source, or create a fallback.
/// Returns the font_id in the font registry.
fn load_font(state: &SharedState, source: Option<FontSource>) -> u64 {
    let Some(source) = source else {
        return 0;
    };
    let cache_key = match &source {
        FontSource::Path(font_path) => format!("path:{font_path}"),
        FontSource::Data { cache_key, .. } => cache_key.clone(),
    };
    if let Some(font_id) = state.font_source_cache.lock().get(&cache_key).copied() {
        return font_id;
    }
    let data = match source {
        FontSource::Path(font_path) => {
            if std::path::Path::new(&font_path).is_absolute() {
                std::fs::read(font_path).ok()
            } else {
                let game_source = state.game_source.lock();
                game_source.read_file(&font_path).ok()
            }
        }
        FontSource::Data { table, .. } => table
            .get::<mlua::String>("_file_data")
            .ok()
            .map(|value| value.as_bytes().to_vec()),
    };
    let Some(ttf_data) = data else {
        return 0;
    };
    let Ok(font) = ab_glyph::FontArc::try_from_vec(ttf_data) else {
        return 0;
    };
    let font_id = {
        let mut id = state.next_font_id.lock();
        let fid = *id;
        *id += 1;
        fid
    };
    state
        .fonts
        .lock()
        .insert(font_id, std::sync::Arc::new(FontData { font }));
    state.font_source_cache.lock().insert(cache_key, font_id);
    font_id
}

/// Get a FontData by ID, or None for bitmap fallback
fn get_font(state: &SharedState, font_id: u64) -> Option<std::sync::Arc<FontData>> {
    if font_id == 0 {
        return None;
    }
    state.fonts.lock().get(&font_id).cloned()
}

fn new_font_table(lua: &Lua, state: &SharedState, font_id: u64, size: f32) -> LuaResult<LuaValue> {
    let font = lua.create_table()?;
    font.set("_size", size)?;
    font.set("_font_id", font_id)?;

    // Use real font metrics if available
    let font_data = get_font(state, font_id);

    let height = match &font_data {
        Some(fd) => fd.height_at(size).ceil(),
        None => size,
    };

    font.set(
        "getHeight",
        lua.create_function(move |_, _self: LuaValue| Ok(height))?,
    )?;

    {
        let fd = font_data.clone();
        font.set(
            "getWidth",
            lua.create_function(move |_, (_self, text): (LuaValue, String)| match &fd {
                Some(f) => Ok(f.text_width_at(&text, size)),
                None => Ok(text.chars().count() as f32 * size.max(8.0)),
            })?,
        )?;
    }

    font.set(
        "getBaseline",
        lua.create_function(move |_, _self: LuaValue| Ok(height * 0.75))?,
    )?;
    font.set(
        "getAscent",
        lua.create_function(move |_, _self: LuaValue| Ok(height * 0.75))?,
    )?;
    font.set(
        "getDescent",
        lua.create_function(move |_, _self: LuaValue| Ok(height * 0.25))?,
    )?;
    font.set(
        "getLineHeight",
        lua.create_function(|_, _self: LuaValue| Ok(1.0f32))?,
    )?;
    font.set(
        "setLineHeight",
        lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
    )?;

    {
        let fd = font_data.clone();
        font.set(
            "getWrap",
            lua.create_function(move |lua, (_self, text, limit): (LuaValue, String, f32)| {
                let char_w_fn = |s: &str| -> f32 {
                    match &fd {
                        Some(f) => f.text_width_at(s, size),
                        None => s.chars().count() as f32 * size.max(8.0),
                    }
                };

                let mut lines_vec: Vec<String> = Vec::new();
                let mut current_line = String::new();
                let mut current_width: f32 = 0.0;

                for word in text.split_whitespace() {
                    let word_width = char_w_fn(word);
                    if current_width + word_width > limit && !current_line.is_empty() {
                        lines_vec.push(current_line.clone());
                        current_line.clear();
                        current_width = 0.0;
                    }
                    if !current_line.is_empty() {
                        current_line.push(' ');
                        current_width += char_w_fn(" ");
                    }
                    current_line.push_str(word);
                    current_width += word_width;
                }
                if !current_line.is_empty() {
                    lines_vec.push(current_line);
                }

                let max_width = lines_vec
                    .iter()
                    .map(|l| char_w_fn(l))
                    .fold(0.0f32, f32::max);
                let lines = lua.create_table()?;
                for (i, line) in lines_vec.iter().enumerate() {
                    lines.set(i + 1, line.as_str())?;
                }
                Ok((max_width.min(limit), lines))
            })?,
        )?;
    }

    font.set(
        "setFilter",
        lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
    )?;
    font.set(
        "getFilter",
        lua.create_function(|_, _self: LuaValue| Ok(("nearest", "nearest")))?,
    )?;
    font.set(
        "setFallbacks",
        lua.create_function(|_, _args: LuaMultiValue| Ok(()))?,
    )?;
    font.set(
        "hasGlyphs",
        lua.create_function(|_, _args: LuaMultiValue| Ok(true))?,
    )?;
    font.set(
        "type",
        lua.create_function(|_, _self: LuaValue| Ok("Font"))?,
    )?;
    font.set(
        "typeOf",
        lua.create_function(|_, (_self, t): (LuaValue, String)| Ok(t == "Font" || t == "Object"))?,
    )?;
    Ok(LuaValue::Table(font))
}

/// Render text string into a new image in the image registry.
/// Uses the active font if available, otherwise falls back to bitmap.
/// Returns (image_id, width, height).
fn render_text_to_image(state: &SharedState, text: &str, font_size: f32) -> (u64, i32, i32) {
    if text.is_empty() {
        return (0, 0, 0);
    }

    // Try to use TTF font
    let font_id = *state.active_font_id.lock();
    if let Some(fd) = get_font(state, font_id) {
        let (w, h, pixels) = fd.rasterize_text_at(text, font_size);
        if w == 0 || h == 0 {
            return (0, 0, 0);
        }
        let image_id = {
            let mut id = state.next_image_id.lock();
            let iid = *id;
            *id += 1;
            iid
        };
        state.images.lock().insert(
            image_id,
            ImageData {
                width: w,
                height: h,
                pixels,
            },
        );
        return (image_id, w as i32, h as i32);
    }

    // Bitmap fallback
    let scale = (font_size / 8.0).max(1.0);
    let char_w = (8.0 * scale) as u32;
    let char_h = (8.0 * scale) as u32;
    let tw = (text.len() as u32 * char_w).min(4096);
    let th = char_h.min(256);

    if tw == 0 || th == 0 {
        return (0, 0, 0);
    }

    let mut pb = PixelBuffer::new(tw, th);
    let mut cx: u32 = 0;
    for ch in text.chars() {
        if cx >= tw {
            break;
        }
        let glyph_idx = (ch as usize).min(127);
        let glyph = &sprite_to_text::pixel_buffer::FONT_8X8[glyph_idx];
        for row in 0..8u32 {
            let byte = glyph[row as usize];
            for col in 0..8u32 {
                if byte & (0x80 >> col) != 0 {
                    let px_start = cx + (col as f32 * scale) as u32;
                    let py_start = (row as f32 * scale) as u32;
                    let px_end = (cx + ((col + 1) as f32 * scale) as u32).min(tw);
                    let py_end = (((row + 1) as f32 * scale) as u32).min(th);
                    for py in py_start..py_end {
                        for px in px_start..px_end {
                            pb.set_pixel(px, py, 255, 255, 255, 255);
                        }
                    }
                }
            }
        }
        cx += char_w;
    }

    let image_id = {
        let mut id = state.next_image_id.lock();
        let iid = *id;
        *id += 1;
        iid
    };
    state.images.lock().insert(
        image_id,
        ImageData {
            width: tw,
            height: th,
            pixels: pb.pixels,
        },
    );

    (image_id, tw as i32, th as i32)
}

/// Render colored text segments to an RGBA image.
/// Each segment has its own color baked into the pixel data.
fn render_colored_text_to_image(
    state: &SharedState,
    segments: &[ColoredSegment],
    font_size: f32,
) -> (u64, i32, i32) {
    if segments.is_empty() {
        return (0, 0, 0);
    }

    let font_id = *state.active_font_id.lock();
    if let Some(fd) = get_font(state, font_id) {
        // Measure total width
        let mut total_width = 0.0f32;
        for (_, text) in segments {
            total_width += fd.text_width_at(text, font_size);
        }
        let width = total_width.ceil() as u32;
        let line_h = fd.line_height_at(font_size).ceil() as u32;
        if width == 0 || line_h == 0 {
            return (0, 0, 0);
        }

        let ascent = fd.ascent_at(font_size).ceil();

        let mut pixels = vec![0u8; (width * line_h * 4) as usize];
        let mut cursor_x = 0.0f32;

        for (color, text) in segments {
            for ch in text.chars() {
                let glyph = fd.rasterize_glyph_at(ch, font_size, cursor_x, ascent);

                for gy in 0..glyph.height {
                    for gx in 0..glyph.width {
                        let px = glyph.x + gx as i32;
                        let py = glyph.y + gy as i32;
                        if px >= 0 && (px as u32) < width && py >= 0 && (py as u32) < line_h {
                            let alpha = glyph.alpha[(gy * glyph.width + gx) as usize];
                            if alpha > 0 {
                                let idx = ((py as u32 * width + px as u32) * 4) as usize;
                                // Blend with existing pixel (later segments overlay)
                                let fa = (alpha as u16 * color[3] as u16 / 255) as u8;
                                let da = pixels[idx + 3];
                                if da == 0 {
                                    pixels[idx] = color[0];
                                    pixels[idx + 1] = color[1];
                                    pixels[idx + 2] = color[2];
                                    pixels[idx + 3] = fa;
                                } else {
                                    // Proper source-over alpha compositing
                                    let inv_sa = 255 - fa as u16;
                                    pixels[idx] = ((color[0] as u16 * fa as u16
                                        + pixels[idx] as u16 * inv_sa)
                                        / 255)
                                        as u8;
                                    pixels[idx + 1] = ((color[1] as u16 * fa as u16
                                        + pixels[idx + 1] as u16 * inv_sa)
                                        / 255)
                                        as u8;
                                    pixels[idx + 2] = ((color[2] as u16 * fa as u16
                                        + pixels[idx + 2] as u16 * inv_sa)
                                        / 255)
                                        as u8;
                                    pixels[idx + 3] =
                                        (fa as u16 + da as u16 * inv_sa / 255).min(255) as u8;
                                }
                            }
                        }
                    }
                }
                cursor_x += glyph.advance;
            }
        }

        let image_id = {
            let mut id = state.next_image_id.lock();
            let iid = *id;
            *id += 1;
            iid
        };
        state.images.lock().insert(
            image_id,
            ImageData {
                width,
                height: line_h,
                pixels,
            },
        );
        return (image_id, width as i32, line_h as i32);
    }

    // Fallback: strip colors and render as plain white text
    let full_text: String = segments.iter().map(|(_, t)| t.as_str()).collect();
    render_text_to_image(state, &full_text, font_size)
}

fn current_transform(state: &SharedState) -> Transform {
    state
        .transform_stack
        .lock()
        .last()
        .cloned()
        .unwrap_or_default()
}

const TEXT_CACHE_MAX_ENTRIES: usize = 512;
const TEXT_CACHE_MAX_BYTES: usize = 32 * 1024 * 1024;

fn plain_text_cache_key(
    kind: u8,
    font_id: u64,
    font_size: f32,
    text: &str,
    extra: &[u8],
) -> Vec<u8> {
    let mut key = Vec::with_capacity(1 + 8 + 4 + 8 + text.len() + 8 + extra.len());
    key.push(kind);
    key.extend_from_slice(&font_id.to_le_bytes());
    key.extend_from_slice(&font_size.to_bits().to_le_bytes());
    key.extend_from_slice(&(text.len() as u64).to_le_bytes());
    key.extend_from_slice(text.as_bytes());
    key.extend_from_slice(&(extra.len() as u64).to_le_bytes());
    key.extend_from_slice(extra);
    key
}

fn colored_text_cache_key(font_id: u64, font_size: f32, segments: &[ColoredSegment]) -> Vec<u8> {
    let text_bytes = segments.iter().map(|(_, text)| text.len()).sum::<usize>();
    let mut key = Vec::with_capacity(1 + 8 + 4 + 8 + segments.len() * 12 + text_bytes);
    key.push(b'c');
    key.extend_from_slice(&font_id.to_le_bytes());
    key.extend_from_slice(&font_size.to_bits().to_le_bytes());
    key.extend_from_slice(&(segments.len() as u64).to_le_bytes());
    for (color, text) in segments {
        key.extend_from_slice(color);
        key.extend_from_slice(&(text.len() as u64).to_le_bytes());
        key.extend_from_slice(text.as_bytes());
    }
    key
}

fn cached_text_image(
    state: &SharedState,
    key: Vec<u8>,
    render: impl FnOnce() -> (u64, i32, i32),
) -> (u64, i32, i32, bool) {
    {
        let mut cache = state.text_image_cache.lock();
        if let Some(entry) = cache.entries.get(&key).copied() {
            if let Some(position) = cache.order.iter().position(|value| value == &key) {
                cache.order.remove(position);
            }
            cache.order.push_back(key);
            return (entry.image_id, entry.width, entry.height, true);
        }
    }

    let (image_id, width, height) = render();
    let bytes = width.max(0) as usize * height.max(0) as usize * 4;
    if image_id == 0 || bytes == 0 || bytes > TEXT_CACHE_MAX_BYTES {
        return (image_id, width, height, false);
    }

    let mut cache = state.text_image_cache.lock();
    while !cache.entries.is_empty()
        && (cache.entries.len() >= TEXT_CACHE_MAX_ENTRIES
            || cache.bytes.saturating_add(bytes) > TEXT_CACHE_MAX_BYTES)
    {
        let Some(old_key) = cache.order.pop_front() else {
            break;
        };
        if let Some(old) = cache.entries.remove(&old_key) {
            cache.bytes = cache.bytes.saturating_sub(old.bytes);
            state.images.lock().remove(&old.image_id);
        }
    }
    cache.entries.insert(
        key.clone(),
        CachedTextImage {
            image_id,
            width,
            height,
            bytes,
        },
    );
    cache.order.push_back(key);
    cache.bytes += bytes;
    (image_id, width, height, true)
}

#[allow(clippy::too_many_arguments)]
fn draw_transient_text(
    state: &SharedState,
    image_id: u64,
    width: i32,
    height: i32,
    x: f32,
    y: f32,
    rotation: f32,
    scale_x: f32,
    scale_y: f32,
    origin_x: f32,
    origin_y: f32,
    cached: bool,
) {
    if image_id == 0 || width <= 0 || height <= 0 {
        return;
    }
    let transform = current_transform(state);
    let color = color_f32_to_u8(*state.current_color.lock());
    if state.is_gpu_recording() {
        if rotation.abs() > 0.001 || transform.b.abs() > 0.001 || transform.c.abs() > 0.001 {
            state.reject_gpu_frame();
            return;
        }
        let (scale_tx, scale_ty) = transform.scale_factor();
        let (tx, ty) = transform.apply(x - origin_x * scale_x, y - origin_y * scale_y);
        state.record_gpu(GpuCommand::Image {
            image_id,
            source: (0, 0, width as u32, height as u32),
            destination: (
                tx.round(),
                ty.round(),
                (width as f32 * scale_x.abs() * scale_tx).round(),
                (height as f32 * scale_y.abs() * scale_ty).round(),
            ),
            color,
            clip: *state.scissor.lock(),
        });
        return;
    }
    {
        let images = state.images.lock();
        if let Some(image) = images.get(&image_id) {
            draw_region(
                state,
                &image.pixels,
                image.width,
                image.height,
                0.0,
                0.0,
                width as f32,
                height as f32,
                x,
                y,
                rotation,
                scale_x,
                scale_y,
                origin_x,
                origin_y,
                &transform,
                color,
                false,
                DissolveParams::NONE,
            );
        }
    }
    if !cached {
        state.images.lock().remove(&image_id);
    }
}

/// Extract text string from a Lua value that may be a plain string or a colored text table.
/// Colored text tables have the form: {color_table, "text", color_table, "text", ...}
fn extract_text_from_lua(value: &LuaValue) -> String {
    match value {
        LuaValue::String(s) => s.to_string_lossy().to_string(),
        LuaValue::Table(t) => {
            let mut result = String::new();
            let len = t.raw_len();
            for i in 1..=len {
                if let Ok(LuaValue::String(s)) = t.get::<LuaValue>(i) {
                    result.push_str(&s.to_string_lossy());
                }
                // Skip color tables (they're tables, not strings)
            }
            result
        }
        _ => String::new(),
    }
}

/// A text segment with its own color: (color_rgba_u8, text_string)
type ColoredSegment = ([u8; 4], String);

/// Parse a LÖVE colored text table into segments.
/// Format: {color_table, "text", color_table, "text", ...}
/// where color_table = {r, g, b [, a]} with floats in 0..1
/// Returns None for plain strings (caller should use current color).
fn parse_colored_text(value: &LuaValue) -> Option<Vec<ColoredSegment>> {
    match value {
        LuaValue::Table(t) => {
            let len = t.raw_len();
            if len == 0 {
                return None;
            }
            let mut segments: Vec<ColoredSegment> = Vec::new();
            let mut current_color = [255u8, 255, 255, 255]; // default white
            for i in 1..=len {
                match t.get::<LuaValue>(i) {
                    Ok(LuaValue::Table(color_tbl)) => {
                        // Color table: {r, g, b [, a]}
                        let r = color_tbl.get::<f32>(1).unwrap_or(1.0);
                        let g = color_tbl.get::<f32>(2).unwrap_or(1.0);
                        let b = color_tbl.get::<f32>(3).unwrap_or(1.0);
                        let a = color_tbl.get::<f32>(4).unwrap_or(1.0);
                        current_color = color_f32_to_u8([r, g, b, a]);
                    }
                    Ok(LuaValue::String(s)) => {
                        let text = s.to_string_lossy().to_string();
                        if !text.is_empty() {
                            segments.push((current_color, text));
                        }
                    }
                    _ => {}
                }
            }
            if segments.is_empty() {
                None
            } else {
                Some(segments)
            }
        }
        _ => None,
    }
}

/// Draw a source image region with full transform support (including rotation).
/// Draw a source image region to a specific PixelBuffer (no lock acquisition)
fn draw_region_to_buf(
    pb: &mut PixelBuffer,
    src_pixels: &[u8],
    src_w: u32,
    src_h: u32,
    src_x: f32,
    src_y: f32,
    src_rw: f32,
    src_rh: f32,
    x: f32,
    y: f32,
    r: f32,
    sx: f32,
    sy: f32,
    ox: f32,
    oy: f32,
    t: &Transform,
    color: [u8; 4],
    replace: bool,
    dp: DissolveParams,
) {
    if r.abs() > 0.001 {
        let mut composite = t.clone();
        composite.translate(x, y);
        composite.rotate(r);
        composite.scale(sx, sy);
        composite.translate(-ox, -oy);
        let inv = match composite.inverse() {
            Some(inv) => inv,
            None => return,
        };
        let corners = [
            composite.apply(0.0, 0.0),
            composite.apply(src_rw, 0.0),
            composite.apply(src_rw, src_rh),
            composite.apply(0.0, src_rh),
        ];
        let min_x = corners.iter().map(|c| c.0).fold(f32::MAX, f32::min).floor() as i32;
        let max_x = corners.iter().map(|c| c.0).fold(f32::MIN, f32::max).ceil() as i32;
        let min_y = corners.iter().map(|c| c.1).fold(f32::MAX, f32::min).floor() as i32;
        let max_y = corners.iter().map(|c| c.1).fold(f32::MIN, f32::max).ceil() as i32;
        pb.draw_image_region_transformed(
            src_pixels,
            src_w,
            src_x,
            src_y,
            src_rw,
            src_rh,
            (min_x, min_y, max_x, max_y),
            [inv.a, inv.b, inv.tx, inv.c, inv.d, inv.ty],
            color,
            replace,
            dp,
        );
    } else {
        let local_x = x - ox * sx;
        let local_y = y - oy * sy;
        let (dst_x, dst_y) = t.apply(local_x, local_y);
        let (scale_x, scale_y) = t.scale_factor();
        let final_sx = sx * scale_x;
        let final_sy = sy * scale_y;
        pb.draw_image_region(
            src_pixels, src_w, src_h, src_x, src_y, src_rw, src_rh, dst_x, dst_y, final_sx,
            final_sy, color, replace, dp,
        );
    }
}

fn draw_region(
    state: &SharedState,
    src_pixels: &[u8],
    src_w: u32,
    src_h: u32,
    src_x: f32,
    src_y: f32,
    src_rw: f32,
    src_rh: f32,
    x: f32,
    y: f32,
    r: f32,
    sx: f32,
    sy: f32,
    ox: f32,
    oy: f32,
    t: &Transform,
    color: [u8; 4],
    replace: bool,
    dp: DissolveParams,
) {
    state.with_active_buffer(|pb| {
        draw_region_to_buf(
            pb, src_pixels, src_w, src_h, src_x, src_y, src_rw, src_rh, x, y, r, sx, sy, ox, oy, t,
            color, replace, dp,
        );
    });
}

/// Render word-wrapped text into a new image in the image registry.
fn render_text_to_image_wrapped(
    state: &SharedState,
    text: &str,
    font_size: f32,
    wrap_limit: f32,
    align: &str,
) -> (u64, i32, i32) {
    if text.is_empty() {
        return (0, 0, 0);
    }

    let font_id = *state.active_font_id.lock();
    if let Some(fd) = get_font(state, font_id) {
        // TTF path — use fontdue for proper word wrapping and rendering
        let measure = |s: &str| -> f32 { fd.text_width_at(s, font_size) };
        let line_h = fd.line_height_at(font_size).ceil() as u32;

        // Word wrap using real font metrics
        let mut lines: Vec<String> = Vec::new();
        for paragraph in text.split('\n') {
            let mut current_line = String::new();
            let mut current_width: f32 = 0.0;
            for word in paragraph.split_whitespace() {
                let word_w = measure(word);
                if current_width + word_w > wrap_limit && !current_line.is_empty() {
                    lines.push(current_line.clone());
                    current_line.clear();
                    current_width = 0.0;
                }
                if !current_line.is_empty() {
                    current_line.push(' ');
                    current_width += measure(" ");
                }
                current_line.push_str(word);
                current_width += word_w;
            }
            lines.push(current_line);
        }

        let total_h = (lines.len() as u32 * line_h).max(1);
        let total_w = wrap_limit.ceil() as u32;
        if total_w == 0 || total_h == 0 {
            return (0, 0, 0);
        }

        let mut pb = PixelBuffer::new(total_w, total_h);
        for (i, line) in lines.iter().enumerate() {
            if line.is_empty() {
                continue;
            }
            let (lw, lh, lpixels) = fd.rasterize_text_at(line, font_size);
            if lw == 0 || lh == 0 {
                continue;
            }
            let line_px_w = lw as f32;
            let lx = match align {
                "center" => ((total_w as f32 - line_px_w) / 2.0).max(0.0) as i32,
                "right" => (total_w as f32 - line_px_w).max(0.0) as i32,
                _ => 0,
            };
            let ly = (i as u32 * line_h) as i32;
            // Blit the rasterized line onto the buffer
            for gy in 0..lh {
                for gx in 0..lw {
                    let si = ((gy * lw + gx) * 4) as usize;
                    let alpha = lpixels[si + 3];
                    if alpha > 0 {
                        let px = lx + gx as i32;
                        let py = ly + gy as i32;
                        if px >= 0 && (px as u32) < total_w && py >= 0 && (py as u32) < total_h {
                            pb.set_pixel(px as u32, py as u32, 255, 255, 255, alpha);
                        }
                    }
                }
            }
        }

        let image_id = {
            let mut id = state.next_image_id.lock();
            let iid = *id;
            *id += 1;
            iid
        };
        state.images.lock().insert(
            image_id,
            ImageData {
                width: total_w,
                height: total_h,
                pixels: pb.pixels,
            },
        );
        return (image_id, total_w as i32, total_h as i32);
    }

    // Bitmap fallback
    let scale = (font_size / 8.0).max(1.0);
    let char_w = (8.0 * scale).ceil();
    let line_h = (8.0 * scale).ceil() as u32;

    let lines = word_wrap(text, char_w, wrap_limit);
    let total_h = (lines.len() as u32 * line_h).max(1);
    let total_w = wrap_limit.ceil() as u32;

    if total_w == 0 || total_h == 0 {
        return (0, 0, 0);
    }

    let mut pb = PixelBuffer::new(total_w, total_h);
    for (i, line) in lines.iter().enumerate() {
        let ly = (i as u32 * line_h) as i32;
        let line_px_w = line.len() as f32 * char_w;
        let lx = match align {
            "center" => ((total_w as f32 - line_px_w) / 2.0).max(0.0) as i32,
            "right" => (total_w as f32 - line_px_w).max(0.0) as i32,
            _ => 0,
        };
        pb.draw_text_scaled(line, lx, ly, scale, [255, 255, 255, 255]);
    }

    let image_id = {
        let mut id = state.next_image_id.lock();
        let iid = *id;
        *id += 1;
        iid
    };
    state.images.lock().insert(
        image_id,
        ImageData {
            width: total_w,
            height: total_h,
            pixels: pb.pixels,
        },
    );

    (image_id, total_w as i32, total_h as i32)
}

/// Bresenham line drawing between two points.
fn draw_line_bresenham(pb: &mut PixelBuffer, x0: i32, y0: i32, x1: i32, y1: i32, color: [u8; 4]) {
    let dx = (x1 - x0).abs();
    let dy = -(y1 - y0).abs();
    let sx: i32 = if x0 < x1 { 1 } else { -1 };
    let sy: i32 = if y0 < y1 { 1 } else { -1 };
    let mut err = dx + dy;
    let mut cx = x0;
    let mut cy = y0;

    loop {
        if cx >= 0 && cy >= 0 {
            pb.set_pixel(cx as u32, cy as u32, color[0], color[1], color[2], color[3]);
        }
        if cx == x1 && cy == y1 {
            break;
        }
        let e2 = 2 * err;
        if e2 >= dy {
            err += dy;
            cx += sx;
        }
        if e2 <= dx {
            err += dx;
            cy += sy;
        }
    }
}

/// Draw a line with thickness. For width <= 1.5, falls back to Bresenham.
/// For thicker lines, draws a filled rectangle along the line direction.
fn draw_thick_line(
    pb: &mut PixelBuffer,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    width: f32,
    color: [u8; 4],
) {
    if width <= 1.5 {
        draw_line_bresenham(pb, x0 as i32, y0 as i32, x1 as i32, y1 as i32, color);
        return;
    }
    let dx = x1 - x0;
    let dy = y1 - y0;
    let len = (dx * dx + dy * dy).sqrt();
    if len < 0.5 {
        return;
    }
    // Normal perpendicular to line direction
    let half_w = width * 0.5;
    let nx = -dy / len * half_w;
    let ny = dx / len * half_w;
    // Four corners of the thick line rectangle
    let vertices = [
        (x0 + nx, y0 + ny),
        (x0 - nx, y0 - ny),
        (x1 - nx, y1 - ny),
        (x1 + nx, y1 + ny),
    ];
    fill_polygon(pb, &vertices, color);
}

/// Draw a filled ellipse using the midpoint algorithm with horizontal spans.
fn draw_filled_ellipse(pb: &mut PixelBuffer, cx: i32, cy: i32, rx: i32, ry: i32, color: [u8; 4]) {
    if rx <= 0 || ry <= 0 {
        return;
    }
    let rx_f = rx as f32;
    let ry_f = ry as f32;

    for dy in -ry..=ry {
        let ny = dy as f32 / ry_f;
        let ny2 = ny * ny;
        if ny2 >= 1.0 {
            continue;
        }
        // Exact edge x at this y: x_edge = rx * sqrt(1 - ny^2)
        let x_edge = rx_f * (1.0 - ny2).sqrt();
        let x_span = x_edge as i32;
        let row_y = cy + dy;
        // Interior fill (fully inside)
        if x_span > 0 {
            pb.fill_rect(cx - x_span + 1, row_y, (x_span - 1) * 2, 1, color);
        }
        // Anti-alias edge pixels: compute coverage from ellipse distance
        for &dx in &[-(x_span), x_span] {
            let nx = dx as f32 / rx_f;
            let d = nx * nx + ny2;
            let cov = if d <= 0.85 {
                1.0
            } else if d >= 1.15 {
                0.0
            } else {
                let t = ((d - 0.85) * (1.0 / 0.3)).clamp(0.0, 1.0);
                1.0 - t * t * (3.0 - 2.0 * t)
            };
            if cov > 0.01 {
                let a = (color[3] as f32 * cov) as u8;
                let px = cx + dx;
                if px >= 0 && row_y >= 0 {
                    pb.set_pixel(px as u32, row_y as u32, color[0], color[1], color[2], a);
                }
            }
        }
        // Also AA the pixel just outside the edge
        for &dx in &[-(x_span + 1), x_span + 1] {
            let nx = dx as f32 / rx_f;
            let d = nx * nx + ny2;
            if d < 1.15 {
                let cov = if d <= 0.85 {
                    1.0
                } else {
                    let t = ((d - 0.85) * (1.0 / 0.3)).clamp(0.0, 1.0);
                    1.0 - t * t * (3.0 - 2.0 * t)
                };
                if cov > 0.01 {
                    let a = (color[3] as f32 * cov) as u8;
                    let px = cx + dx;
                    if px >= 0 && row_y >= 0 {
                        pb.set_pixel(px as u32, row_y as u32, color[0], color[1], color[2], a);
                    }
                }
            }
        }
    }
}

/// Fill a polygon using scanline with even-odd rule.
/// For convex/simple polygons (like Balatro's rounded rects), this works directly.
/// For complex polygons with a center vertex (triangle fan format), the even-odd
/// rule still produces correct results for the perimeter shape.
fn fill_polygon(pb: &mut PixelBuffer, vertices: &[(f32, f32)], color: [u8; 4]) {
    if vertices.len() < 3 {
        return;
    }

    // Detect triangle-fan format: if vertex[0] is roughly at the centroid
    // (inside the bounding box of the remaining vertices), use perimeter only.
    // This avoids seam artifacts from triangle decomposition.
    let perimeter = if vertices.len() > 6 {
        let (cx, cy) = vertices[0];
        let (mut min_x, mut max_x, mut min_y, mut max_y) = (f32::MAX, f32::MIN, f32::MAX, f32::MIN);
        for &(x, y) in &vertices[1..] {
            min_x = min_x.min(x);
            max_x = max_x.max(x);
            min_y = min_y.min(y);
            max_y = max_y.max(y);
        }
        if cx > min_x && cx < max_x && cy > min_y && cy < max_y {
            &vertices[1..] // Skip center vertex, use perimeter only
        } else {
            vertices
        }
    } else {
        vertices
    };

    // Scanline fill with even-odd rule
    let mut min_y = f32::MAX;
    let mut max_y = f32::MIN;
    for &(_, y) in perimeter {
        min_y = min_y.min(y);
        max_y = max_y.max(y);
    }

    let y_start = min_y.floor() as i32;
    let y_end = max_y.ceil() as i32;

    for y in y_start..=y_end {
        let yf = y as f32 + 0.5;
        let mut intersections: Vec<f32> = Vec::new();

        for i in 0..perimeter.len() {
            let j = (i + 1) % perimeter.len();
            let (x0, y0) = perimeter[i];
            let (x1, y1) = perimeter[j];

            if (y0 <= yf && y1 > yf) || (y1 <= yf && y0 > yf) {
                let t = (yf - y0) / (y1 - y0);
                intersections.push(x0 + t * (x1 - x0));
            }
        }

        intersections.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));

        for pair in intersections.chunks(2) {
            if pair.len() == 2 {
                let left = pair[0];
                let right = pair[1];
                let x_start = left.floor() as i32;
                let x_end = right.ceil() as i32;
                if x_end <= x_start {
                    continue;
                }
                // Left edge AA pixel
                let left_cov = (1.0 - (left - left.floor())).clamp(0.0, 1.0);
                if left_cov > 0.01 && left_cov < 0.99 {
                    let a = (color[3] as f32 * left_cov) as u8;
                    if x_start >= 0 && y >= 0 {
                        pb.set_pixel(x_start as u32, y as u32, color[0], color[1], color[2], a);
                    }
                    // Fill interior (skip left edge pixel)
                    if x_end - x_start - 1 > 0 {
                        // Right edge AA pixel
                        let right_cov = (right - right.floor()).clamp(0.0, 1.0);
                        let r_end = x_end - 1;
                        if right_cov > 0.01 && right_cov < 0.99 && r_end > x_start + 1 {
                            pb.fill_rect(x_start + 1, y, r_end - x_start - 1, 1, color);
                            let a2 = (color[3] as f32 * right_cov) as u8;
                            if r_end >= 0 {
                                pb.set_pixel(
                                    r_end as u32,
                                    y as u32,
                                    color[0],
                                    color[1],
                                    color[2],
                                    a2,
                                );
                            }
                        } else {
                            pb.fill_rect(x_start + 1, y, x_end - x_start - 1, 1, color);
                        }
                    }
                } else {
                    // Left edge is near-fully covered, use simple fill
                    // Right edge AA
                    let right_cov = (right - right.floor()).clamp(0.0, 1.0);
                    let r_end = x_end - 1;
                    if right_cov > 0.01 && right_cov < 0.99 && r_end > x_start {
                        pb.fill_rect(x_start, y, r_end - x_start, 1, color);
                        let a2 = (color[3] as f32 * right_cov) as u8;
                        if r_end >= 0 {
                            pb.set_pixel(r_end as u32, y as u32, color[0], color[1], color[2], a2);
                        }
                    } else {
                        pb.fill_rect(x_start, y, x_end - x_start, 1, color);
                    }
                }
            }
        }
    }
}

/// Parse a numeric argument from a LuaValue, with a default fallback.
#[inline]
fn parse_num_arg(val: Option<&LuaValue>, default: f32) -> f32 {
    match val {
        Some(LuaValue::Number(n)) => *n as f32,
        Some(LuaValue::Integer(n)) => *n as f32,
        _ => default,
    }
}

/// Word-wrap text to fit within a pixel width limit.
fn word_wrap(text: &str, char_w: f32, limit: f32) -> Vec<String> {
    if text.is_empty() {
        return vec![String::new()];
    }
    let mut lines = Vec::new();
    // Split by explicit newlines first
    for paragraph in text.split('\n') {
        let mut current_line = String::new();
        let mut current_width: f32 = 0.0;

        for word in paragraph.split_whitespace() {
            let word_width = word.len() as f32 * char_w;
            if current_width + word_width > limit && !current_line.is_empty() {
                lines.push(current_line.clone());
                current_line.clear();
                current_width = 0.0;
            }
            if !current_line.is_empty() {
                current_line.push(' ');
                current_width += char_w;
            }
            current_line.push_str(word);
            current_width += word_width;
        }
        lines.push(current_line);
    }
    if lines.is_empty() {
        lines.push(String::new());
    }
    lines
}

/// Draw a stroked (outline) ellipse with anti-aliased edges using distance field.
/// Per-pixel flame shader matching flame.fs GLSL.
/// ux, uy: UV coordinates in -0.5..0.5 (centered within the sprite).
/// Returns [r, g, b, a] in 0..255. Alpha=0 means transparent (no flame here).
fn flame_pixel(
    ux: f32,
    uy: f32,
    time: f32,
    intensity: f32, // already clamped to 10.0
    id: f32,
    c1: [f32; 3],
    c2: [f32; 3],
) -> [u8; 4] {
    const PIXEL_SIZE_FAC: f32 = 60.0;

    // Pixelate UV to PIXEL_SIZE_FAC grid
    let floored_x = (ux * PIXEL_SIZE_FAC).floor() / PIXEL_SIZE_FAC;
    let floored_y = (uy * PIXEL_SIZE_FAC).floor() / PIXEL_SIZE_FAC;

    // Small wavering wobble
    let wobble =
        0.01 * (-1.123 * floored_x + 0.2 * time).sin() * (5.3332 * floored_y + time * 0.931).cos();
    let usc_x = floored_x + floored_x * wobble;
    let usc_y = floored_y + floored_y * wobble;

    // Upward-scrolling offset (gives fire the rising motion)
    let flame_up_y = (4.0 * time).rem_euclid(10000.0) - 5000.0 + (1.781 * id).rem_euclid(1000.0);

    let scale_fac = 7.5 + 3.0 / (2.0 + 2.0 * intensity);

    let mut sv_x = usc_x * scale_fac;
    let mut sv_y = usc_y * scale_fac + flame_up_y;

    let speed = (20.781 * id).rem_euclid(100.0) + (time + id).sin() * (time * 0.151 + id).cos();

    let mut sv2_x = 0.0f32;
    let mut sv2_y = 0.0f32;

    // 5-iteration turbulence loop (matches GLSL exactly)
    // Note: mod(float(i), 2.) > 1. is never true for i in 0..4, so sign = +1 always
    for _ in 0..5 {
        let len_sv = (sv_x * sv_x + sv_y * sv_y).sqrt();
        let noise = 0.3 * ((len_sv * 0.411).cos() + 0.3344 * len_sv.sin() - 0.23 * len_sv.cos());
        // GLSL simultaneous vec2 update using old sv2 values and sv2.yx swizzle
        let new_sv2_x = sv2_x + sv_x + 0.05 * sv2_y + noise;
        let new_sv2_y = sv2_y + sv_y + 0.05 * sv2_x + noise;
        sv2_x = new_sv2_x;
        sv2_y = new_sv2_y;
        // sv update uses the new sv2
        sv_x += 0.5 * (sv2_y.cos() + speed * 0.0812).cos() * (3.22 + sv2_x - speed * 0.1531).sin();
        sv_y += 0.5
            * (-sv2_x * 1.21222 + 0.113785 * speed).sin()
            * (sv2_y * 0.91213 - 0.13582 * speed).cos();
    }

    // Smoke density: distance of sv from the upward offset, normalized back to UV space
    let dist_x = (sv_x) / scale_fac * 5.0;
    let dist_y = (sv_y - flame_up_y) / scale_fac * 5.0;
    let len_dist = (dist_x * dist_x + dist_y * dist_y).sqrt();
    let len_usc = (usc_x * usc_x + usc_y * usc_y).sqrt();

    let mut smoke_res =
        (len_dist + 0.1 * (len_usc - 0.5)).max(0.0) * (2.0 / (2.0 + intensity * 0.2));

    // Fade out toward top of sprite (usc_y = -0.5 → large term, usc_y = 0.5 → 0)
    let fade_top =
        (2.0 - 0.3 * intensity).max(0.0) * (2.0 * (usc_y - 0.5) * (usc_y - 0.5)).max(0.0);
    smoke_res += fade_top;

    // Clip beyond horizontal edges
    if ux.abs() > 0.4 {
        smoke_res += 10.0 * (ux.abs() - 0.4);
    }

    // Small dip at bottom center: punch through smoke if inside the oval near (0, 0.1)
    let adj_x = ux * 0.19;
    let adj_y = uy - 0.1;
    let len_adj = (adj_x * adj_x + adj_y * adj_y).sqrt();
    if len_adj < (0.1f32).min(intensity * 0.5) && smoke_res > 1.0 {
        smoke_res += (intensity * 10.0).min(8.5) * (len_adj - 0.1);
    }

    if smoke_res > 1.0 {
        return [0, 0, 0, 0];
    }

    // Color: mostly c1, blend toward c2 in the upper portion (uy < 0.12)
    let mut r = c1[0];
    let mut g = c1[1];
    let mut b = c1[2];
    if uy < 0.12 {
        let diff = 0.12 - uy;
        r = c1[0] * (1.0 - 0.5 * diff) + 2.5 * diff * c2[0];
        g = c1[1] * (1.0 - 0.5 * diff) + 2.5 * diff * c2[1];
        b = c1[2] * (1.0 - 0.5 * diff) + 2.5 * diff * c2[2];
        let mod_f = (-2.0 + 0.5 * intensity * smoke_res) * diff;
        r = (r + r * mod_f).max(0.0);
        g = (g + g * mod_f).max(0.0);
        b = (b + b * mod_f).max(0.0);
    }

    [
        (r * 255.0).clamp(0.0, 255.0) as u8,
        (g * 255.0).clamp(0.0, 255.0) as u8,
        (b * 255.0).clamp(0.0, 255.0) as u8,
        255,
    ]
}

fn draw_stroke_ellipse(pb: &mut PixelBuffer, cx: i32, cy: i32, rx: i32, ry: i32, color: [u8; 4]) {
    if rx <= 0 || ry <= 0 {
        return;
    }
    let rx_f = rx as f32;
    let ry_f = ry as f32;
    // Stroke is 1 pixel wide; check band around ellipse
    for dy in -(ry + 1)..=(ry + 1) {
        let ny = dy as f32 / ry_f;
        let row_y = cy + dy;
        if row_y < 0 || row_y >= pb.height as i32 {
            continue;
        }
        // Find approximate x range where ellipse passes
        let ny2 = ny * ny;
        if ny2 > 1.3 {
            continue;
        }
        let x_edge = if ny2 < 1.0 {
            rx_f * (1.0 - ny2).sqrt()
        } else {
            0.0
        };
        let x_lo = (x_edge - 1.5).max(0.0) as i32;
        let x_hi = (x_edge + 1.5) as i32 + 1;
        for sign in &[-1i32, 1] {
            for dx_abs in x_lo..=x_hi {
                let dx = dx_abs * sign;
                let px = cx + dx;
                if px < 0 || px >= pb.width as i32 {
                    continue;
                }
                let nx = dx as f32 / rx_f;
                let d = nx * nx + ny2;
                // d = 1.0 is the ellipse. We want pixels near d=1.0 to be bright.
                let dist_from_edge = (d - 1.0).abs();
                if dist_from_edge < 0.15 {
                    pb.set_pixel(
                        px as u32,
                        row_y as u32,
                        color[0],
                        color[1],
                        color[2],
                        color[3],
                    );
                } else if dist_from_edge < 0.3 {
                    let t = ((dist_from_edge - 0.15) / 0.15).clamp(0.0, 1.0);
                    let cov = 1.0 - t * t * (3.0 - 2.0 * t);
                    let a = (color[3] as f32 * cov) as u8;
                    pb.set_pixel(px as u32, row_y as u32, color[0], color[1], color[2], a);
                }
            }
        }
    }
}
