//! The glass atmosphere: on a black background a point whose color is dark (a
//! dim class color, a point damped by its pulse, a filtered-out one) reads as a
//! hole. This plugin is the floor under every visual — it lifts what is too dark
//! toward a pale-blue glass tint, twinkling out of phase point by point, so the
//! whole system stays legible as an atmosphere the lit ones stand out from.
//!
//! Registered LAST: it only ever raises what the earlier plugins left dark, so
//! the selection, its orbit flare and anything already bright pass through
//! untouched.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;

pub const id = "atmosphere";

/// The tint of the atmosphere — a live, glassy cyan-blue.
pub const glass_rgb: [3]f32 = .{ 0.35, 0.80, 1.0 };

/// A point's own twinkle, 0..1. The golden angle keeps any two points out of
/// step, so the field shimmers instead of pulsing as one.
pub fn twinkle(anim: f32, i: usize) f32 {
    return 0.5 + 0.5 * @sin(anim * 1.6 + @as(f32, @floatFromInt(i)) * 2.399);
}

/// `base` blended toward the glass tint by `t`, the glass side breathing with `k`.
pub fn glassTint(base: [3]f32, t: f32, k: f32) [3]f32 {
    var c: [3]f32 = undefined;
    for (0..3) |j| c[j] = (1 - t) * base[j] + t * glass_rgb[j] * (0.75 + 0.25 * k);
    return c;
}

fn luma(c: [3]f32) f32 {
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}

/// Below this perceived brightness a point needs the atmosphere to be seen.
const floor: f32 = 0.38;
/// A halo is the expensive part on the software path (O(radius²) per point, and
/// it is drawn every frame): only the points that would otherwise VANISH get one.
const halo_need: f32 = 0.45;

pub fn visual(a: *App, i: usize, v: *app_mod.Visual) void {
    const k = twinkle(a.anim, i);
    if (!v.pass) {
        // Filtered out: the point stays context, but as a shard of cold glass
        // catching the light — never a black hole on a black background.
        v.color = glassTint(v.color, 0.9, k);
        v.bright = 0.65 + 0.45 * k;
        v.glow = 0.75 + 0.85 * k;
        v.radius *= 0.9;
        v.halo = .{ .rgb = glass_rgb, .radius_mul = 1.9, .k = 9.0 + 14.0 * k };
        return;
    }
    const lit = luma(v.color) * v.bright;
    if (lit >= floor) return;
    const need = 1.0 - lit / floor; // 0 at the floor, 1 for a black point
    v.color = glassTint(v.color, 0.7 * need, k);
    v.bright = @max(v.bright, 0.7 + 0.3 * k * need);
    v.glow = @max(v.glow, 0.5 + 0.6 * k * need);
    // The reflection that keeps a dark point off the black — but only where the
    // point is dark enough to need it (a whole structure of grey carbons would
    // otherwise pay for a halo it does not read).
    if (v.halo == null and need > halo_need)
        v.halo = .{ .rgb = glass_rgb, .radius_mul = 1.9, .k = (5.0 + 12.0 * k) * need };
}
