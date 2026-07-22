/// Convert RGB (0..1) to HSL (h: 0..6, s: 0..1, l: 0..1).
/// Matches the GLSL HSL() used in Balatro's shaders.
#[inline(always)]
fn rgb_to_hsl(r: f32, g: f32, b: f32) -> (f32, f32, f32) {
    let low = r.min(g.min(b));
    let high = r.max(g.max(b));
    let delta = high - low;
    let sum = high + low;
    let l = sum * 0.5;
    if delta < 0.001 {
        return (0.0, 0.0, l);
    }
    let s = if l < 0.5 {
        delta / sum
    } else {
        delta / (2.0 - sum)
    };
    let h = if high == r {
        (g - b) / delta
    } else if high == g {
        (b - r) / delta + 2.0
    } else {
        (r - g) / delta + 4.0
    };
    let h = ((h / 6.0) % 1.0 + 1.0) % 1.0;
    (h, s, l)
}

/// Convert HSL (h: 0..1, s: 0..1, l: 0..1) to RGB (0..1).
/// Matches the GLSL RGB() used in Balatro's shaders.
#[inline(always)]
fn hsl_to_rgb(h: f32, s: f32, l: f32) -> (f32, f32, f32) {
    if s < 0.0001 {
        return (l, l, l);
    }
    let t = if l < 0.5 { s * l + l } else { -s * l + (s + l) };
    let sv = 2.0 * l - t;
    let hue_comp = |hp: f32| -> f32 {
        let hp = ((hp % 1.0) + 1.0) % 1.0;
        let hs = hp * 6.0;
        if hs < 1.0 {
            (t - sv) * hs + sv
        } else if hs < 3.0 {
            t
        } else if hs < 4.0 {
            (t - sv) * (4.0 - hs) + sv
        } else {
            sv
        }
    };
    (
        hue_comp(h + 1.0 / 3.0),
        hue_comp(h),
        hue_comp(h - 1.0 / 3.0),
    )
}

// ══════════════════════════════════════════════════════════════════════════════
// Fast sin/cos via 4096-entry lookup table (16KB — fits in L1 cache).
// Max error ±0.00077, below the 1/255 = 0.0039 8-bit color quantization step.
// Replaces expensive f32::sin()/cos() (~25-50ns each) with ~2-3ns lookups.
// ══════════════════════════════════════════════════════════════════════════════

const TRIG_LUT_SIZE: usize = 4096;
const TRIG_LUT_SCALE: f32 = TRIG_LUT_SIZE as f32 / std::f32::consts::TAU;

static SIN_LUT_GLOBAL: std::sync::LazyLock<[f32; TRIG_LUT_SIZE]> = std::sync::LazyLock::new(|| {
    let mut lut = [0.0f32; TRIG_LUT_SIZE];
    for i in 0..TRIG_LUT_SIZE {
        lut[i] = (i as f32 * std::f32::consts::TAU / TRIG_LUT_SIZE as f32).sin();
    }
    lut
});

#[inline(always)]
fn fast_sin(x: f32) -> f32 {
    let lut = &*SIN_LUT_GLOBAL;
    let idx = ((x * TRIG_LUT_SCALE) % TRIG_LUT_SIZE as f32 + TRIG_LUT_SIZE as f32) as usize
        % TRIG_LUT_SIZE;
    lut[idx]
}

#[inline(always)]
fn fast_cos(x: f32) -> f32 {
    fast_sin(x + std::f32::consts::FRAC_PI_2)
}

/// Time-only precomputed values for card shaders.
/// Computed once per sprite (not per pixel) to avoid redundant trig.
#[derive(Clone, Copy)]
struct ShaderPre {
    // Foil (effect 3)
    foil_r: f32,
    foil_g: f32,
    foil_rot_x: f32,
    foil_rot_y: f32,
    foil_rot_len: f32,
    foil_inner_sin: f32, // fast_sin(foil_r * 1.65 + 0.2 * foil_g)
    foil_cos7: f32,      // fast_cos(foil_r * 7.0)
    foil_cos3414: f32,   // fast_cos(foil_r * 3.414)
    // Holo (effect 4) — time-only noise field offsets
    holo_x: f32,
    holo_t: f32,
    holo_off: [f32; 6], // sin1, cos1, cos2, cos2y, sin3, sin3y
    // Poly (effect 5)
    poly_x: f32,
    poly_y: f32,
    poly_t: f32,
    poly_off: [f32; 6],
    // Hologram (effect 9)
    holo9_sin_g: f32,
    holo9_sin_r: f32,
    // Voucher/Booster/Neg_shine (effects 7/8/10) — time/28 precomputed
    t28: f32,
    // Gold seal (effect 11)
    gs_t: f32,
    gs_sin6t: f32,
}

impl ShaderPre {
    fn compute(effect: u8, time: f32) -> Self {
        let mut sp = Self {
            foil_r: 0.0,
            foil_g: 0.0,
            foil_rot_x: 0.0,
            foil_rot_y: 0.0,
            foil_rot_len: 1.0,
            foil_inner_sin: 0.0,
            foil_cos7: 0.0,
            foil_cos3414: 0.0,
            holo_x: 0.0,
            holo_t: 0.0,
            holo_off: [0.0; 6],
            poly_x: 0.0,
            poly_y: 0.0,
            poly_t: 0.0,
            poly_off: [0.0; 6],
            holo9_sin_g: 0.0,
            holo9_sin_r: 0.0,
            t28: 0.0,
            gs_t: 0.0,
            gs_sin6t: 0.0,
        };
        match effect {
            3 => {
                sp.foil_r = time / 28.0;
                sp.foil_g = time;
                sp.foil_rot_x = fast_cos(sp.foil_r * 0.1221);
                sp.foil_rot_y = fast_sin(sp.foil_r * 0.3512);
                sp.foil_rot_len =
                    (sp.foil_rot_x * sp.foil_rot_x + sp.foil_rot_y * sp.foil_rot_y).sqrt();
                sp.foil_inner_sin = fast_sin(sp.foil_r * 1.65 + 0.2 * sp.foil_g);
                sp.foil_cos7 = fast_cos(sp.foil_r * 7.0);
                sp.foil_cos3414 = fast_cos(sp.foil_r * 3.414);
            }
            4 => {
                sp.holo_x = time / 28.0;
                sp.holo_t = time * 8.221;
                let t = sp.holo_t;
                sp.holo_off = [
                    50.0 * fast_sin(-t / 143.634),
                    50.0 * fast_cos(-t / 99.432),
                    50.0 * fast_cos(t / 53.153),
                    50.0 * fast_cos(t / 61.453),
                    50.0 * fast_sin(-t / 87.532),
                    50.0 * fast_sin(-t / 49.0),
                ];
            }
            5 => {
                sp.poly_x = time / 28.0;
                sp.poly_y = time;
                sp.poly_t = time * 3.221;
                let t = sp.poly_t;
                sp.poly_off = [
                    50.0 * fast_sin(-t / 143.634),
                    50.0 * fast_cos(-t / 99.432),
                    50.0 * fast_cos(t / 53.153),
                    50.0 * fast_cos(t / 61.453),
                    50.0 * fast_sin(-t / 87.532),
                    50.0 * fast_sin(-t / 49.0),
                ];
            }
            7 | 8 | 10 => {
                sp.t28 = time / 28.0;
            }
            9 => {
                let holo_r = time / 28.0;
                let holo_g = time;
                sp.holo9_sin_g = fast_sin(2.0 * holo_g);
                sp.holo9_sin_r = fast_sin(holo_r * 3.0);
            }
            11 => {
                sp.gs_t = time / 28.0;
                sp.gs_sin6t = fast_sin(sp.gs_t * 6.0);
            }
            _ => {}
        }
        sp
    }
}

