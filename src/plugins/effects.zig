//! Descriptor-driven emphasis: each point's `descriptor.Object` (from the
//! domain) declares its resting look and optional pulse; the selection's
//! relation-orbit partners flare in the descriptor's orbit color, peaking in
//! phase order (the lighthouse). Registered after selection so the flare wins.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;

pub const id = "effects";

pub fn visual(a: *App, i: usize, v: *app_mod.Visual) void {
    const d = a.objectOf(i);
    v.radius *= d.radius;
    v.glow *= d.glow;
    const is_sel = a.selected >= 0 and i == @as(usize, @intCast(a.selected));
    const is_orbit = a.selected >= 0 and !is_sel and a.rel.len > 0 and blk: {
        const sel: usize = @intCast(a.selected);
        break :blk i == a.rel[0][sel] or i == a.rel[0][a.rel[0][sel]];
    };
    if (d.pulse) |p| {
        // factor ≈ 1 at amp 0; dips and peaks by `amp` around it.
        const f = (1.0 - p.amp * 0.27) + p.amp * @sin(a.anim * p.rate + p.phase);
        if (v.pass and !is_sel and !is_orbit) {
            v.glow *= f;
            v.radius *= 0.96 + 0.06 * f;
            v.bright *= 0.75 + 0.35 * f;
            v.halo = .{ .rgb = v.color, .radius_mul = 3.0, .k = 22.0 * (f - 0.25) };
        }
    }
    if (is_orbit) {
        const k = 0.55 + 0.75 * @max(0.0, @sin(a.anim * 2.6 - d.orbit_phase));
        v.color = .{
            0.35 * v.color[0] + 0.65 * d.orbit_rgb[0],
            0.35 * v.color[1] + 0.65 * d.orbit_rgb[1],
            0.35 * v.color[2] + 0.65 * d.orbit_rgb[2],
        };
        v.glow = 1.1 + 1.9 * k;
        v.radius = 1.35 + 0.35 * k;
        v.bright = 1.1 + 0.5 * k;
        v.halo = .{ .rgb = d.orbit_rgb, .radius_mul = 4.0, .k = 34.0 * k };
        v.ring = d.orbit_rgb;
    }
}
