//! Root selection: click picking, the G triality-orbit hop, the selected
//! root's white ring/halo and neighbor emphasis, and the HUD detail line.

const std = @import("std");
const e8 = @import("../e8.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;

pub const id = "selection";

pub fn key(a: *App, code: u32) bool {
    if (code != 34) return false; // G: hop the triality orbit
    if (a.selected >= 0) {
        a.selected = a.triality[@intCast(a.selected)];
        a.info_dirty = true;
    }
    return true;
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
    if (a.info_dirty) refreshLine(a);
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
    for (a.neighbors[sel]) |n| {
        if (n == i) {
            v.radius *= 1.25;
            v.glow = 1.5;
            v.bright = 1.25;
            return;
        }
    }
}

fn fmtHalf(buf: []u8, v: f32) []const u8 {
    // Roots only ever hold 0, ±½, ±1 — print them the way a physicist writes them.
    if (v == 0) return std.fmt.bufPrint(buf, "0", .{}) catch "0";
    if (v == 0.5) return std.fmt.bufPrint(buf, "½", .{}) catch "";
    if (v == -0.5) return std.fmt.bufPrint(buf, "-½", .{}) catch "";
    return std.fmt.bufPrint(buf, "{d:.0}", .{v}) catch "";
}

fn refreshLine(a: *App) void {
    if (a.selected < 0) {
        a.hud.setLine2("click a root to inspect it — P panel, G triality hop, A atlas, X CSV");
        return;
    }
    const sel: usize = @intCast(a.selected);
    const r = &a.roots[sel];
    var buf: [200]u8 = undefined;
    var cbuf: [9][8]u8 = undefined;
    var coords: [8][]const u8 = undefined;
    for (0..8) |k| coords[k] = fmtHalf(&cbuf[k], r.v[k]);
    a.hud.setLine2(std.fmt.bufPrint(&buf, "root #{d}: {s} · {s} [{s}] · ({s},{s},{s},{s},{s},{s},{s},{s}) · λ3={d:.2} λ8={d:.2} w={s} B−L={d:.2} · {s} · G→#{d}", .{
        sel,
        e8.genName(r.gen),
        r.class.name(),
        r.color.name(),
        coords[0], coords[1], coords[2], coords[3],
        coords[4], coords[5], coords[6], coords[7],
        r.t3,
        r.t8,
        fmtHalf(&cbuf[8], r.w),
        r.bl,
        if (r.integer) "so(16) adjoint" else "16⁺ spinor",
        a.triality[sel],
    }) catch "");
}
