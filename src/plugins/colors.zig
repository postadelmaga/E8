//! Color modes (C): physics classes → generations (triality) → so(16) split →
//! hidden-dimension depth. Sets each root's base color and keeps the HUD
//! legend in sync.

const std = @import("std");
const e8 = @import("../e8.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;

pub const id = "colors";

pub const State = struct {
    mode: u32 = 0,
    /// Last legend pushed to the HUD (99 forces a refresh).
    pushed: u32 = 99,
};

pub fn key(a: *App, code: u32) bool {
    if (code != 46) return false; // C
    const st = a.pluginState(@This());
    st.mode = (st.mode + 1) % 4;
    a.status_dirty = true;
    return true;
}

pub fn visual(a: *App, i: usize, v: *app_mod.Visual) void {
    const st = a.pluginState(@This());
    v.color = e8.rootRgb(&a.roots[i], @enumFromInt(st.mode), a.hidden[i]);
}

pub fn post(a: *App) void {
    const st = a.pluginState(@This());
    if (st.pushed == st.mode) return;
    st.pushed = st.mode;
    switch (st.mode) {
        0 => a.hud.setLegend(&.{
            .{ .rgb = .{ 89, 191, 255 }, .label = "gravity" },
            .{ .rgb = .{ 255, 235, 77 }, .label = "electroweak" },
            .{ .rgb = .{ 158, 140, 217 }, .label = "frame-Higgs" },
            .{ .rgb = .{ 255, 140, 26 }, .label = "gluon" },
            .{ .rgb = .{ 191, 140, 115 }, .label = "xΦ boson" },
            .{ .rgb = .{ 140, 255, 140 }, .label = "lepton" },
            .{ .rgb = .{ 255, 64, 56 }, .label = "quark r" },
            .{ .rgb = .{ 64, 255, 77 }, .label = "g" },
            .{ .rgb = .{ 77, 115, 255 }, .label = "b" },
        }),
        1 => a.hud.setLegend(&.{
            .{ .rgb = .{ 102, 118, 143 }, .label = "bosons (48)" },
            .{ .rgb = .{ 77, 255, 115 }, .label = "gen I (64)" },
            .{ .rgb = .{ 255, 184, 46 }, .label = "gen II (64)" },
            .{ .rgb = .{ 217, 107, 255 }, .label = "gen III (64)" },
        }),
        2 => a.hud.setLegend(&.{
            .{ .rgb = .{ 102, 179, 255 }, .label = "120 adjoint (so(16))" },
            .{ .rgb = .{ 255, 153, 89 }, .label = "128 spinor (16+)" },
        }),
        else => a.hud.setLegend(&.{
            .{ .rgb = .{ 64, 128, 255 }, .label = "in the view plane" },
            .{ .rgb = .{ 255, 100, 64 }, .label = "hidden dimensions" },
        }),
    }
}

pub fn status(a: *App, buf: []u8) []const u8 {
    const st = a.pluginState(@This());
    const name = @as(e8.ColorMode, @enumFromInt(st.mode)).name();
    return std.fmt.bufPrint(buf, "colors: {s}", .{name}) catch name;
}
