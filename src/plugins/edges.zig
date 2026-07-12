//! Edge modes (E): all 6720 lattice edges → 228 triality-orbit links → the
//! selection's edges only → none. Owns which lines are drawn and their style;
//! lines touching the selected root highlight white on both render paths.

const std = @import("std");
const e8 = @import("../e8.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;

pub const id = "edges";

pub const State = struct {
    /// 0 none · 1 selection-only · 2 all · 3 triality links.
    mode: u32 = 2,
    /// Triality-orbit links ("lines drawn between triality partners" —
    /// 0711.0770 Fig 2, 2407.02497 Figs 1–2): each 3-cycle contributes its
    /// three sides once; the 12 fixed roots contribute none.
    tri: [e8.n_roots][2]u16 = undefined,
    n_tri: usize = 0,
};

pub fn init(a: *App) void {
    const st = a.pluginState(@This());
    for (a.triality, 0..) |j, i| {
        if (j != i) {
            st.tri[st.n_tri] = .{ @intCast(i), j };
            st.n_tri += 1;
        }
    }
}

pub fn key(a: *App, code: u32) bool {
    if (code != 18) return false; // E
    const st = a.pluginState(@This());
    st.mode = switch (st.mode) {
        2 => 3,
        3 => 1,
        1 => 0,
        else => 2,
    };
    a.status_dirty = true;
    return true;
}

pub fn edgePairs(a: *App) []const [2]u16 {
    const st = a.pluginState(@This());
    return switch (st.mode) {
        0 => &.{},
        3 => st.tri[0..st.n_tri],
        else => a.edges,
    };
}

pub fn edgeVisual(a: *App, ai: u16, bi: u16) ?app_mod.EdgeVisual {
    const st = a.pluginState(@This());
    const involves_sel = a.selected >= 0 and
        (ai == @as(u16, @intCast(a.selected)) or bi == @as(u16, @intCast(a.selected)));
    if (st.mode == 1 and !involves_sel) return null;
    if (involves_sel) return .{ .color = .{ 1, 1, 1 }, .glow = 1.1, .k = 110.0, .width = 1.6 };
    const va = &a.visuals[ai];
    const vb = &a.visuals[bi];
    const pass = va.pass and vb.pass;
    // The few triality links glow brighter than the 6720-edge bundle.
    const glow: f32 = if (st.mode == 3) 0.45 else 0.16;
    const k: f32 = if (st.mode == 3) 80.0 else 30.0;
    return .{
        .color = .{
            (va.color[0] + vb.color[0]) * 0.5,
            (va.color[1] + vb.color[1]) * 0.5,
            (va.color[2] + vb.color[2]) * 0.5,
        },
        .glow = if (pass) glow else 0.015,
        .k = if (pass) k else 4.0,
    };
}

pub fn status(a: *App, buf: []u8) []const u8 {
    _ = buf;
    return switch (a.pluginState(@This()).mode) {
        0 => "edges: off",
        1 => "edges: selection",
        3 => "edges: triality",
        else => "edges: all 6720",
    };
}
