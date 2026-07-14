//! Point selection: click picking, the selected point's white ring/halo and
//! neighbor emphasis, and the domain-described HUD detail line.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const D = app_mod.D;

pub const id = "selection";

pub const State = struct {
    /// Per-point "is a lattice neighbor of the selection", rebuilt on selection
    /// change: `visual` runs per point per frame and must not walk the adjacency
    /// list each time (a graph hub can have thousands of neighbors).
    nb_mask: []bool = &.{},
    mask_for: i32 = -1,
};

pub fn init(a: *App) void {
    const st = a.pluginState(@This());
    st.nb_mask = a.gpa.alloc(bool, a.count()) catch &.{};
    @memset(st.nb_mask, false);
}

pub fn deinit(a: *App) void {
    const st = a.pluginState(@This());
    if (st.nb_mask.len > 0) a.gpa.free(st.nb_mask);
}

/// A new point system (a slide changed the data): the mask is sized by the old one.
pub fn reload(a: *App) void {
    const st = a.pluginState(@This());
    if (st.nb_mask.len > 0) a.gpa.free(st.nb_mask);
    st.nb_mask = a.gpa.alloc(bool, a.count()) catch &.{};
    @memset(st.nb_mask, false);
    st.mask_for = -1;
}

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
    const st = a.pluginState(@This());
    if (a.selected != st.mask_for and st.nb_mask.len > 0) {
        if (st.mask_for >= 0) for (a.neighbors(@intCast(st.mask_for))) |nb| {
            st.nb_mask[nb] = false;
        };
        if (a.selected >= 0) for (a.neighbors(@intCast(a.selected))) |nb| {
            st.nb_mask[nb] = true;
        };
        st.mask_for = a.selected;
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
    const st = a.pluginState(@This());
    const is_nb = if (st.nb_mask.len > 0) st.nb_mask[i] else blk: {
        // Mask allocation failed (OOM): fall back to the adjacency walk.
        for (a.neighbors(sel)) |nb| {
            if (nb == i) break :blk true;
        }
        break :blk false;
    };
    if (is_nb) {
        v.radius *= 1.25;
        v.glow = 1.5;
        v.bright = 1.25;
    }
}