/// Apply spatially-varying card shader effects per-pixel.
/// sp: precomputed time-only values (computed once per sprite, not per pixel)
#[inline(always)]
fn apply_card_shader(
    effect: u8,
    sp: &ShaderPre,
    ux: f32,
    uy: f32,
    _px: f32,
    _py: f32,
    r: &mut u8,
    g: &mut u8,
    b: &mut u8,
    a: &mut u8,
) {
    match effect {
        1 => {
            // Played: desaturate and darken, halve alpha
            // GLSL: SAT.g *= 0.5, SAT.b *= 0.8, tex.a *= 0.5
            let (rf, gf, bf) = (*r as f32 / 255.0, *g as f32 / 255.0, *b as f32 / 255.0);
            let (h, s, l) = rgb_to_hsl(rf, gf, bf);
            let (ro, go, bo) = hsl_to_rgb(h, s * 0.5, l * 0.8);
            *r = (ro * 255.0) as u8;
            *g = (go * 255.0) as u8;
            *b = (bo * 255.0) as u8;
            *a = *a >> 1; // * 0.5
        }
        2 => {
            // Debuff: HSL desaturation + reddish tint + diagonal stripe pattern
            // GLSL: blend tex*0.8+0.2*red, convert to HSL, apply stripes via UV
            let (rf, gf, bf) = (*r as f32 / 255.0, *g as f32 / 255.0, *b as f32 / 255.0);
            // Red tint: tex * 0.8 + 0.2 * (1, 0, 0)
            let rr = rf * 0.8 + 0.2;
            let rg = gf * 0.8;
            let rb = bf * 0.8;
            let (h, _s, l) = rgb_to_hsl(rr, rg, rb);

            // Diagonal stripe test: (uv.x+uv.y ≈ 1) or ((1-uv.x)+uv.y ≈ 1)
            let stripe_width = 0.1_f32;
            let d1 = (ux + uy - 1.0).abs();
            let d2 = ((1.0 - ux) + uy - 1.0).abs();
            let on_stripe = d1 < stripe_width || d2 < stripe_width;

            if on_stripe {
                // Bright magenta stripe: hue=1 (red), sat=0.7, lightness *= 0.8
                let (ro, go, bo) = hsl_to_rgb(1.0, 0.7, l * 0.8);
                *r = (ro * 255.0).min(255.0) as u8;
                *g = (go * 255.0).min(255.0) as u8;
                *b = (bo * 255.0).min(255.0) as u8;
                // Full alpha on stripe
            } else {
                // Desaturated, dark, 30% alpha
                let (ro, go, bo) = hsl_to_rgb(h, 0.25, l * 0.7);
                *r = (ro * 255.0).min(255.0) as u8;
                *g = (go * 255.0).min(255.0) as u8;
                *b = (bo * 255.0).min(255.0) as u8;
                *a = (*a as u16 * 77 / 256) as u8; // ~30% alpha
            }
        }
        3 => {
            // Foil: radial + angular shimmer in silvery-blue (time-only values precomputed in sp)
            let foil_r = sp.foil_r;
            let foil_g = sp.foil_g;
            let ax = (ux - 0.5) * (71.0 / 95.0);
            let ay = uy - 0.5;
            let len_uv = (ax * ax + ay * ay).sqrt();
            let len90 = len_uv * 90.0;

            let fac =
                (2.0 * fast_sin(
                    len90
                        + foil_r * 2.0
                        + 3.0 * (1.0 + 0.8 * fast_cos(len_uv * 113.1121 - foil_r * 3.121)),
                ) - 1.0
                    - (5.0 - len90).max(0.0))
                .clamp(0.0, 1.0);

            // Angle-based component (rot_x, rot_y, rot_len precomputed)
            let uv_len = len_uv.max(0.001);
            let angle = (sp.foil_rot_x * ax + sp.foil_rot_y * ay) / (sp.foil_rot_len * uv_len);
            let fac2 = (5.0
                * fast_cos(foil_g * 0.3 + angle * 3.14 * (2.2 + 0.9 * sp.foil_inner_sin))
                - 4.0
                - (2.0 - len_uv * 20.0).max(0.0))
            .clamp(0.0, 1.0);

            let fac3 = 0.3
                * (2.0 * fast_sin(foil_r * 5.0 + ux * 3.0 + 3.0 * (1.0 + 0.5 * sp.foil_cos7))
                    - 1.0)
                    .clamp(-1.0, 1.0);
            let fac4 = 0.3
                * (2.0 * fast_sin(foil_r * 6.66 + uy * 3.8 + 3.0 * (1.0 + 0.5 * sp.foil_cos3414))
                    - 1.0)
                    .clamp(-1.0, 1.0);

            let maxfac = (fac.max(fac2.max(fac3.max(fac4.max(0.0))))
                + 2.2 * (fac + fac2 + fac3 + fac4))
                .max(0.0);

            let (rf, gf, bf) = (*r as f32 / 255.0, *g as f32 / 255.0, *b as f32 / 255.0);
            let low = rf.min(gf.min(bf));
            let high = rf.max(gf.max(bf));
            // GLSL: delta = min(high, max(0.5, 1.0 - low))
            let delta = high.min((1.0_f32 - low).max(0.5));

            // Foil: silvery-blue shift — red/green get small boost, blue gets strong boost
            let ro = (rf - delta + delta * maxfac * 0.3).clamp(0.0, 1.0);
            let go = (gf - delta + delta * maxfac * 0.3).clamp(0.0, 1.0);
            let bo = (bf + delta * maxfac * 1.9).clamp(0.0, 1.0);
            *r = (ro * 255.0) as u8;
            *g = (go * 255.0) as u8;
            *b = (bo * 255.0) as u8;
            // GLSL: tex.a = min(tex.a, 0.3*tex.a + 0.9*min(0.5, maxfac*0.1))
            // Using min() ensures alpha only decreases, preserving edge pixels at bright shimmer.
            let af = *a as f32 / 255.0;
            let foil_a = af.min(0.3 * af + 0.9 * (maxfac * 0.1).min(0.5));
            *a = (foil_a * 255.0) as u8;
        }
        4 => {
            // Holo: HSL rainbow shift + grid pattern (time-only offsets precomputed in sp)
            let (rf, gf, bf) = (*r as f32 / 255.0, *g as f32 / 255.0, *b as f32 / 255.0);
            let mix_r = rf * 0.5;
            let mix_g = gf * 0.5;
            let mix_b = bf * 0.5 + 0.5;
            let (mut h, mut s, mut l) = rgb_to_hsl(mix_r, mix_g, mix_b);

            // Noise field with precomputed time-only offsets
            let fuv_x = ux * 250.0 - 125.0;
            let fuv_y = uy * 250.0 - 125.0;
            let f1x = fuv_x + sp.holo_off[0];
            let f1y = fuv_y + sp.holo_off[1];
            let f2x = fuv_x + sp.holo_off[2];
            let f2y = fuv_y + sp.holo_off[3];
            let f3x = fuv_x + sp.holo_off[4];
            let f3y = fuv_y + sp.holo_off[5];
            let field_len1 = (f1x * f1x + f1y * f1y).sqrt();
            let field_len2 = (f2x * f2x + f2y * f2y).sqrt();
            let field_len3 = (f3x * f3x + f3y * f3y).sqrt();
            let field = (1.0
                + fast_cos(field_len1 / 19.483)
                + fast_sin(field_len2 / 33.155) * fast_cos(f2y / 15.73)
                + fast_cos(field_len3 / 27.193) * fast_sin(f3x / 21.92))
                / 2.0;
            let res = 0.5 + 0.5 * fast_cos(sp.holo_x * 2.612 + (field - 0.5) * 3.14);

            // Grid pattern (hexagonal-ish)
            let gridsize = 0.79_f32;
            let grid1 = (7.0 * fast_cos(ux * gridsize * 20.0).abs() - 6.0).max(0.0);
            let grid2 =
                (7.0 * fast_cos(uy * gridsize * 45.0 + ux * gridsize * 20.0) - 6.0).max(0.0);
            let grid3 =
                (7.0 * fast_cos(uy * gridsize * 45.0 - ux * gridsize * 20.0) - 6.0).max(0.0);
            let fac = 0.5 * grid1.max(grid2.max(grid3));

            let low = rf.min(gf.min(bf));
            let high = rf.max(gf.max(bf));
            let delta = 0.2 + 0.3 * (high - low) + 0.1 * high;

            h = h + res + fac;
            s = s * 1.3;
            l = l * 0.6 + 0.4;

            let (hr, hg, hb) = hsl_to_rgb(((h % 1.0) + 1.0) % 1.0, s.min(1.0), l.min(1.0));
            let ro = (1.0 - delta) * rf + delta * hr * 0.9;
            let go = (1.0 - delta) * gf + delta * hg * 0.8;
            let bo = (1.0 - delta) * bf + delta * hb * 1.2;
            *r = (ro.clamp(0.0, 1.0) * 255.0) as u8;
            *g = (go.clamp(0.0, 1.0) * 255.0) as u8;
            *b = (bo.clamp(0.0, 1.0) * 255.0) as u8;
            if (*a as f32) < 178.5 {
                // < 0.7 * 255
                *a = *a / 3;
            }
        }
        5 => {
            // Polychrome: HSL hue rotation via noise field
            // GLSL: polychrome.x ≈ REAL/28 (slow, drives color sweep)
            //        polychrome.y = REAL (fast, drives field + hue drift)
            let (rf, gf, bf) = (*r as f32 / 255.0, *g as f32 / 255.0, *b as f32 / 255.0);
            let low = rf.min(gf.min(bf));
            let high = rf.max(gf.max(bf));
            let delta = high - low;
            let sat_fac = 1.0 - (0.05 * (1.1 - delta)).max(0.0);
            let (mut h, s, _l) = rgb_to_hsl(rf * sat_fac, gf * sat_fac, bf);

            // 3-part noise field — time-only offsets precomputed in sp.poly_off
            let fuv_x = ux * 50.0 - 25.0;
            let fuv_y = uy * 50.0 - 25.0;
            let f1x = fuv_x + sp.poly_off[0];
            let f1y = fuv_y + sp.poly_off[1];
            let f2x = fuv_x + sp.poly_off[2];
            let f2y = fuv_y + sp.poly_off[3];
            let f3x = fuv_x + sp.poly_off[4];
            let f3y = fuv_y + sp.poly_off[5];
            let field_len1 = (f1x * f1x + f1y * f1y).sqrt();
            let field_len2 = (f2x * f2x + f2y * f2y).sqrt();
            let field_len3 = (f3x * f3x + f3y * f3y).sqrt();
            let field = (1.0
                + fast_cos(field_len1 / 19.483)
                + fast_sin(field_len2 / 33.155) * fast_cos(f2y / 15.73)
                + fast_cos(field_len3 / 27.193) * fast_sin(f3x / 21.92))
                / 2.0;
            let res = 0.5 + 0.5 * fast_cos(sp.poly_x * 2.612 + (field - 0.5) * 3.14);

            h = h + res + sp.poly_y * 0.04;
            let s_out = s.min(0.6).max(s + 0.5);
            let s_clamped = s_out.min(0.6);

            let (ro, go, bo) = hsl_to_rgb(((h % 1.0) + 1.0) % 1.0, s_clamped, _l);
            *r = (ro.clamp(0.0, 1.0) * 255.0) as u8;
            *g = (go.clamp(0.0, 1.0) * 255.0) as u8;
            *b = (bo.clamp(0.0, 1.0) * 255.0) as u8;
            if (*a as f32) < 178.5 {
                *a = *a / 3;
            }
        }
        6 => {
            // Negative: HSL-based inversion + blue-green tint
            // GLSL: convert to HSL, invert lightness, shift hue, convert back, add tint
            let (rf, gf, bf) = (*r as f32 / 255.0, *g as f32 / 255.0, *b as f32 / 255.0);
            let (h, s, l) = rgb_to_hsl(rf, gf, bf);
            // Invert lightness (negative.g != 0 case, which is the normal card state)
            let l_inv = 1.0 - l;
            // Shift hue: -h + 0.2
            let h_new = ((-h + 0.2) % 1.0 + 1.0) % 1.0;
            let (nr, ng, nb) = hsl_to_rgb(h_new, s, l_inv);
            // Add blue-green tint: + 0.8 * (79/255, 99/255, 103/255)
            *r = ((nr + 0.8 * 79.0 / 255.0).clamp(0.0, 1.0) * 255.0) as u8;
            *g = ((ng + 0.8 * 99.0 / 255.0).clamp(0.0, 1.0) * 255.0) as u8;
            *b = ((nb + 0.8 * 103.0 / 255.0).clamp(0.0, 1.0) * 255.0) as u8;
            if (*a as f32) < 178.5 {
                *a = *a / 3;
            }
        }
        10 => {
            // Negative_shine: multi-component animated sine wave shimmer
            // From negative_shine.fs: 5 sine components create moving light patterns
            let (rf, gf, bf) = (*r as f32 / 255.0, *g as f32 / 255.0, *b as f32 / 255.0);
            let low = rf.min(gf.min(bf));
            let high = rf.max(gf.max(bf));
            let delta = high - low - 0.1;

            let t = sp.t28;
            let fac = 0.8
                + 0.9
                    * fast_sin(
                        11.0 * ux + 4.32 * uy + t * 12.0 + fast_cos(t * 5.3 + uy * 4.2 - ux * 4.0),
                    );
            let fac2 =
                0.5 + 0.5 * fast_sin(8.0 * ux + 2.32 * uy + t * 5.0 - fast_cos(t * 2.3 + ux * 8.2));
            let fac3 = 0.5
                + 0.5 * fast_sin(10.0 * ux + 5.32 * uy + t * 6.111 + fast_sin(t * 5.3 + uy * 3.2));
            let fac4 = 0.5
                + 0.5 * fast_sin(3.0 * ux + 2.32 * uy + t * 8.111 + fast_sin(t * 1.3 + uy * 11.2));
            let fac5 = fast_sin(
                0.9 * 16.0 * ux + 5.32 * uy + t * 12.0 + fast_cos(t * 5.3 + uy * 4.2 - ux * 4.0),
            );

            let maxfac =
                (0.7 * (fac.max(fac2.max(fac3.max(0.0))) + (fac + fac2 + fac3 * fac4))).max(0.0);

            // Base: darken original, add blue-ish tint
            let base_r = rf * 0.5 + 0.4;
            let base_g = gf * 0.5 + 0.4;
            let base_b = bf * 0.5 + 0.8;

            let ro = (base_r - delta + delta * maxfac * (0.7 + fac5 * 0.27) - 0.1).clamp(0.0, 1.0);
            let go = (base_g - delta + delta * maxfac * (0.7 - fac5 * 0.27) - 0.1).clamp(0.0, 1.0);
            let bo = (base_b - delta + delta * maxfac * 0.7 - 0.1).clamp(0.0, 1.0);
            *r = (ro * 255.0) as u8;
            *g = (go * 255.0) as u8;
            *b = (bo * 255.0) as u8;

            // Alpha: complex formula from GLSL
            let alpha_fac = 0.5
                * (1.0_f32.min(
                    (0.3 * (low * 0.2).max(delta) + (maxfac * 0.1).max(0.0).min(0.4)).max(0.0),
                ))
                .max(0.0)
                + 0.15 * maxfac * (0.1 + delta);
            *a = ((*a as f32) * alpha_fac).clamp(0.0, 255.0) as u8;
        }
        7 | 8 => {
            // Voucher/Booster: animated sine wave shimmer with blue tint
            // From voucher.fs/booster.fs: 5-component sine patterns (same structure as negative_shine)
            let (rf, gf, bf) = (*r as f32 / 255.0, *g as f32 / 255.0, *b as f32 / 255.0);
            let low = rf.min(gf.min(bf));
            let high = rf.max(gf.max(bf));
            let delta = if effect == 8 {
                // Booster uses: max(high-low, low*0.7)
                (high - low).max(low * 0.7)
            } else {
                high - low
            };

            let t = sp.t28;
            let fac = 0.8
                + 0.9
                    * fast_sin(
                        13.0 * ux + 5.32 * uy + t * 12.0 + fast_cos(t * 5.3 + uy * 4.2 - ux * 4.0),
                    );
            let fac2 = 0.5
                + 0.5 * fast_sin(10.0 * ux + 2.32 * uy + t * 5.0 - fast_cos(t * 2.3 + ux * 8.2));
            let fac3 = 0.5
                + 0.5 * fast_sin(12.0 * ux + 6.32 * uy + t * 6.111 + fast_sin(t * 5.3 + uy * 3.2));
            let fac4 = 0.5
                + 0.5 * fast_sin(4.0 * ux + 2.32 * uy + t * 8.111 + fast_sin(t * 1.3 + uy * 13.2));
            let fac5 = fast_sin(
                0.5 * 16.0 * ux + 5.32 * uy + t * 12.0 + fast_cos(t * 5.3 + uy * 4.2 - ux * 4.0),
            );

            let maxfac =
                (0.6 * (fac.max(fac2.max(fac3.max(0.0))) + (fac + fac2 + fac3 * fac4))).max(0.0);

            // Blue base tint: rgb * 0.5 + (0.4, 0.4, 0.8)
            let base_r = rf * 0.5 + 0.4;
            let base_g = gf * 0.5 + 0.4;
            let base_b = bf * 0.5 + 0.8;

            let ro = (base_r - delta + delta * maxfac * (0.7 + fac5 * 0.07) - 0.1).clamp(0.0, 1.0);
            let go = (base_g - delta + delta * maxfac * (0.7 - fac5 * 0.17) - 0.1).clamp(0.0, 1.0);
            let bo = (base_b - delta + delta * maxfac * 0.7 - 0.1).clamp(0.0, 1.0);
            *r = (ro * 255.0) as u8;
            *g = (go * 255.0) as u8;
            *b = (bo * 255.0) as u8;

            let alpha_fac = 0.8
                * (1.0_f32.min(
                    (0.3 * (low * 0.2).max(delta) + (maxfac * 0.1).max(0.0).min(0.4)).max(0.0),
                ))
                .max(0.0)
                + 0.15 * maxfac * (0.1 + delta);
            *a = ((*a as f32) * alpha_fac).clamp(0.0, 255.0) as u8;
        }
        9 => {
            // Hologram: card interior transparent, edges glow with animated cyan light.
            // GLSL hologram.fs: fully opaque pixels → invisible (alpha→0);
            //   semi-transparent edge pixels keep their alpha with cyan-green glow.
            // The draw color in graphics.rs already shifts the image toward cyan-blue
            // (tint ≈ [77, 200, 240, 180/255*original_a]), so *g and *b are already cyan.
            //
            // After the cyan tint, interior pixels have fa ≈ 180 (sa=255 * 180/255).
            // Edge pixels (anti-aliased border) have fa ≈ 70-140 (sa=100-200 * 180/255).
            // Background pixels have fa = 0 (skipped before reaching shader).
            if *a > 165 {
                // Card interior: make fully transparent (hologram ghost effect)
                *a = 0;
            } else if *a > 8 {
                // Card edges/outline: animate with pulsing cyan-green light
                // light_strength from GLSL: 0.4*(0.3*sin(2*holo_g) + 0.6 + 0.3*sin(holo_r*3) + 0.9)
                let light = (0.4 * (0.3 * sp.holo9_sin_g + 0.6 + 0.3 * sp.holo9_sin_r + 0.9))
                    .clamp(0.4_f32, 1.0_f32);
                // Zero red channel, boost green-blue for pure cyan glow
                *r = 0;
                *g = ((*g as f32) * light * 1.3).min(255.0) as u8;
                *b = ((*b as f32) * light).min(255.0) as u8;
                // Keep alpha: don't reduce it further (edges should remain visible)
            }
            // a <= 8: fully transparent background — leave as-is
        }
        11 => {
            // Gold seal: animated golden shine sweep
            // From gold_seal.fs: sine-wave based highlight that sweeps across
            let (rf, gf, bf) = (*r as f32 / 255.0, *g as f32 / 255.0, *b as f32 / 255.0);
            let high = rf.max(gf.max(bf));
            let delta = high * 0.5;

            let t = sp.gs_t;
            let fac = 0.3 + fast_sin(ux * 450.0 + sp.gs_sin6t * 180.0 - 700.0 * t)
                - fast_sin(ux * 190.0 + uy * 30.0 + 1080.3 * t);

            let ro = rf.max((1.0 - rf) * delta * fac + rf);
            let go = gf.max((1.0 - gf) * delta * fac + gf);
            let bo = bf.max((1.0 - bf) * delta * fac + bf);
            *r = (ro.clamp(0.0, 1.0) * 255.0) as u8;
            *g = (go.clamp(0.0, 1.0) * 255.0) as u8;
            *b = (bo.clamp(0.0, 1.0) * 255.0) as u8;
        }
        _ => {}
    }
}

