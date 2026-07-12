//! Animated emphasis for the theory's special particles: the xΦ bosons pulse
//! as a w-phased wave, the 12 triality-fixed roots breathe, and a selected
//! root's two triality partners flare in generation colors, peaking in
//! I → II → III order. Registered after selection so the orbit flare wins.

const std = @import("std");
const e8 = @import("../e8.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;

pub const id = "effects";

/// The 18 xΦ bosons — Lisi's new-particle prediction (proton decay mediators)
/// — pulse phased by their w charge, so x1/x2/x3 light up in sequence; the 12
/// triality-fixed roots (W±, four eφ, the gluon hexagon) breathe slowly.
fn specialPulse(r: *const e8.Root, self_partner: bool, t: f32) f32 {
    if (r.class == .color_x) return 0.85 + 0.55 * @sin(t * 2.2 + r.w * 2.0 * std.math.pi / 3.0);
    if (self_partner) return 0.90 + 0.35 * @sin(t * 1.1);
    return 1.0;
}

/// Lighthouse pulse around a triality orbit: each generation peaks in turn.
fn orbitPulse(gen: u8, t: f32) f32 {
    const ph = @as(f32, @floatFromInt(gen)) * 2.0 * std.math.pi / 3.0;
    return 0.55 + 0.75 * @max(0.0, @sin(t * 2.6 - ph));
}

pub fn visual(a: *App, i: usize, v: *app_mod.Visual) void {
    const r = &a.roots[i];
    const is_sel = a.selected >= 0 and i == @as(usize, @intCast(a.selected));
    const is_orbit = a.selected >= 0 and !is_sel and blk: {
        const sel: usize = @intCast(a.selected);
        break :blk i == a.triality[sel] or i == a.triality[a.triality[sel]];
    };
    const pulse = specialPulse(r, a.triality[i] == i, a.anim);
    if (v.pass and !is_sel and !is_orbit and pulse != 1.0) {
        // Bloom (GPU) / additive halo (CPU) amplify the same pulse.
        v.glow *= pulse;
        v.radius *= 0.96 + 0.06 * pulse;
        v.bright *= 0.75 + 0.35 * pulse;
        v.halo = .{ .rgb = v.color, .radius_mul = 3.0, .k = 22.0 * (pulse - 0.25) };
    }
    if (is_orbit) {
        const gc = e8.rootRgb(r, .generation, 0);
        const k = orbitPulse(r.gen, a.anim);
        v.color = .{
            0.35 * v.color[0] + 0.65 * gc[0],
            0.35 * v.color[1] + 0.65 * gc[1],
            0.35 * v.color[2] + 0.65 * gc[2],
        };
        v.glow = 1.1 + 1.9 * k;
        v.radius = 1.35 + 0.35 * k;
        v.bright = 1.1 + 0.5 * k;
        v.halo = .{ .rgb = gc, .radius_mul = 4.0, .k = 34.0 * k };
        v.ring = gc;
    }
}
