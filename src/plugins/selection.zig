//! Point selection: click picking, the selected point's white ring/halo and
//! neighbor emphasis, and the domain-described HUD detail line.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const D = app_mod.D;

pub const id = "selection";

pub fn post(a: *App) void {
    if (a.pick) |xy| {
        a.pick = null;
        var best: i32 = -1;
        var best_d: f32 = 18.0 * 18.0;
        var best_z: f32 = 1e30;
        for (a.scr, 0..) |s, i| {
            if (!a.vis[i]) continue;
            const dx = s[0] - xy[0];
            const dy = s[1] - xy[1];
            const d2 = dx * dx + dy * dy;
            if (d2 < best_d and (d2 < best_d * 0.5 or s[2] < best_z)) {
                best = @intCast(i);
                best_d = d2;
                best_z = s[2];
            }
        }
        a.selected = if (best == a.selected) -1 else best; // click again to deselect
        a.info_dirty = true;
    }
    if (a.info_dirty) {
        if (a.selected < 0) {
            a.hud.setLine2("click a point to inspect it — P journey, Esc closes layers");
        } else {
            var buf: [220]u8 = undefined;
            a.hud.setLine2(D.describe(a, @intCast(a.selected), &buf));
        }
    }
}

pub fn visual(a: *App, i: usize, v: *app_mod.Visual) void {
    if (a.selected < 0) return;
    const sel: usize = @intCast(a.selected);
    if (i == sel) {
        v.radius *= 1.9;
        v.glow = 2.2 + 0.7 * @sin(a.anim * 3.0);
        v.ring = .{ 1, 1, 1 };
        v.halo = .{ .rgb = .{ 1, 1, 1 }, .radius_mul = 4.5, .k = 16.0 + 8.0 * @sin(a.anim * 3.0) };
        return;
    }
    for (a.neighbors(sel)) |nb| {
        if (nb == i) {
            v.radius *= 1.25;
            v.glow = 1.5;
            v.bright = 1.25;
            return;
        }
    }
}