/// Parameters for the dissolve shader emulation.
#[derive(Clone, Copy)]
pub struct DissolveParams {
    /// Dissolve amount: 0.0 = fully visible, 0.6+ = fully invisible
    pub dissolve: f32,
    /// Inner burn edge color [r,g,b,a] (0..255)
    pub burn1: [u8; 4],
    /// Outer burn edge color [r,g,b,a] (0..255)
    pub burn2: [u8; 4],
    /// Card shader effect: 0=none, 1=played, 2=debuff, 3=foil, 4=holo, 5=polychrome, 6=negative, 7=voucher, 8=booster, 9=hologram, 10=negative_shine, 11=gold_seal
    pub shader_effect: u8,
    /// Time value for animated shader effects and dissolve noise field
    pub shader_time: f32,
    /// Sprite pixel dimensions for dissolve noise field (from texture_details.ba)
    pub sprite_w: f32,
    pub sprite_h: f32,
}

impl DissolveParams {
    pub const NONE: Self = Self {
        dissolve: 0.0,
        burn1: [0, 0, 0, 0],
        burn2: [0, 0, 0, 0],
        shader_effect: 0,
        shader_time: 0.0,
        sprite_w: 71.0,
        sprite_h: 95.0,
    };
}

/// GLSL-matching dissolve noise field from dissolve_mask() in Balatro's shaders.
/// Returns `res` value; pixel is visible when `res > adjusted_dissolve`.
#[inline(always)]
fn dissolve_field(
    ux: f32,
    uy: f32,
    time: f32,
    dissolve: f32,
    adjusted_dissolve: f32,
    sprite_w: f32,
    sprite_h: f32,
) -> f32 {
    let max_dim = sprite_w.max(sprite_h);
    let floored_x = (ux * sprite_w).floor() / max_dim;
    let floored_y = (uy * sprite_h).floor() / max_dim;
    let usc_x = (floored_x - 0.5) * 2.3 * max_dim;
    let usc_y = (floored_y - 0.5) * 2.3 * max_dim;

    let t = time * 10.0 + 2003.0;
    let f1x = usc_x + 50.0 * fast_sin(-t / 143.634);
    let f1y = usc_y + 50.0 * fast_cos(-t / 99.4324);
    let f2x = usc_x + 50.0 * fast_cos(t / 53.1532);
    let f2y = usc_y + 50.0 * fast_cos(t / 61.4532);
    let f3x = usc_x + 50.0 * fast_sin(-t / 87.53218);
    let f3y = usc_y + 50.0 * fast_sin(-t / 49.0);

    let len1 = (f1x * f1x + f1y * f1y).sqrt();
    let len2 = (f2x * f2x + f2y * f2y).sqrt();
    let len3 = (f3x * f3x + f3y * f3y).sqrt();

    let field = (1.0
        + fast_cos(len1 / 19.483)
        + fast_sin(len2 / 33.155) * fast_cos(f2y / 15.73)
        + fast_cos(len3 / 27.193) * fast_sin(f3x / 21.92))
        / 2.0;

    let d = dissolve;
    0.5 + 0.5 * fast_cos(adjusted_dissolve / 82.612 + (field - 0.5) * std::f32::consts::PI)
        - if floored_x > 0.8 {
            (floored_x - 0.8) * (5.0 + 5.0 * d) * d
        } else {
            0.0
        }
        - if floored_y > 0.8 {
            (floored_y - 0.8) * (5.0 + 5.0 * d) * d
        } else {
            0.0
        }
        - if floored_x < 0.2 {
            (0.2 - floored_x) * (5.0 + 5.0 * d) * d
        } else {
            0.0
        }
        - if floored_y < 0.2 {
            (0.2 - floored_y) * (5.0 + 5.0 * d) * d
        } else {
            0.0
        }
}

/// Stencil compare mode for `setStencilTest(compare, value)`.
#[derive(Clone, Copy, PartialEq)]
pub enum StencilCompare {
    Disabled,
    Greater,  // pixel drawn only where stencil > value
    GEqual,   // pixel drawn only where stencil >= value
    Equal,    // pixel drawn only where stencil == value
    LEqual,   // pixel drawn only where stencil <= value
    Less,     // pixel drawn only where stencil < value
    NotEqual, // pixel drawn only where stencil != value
    Always,   // always draw (ignore stencil)
    Never,    // never draw
}

/// RGBA pixel buffer — virtual framebuffer for LÖVE's coordinate space.
/// Pixels are stored row-major: index = (y * width + x) * 4
pub struct PixelBuffer {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>, // RGBA, 4 bytes per pixel
    /// Optional scissor rectangle (x, y, w, h) for clipping
    pub scissor: Option<(i32, i32, u32, u32)>,
    /// Stencil buffer — one byte per pixel, same w*h as pixels
    pub stencil: Vec<u8>,
    /// When true, drawing operations write to stencil instead of pixels
    pub stencil_write_mode: bool,
    /// Stencil compare function + reference value
    pub stencil_compare: StencilCompare,
    pub stencil_ref: u8,
    /// Blend mode: 0=alpha (default), 1=replace, 2=add, 3=multiply, 4=premultiplied
    pub blend: u8,
    /// Filter mode: false=nearest (default), true=linear (bilinear interpolation)
    pub filter_linear: bool,
    // Reusable CRT bloom buffers (avoid per-frame allocation)
    crt_bright: Vec<u16>,
    crt_temp: Vec<u16>,
    crt_col_bloom: Vec<(usize, usize, u32)>,
}

impl PixelBuffer {
    pub fn new(width: u32, height: u32) -> Self {
        PixelBuffer {
            width,
            height,
            pixels: vec![0u8; (width * height * 4) as usize],
            scissor: None,
            stencil: vec![0u8; (width * height) as usize],
            stencil_write_mode: false,
            stencil_compare: StencilCompare::Disabled,
            stencil_ref: 0,
            blend: 0,
            filter_linear: false,
            crt_bright: Vec::new(),
            crt_temp: Vec::new(),
            crt_col_bloom: Vec::new(),
        }
    }

    /// Resize the buffer to new dimensions, clearing all pixels.
    pub fn resize(&mut self, width: u32, height: u32) {
        self.width = width;
        self.height = height;
        let size = (width * height) as usize;
        self.pixels.resize(size * 4, 0);
        self.pixels.fill(0);
        self.stencil.resize(size, 0);
        self.stencil.fill(0);
        self.scissor = None;
    }

    /// Clear stencil buffer to zero.
    pub fn clear_stencil(&mut self) {
        for v in self.stencil.iter_mut() {
            *v = 0;
        }
    }

    /// Test stencil at pixel position. Returns true if drawing is allowed.
    #[inline(always)]
    fn stencil_test(&self, x: u32, y: u32) -> bool {
        match self.stencil_compare {
            StencilCompare::Disabled | StencilCompare::Always => true,
            StencilCompare::Never => false,
            _ => {
                let si = (y * self.width + x) as usize;
                let sv = if si < self.stencil.len() {
                    self.stencil[si]
                } else {
                    0
                };
                let rv = self.stencil_ref;
                match self.stencil_compare {
                    StencilCompare::Greater => sv > rv,
                    StencilCompare::GEqual => sv >= rv,
                    StencilCompare::Equal => sv == rv,
                    StencilCompare::LEqual => sv <= rv,
                    StencilCompare::Less => sv < rv,
                    StencilCompare::NotEqual => sv != rv,
                    _ => true,
                }
            }
        }
    }

    /// Write to stencil buffer at pixel position (increment by 1, capped at 255).
    #[inline(always)]
    fn stencil_write(&mut self, x: u32, y: u32) {
        let si = (y * self.width + x) as usize;
        if si < self.stencil.len() {
            self.stencil[si] = self.stencil[si].saturating_add(1);
        }
    }

    pub fn clear(&mut self, r: f32, g: f32, b: f32, a: f32) {
        let ri = (r.clamp(0.0, 1.0) * 255.0) as u8;
        let gi = (g.clamp(0.0, 1.0) * 255.0) as u8;
        let bi = (b.clamp(0.0, 1.0) * 255.0) as u8;
        let ai = (a.clamp(0.0, 1.0) * 255.0) as u8;
        let total = self.pixels.len();
        if total < 4 {
            return;
        }
        // Seed first pixel
        self.pixels[0] = ri;
        self.pixels[1] = gi;
        self.pixels[2] = bi;
        self.pixels[3] = ai;
        // Doubling copy: fill 4, 8, 16, ... bytes at a time
        let mut filled = 4;
        while filled < total {
            let copy_len = filled.min(total - filled);
            self.pixels.copy_within(0..copy_len, filled);
            filled += copy_len;
        }
    }

    /// Compute clipping bounds as (x0, y0, x1, y1) — intersection of buffer and scissor.
    #[inline]
    fn clip_bounds(&self) -> (i32, i32, i32, i32) {
        if let Some((sx, sy, sw, sh)) = self.scissor {
            (
                sx.max(0),
                sy.max(0),
                (sx + sw as i32).min(self.width as i32),
                (sy + sh as i32).min(self.height as i32),
            )
        } else {
            (0, 0, self.width as i32, self.height as i32)
        }
    }

    /// Blend a pixel at a known-valid index, dispatching by active blend mode.
    /// Modes: 0=alpha (source-over), 1=replace, 2=add, 3=multiply, 4=premultiplied, 5=screen
    #[inline(always)]
    pub fn blend_at(&mut self, idx: usize, r: u8, g: u8, b: u8, a: u8) {
        match self.blend {
            2 => self.blend_add_at(idx, r, g, b, a),
            3 => self.blend_multiply_at(idx, r, g, b, a),
            4 => self.blend_premultiplied_at(idx, r, g, b, a),
            5 => self.blend_screen_at(idx, r, g, b, a),
            _ => {
                // Default: source-over alpha compositing
                if a == 255 {
                    self.pixels[idx] = r;
                    self.pixels[idx + 1] = g;
                    self.pixels[idx + 2] = b;
                    self.pixels[idx + 3] = 255;
                } else if a > 0 {
                    let sa = a as u16;
                    let da = self.pixels[idx + 3] as u16;
                    let inv_sa = 255 - sa;
                    let out_a = sa + (da * inv_sa / 255);
                    self.pixels[idx] =
                        ((r as u16 * sa + self.pixels[idx] as u16 * inv_sa) / 255) as u8;
                    self.pixels[idx + 1] =
                        ((g as u16 * sa + self.pixels[idx + 1] as u16 * inv_sa) / 255) as u8;
                    self.pixels[idx + 2] =
                        ((b as u16 * sa + self.pixels[idx + 2] as u16 * inv_sa) / 255) as u8;
                    self.pixels[idx + 3] = out_a.min(255) as u8;
                }
            }
        }
    }

    /// Additive blend: dst += src * alpha (clamped at 255).
    #[inline(always)]
    fn blend_add_at(&mut self, idx: usize, r: u8, g: u8, b: u8, a: u8) {
        if a == 0 {
            return;
        }
        let sa = a as u16;
        self.pixels[idx] = (self.pixels[idx] as u16 + r as u16 * sa / 255).min(255) as u8;
        self.pixels[idx + 1] = (self.pixels[idx + 1] as u16 + g as u16 * sa / 255).min(255) as u8;
        self.pixels[idx + 2] = (self.pixels[idx + 2] as u16 + b as u16 * sa / 255).min(255) as u8;
        // Alpha: keep existing or saturate
        self.pixels[idx + 3] = (self.pixels[idx + 3] as u16 + sa).min(255) as u8;
    }

    /// Multiply blend: dst *= src (component-wise, src alpha-premultiplied).
    #[inline(always)]
    fn blend_multiply_at(&mut self, idx: usize, r: u8, g: u8, b: u8, a: u8) {
        if a == 0 {
            return;
        }
        let sa = a as u16;
        let inv_sa = 255 - sa;
        // multiply = dst * src * alpha + dst * (1 - alpha)
        self.pixels[idx] = (self.pixels[idx] as u16 * r as u16 * sa / 65025
            + self.pixels[idx] as u16 * inv_sa / 255)
            .min(255) as u8;
        self.pixels[idx + 1] = (self.pixels[idx + 1] as u16 * g as u16 * sa / 65025
            + self.pixels[idx + 1] as u16 * inv_sa / 255)
            .min(255) as u8;
        self.pixels[idx + 2] = (self.pixels[idx + 2] as u16 * b as u16 * sa / 65025
            + self.pixels[idx + 2] as u16 * inv_sa / 255)
            .min(255) as u8;
    }

