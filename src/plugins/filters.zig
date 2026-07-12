//! Point filters (F), from the domain's table; filtered-out points render dim.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const D = app_mod.D;

pub const id = "filters";

pub const State = struct {
    filter: u32 = 0,
};

pub fn passes(a: *App, p: *const D.Point) bool {
    return D.filters[a.pluginState(@This()).filter].pass(p);
}

pub fn setByName(a: *App, name: []const u8) void {
    const st = a.pluginState(@This());
    for (D.filters, 0..) |f, i| {
        if (std.mem.eql(u8, f.name, name)) st.filter = @intCast(i);
    }
}

pub fn key(a: *App, code: u32) bool {
    if (code != 33) return false; // F
    const st = a.pluginState(@This());
    st.filter = (st.filter + 1) % @as(u32, @intCast(D.filters.len));
    a.status_dirty = true;
    return true;
}

pub fn visual(a: *App, i: usize, v: *app_mod.Visual) void {
    if (passes(a, &a.points[i])) return;
    v.pass = false;
    v.glow = 0.04;
    for (&v.color) |*c| c.* *= 0.13;
}

pub fn status(a: *App, buf: []u8) []const u8 {
    const name = D.filters[a.pluginState(@This()).filter].name;
    return std.fmt.bufPrint(buf, "filter: {s}", .{name}) catch name;
}
