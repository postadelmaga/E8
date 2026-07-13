//! Color modes (C), from the domain's table; keeps the HUD legend in sync.

const std = @import("std");
const keys = @import("../keys.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const D = app_mod.D;

pub const id = "colors";

pub const State = struct {
    mode: u32 = 0,
    pushed: u32 = 99,
};

pub fn setByName(a: *App, name: []const u8) void {
    const st = a.pluginState(@This());
    for (D.color_modes, 0..) |m, i| {
        if (std.mem.eql(u8, m.name, name)) st.mode = @intCast(i);
    }
    st.pushed = 99;
}

pub fn key(a: *App, code: u32) bool {
    if (code != keys.colors) return false; // C
    const st = a.pluginState(@This());
    st.mode = (st.mode + 1) % @as(u32, @intCast(D.color_modes.len));
    a.status_dirty = true;
    return true;
}

pub fn visual(a: *App, i: usize, v: *app_mod.Visual) void {
    const st = a.pluginState(@This());
    v.color = D.color_modes[st.mode].color(&a.points[i], a.hidden[i]);
}

pub fn post(a: *App) void {
    const st = a.pluginState(@This());
    if (st.pushed == st.mode) return;
    st.pushed = st.mode;
    a.hud.setLegend(D.color_modes[st.mode].legend);
}

pub fn status(a: *App, buf: []u8) []const u8 {
    const name = D.color_modes[a.pluginState(@This()).mode].name;
    return std.fmt.bufPrint(buf, "colors: {s}", .{name}) catch name;
}