    /// Premultiplied alpha blend: source RGB already multiplied by alpha.
    /// Formula: dst = src + dst * (1 - src_a)
    #[inline(always)]
    fn blend_premultiplied_at(&mut self, idx: usize, r: u8, g: u8, b: u8, a: u8) {
        if a == 255 {
            self.pixels[idx] = r;
            self.pixels[idx + 1] = g;
            self.pixels[idx + 2] = b;
            self.pixels[idx + 3] = 255;
        } else if a > 0 {
            let inv_sa = (255 - a) as u16;
            self.pixels[idx] = (r as u16 + self.pixels[idx] as u16 * inv_sa / 255).min(255) as u8;
            self.pixels[idx + 1] =
                (g as u16 + self.pixels[idx + 1] as u16 * inv_sa / 255).min(255) as u8;
            self.pixels[idx + 2] =
                (b as u16 + self.pixels[idx + 2] as u16 * inv_sa / 255).min(255) as u8;
            self.pixels[idx + 3] =
                (a as u16 + self.pixels[idx + 3] as u16 * inv_sa / 255).min(255) as u8;
        }
    }

    /// Screen blend: result = src + dst - src * dst (lightens image).
    /// With alpha: lerp between dst and screen(dst, src) by alpha.
    #[inline(always)]
    fn blend_screen_at(&mut self, idx: usize, r: u8, g: u8, b: u8, a: u8) {
        if a == 0 {
            return;
        }
        let sa = a as u16;
        let inv_sa = 255 - sa;
        // screen(s,d) = s + d - s*d/255
        // final = screen * alpha + dst * (1-alpha)
        let dr = self.pixels[idx] as u16;
        let dg = self.pixels[idx + 1] as u16;
        let db = self.pixels[idx + 2] as u16;
        let sr = r as u16 + dr - (r as u16 * dr / 255);
        let sg = g as u16 + dg - (g as u16 * dg / 255);
        let sb = b as u16 + db - (b as u16 * db / 255);
        self.pixels[idx] = ((sr * sa + dr * inv_sa) / 255).min(255) as u8;
        self.pixels[idx + 1] = ((sg * sa + dg * inv_sa) / 255).min(255) as u8;
        self.pixels[idx + 2] = ((sb * sa + db * inv_sa) / 255).min(255) as u8;
    }

    /// Write a pixel directly without blending (replace mode).
    #[inline(always)]
    pub fn write_at(&mut self, idx: usize, r: u8, g: u8, b: u8, a: u8) {
        self.pixels[idx] = r;
        self.pixels[idx + 1] = g;
        self.pixels[idx + 2] = b;
        self.pixels[idx + 3] = a;
    }

    #[inline(always)]
    pub fn set_pixel(&mut self, x: u32, y: u32, r: u8, g: u8, b: u8, a: u8) {
        if x >= self.width || y >= self.height {
            return;
        }
        if let Some((sx, sy, sw, sh)) = self.scissor {
            let xi = x as i32;
            let yi = y as i32;
            if xi < sx || xi >= sx + sw as i32 || yi < sy || yi >= sy + sh as i32 {
                return;
            }
        }
        // Stencil write mode: write to stencil buffer instead of pixels
        if self.stencil_write_mode {
            self.stencil_write(x, y);
            return;
        }
        // Stencil test: skip pixel if stencil test fails
        if self.stencil_compare != StencilCompare::Disabled && !self.stencil_test(x, y) {
            return;
        }
        let idx = ((y * self.width + x) * 4) as usize;
        self.blend_at(idx, r, g, b, a);
    }

    /// Write a pixel directly without blending (for replace blend mode)
    #[inline(always)]
    pub fn set_pixel_replace(&mut self, x: u32, y: u32, r: u8, g: u8, b: u8, a: u8) {
        if x >= self.width || y >= self.height {
            return;
        }
        if let Some((sx, sy, sw, sh)) = self.scissor {
            let xi = x as i32;
            let yi = y as i32;
            if xi < sx || xi >= sx + sw as i32 || yi < sy || yi >= sy + sh as i32 {
                return;
            }
        }
        if self.stencil_write_mode {
            self.stencil_write(x, y);
            return;
        }
        if self.stencil_compare != StencilCompare::Disabled && !self.stencil_test(x, y) {
            return;
        }
        let idx = ((y * self.width + x) * 4) as usize;
        self.write_at(idx, r, g, b, a);
    }

    /// Draw a filled axis-aligned rectangle
    pub fn fill_rect(&mut self, x: i32, y: i32, w: i32, h: i32, color: [u8; 4]) {
        let (clip_x0, clip_y0, clip_x1, clip_y1) = self.clip_bounds();
        let x0 = x.max(clip_x0);
        let y0 = y.max(clip_y0);
        let x1 = (x + w).min(clip_x1);
        let y1 = (y + h).min(clip_y1);
        if x0 >= x1 || y0 >= y1 {
            return;
        }
        let x0 = x0 as u32;
        let y0 = y0 as u32;
        let x1 = x1 as u32;
        let y1 = y1 as u32;
        let row_width = (x1 - x0) as usize;

        // Stencil write mode: mark stencil buffer instead of drawing pixels
        if self.stencil_write_mode {
            for py in y0..y1 {
                for px in x0..x1 {
                    self.stencil_write(px, py);
                }
            }
            return;
        }

        let use_stencil = self.stencil_compare != StencilCompare::Disabled;

        if color[3] == 255 && !use_stencil && self.blend == 0 {
            // Fast path: opaque fill with row memcpy (only when alpha blend, no stencil)
            let first_row_start = (y0 * self.width + x0) as usize * 4;
            for i in 0..row_width {
                let idx = first_row_start + i * 4;
                self.pixels[idx] = color[0];
                self.pixels[idx + 1] = color[1];
                self.pixels[idx + 2] = color[2];
                self.pixels[idx + 3] = 255;
            }
            let row_bytes = row_width * 4;
            for py in (y0 + 1)..y1 {
                let dst_start = (py * self.width + x0) as usize * 4;
                self.pixels
                    .copy_within(first_row_start..first_row_start + row_bytes, dst_start);
            }
        } else {
            // Per-pixel path (alpha blending and/or stencil test)
            let buf_w = self.width;
            for py in y0..y1 {
                let row_base = (py * buf_w + x0) as usize * 4;
                for i in 0..row_width {
                    if use_stencil && !self.stencil_test(x0 + i as u32, py) {
                        continue;
                    }
                    self.blend_at(row_base + i * 4, color[0], color[1], color[2], color[3]);
                }
            }
        }
    }

    /// Draw a stroked axis-aligned rectangle
    pub fn stroke_rect(&mut self, x: i32, y: i32, w: i32, h: i32, line_width: u32, color: [u8; 4]) {
        let lw = line_width as i32;
        // Top edge
        self.fill_rect(x, y, w, lw, color);
        // Bottom edge
        self.fill_rect(x, y + h - lw, w, lw, color);
        // Left edge
        self.fill_rect(x, y + lw, lw, h - lw * 2, color);
        // Right edge
        self.fill_rect(x + w - lw, y + lw, lw, h - lw * 2, color);
    }

    /// Fill with a 2D vignette background, darkening toward all edges.
    /// Uses horizontal bands: first row per band has per-pixel horizontal gradient,
    /// then copy_within duplicates it — fast 2D vignette at ~same cost as 1D.
    /// `colours`: [[r,g,b,a]; 3] as f32 (0.0-1.0) — [centre, light, dark]
    /// Procedural background emulating Balatro's background.fs shader.
    /// Implements pixelation, UV swirl, and iterative paint distortion.
    /// bg_params: [time, spin_time, spin_amount, contrast]
    pub fn fill_procedural_background(
        &mut self,
        _x: i32,
        _y: i32,
        _w: i32,
        _h: i32,
        colours: &[[f32; 4]; 3],
        bg_params: [f32; 4],
    ) {
        let bw = self.width as usize;
        let bh = self.height as usize;
        if bw == 0 || bh == 0 {
            return;
        }

        let time = bg_params[0];
        let spin_time = bg_params[1];
        let spin_amount = bg_params[2];
        let contrast = bg_params[3];

        let c1 = colours[0]; // centre color
        let c2 = colours[1]; // light accent
        let c3 = colours[2]; // dark accent

        let screen_len = ((bw * bw + bh * bh) as f32).sqrt();
        let pixel_size = screen_len / 700.0;
        let inv_pixel = 1.0 / pixel_size;

        let half_w = bw as f32 * 0.5;
        let half_h = bh as f32 * 0.5;
        let _mid_x = (bw as f32 / screen_len) * 0.5;
        let _mid_y = (bh as f32 / screen_len) * 0.5;
        let inv_screen_len = 1.0 / screen_len;

        let spin_speed = spin_time * 0.5 * 0.2 + 302.2;
        let paint_speed = time * 2.0;
        let contrast_mod = 0.25 * contrast + 0.5 * spin_amount + 1.2;

        // Compute on a coarse grid, then nearest-neighbor fill.
        // Grid density adapts to canvas size: at 800x600 use 60x45 (block ~13px),
        // at smaller sizes use more grid points per pixel to avoid blocky artifacts.
        // Target: each grid cell ≈ 8-10 pixels wide (matching shader's PIXEL_SIZE_FAC).
        let gw = (bw / 8).max(30).min(120);
        let gh = (bh / 8).max(20).min(90);
        let row_bytes = bw * 4;

        // Compute paint value at each grid point → (r, g, b)
        let mut grid = vec![(0u8, 0u8, 0u8); (gw + 1) * (gh + 1)];
        for gy in 0..=gh {
            for gx in 0..=gw {
                let px_f = (gx as f32 / gw as f32) * bw as f32;
                let py_f = (gy as f32 / gh as f32) * bh as f32;

                // Pixelation
                let sx = (px_f * inv_pixel).floor() * pixel_size;
                let sy = (py_f * inv_pixel).floor() * pixel_size;
                let mut ux = (sx - half_w) * inv_screen_len - 0.12;
                let mut uy = (sy - half_h) * inv_screen_len;
                let uv_len = (ux * ux + uy * uy).sqrt();

                // Swirl
                let new_angle = uy.atan2(ux) + spin_speed
                    - 0.5 * 20.0 * (spin_amount * uv_len + (1.0 - spin_amount));
                ux = uv_len * fast_cos(new_angle);
                uy = uv_len * fast_sin(new_angle);

                // Paint distortion
                ux *= 30.0;
                uy *= 30.0;
                let mut uv2x = ux + uy;
                let mut uv2y = ux + uy;
                for _ in 0..5 {
                    let mx = if ux > uy { ux } else { uy };
                    let smx = fast_sin(mx);
                    uv2x += smx + ux;
                    uv2y += smx + uy;
                    ux += 0.5 * fast_cos(5.1123314 + 0.353 * uv2y + paint_speed * 0.131121);
                    uy += 0.5 * fast_sin(uv2x - 0.113 * paint_speed);
                    let cxy = fast_cos(ux + uy);
                    let sxy = fast_sin(ux * 0.711 - uy);
                    ux -= cxy - sxy;
                    uy -= cxy - sxy;
                }

                // paint_res: 0..2 range from UV distortion magnitude
                let paint_res = ((ux * ux + uy * uy).sqrt() * 0.035 * contrast_mod)
                    .max(0.0)
                    .min(2.0);
                // c1p peaks when paint_res ≈ 1, c2p peaks when paint_res ≈ 0
                let c1p = (1.0 - contrast_mod * (1.0 - paint_res).abs()).max(0.0);
                let c2p = (1.0 - contrast_mod * paint_res.abs()).max(0.0);
                let c3p = (1.0 - (c1p + c2p).min(1.0)).max(0.0);

                // Final: base tint + weighted color mix
                let base_w = (0.3 / contrast).min(1.0);
                let mix_w = 1.0 - base_w;
                let r = base_w * c1[0] + mix_w * (c1[0] * c1p + c2[0] * c2p + c3[0] * c3p);
                let g = base_w * c1[1] + mix_w * (c1[1] * c1p + c2[1] * c2p + c3[1] * c3p);
                let b = base_w * c1[2] + mix_w * (c1[2] * c1p + c2[2] * c2p + c3[2] * c3p);

                grid[gy * (gw + 1) + gx] = (
                    (r * 255.0).max(0.0).min(255.0) as u8,
                    (g * 255.0).max(0.0).min(255.0) as u8,
                    (b * 255.0).max(0.0).min(255.0) as u8,
                );
            }
        }

        // Fill pixels: bilinear interpolation from grid for smooth transitions
        let inv_gw = gw as f32 / bw as f32;
        let inv_gh = gh as f32 / bh as f32;

        for py in 0..bh {
            let fy = py as f32 * inv_gh;
            let gy0 = (fy as usize).min(gh - 1);
            let gy1 = (gy0 + 1).min(gh);
            let ty = fy - gy0 as f32; // fractional part [0..1)
            let ity = 1.0 - ty;
            let row_base = py * row_bytes;
            let grid_row0 = gy0 * (gw + 1);
            let grid_row1 = gy1 * (gw + 1);

            for px in 0..bw {
                let fx = px as f32 * inv_gw;
                let gx0 = (fx as usize).min(gw - 1);
                let gx1 = (gx0 + 1).min(gw);
                let tx = fx - gx0 as f32;
                let itx = 1.0 - tx;

                // Bilinear: weighted average of 4 surrounding grid points
                let c00 = grid[grid_row0 + gx0];
                let c10 = grid[grid_row0 + gx1];
                let c01 = grid[grid_row1 + gx0];
                let c11 = grid[grid_row1 + gx1];

                let w00 = itx * ity;
                let w10 = tx * ity;
                let w01 = itx * ty;
                let w11 = tx * ty;

                let i = row_base + px * 4;
                self.pixels[i] = (c00.0 as f32 * w00
                    + c10.0 as f32 * w10
                    + c01.0 as f32 * w01
                    + c11.0 as f32 * w11) as u8;
                self.pixels[i + 1] = (c00.1 as f32 * w00
                    + c10.1 as f32 * w10
                    + c01.1 as f32 * w01
                    + c11.1 as f32 * w11) as u8;
                self.pixels[i + 2] = (c00.2 as f32 * w00
                    + c10.2 as f32 * w10
                    + c01.2 as f32 * w01
                    + c11.2 as f32 * w11) as u8;
                self.pixels[i + 3] = 255;
            }
        }
    }

