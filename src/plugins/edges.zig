//! Edge modes (E): all lattice edges → one mode per domain relation (partner
//! links) → the selection's edges only → none. Lines touching the selected
//! point highlight white on both render paths.

const std = @import("std");
const keys = @import("../keys.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const D = app_mod.D;

pub const id = "edges";

/// Mode encoding: 0 none · 1 selection-only · 2 all · 3+r relation r.
pub const State = struct {
    mode: u32 = 2,
    /// Link lists for each relation (each cycle contributes its sides once;
    /// fixed points contribute none). Allocated at `n` entries each, with the
    /// used count alongside, so `deinit` frees exactly what it allocated.
    rel_buf: [][]([2]u16) = &.{},
    rel_len: []usize = &.{},
};

pub fn init(a: *App) void {
    const st = a.pluginState(@This());
    st.rel_buf = a.gpa.alloc([]([2]u16), a.rel.len) catch return;
    st.rel_len = a.gpa.alloc(usize, a.rel.len) catch return;
    for (a.rel, 0..) |table, r| {
        st.rel_buf[r] = a.gpa.alloc([2]u16, a.count()) catch return;
        var cnt: usize = 0;
        for (table, 0..) |j, i| {
            if (j != i) {
                st.rel_buf[r][cnt] = .{ @intCast(i), j };
                cnt += 1;
            }
        }
        st.rel_len[r] = cnt;
    }
}

pub fn deinit(a: *App) void {
    const st = a.pluginState(@This());
    for (st.rel_buf) |buf| a.gpa.free(buf);
    if (st.rel_buf.len > 0) a.gpa.free(st.rel_buf);
    if (st.rel_len.len > 0) a.gpa.free(st.rel_len);
}

pub fn setByName(a: *App, name: []const u8) void {
    const st = a.pluginState(@This());
    if (std.mem.eql(u8, name, "off") or std.mem.eql(u8, name, "none")) {
        st.mode = 0;
    } else if (std.mem.eql(u8, name, "selection")) {
        st.mode = 1;
    } else if (std.mem.eql(u8, name, "all")) {
        st.mode = 2;
    } else for (D.relations, 0..) |rd, r| {
        if (std.mem.eql(u8, rd.name, name)) st.mode = @intCast(3 + r);
    }
}

pub fn key(a: *App, code: u32) bool {
    if (code != keys.edges) return false; // E
    const st = a.pluginState(@This());
    // all → relations… → selection → off → all
    const n_rel: u32 = @intCast(D.relations.len);
    st.mode = switch (st.mode) {
        2 => if (n_rel > 0) 3 else 1,
        1 => 0,
        0 => 2,
        else => if (st.mode - 3 + 1 < n_rel) st.mode + 1 else 1,
    };
    a.status_dirty = true;
    return true;
}

pub fn edgePairs(a: *App) []const [2]u16 {
    const st = a.pluginState(@This());
    if (st.mode == 0) return &.{};
    if (st.mode >= 3) {
        const r = st.mode - 3;
        return st.rel_buf[r][0..st.rel_len[r]];
    }
    return a.edges;
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
    // The few relation links glow brighter than the full edge bundle.
    const glow: f32 = if (st.mode >= 3) 0.45 else 0.16;
    const k: f32 = if (st.mode >= 3) 80.0 else 30.0;
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
    const st = a.pluginState(@This());
    return switch (st.mode) {
        0 => "edges: off",
        1 => "edges: selection",
        2 => "edges: all",
        else => std.fmt.bufPrint(buf, "edges: {s}", .{D.relations[st.mode - 3].name}) catch "edges",
    };
}
