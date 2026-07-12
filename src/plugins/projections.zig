//! Projection presets (1..9, from the domain's table), coordinate-plane
//! rotation (←/→, Tab), tumble (T), auto-spin (Space), view/camera reset (R).

const std = @import("std");
const geom = @import("../geom.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const D = app_mod.D;

pub const id = "projections";

pub const State = struct {
    plane: u32 = 0,
    tumble: bool = false,
    spin: bool = false,
    /// Sweep parameter for animated presets.
    theta: f32 = 0,
};

pub fn apply(a: *App, preset: u32) void {
    const st = a.pluginState(@This());
    a.preset = preset;
    st.theta = 0;
    a.basis = D.presets[preset].basis(0);
    a.status_dirty = true;
}

/// Deck slides reference presets by name.
pub fn applyByName(a: *App, name: []const u8) void {
    for (D.presets, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) {
            apply(a, @intCast(i));
            return;
        }
    }
    apply(a, 0);
}

pub fn key(a: *App, code: u32) bool {
    const st = a.pluginState(@This());
    switch (code) {
        2...10 => { // KEY_1..9 → preset index
            const idx = code - 2;
            if (idx >= D.presets.len) return false;
            apply(a, @intCast(idx));
        },
        15 => { // Tab
            st.plane = (st.plane + 1) % @as(u32, geom.planes.len);
            a.status_dirty = true;
        },
        105, 106 => { // ←/→: rotate the basis, or sweep an animated preset
            const th: f32 = if (code == 105) -0.06 else 0.06;
            if (D.presets[a.preset].animated) {
                st.theta += th;
            } else {
                const p = geom.planes[st.plane];
                geom.rotateBasis(&a.basis, p[0], p[1], th);
            }
        },
        20 => st.tumble = !st.tumble, // T
        57 => st.spin = !st.spin, // Space
        19 => { // R
            apply(a, a.preset);
            a.reset_camera = true;
        },
        else => return false,
    }
    return true;
}

pub fn frame(a: *App) void {
    const st = a.pluginState(@This());
    if (D.presets[a.preset].animated) {
        if (st.tumble) st.theta += 0.15 * a.dt;
        a.basis = D.presets[a.preset].basis(st.theta);
    } else if (st.tumble) {
        // Slow drift through a few hidden planes.
        const speeds = [_]f32{ 0.16, 0.11, 0.07 };
        for (speeds, 0..) |s, k| {
            if (k >= geom.planes.len) break;
            const p = geom.planes[(st.plane + k) % geom.planes.len];
            geom.rotateBasis(&a.basis, p[0], p[1], s * a.dt);
        }
    }
    if (st.spin)
        app_mod.storeF32(&app_mod.cam_yaw, app_mod.loadF32(&app_mod.cam_yaw) + 0.25 * a.dt);
}

pub fn status(a: *App, buf: []u8) []const u8 {
    const st = a.pluginState(@This());
    const name = D.presets[a.preset].name;
    const p = geom.planes[st.plane];
    return std.fmt.bufPrint(buf, "{s} · plane e{d}e{d}", .{ name, p[0] + 1, p[1] + 1 }) catch name;
}