    /// Draw a sub-region of an RGBA source image onto this buffer.
    /// Fully inlined — no per-pixel function calls, bounds pre-computed.
    /// When `replace` is true, pixels are written directly without alpha blending.
    /// When `dissolve` > 0, pixels are randomly discarded based on per-pixel noise
    /// to emulate the dissolve shader effect.
    pub fn draw_image_region(
        &mut self,
        src_pixels: &[u8],
        src_w: u32,
        _src_h: u32,
        src_x: f32,
        src_y: f32,
        src_rw: f32,
        src_rh: f32,
        dst_x: f32,
        dst_y: f32,
        sx: f32,
        sy: f32,
        tint: [u8; 4],
        replace: bool,
        dp: DissolveParams,
    ) {
        let abs_sx = sx.abs();
        let abs_sy = sy.abs();
        let dst_w = (src_rw * abs_sx).ceil() as i32;
        let dst_h = (src_rh * abs_sy).ceil() as i32;
        if dst_w <= 0 || dst_h <= 0 {
            return;
        }
        // When scale is negative, the drawing origin shifts
        let dx0 = if sx < 0.0 {
            (dst_x - dst_w as f32) as i32
        } else {
            dst_x as i32
        };
        let dy0 = if sy < 0.0 {
            (dst_y - dst_h as f32) as i32
        } else {
            dst_y as i32
        };

        // Pre-compute clip bounds (buffer intersected with scissor)
        let (clip_x0, clip_y0, clip_x1, clip_y1) = self.clip_bounds();
        let x_start = (clip_x0 - dx0).max(0);
        let y_start = (clip_y0 - dy0).max(0);
        let x_end = dst_w.min(clip_x1 - dx0);
        let y_end = dst_h.min(clip_y1 - dy0);
        if x_start >= x_end || y_start >= y_end {
            return;
        }

        let inv_sx = 1.0 / abs_sx;
        let inv_sy = 1.0 / abs_sy;
        let flip_x = sx < 0.0;
        let flip_y = sy < 0.0;
        let white_tint = tint == [255, 255, 255, 255];
        let buf_w = self.width;
        let src_len = src_pixels.len();
        let src_rw_minus1 = src_rw - 1.0;
        let src_rh_minus1 = src_rh - 1.0;
        // GLSL-matching dissolve: smooth-step + noise field
        let dissolve_active = dp.dissolve > 0.01;
        let d_raw = dp.dissolve;
        let adjusted_dissolve = if dissolve_active {
            let d = d_raw;
            (d * d * (3.0 - 2.0 * d)) * 1.02 - 0.01
        } else {
            0.0
        };
        let has_burn = dissolve_active && (dp.burn1[3] > 0 || dp.burn2[3] > 0);
        // GLSL burn width: 0.8*(0.5 - |adjusted_dissolve - 0.5|) for outer, 0.5*(...) for inner
        let half_minus = if has_burn {
            (0.5 - (adjusted_dissolve - 0.5).abs()).max(0.0)
        } else {
            0.0
        };
        let burn_outer = 0.8 * half_minus;
        let burn_inner = 0.5 * half_minus;

        // Filtering mode selection:
        // - Box filter (area average) when downscaling >2x — averages all source texels
        //   that map to each destination pixel for correct minification
        // - Bilinear when filter_linear + scale != 1:1 but ratio <= 2x
        // - Nearest otherwise
        // Threshold 2.0: at our ~360px canvas, Balatro draws sprites at ~3.5x smaller scale,
        // so bilinear at >2x would skip >50% of source pixels causing visible aliasing.
        let non_identity = abs_sx < 0.99 || abs_sx > 1.01 || abs_sy < 0.99 || abs_sy > 1.01;
        let use_box = self.filter_linear
            && non_identity
            && (inv_sx > 2.0 || inv_sy > 2.0)
            && (x_end - x_start > 3 && y_end - y_start > 3);
        let use_bilinear = self.filter_linear && non_identity && !use_box;
        let src_w_i = src_w as i32;
        // For box filter: source pixel span per dst pixel, capped at 4 samples per axis
        let box_w = if use_box { inv_sx.ceil() as u32 } else { 0 };
        let box_h = if use_box { inv_sy.ceil() as u32 } else { 0 };
        let box_step_x = if box_w > 4 { box_w / 4 } else { 1 };
        let box_step_y = if box_h > 4 { box_h / 4 } else { 1 };
        let src_rx_end = (src_x as u32 + src_rw as u32).min(src_w);
        let src_ry_end = src_y as u32 + src_rh as u32;

        // Precompute time-only shader values once per sprite (not per pixel)
        let shader_pre = if dp.shader_effect >= 1 {
            ShaderPre::compute(dp.shader_effect, dp.shader_time)
        } else {
            ShaderPre::compute(0, 0.0)
        };

        for py in y_start..y_end {
            let local_y = py as f32 * inv_sy;
            let fy = src_y
                + if flip_y {
                    src_rh_minus1 - local_y
                } else {
                    local_y
                };
            let src_row = fy as u32;
            let dst_row_base = ((dy0 + py) as u32 * buf_w) as usize * 4;
            let src_row_base = (src_row * src_w) as usize * 4;

            for px in x_start..x_end {
                let local_x = px as f32 * inv_sx;
                let fx = src_x
                    + if flip_x {
                        src_rw_minus1 - local_x
                    } else {
                        local_x
                    };
                let src_col = fx as u32;

                // Sample pixel (box filter, bilinear, or nearest)
                let (sr_raw, sg_raw, sb_raw, sa);
                if use_box {
                    // Box filter: alpha-weighted average to prevent dark fringing at sprite edges.
                    // For opaque pixels (alpha=255) this equals simple averaging.
                    // For sprites with transparency, color is weighted by alpha so that
                    // transparent border pixels don't muddy the sampled color.
                    let bx0 = (fx as u32).min(src_w - 1);
                    let by0 = (fy as u32).min(src_ry_end.saturating_sub(1));
                    if bx0 >= src_rx_end || by0 >= src_ry_end {
                        continue;
                    }
                    let bx1 = (bx0 + box_w).min(src_rx_end);
                    let by1 = (by0 + box_h).min(src_ry_end);
                    let mut ra_sum: u32 = 0; // R * alpha
                    let mut ga_sum: u32 = 0; // G * alpha
                    let mut ba_sum: u32 = 0; // B * alpha
                    let mut a_sum: u32 = 0;
                    let mut n: u32 = 0;
                    let mut sy_i = by0;
                    while sy_i < by1 {
                        let row_off = (sy_i * src_w) as usize * 4;
                        let mut sx_i = bx0;
                        while sx_i < bx1 {
                            let si = row_off + sx_i as usize * 4;
                            if si + 3 >= src_len {
                                break;
                            }
                            let a = src_pixels[si + 3] as u32;
                            ra_sum += src_pixels[si] as u32 * a;
                            ga_sum += src_pixels[si + 1] as u32 * a;
                            ba_sum += src_pixels[si + 2] as u32 * a;
                            a_sum += a;
                            n += 1;
                            sx_i += box_step_x;
                        }
                        sy_i += box_step_y;
                    }
                    if n == 0 {
                        continue;
                    }
                    sr_raw = if a_sum > 0 { (ra_sum / a_sum) as u8 } else { 0 };
                    sg_raw = if a_sum > 0 { (ga_sum / a_sum) as u8 } else { 0 };
                    sb_raw = if a_sum > 0 { (ba_sum / a_sum) as u8 } else { 0 };
                    sa = (a_sum / n) as u8;
                } else if use_bilinear {
                    // Bilinear: interpolate 4 surrounding pixels
                    let x0 = fx.floor() as i32;
                    let y0 = fy.floor() as i32;
                    let x1 = x0 + 1;
                    let y1 = y0 + 1;
                    let xf = ((fx - x0 as f32) * 256.0) as u32;
                    let yf = ((fy - y0 as f32) * 256.0) as u32;
                    let ixf = 256 - xf;
                    let iyf = 256 - yf;

                    // Fetch 4 texels (clamped to source bounds — clamp-to-edge)
                    let src_h_max = (src_len / (src_w as usize * 4)).saturating_sub(1) as i32;
                    let cx0 = x0.max(0).min(src_w_i - 1) as usize;
                    let cx1 = x1.max(0).min(src_w_i - 1) as usize;
                    let cy0 = y0.max(0).min(src_h_max) as u32;
                    let cy1 = y1.max(0).min(src_h_max) as u32;
                    let i00 = (cy0 * src_w) as usize * 4 + cx0 * 4;
                    let i10 = (cy0 * src_w) as usize * 4 + cx1 * 4;
                    let i01 = (cy1 * src_w) as usize * 4 + cx0 * 4;
                    let i11 = (cy1 * src_w) as usize * 4 + cx1 * 4;

                    if i11 + 3 >= src_len {
                        continue;
                    } // safety guard

                    let w00 = ixf * iyf;
                    let w10 = xf * iyf;
                    let w01 = ixf * yf;
                    let w11 = xf * yf;

                    sr_raw = ((src_pixels[i00] as u32 * w00
                        + src_pixels[i10] as u32 * w10
                        + src_pixels[i01] as u32 * w01
                        + src_pixels[i11] as u32 * w11)
                        >> 16) as u8;
                    sg_raw = ((src_pixels[i00 + 1] as u32 * w00
                        + src_pixels[i10 + 1] as u32 * w10
                        + src_pixels[i01 + 1] as u32 * w01
                        + src_pixels[i11 + 1] as u32 * w11)
                        >> 16) as u8;
                    sb_raw = ((src_pixels[i00 + 2] as u32 * w00
                        + src_pixels[i10 + 2] as u32 * w10
                        + src_pixels[i01 + 2] as u32 * w01
                        + src_pixels[i11 + 2] as u32 * w11)
                        >> 16) as u8;
                    sa = ((src_pixels[i00 + 3] as u32 * w00
                        + src_pixels[i10 + 3] as u32 * w10
                        + src_pixels[i01 + 3] as u32 * w01
                        + src_pixels[i11 + 3] as u32 * w11)
                        >> 16) as u8;
                } else {
                    let si = src_row_base + src_col as usize * 4;
                    if si + 3 >= src_len {
                        continue;
                    }
                    sr_raw = src_pixels[si];
                    sg_raw = src_pixels[si + 1];
                    sb_raw = src_pixels[si + 2];
                    sa = src_pixels[si + 3];
                }

                if sa == 0 {
                    continue;
                }

                // Dissolve: GLSL-matching noise field + burn edge colors
                let mut burn_override: Option<[u8; 3]> = None;
                if dissolve_active {
                    let ux_d = px as f32 / dst_w as f32;
                    let uy_d = py as f32 / dst_h as f32;
                    let res = dissolve_field(
                        ux_d,
                        uy_d,
                        dp.shader_time,
                        d_raw,
                        adjusted_dissolve,
                        dp.sprite_w,
                        dp.sprite_h,
                    );
                    if res <= adjusted_dissolve {
                        continue;
                    }
                    if has_burn && res < adjusted_dissolve + burn_outer {
                        if res < adjusted_dissolve + burn_inner {
                            burn_override = Some([dp.burn1[0], dp.burn1[1], dp.burn1[2]]);
                        } else if dp.burn2[3] > 0 {
                            burn_override = Some([dp.burn2[0], dp.burn2[1], dp.burn2[2]]);
                        }
                    }
                }

                // Stencil: write or test
                let dst_px = (dx0 + px) as u32;
                let dst_py = (dy0 + py) as u32;
                if self.stencil_write_mode {
                    self.stencil_write(dst_px, dst_py);
                    continue;
                }
                if self.stencil_compare != StencilCompare::Disabled
                    && !self.stencil_test(dst_px, dst_py)
                {
                    continue;
                }

                let (mut sr, mut sg, mut sb, mut fa) = if let Some(bc) = burn_override {
                    (bc[0], bc[1], bc[2], sa)
                } else if white_tint {
                    (sr_raw, sg_raw, sb_raw, sa)
                } else {
                    (
                        (sr_raw as u16 * tint[0] as u16 / 255) as u8,
                        (sg_raw as u16 * tint[1] as u16 / 255) as u8,
                        (sb_raw as u16 * tint[2] as u16 / 255) as u8,
                        (sa as u16 * tint[3] as u16 / 255) as u8,
                    )
                };

                // GLSL dissolve color tint: blend burn color into entire sprite proportional to dissolve
                if dissolve_active && burn_override.is_none() {
                    let d = d_raw;
                    let mix = 0.6 * d;
                    let inv = 1.0 - mix;
                    if dp.burn2[3] > 0 {
                        sr = (sr as f32 * inv + dp.burn2[0] as f32 * mix) as u8;
                        sg = (sg as f32 * inv + dp.burn2[1] as f32 * mix) as u8;
                        sb = (sb as f32 * inv + dp.burn2[2] as f32 * mix) as u8;
                    } else if dp.burn1[3] > 0 {
                        sr = (sr as f32 * inv + dp.burn1[0] as f32 * mix) as u8;
                        sg = (sg as f32 * inv + dp.burn1[1] as f32 * mix) as u8;
                        sb = (sb as f32 * inv + dp.burn1[2] as f32 * mix) as u8;
                    }
                }

                // Per-pixel shader effects (played/debuff/foil/holo/polychrome/negative/negative_shine/gold_seal)
                // Skip shader on burn-edge pixels: GLSL applies dissolve_mask AFTER the shader,
                // and burn colors replace the shader output — so burn pixels are final.
                if dp.shader_effect >= 1 && burn_override.is_none() {
                    let ux = px as f32 / dst_w as f32;
                    let uy = py as f32 / dst_h as f32;
                    apply_card_shader(
                        dp.shader_effect,
                        &shader_pre,
                        ux,
                        uy,
                        dst_px as f32,
                        dst_py as f32,
                        &mut sr,
                        &mut sg,
                        &mut sb,
                        &mut fa,
                    );
                }

                let di = dst_row_base + dst_px as usize * 4;
                if replace {
                    self.pixels[di] = sr;
                    self.pixels[di + 1] = sg;
                    self.pixels[di + 2] = sb;
                    self.pixels[di + 3] = fa;
                } else if (self.blend == 0 || self.blend == 4) && fa == 255 {
                    // Alpha/premultiplied + fully opaque: direct write (fast path)
                    self.pixels[di] = sr;
                    self.pixels[di + 1] = sg;
                    self.pixels[di + 2] = sb;
                    self.pixels[di + 3] = 255;
                } else if fa > 0 {
                    self.blend_at(di, sr, sg, sb, fa);
                }
            }
        }
    }

