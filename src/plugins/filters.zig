//! Root filters (F): all → bosons → fermions → gen I/II/III → leptons →
//! quarks → graviweak d4 → color d4. Filtered-out roots render dimmed.

const std = @import("std");
const e8 = @import("../e8.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;

pub const id = "filters";

pub const State = struct {
    filter: u32 = 0,
};

const names = [_][]const u8{
    "all 240",     "bosons (48)",  "fermions (192)",   "gen I (64)",
    "gen II (64)", "gen III (64)", "leptons (48)",     "quarks (144)",
    "graviweak d4 (24)", "color d4 (24)",
};

pub fn passes(a: *App, r: *const e8.Root) bool {
    return switch (a.pluginState(@This()).filter) {
        0 => true,
        1 => r.gen == 0,
        2 => r.gen != 0,
        3 => r.gen == 1,
        4 => r.gen == 2,
        5 => r.gen == 3,
        6 => r.class == .lepton,
        7 => r.class == .quark,
        8 => r.class == .gravity or r.class == .electroweak or r.class == .frame_higgs,
        9 => r.class == .gluon or r.class == .color_x,
        else => true,
    };
}

pub fn key(a: *App, code: u32) bool {
    if (code != 33) return false; // F
    const st = a.pluginState(@This());
    st.filter = (st.filter + 1) % @as(u32, names.len);
    a.status_dirty = true;
    return true;
}

pub fn visual(a: *App, i: usize, v: *app_mod.Visual) void {
    if (passes(a, &a.roots[i])) return;
    v.pass = false;
    v.glow = 0.04;
    for (&v.color) |*c| c.* *= 0.13;
}

pub fn status(a: *App, buf: []u8) []const u8 {
    const name = names[a.pluginState(@This()).filter];
    return std.fmt.bufPrint(buf, "filter: {s}", .{name}) catch name;
}