    /// Draw a sub-region of an RGBA source image using an arbitrary affine transform.
    /// Fully inlined — no per-pixel function calls.
    pub fn draw_image_region_transformed(
        &mut self,
        src_pixels: &[u8],
        src_w: u32,
        src_x: f32,
        src_y: f32,
        src_rw: f32,
        src_rh: f32,
        dst_bounds: (i32, i32, i32, i32),
        inv: [f32; 6],
        tint: [u8; 4],
        replace: bool,
        dp: DissolveParams,
    ) {
        let (min_x, min_y, max_x, max_y) = dst_bounds;
        // Clip to buffer and scissor bounds
        let (clip_x0, clip_y0, clip_x1, clip_y1) = self.clip_bounds();
        let x_start = min_x.max(clip_x0);
        let x_end = max_x.min(clip_x1);
        let y_start = min_y.max(clip_y0);
        let y_end = max_y.min(clip_y1);
        if x_start >= x_end || y_start >= y_end {
            return;
        }

        let [ia, ib, itx, ic, id, ity] = inv;
        let white_tint = tint == [255, 255, 255, 255];
        let buf_w = self.width;
        let src_len = src_pixels.len();
        let src_w_i = src_w as i32;
        // Effective scale: how many src pixels per dst pixel along each axis
        let eff_sx = (ia * ia + ic * ic).sqrt();
        let eff_sy = (ib * ib + id * id).sqrt();
        let use_box = self.filter_linear
            && (eff_sx > 2.0 || eff_sy > 2.0)
            && (x_end - x_start > 3 && y_end - y_start > 3);
        let use_bilinear = self.filter_linear && !use_box;
        let box_w = if use_box { eff_sx.ceil() as u32 } else { 0 };
        let box_h = if use_box { eff_sy.ceil() as u32 } else { 0 };
        let box_step_x = if box_w > 4 { box_w / 4 } else { 1 };
        let box_step_y = if box_h > 4 { box_h / 4 } else { 1 };
        let src_rx_end = (src_x as u32 + src_rw as u32).min(src_w);
        let src_ry_end = src_y as u32 + src_rh as u32;
        let dissolve_active = dp.dissolve > 0.01;
        let d_raw = dp.dissolve;
        let adjusted_dissolve = if dissolve_active {
            let d = d_raw;
            (d * d * (3.0 - 2.0 * d)) * 1.02 - 0.01
        } else {
            0.0
        };
        let has_burn = dissolve_active && (dp.burn1[3] > 0 || dp.burn2[3] > 0);
        let half_minus = if has_burn {
            (0.5 - (adjusted_dissolve - 0.5).abs()).max(0.0)
        } else {
            0.0
        };
        let burn_outer = 0.8 * half_minus;
        let burn_inner = 0.5 * half_minus;

        // Precompute time-only shader values once per sprite (not per pixel)
        let shader_pre = if dp.shader_effect >= 1 {
            ShaderPre::compute(dp.shader_effect, dp.shader_time)
        } else {
            ShaderPre::compute(0, 0.0)
        };

        for py in y_start..y_end {
            let pf = py as f32 + 0.5;
            let base_su = ib * pf + itx;
            let base_sv = id * pf + ity;
            let dst_row_base = (py as u32 * buf_w) as usize * 4;

            for px in x_start..x_end {
                let xf = px as f32 + 0.5;
                let su = ia * xf + base_su;
                let sv = ic * xf + base_sv;

                if su < 0.0 || sv < 0.0 || su >= src_rw || sv >= src_rh {
                    continue;
                }

                let abs_su = src_x + su;
                let abs_sv = src_y + sv;
                let src_col = abs_su as u32;
                let src_row = abs_sv as u32;
                if src_col >= src_w {
                    continue;
                }

                // Sample pixel (box filter, bilinear, or nearest)
                let (sr_raw, sg_raw, sb_raw, sa);
                if use_box {
                    // Alpha-weighted box filter (matches draw_image_region)
                    let bx0 = (abs_su as u32).min(src_w - 1);
                    let by0 = (abs_sv as u32).min(src_ry_end.saturating_sub(1));
                    if bx0 >= src_rx_end || by0 >= src_ry_end {
                        continue;
                    }
                    let bx1 = (bx0 + box_w).min(src_rx_end);
                    let by1 = (by0 + box_h).min(src_ry_end);
                    let mut ra_sum: u32 = 0;
                    let mut ga_sum: u32 = 0;
                    let mut ba_sum: u32 = 0;
                    let mut a_sum: u32 = 0;
                    let mut n: u32 = 0;
                    let mut sy_i = by0;
                    while sy_i < by1 {
                        let row_off = (sy_i * src_w) as usize * 4;
                        let mut sx_i = bx0;
                        while sx_i < bx1 {
                            let si = row_off + sx_i as usize * 4;
                            if si + 3 >= src_len {
                                break;
                            }
                            let a = src_pixels[si + 3] as u32;
                            ra_sum += src_pixels[si] as u32 * a;
                            ga_sum += src_pixels[si + 1] as u32 * a;
                            ba_sum += src_pixels[si + 2] as u32 * a;
                            a_sum += a;
                            n += 1;
                            sx_i += box_step_x;
                        }
                        sy_i += box_step_y;
                    }
                    if n == 0 {
                        continue;
                    }
                    sr_raw = if a_sum > 0 { (ra_sum / a_sum) as u8 } else { 0 };
                    sg_raw = if a_sum > 0 { (ga_sum / a_sum) as u8 } else { 0 };
                    sb_raw = if a_sum > 0 { (ba_sum / a_sum) as u8 } else { 0 };
                    sa = (a_sum / n) as u8;
                } else if use_bilinear {
                    let x0 = abs_su.floor() as i32;
                    let y0 = abs_sv.floor() as i32;
                    let x1 = x0 + 1;
                    let y1 = y0 + 1;
                    let xf = ((abs_su - x0 as f32) * 256.0) as u32;
                    let yf = ((abs_sv - y0 as f32) * 256.0) as u32;
                    let ixf = 256 - xf;
                    let iyf = 256 - yf;
                    let src_h_max = (src_len / (src_w as usize * 4)).saturating_sub(1) as i32;
                    let cx0 = x0.max(0).min(src_w_i - 1) as usize;
                    let cx1 = x1.max(0).min(src_w_i - 1) as usize;
                    let cy0 = y0.max(0).min(src_h_max) as u32;
                    let cy1 = y1.max(0).min(src_h_max) as u32;
                    let i00 = (cy0 * src_w) as usize * 4 + cx0 * 4;
                    let i10 = (cy0 * src_w) as usize * 4 + cx1 * 4;
                    let i01 = (cy1 * src_w) as usize * 4 + cx0 * 4;
                    let i11 = (cy1 * src_w) as usize * 4 + cx1 * 4;
                    if i11 + 3 >= src_len {
                        continue;
                    } // safety guard
                    let w00 = ixf * iyf;
                    let w10 = xf * iyf;
                    let w01 = ixf * yf;
                    let w11 = xf * yf;
                    sr_raw = ((src_pixels[i00] as u32 * w00
                        + src_pixels[i10] as u32 * w10
                        + src_pixels[i01] as u32 * w01
                        + src_pixels[i11] as u32 * w11)
                        >> 16) as u8;
                    sg_raw = ((src_pixels[i00 + 1] as u32 * w00
                        + src_pixels[i10 + 1] as u32 * w10
                        + src_pixels[i01 + 1] as u32 * w01
                        + src_pixels[i11 + 1] as u32 * w11)
                        >> 16) as u8;
                    sb_raw = ((src_pixels[i00 + 2] as u32 * w00
                        + src_pixels[i10 + 2] as u32 * w10
                        + src_pixels[i01 + 2] as u32 * w01
                        + src_pixels[i11 + 2] as u32 * w11)
                        >> 16) as u8;
                    sa = ((src_pixels[i00 + 3] as u32 * w00
                        + src_pixels[i10 + 3] as u32 * w10
                        + src_pixels[i01 + 3] as u32 * w01
                        + src_pixels[i11 + 3] as u32 * w11)
                        >> 16) as u8;
                } else {
                    let si = ((src_row * src_w + src_col) * 4) as usize;
                    if si + 3 >= src_len {
                        continue;
                    }
                    sr_raw = src_pixels[si];
                    sg_raw = src_pixels[si + 1];
                    sb_raw = src_pixels[si + 2];
                    sa = src_pixels[si + 3];
                }

                if sa == 0 {
                    continue;
                }

                let mut burn_override: Option<[u8; 3]> = None;
                if dissolve_active {
                    let ux_d = su / src_rw;
                    let uy_d = sv / src_rh;
                    let res = dissolve_field(
                        ux_d,
                        uy_d,
                        dp.shader_time,
                        d_raw,
                        adjusted_dissolve,
                        dp.sprite_w,
                        dp.sprite_h,
                    );
                    if res <= adjusted_dissolve {
                        continue;
                    }
                    if has_burn && res < adjusted_dissolve + burn_outer {
                        if res < adjusted_dissolve + burn_inner {
                            burn_override = Some([dp.burn1[0], dp.burn1[1], dp.burn1[2]]);
                        } else if dp.burn2[3] > 0 {
                            burn_override = Some([dp.burn2[0], dp.burn2[1], dp.burn2[2]]);
                        }
                    }
                }

                // Stencil: write or test
                let dpx = px as u32;
                let dpy = py as u32;
                if self.stencil_write_mode {
                    self.stencil_write(dpx, dpy);
                    continue;
                }
                if self.stencil_compare != StencilCompare::Disabled && !self.stencil_test(dpx, dpy)
                {
                    continue;
                }

                let (mut sr, mut sg, mut sb, mut fa) = if let Some(bc) = burn_override {
                    (bc[0], bc[1], bc[2], sa)
                } else if white_tint {
                    (sr_raw, sg_raw, sb_raw, sa)
                } else {
                    (
                        (sr_raw as u16 * tint[0] as u16 / 255) as u8,
                        (sg_raw as u16 * tint[1] as u16 / 255) as u8,
                        (sb_raw as u16 * tint[2] as u16 / 255) as u8,
                        (sa as u16 * tint[3] as u16 / 255) as u8,
                    )
                };

                // GLSL dissolve color tint: blend burn color into entire sprite proportional to dissolve
                if dissolve_active && burn_override.is_none() {
                    let d = d_raw;
                    let mix = 0.6 * d;
                    let inv = 1.0 - mix;
                    if dp.burn2[3] > 0 {
                        sr = (sr as f32 * inv + dp.burn2[0] as f32 * mix) as u8;
                        sg = (sg as f32 * inv + dp.burn2[1] as f32 * mix) as u8;
                        sb = (sb as f32 * inv + dp.burn2[2] as f32 * mix) as u8;
                    } else if dp.burn1[3] > 0 {
                        sr = (sr as f32 * inv + dp.burn1[0] as f32 * mix) as u8;
                        sg = (sg as f32 * inv + dp.burn1[1] as f32 * mix) as u8;
                        sb = (sb as f32 * inv + dp.burn1[2] as f32 * mix) as u8;
                    }
                }

                if dp.shader_effect >= 1 && burn_override.is_none() {
                    let ux = su / src_rw;
                    let uy = sv / src_rh;
                    apply_card_shader(
                        dp.shader_effect,
                        &shader_pre,
                        ux,
                        uy,
                        px as f32,
                        dpy as f32,
                        &mut sr,
                        &mut sg,
                        &mut sb,
                        &mut fa,
                    );
                }

                let di = dst_row_base + px as usize * 4;
                if replace {
                    self.pixels[di] = sr;
                    self.pixels[di + 1] = sg;
                    self.pixels[di + 2] = sb;
                    self.pixels[di + 3] = fa;
                } else if (self.blend == 0 || self.blend == 4) && fa == 255 {
                    self.pixels[di] = sr;
                    self.pixels[di + 1] = sg;
                    self.pixels[di + 2] = sb;
                    self.pixels[di + 3] = 255;
                } else if fa > 0 {
                    self.blend_at(di, sr, sg, sb, fa);
                }
            }
        }
    }

    /// Apply CRT scanline effect — darken every other row slightly.
    /// Background vignette is handled separately, so this only does scanlines.
    /// Uses fixed-point integer math for performance.
    /// `intensity` ranges from 0.0 (no effect) to 1.0 (full effect).
    /// Apply CRT post-processing: bloom (bright glow), contrast adjustment,
    /// vignette (dark edges), and scanlines.
    /// bloom_fac: bloom intensity (from game, typically 0..2), 0 = no bloom
    /// crt_intensity: CRT effect intensity (from game, typically 0..0.16)
    pub fn apply_crt_effect(&mut self, bloom_fac: f32, crt_intensity: f32) {
        let w = self.width as usize;
        let h = self.height as usize;
        if w == 0 || h == 0 {
            return;
        }

        // Normalize CRT intensity (game sends ~0.016 at default setting)
        let crt_norm = (crt_intensity / 0.048).min(1.0).max(0.0);

        // ---- Step 1: Bloom (bright-pass extraction + blur + lerp blend) ----
        // Matches GLSL CRT shader: 7x7 kernel, cutoff 0.6, min-channel threshold
        let bloom_strength =
            bloom_fac.max(0.0).min(2.0) * 0.03 * (crt_norm / (0.16 * 0.3)).max(0.0);
        if bloom_strength > 0.001 {
            // Downsample to small grid for bloom (1/4 resolution for effective blur spread)
            let bw = (w / 4).max(30).min(200);
            let bh = (h / 4).max(20).min(150);
            let cutoff: u16 = 153; // 0.6 * 255 — matches GLSL cutoff

            // Extract bright pass at reduced resolution (u16 to avoid overflow in blur)
            let bloom_size = bw * bh * 3;
            self.crt_bright.resize(bloom_size, 0);
            self.crt_bright[..bloom_size].fill(0);
            let bright = &mut self.crt_bright;
            for by in 0..bh {
                let sy = by * h / bh;
                let src_row = sy * w * 4;
                for bx in 0..bw {
                    let sx = bx * w / bw;
                    let si = src_row + sx * 4;
                    let r = self.pixels[si] as u16;
                    let g = self.pixels[si + 1] as u16;
                    let b = self.pixels[si + 2] as u16;
                    // GLSL: min(r,g,b) thresholded, weighted by distance from center
                    let mn = r.min(g).min(b);
                    let bi = (by * bw + bx) * 3;
                    if mn > cutoff {
                        // Remap: (val - cutoff) / (255 - cutoff) * 255
                        let scale = 255.0 / (255 - cutoff) as f32;
                        bright[bi] = ((r - cutoff) as f32 * scale) as u16;
                        bright[bi + 1] = ((g - cutoff) as f32 * scale) as u16;
                        bright[bi + 2] = ((b - cutoff) as f32 * scale) as u16;
                    }
                }
            }

            // Three passes of 3x3 box blur (separable) = effective ~7x7 kernel
            // Matches GLSL BLOOM_AMT=3 (-3..+3 sample range)
            // At 1/4 resolution this covers ~28 pixels of the source image
            self.crt_temp.resize(bloom_size, 0);
            let temp = &mut self.crt_temp;
            for _pass in 0..3 {
                // Horizontal pass
                for y in 0..bh {
                    let row = y * bw;
                    for x in 0..bw {
                        let x0 = if x > 0 { x - 1 } else { 0 };
                        let x2 = if x + 1 < bw { x + 1 } else { bw - 1 };
                        let i0 = (row + x0) * 3;
                        let i1 = (row + x) * 3;
                        let i2 = (row + x2) * 3;
                        let di = (row + x) * 3;
                        temp[di] = (bright[i0] + bright[i1] + bright[i2]) / 3;
                        temp[di + 1] = (bright[i0 + 1] + bright[i1 + 1] + bright[i2 + 1]) / 3;
                        temp[di + 2] = (bright[i0 + 2] + bright[i1 + 2] + bright[i2 + 2]) / 3;
                    }
                }
                // Vertical pass
                for y in 0..bh {
                    let y0 = if y > 0 { y - 1 } else { 0 };
                    let y2 = if y + 1 < bh { y + 1 } else { bh - 1 };
                    for x in 0..bw {
                        let i0 = (y0 * bw + x) * 3;
                        let i1 = (y * bw + x) * 3;
                        let i2 = (y2 * bw + x) * 3;
                        let di = (y * bw + x) * 3;
                        bright[di] = (temp[i0] + temp[i1] + temp[i2]) / 3;
                        bright[di + 1] = (temp[i0 + 1] + temp[i1 + 1] + temp[i2 + 1]) / 3;
                        bright[di + 2] = (temp[i0 + 2] + temp[i1 + 2] + temp[i2 + 2]) / 3;
                    }
                }
            }

            // Lerp blend with bilinear upsampling: smooth glow, no blocky 4x4 artifacts.
            // Precompute per-column bloom sample positions (8-bit fixed point fractions).
            self.crt_col_bloom.clear();
            self.crt_col_bloom
                .reserve(w.saturating_sub(self.crt_col_bloom.capacity()));
            for x in 0..w {
                let fx = (x as f32 + 0.5) * (bw as f32 / w as f32) - 0.5;
                let bx0 = (fx.max(0.0) as usize).min(bw - 1);
                let bx1 = (bx0 + 1).min(bw - 1);
                let tx = (fx - bx0 as f32).clamp(0.0, 1.0);
                self.crt_col_bloom.push((bx0, bx1, (tx * 256.0) as u32));
            }
            let col_bloom = &self.crt_col_bloom;
            let mix = (bloom_strength * 256.0).min(256.0) as u32;
            let inv_mix = 256 - mix;
            for y in 0..h {
                let fy = (y as f32 + 0.5) * (bh as f32 / h as f32) - 0.5;
                let by0 = (fy.max(0.0) as usize).min(bh - 1);
                let by1 = (by0 + 1).min(bh - 1);
                let ty_fp = ((fy - by0 as f32).clamp(0.0, 1.0) * 256.0) as u32;
                let ity_fp = 256 - ty_fp;
                let row_base = y * w * 4;
                for x in 0..w {
                    let (bx0, bx1, tx_fp) = col_bloom[x];
                    let itx_fp = 256 - tx_fp;
                    let i00 = (by0 * bw + bx0) * 3;
                    let i10 = (by0 * bw + bx1) * 3;
                    let i01 = (by1 * bw + bx0) * 3;
                    let i11 = (by1 * bw + bx1) * 3;
                    let w00 = itx_fp * ity_fp;
                    let w10 = tx_fp * ity_fp;
                    let w01 = itx_fp * ty_fp;
                    let w11 = tx_fp * ty_fp;
                    let br = (bright[i00] as u32 * w00
                        + bright[i10] as u32 * w10
                        + bright[i01] as u32 * w01
                        + bright[i11] as u32 * w11)
                        >> 16;
                    let bg = (bright[i00 + 1] as u32 * w00
                        + bright[i10 + 1] as u32 * w10
                        + bright[i01 + 1] as u32 * w01
                        + bright[i11 + 1] as u32 * w11)
                        >> 16;
                    let bb = (bright[i00 + 2] as u32 * w00
                        + bright[i10 + 2] as u32 * w10
                        + bright[i01 + 2] as u32 * w01
                        + bright[i11 + 2] as u32 * w11)
                        >> 16;
                    let pi = row_base + x * 4;
                    self.pixels[pi] =
                        ((self.pixels[pi] as u32 * inv_mix + br * mix) >> 8).min(255) as u8;
                    self.pixels[pi + 1] =
                        ((self.pixels[pi + 1] as u32 * inv_mix + bg * mix) >> 8).min(255) as u8;
                    self.pixels[pi + 2] =
                        ((self.pixels[pi + 2] as u32 * inv_mix + bb * mix) >> 8).min(255) as u8;
                }
            }
        }

        // ---- Step 2: Contrast adjustment ----
        // Full GLSL CRT transform (lines 79, 102-104):
        //   A = crt_intensity / (0.16*0.3)       -- crt_amout_adjusted
        //   v1 = v * (1 - crt_intensity)
        //   v2 = v1 - (0.55 + 0.014*A*bloom_fac)
        //   v3 = v2 * (1.14 + A*(0.012 - bloom_fac*0.12))
        //   v4 = v3 + 0.5
        // Net: output = input * glsl_scale + glsl_offset (0-1 space)
        //   with bloom=0: scale≈1.037, offset≈-0.142 (slight contrast boost)
        //   with bloom=1: scale≈0.789, offset≈-0.018 (overall darkening)
        if crt_norm > 0.01 {
            let bf = bloom_fac.max(0.0).min(1.0);
            let a_amt = crt_intensity / (0.16 * 0.3); // actual crt_amout_adjusted
            let subtract = 0.55 + 0.014 * a_amt * bf;
            let mult = (1.14 + a_amt * (0.012 - bf * 0.12)).max(0.0);
            let glsl_scale = (1.0 - crt_intensity) * mult;
            let glsl_offset = (0.5 - subtract * mult) * 255.0; // in 0-255 space
                                                               // Blend: t=0 → identity, t=1 → full GLSL; 0.7 factor softens for terminal
            let t = crt_norm.min(1.0) * 0.7;
            let scale = 1.0 + (glsl_scale - 1.0) * t;
            let offset = glsl_offset * t;
            let scale_i = (scale * 256.0) as u32;
            let offset_i = (offset * 256.0) as i32;
            for chunk in self.pixels.chunks_exact_mut(4) {
                for c in &mut chunk[..3] {
                    let v = ((*c as u32 * scale_i) as i32 + offset_i) >> 8;
                    *c = v.max(0).min(255) as u8;
                }
            }
        }

        // Note: GLSL CRT shader uses feather_fac=0.01 (Balatro's fixed value), so the
        // edge mask only activates at pixels outside the screen boundary — no visible
        // vignette at any in-bounds pixel. Scanlines are also skipped because they get
        // averaged away by the terminal downsampler.
    }

    /// Save buffer as PPM image file (for debug screenshots)
    pub fn save_ppm(&self, path: &str) -> std::io::Result<()> {
        use std::io::Write;
        let mut f = std::fs::File::create(path)?;
        write!(f, "P6\n{} {}\n255\n", self.width, self.height)?;
        let mut rgb = Vec::with_capacity((self.width * self.height * 3) as usize);
        for chunk in self.pixels.chunks_exact(4) {
            rgb.push(chunk[0]);
            rgb.push(chunk[1]);
            rgb.push(chunk[2]);
        }
        f.write_all(&rgb)?;
        Ok(())
    }

    /// Compute smooth coverage (0.0..1.0) for a pixel in a rounded rectangle.
    /// Returns 1.0 for fully inside, 0.0 for fully outside, fractional at edges.
    #[inline]
    fn rounded_rect_coverage(
        px: i32,
        py: i32,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        rx: i32,
        ry: i32,
    ) -> f32 {
        if px < x || px >= x + w || py < y || py >= y + h {
            return 0.0;
        }
        // Determine if we're in a corner region
        let (dx, dy) = if px < x + rx && py < y + ry {
            (px - (x + rx), py - (y + ry))
        } else if px >= x + w - rx && py < y + ry {
            (px - (x + w - rx - 1), py - (y + ry))
        } else if px < x + rx && py >= y + h - ry {
            (px - (x + rx), py - (y + h - ry - 1))
        } else if px >= x + w - rx && py >= y + h - ry {
            (px - (x + w - rx - 1), py - (y + h - ry - 1))
        } else {
            return 1.0; // Not in a corner region — fully inside
        };
        // Ellipse distance: d = (dx/rx)^2 + (dy/ry)^2
        // d < 1.0 = inside, d > 1.0 = outside
        let rx_f = rx as f32;
        let ry_f = ry as f32;
        let nx = dx as f32 / rx_f;
        let ny = dy as f32 / ry_f;
        let d = nx * nx + ny * ny;
        if d <= 0.8 {
            1.0 // Well inside — skip smoothing
        } else if d >= 1.2 {
            0.0 // Well outside
        } else {
            // Smooth transition zone: map [0.8, 1.2] to [1.0, 0.0]
            // Uses smoothstep-like falloff for better anti-aliasing
            let t = (d - 0.8) * 2.5; // maps 0.8..1.2 → 0.0..1.0
            let t = t.clamp(0.0, 1.0);
            1.0 - t * t * (3.0 - 2.0 * t) // smoothstep
        }
    }

    /// Draw a filled rounded rectangle with anti-aliased corners
    pub fn fill_rounded_rect(
        &mut self,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        rx: i32,
        ry: i32,
        color: [u8; 4],
    ) {
        let rx = rx.min(w / 2).max(0);
        let ry = ry.min(h / 2).max(0);
        if rx == 0 && ry == 0 {
            self.fill_rect(x, y, w, h, color);
            return;
        }
        let x0 = x.max(0);
        let y0 = y.max(0);
        let x1 = (x + w).min(self.width as i32);
        let y1 = (y + h).min(self.height as i32);
        for py in y0..y1 {
            // Fast path: rows fully inside (not in corner zone)
            let in_top_corner = py < y + ry;
            let in_bot_corner = py >= y + h - ry;
            if !in_top_corner && !in_bot_corner {
                // Entire row is inside — draw as solid span
                for px in x0..x1 {
                    self.set_pixel(px as u32, py as u32, color[0], color[1], color[2], color[3]);
                }
                continue;
            }
            for px in x0..x1 {
                // Only corner columns need coverage calculation
                let in_left = px < x + rx;
                let in_right = px >= x + w - rx;
                if !in_left && !in_right {
                    self.set_pixel(px as u32, py as u32, color[0], color[1], color[2], color[3]);
                    continue;
                }
                let cov = Self::rounded_rect_coverage(px, py, x, y, w, h, rx, ry);
                if cov >= 0.99 {
                    self.set_pixel(px as u32, py as u32, color[0], color[1], color[2], color[3]);
                } else if cov > 0.01 {
                    let a = (color[3] as f32 * cov) as u8;
                    self.set_pixel(px as u32, py as u32, color[0], color[1], color[2], a);
                }
            }
        }
    }

    /// Draw a stroked rounded rectangle with anti-aliased edges
    pub fn stroke_rounded_rect(
        &mut self,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        rx: i32,
        ry: i32,
        line_width: u32,
        color: [u8; 4],
    ) {
        let rx = rx.min(w / 2).max(0);
        let ry = ry.min(h / 2).max(0);
        if rx == 0 && ry == 0 {
            self.stroke_rect(x, y, w, h, line_width, color);
            return;
        }
        let lw = line_width as i32;
        let x0 = x.max(0);
        let y0 = y.max(0);
        let x1 = (x + w).min(self.width as i32);
        let y1 = (y + h).min(self.height as i32);
        let irx = (rx - lw).max(0);
        let iry = (ry - lw).max(0);
        for py in y0..y1 {
            for px in x0..x1 {
                let outer = Self::rounded_rect_coverage(px, py, x, y, w, h, rx, ry);
                if outer < 0.01 {
                    continue;
                }
                let inner = Self::rounded_rect_coverage(
                    px,
                    py,
                    x + lw,
                    y + lw,
                    w - lw * 2,
                    h - lw * 2,
                    irx,
                    iry,
                );
                let cov = outer - inner; // stroke = outer minus inner
                if cov >= 0.99 {
                    self.set_pixel(px as u32, py as u32, color[0], color[1], color[2], color[3]);
                } else if cov > 0.01 {
                    let a = (color[3] as f32 * cov) as u8;
                    self.set_pixel(px as u32, py as u32, color[0], color[1], color[2], a);
                }
            }
        }
    }

    /// Draw text using embedded 8x8 bitmap font
    pub fn draw_text(&mut self, text: &str, x: i32, y: i32, color: [u8; 4]) {
        self.draw_text_scaled(text, x, y, 1.0, color);
    }

    /// Draw text using embedded 8x8 bitmap font with scaling
    pub fn draw_text_scaled(&mut self, text: &str, x: i32, y: i32, scale: f32, color: [u8; 4]) {
        let char_w = (8.0 * scale) as i32;
        let mut cx = x;
        for ch in text.chars() {
            let glyph_idx = (ch as usize).min(127);
            let glyph = &FONT_8X8[glyph_idx];
            for row in 0..8 {
                let byte = glyph[row as usize];
                for col in 0..8 {
                    if byte & (0x80 >> col) != 0 {
                        // Draw scaled pixel block
                        let px_start = cx + (col as f32 * scale) as i32;
                        let py_start = y + (row as f32 * scale) as i32;
                        let px_end = cx + ((col + 1) as f32 * scale) as i32;
                        let py_end = y + ((row + 1) as f32 * scale) as i32;
                        for py in py_start..py_end {
                            for px in px_start..px_end {
                                if px >= 0 && py >= 0 {
                                    self.set_pixel(
                                        px as u32, py as u32, color[0], color[1], color[2],
                                        color[3],
                                    );
                                }
                            }
                        }
                    }
                }
            }
            cx += char_w;
        }
    }
}

/// Minimal 8x8 bitmap font for ASCII printable characters (0-127).
/// Each character is 8 bytes, each byte is a row (MSB = leftmost pixel).
pub static FONT_8X8: [[u8; 8]; 128] = {
    let mut font = [[0u8; 8]; 128];

    // Space (32) - empty
    // Keep default zeros for 0-31 and 32 (space)

    // ! (33)
    font[33] = [0x18, 0x18, 0x18, 0x18, 0x18, 0x00, 0x18, 0x00];
    // " (34)
    font[34] = [0x6C, 0x6C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];
    // # (35)
    font[35] = [0x6C, 0x6C, 0xFE, 0x6C, 0xFE, 0x6C, 0x6C, 0x00];
    // $ (36)
    font[36] = [0x18, 0x7E, 0xC0, 0x7C, 0x06, 0xFC, 0x18, 0x00];
    // % (37)
    font[37] = [0xC6, 0xCC, 0x18, 0x30, 0x60, 0xC6, 0x86, 0x00];
    // & (38)
    font[38] = [0x38, 0x6C, 0x38, 0x76, 0xDC, 0xCC, 0x76, 0x00];
    // ' (39)
    font[39] = [0x18, 0x18, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00];
    // ( (40)
    font[40] = [0x0C, 0x18, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00];
    // ) (41)
    font[41] = [0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00];
    // * (42)
    font[42] = [0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00];
    // + (43)
    font[43] = [0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00];
    // , (44)
    font[44] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30];
    // - (45)
    font[45] = [0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00];
    // . (46)
    font[46] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00];
    // / (47)
    font[47] = [0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0x80, 0x00];
    // 0 (48)
    font[48] = [0x7C, 0xC6, 0xCE, 0xDE, 0xF6, 0xE6, 0x7C, 0x00];
    // 1 (49)
    font[49] = [0x18, 0x38, 0x78, 0x18, 0x18, 0x18, 0x7E, 0x00];
    // 2 (50)
    font[50] = [0x7C, 0xC6, 0x06, 0x1C, 0x30, 0x60, 0xFE, 0x00];
    // 3 (51)
    font[51] = [0x7C, 0xC6, 0x06, 0x3C, 0x06, 0xC6, 0x7C, 0x00];
    // 4 (52)
    font[52] = [0x1C, 0x3C, 0x6C, 0xCC, 0xFE, 0x0C, 0x1E, 0x00];
    // 5 (53)
    font[53] = [0xFE, 0xC0, 0xFC, 0x06, 0x06, 0xC6, 0x7C, 0x00];
    // 6 (54)
    font[54] = [0x38, 0x60, 0xC0, 0xFC, 0xC6, 0xC6, 0x7C, 0x00];
    // 7 (55)
    font[55] = [0xFE, 0xC6, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00];
    // 8 (56)
    font[56] = [0x7C, 0xC6, 0xC6, 0x7C, 0xC6, 0xC6, 0x7C, 0x00];
    // 9 (57)
    font[57] = [0x7C, 0xC6, 0xC6, 0x7E, 0x06, 0x0C, 0x78, 0x00];
    // : (58)
    font[58] = [0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x00];
    // ; (59)
    font[59] = [0x00, 0x18, 0x18, 0x00, 0x00, 0x18, 0x18, 0x30];
    // < (60)
    font[60] = [0x0C, 0x18, 0x30, 0x60, 0x30, 0x18, 0x0C, 0x00];
    // = (61)
    font[61] = [0x00, 0x00, 0x7E, 0x00, 0x7E, 0x00, 0x00, 0x00];
    // > (62)
    font[62] = [0x60, 0x30, 0x18, 0x0C, 0x18, 0x30, 0x60, 0x00];
    // ? (63)
    font[63] = [0x7C, 0xC6, 0x0C, 0x18, 0x18, 0x00, 0x18, 0x00];
    // @ (64)
    font[64] = [0x7C, 0xC6, 0xDE, 0xDE, 0xDC, 0xC0, 0x7C, 0x00];
    // A (65)
    font[65] = [0x38, 0x6C, 0xC6, 0xC6, 0xFE, 0xC6, 0xC6, 0x00];
    // B (66)
    font[66] = [0xFC, 0x66, 0x66, 0x7C, 0x66, 0x66, 0xFC, 0x00];
    // C (67)
    font[67] = [0x3C, 0x66, 0xC0, 0xC0, 0xC0, 0x66, 0x3C, 0x00];
    // D (68)
    font[68] = [0xF8, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0xF8, 0x00];
    // E (69)
    font[69] = [0xFE, 0x62, 0x68, 0x78, 0x68, 0x62, 0xFE, 0x00];
    // F (70)
    font[70] = [0xFE, 0x62, 0x68, 0x78, 0x68, 0x60, 0xF0, 0x00];
    // G (71)
    font[71] = [0x3C, 0x66, 0xC0, 0xC0, 0xCE, 0x66, 0x3E, 0x00];
    // H (72)
    font[72] = [0xC6, 0xC6, 0xC6, 0xFE, 0xC6, 0xC6, 0xC6, 0x00];
    // I (73)
    font[73] = [0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00];
    // J (74)
    font[74] = [0x1E, 0x0C, 0x0C, 0x0C, 0xCC, 0xCC, 0x78, 0x00];
    // K (75)
    font[75] = [0xE6, 0x66, 0x6C, 0x78, 0x6C, 0x66, 0xE6, 0x00];
    // L (76)
    font[76] = [0xF0, 0x60, 0x60, 0x60, 0x62, 0x66, 0xFE, 0x00];
    // M (77)
    font[77] = [0xC6, 0xEE, 0xFE, 0xD6, 0xC6, 0xC6, 0xC6, 0x00];
    // N (78)
    font[78] = [0xC6, 0xE6, 0xF6, 0xDE, 0xCE, 0xC6, 0xC6, 0x00];
    // O (79)
    font[79] = [0x7C, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00];
    // P (80)
    font[80] = [0xFC, 0x66, 0x66, 0x7C, 0x60, 0x60, 0xF0, 0x00];
    // Q (81)
    font[81] = [0x7C, 0xC6, 0xC6, 0xC6, 0xD6, 0xDE, 0x7C, 0x06];
    // R (82)
    font[82] = [0xFC, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0xE6, 0x00];
    // S (83)
    font[83] = [0x7C, 0xC6, 0xC0, 0x7C, 0x06, 0xC6, 0x7C, 0x00];
    // T (84)
    font[84] = [0x7E, 0x5A, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00];
    // U (85)
    font[85] = [0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0xC6, 0x7C, 0x00];
    // V (86)
    font[86] = [0xC6, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x10, 0x00];
    // W (87)
    font[87] = [0xC6, 0xC6, 0xC6, 0xD6, 0xFE, 0xEE, 0xC6, 0x00];
    // X (88)
    font[88] = [0xC6, 0x6C, 0x38, 0x38, 0x6C, 0xC6, 0xC6, 0x00];
    // Y (89)
    font[89] = [0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x3C, 0x00];
    // Z (90)
    font[90] = [0xFE, 0xC6, 0x8C, 0x18, 0x32, 0x66, 0xFE, 0x00];
    // [ (91)
    font[91] = [0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00];
    // \ (92)
    font[92] = [0xC0, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x02, 0x00];
    // ] (93)
    font[93] = [0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00];
    // ^ (94)
    font[94] = [0x10, 0x38, 0x6C, 0xC6, 0x00, 0x00, 0x00, 0x00];
    // _ (95)
    font[95] = [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF];
    // ` (96)
    font[96] = [0x30, 0x18, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00];
    // a (97)
    font[97] = [0x00, 0x00, 0x78, 0x0C, 0x7C, 0xCC, 0x76, 0x00];
    // b (98)
    font[98] = [0xE0, 0x60, 0x7C, 0x66, 0x66, 0x66, 0xDC, 0x00];
    // c (99)
    font[99] = [0x00, 0x00, 0x7C, 0xC6, 0xC0, 0xC6, 0x7C, 0x00];
    // d (100)
    font[100] = [0x1C, 0x0C, 0x7C, 0xCC, 0xCC, 0xCC, 0x76, 0x00];
    // e (101)
    font[101] = [0x00, 0x00, 0x7C, 0xC6, 0xFE, 0xC0, 0x7C, 0x00];
    // f (102)
    font[102] = [0x1C, 0x36, 0x30, 0x78, 0x30, 0x30, 0x78, 0x00];
    // g (103)
    font[103] = [0x00, 0x00, 0x76, 0xCC, 0xCC, 0x7C, 0x0C, 0x78];
    // h (104)
    font[104] = [0xE0, 0x60, 0x6C, 0x76, 0x66, 0x66, 0xE6, 0x00];
    // i (105)
    font[105] = [0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00];
    // j (106)
    font[106] = [0x06, 0x00, 0x0E, 0x06, 0x06, 0x66, 0x66, 0x3C];
    // k (107)
    font[107] = [0xE0, 0x60, 0x66, 0x6C, 0x78, 0x6C, 0xE6, 0x00];
    // l (108)
    font[108] = [0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00];
    // m (109)
    font[109] = [0x00, 0x00, 0xCC, 0xFE, 0xD6, 0xC6, 0xC6, 0x00];
    // n (110)
    font[110] = [0x00, 0x00, 0xDC, 0x66, 0x66, 0x66, 0x66, 0x00];
    // o (111)
    font[111] = [0x00, 0x00, 0x7C, 0xC6, 0xC6, 0xC6, 0x7C, 0x00];
    // p (112)
    font[112] = [0x00, 0x00, 0xDC, 0x66, 0x66, 0x7C, 0x60, 0xF0];
    // q (113)
    font[113] = [0x00, 0x00, 0x76, 0xCC, 0xCC, 0x7C, 0x0C, 0x1E];
    // r (114)
    font[114] = [0x00, 0x00, 0xDC, 0x76, 0x60, 0x60, 0xF0, 0x00];
    // s (115)
    font[115] = [0x00, 0x00, 0x7C, 0xC0, 0x7C, 0x06, 0xFC, 0x00];
    // t (116)
    font[116] = [0x30, 0x30, 0x7C, 0x30, 0x30, 0x36, 0x1C, 0x00];
    // u (117)
    font[117] = [0x00, 0x00, 0xCC, 0xCC, 0xCC, 0xCC, 0x76, 0x00];
    // v (118)
    font[118] = [0x00, 0x00, 0xC6, 0xC6, 0xC6, 0x6C, 0x38, 0x00];
    // w (119)
    font[119] = [0x00, 0x00, 0xC6, 0xC6, 0xD6, 0xFE, 0x6C, 0x00];
    // x (120)
    font[120] = [0x00, 0x00, 0xC6, 0x6C, 0x38, 0x6C, 0xC6, 0x00];
    // y (121)
    font[121] = [0x00, 0x00, 0xC6, 0xC6, 0xCE, 0x76, 0x06, 0x7C];
    // z (122)
    font[122] = [0x00, 0x00, 0xFE, 0x0C, 0x38, 0x60, 0xFE, 0x00];
    // { (123)
    font[123] = [0x0E, 0x18, 0x18, 0x70, 0x18, 0x18, 0x0E, 0x00];
    // | (124)
    font[124] = [0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00];
    // } (125)
    font[125] = [0x70, 0x18, 0x18, 0x0E, 0x18, 0x18, 0x70, 0x00];
    // ~ (126)
    font[126] = [0x76, 0xDC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00];

    font
};
