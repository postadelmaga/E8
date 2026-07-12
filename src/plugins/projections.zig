//! Projection presets (1..6), 8D plane rotation (←/→, Tab), tumble (T),
//! auto-spin (Space) and view/camera reset (R).

const std = @import("std");
const e8 = @import("../e8.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;

pub const id = "projections";

pub const State = struct {
    /// Index into `planes` for the ←/→ rotation.
    plane: u32 = 0,
    tumble: bool = false,
    spin: bool = false,
    /// F4↔G2 sweep angle (preset 6).
    lisi_theta: f32 = 0,
};

/// The 8D coordinate planes the ←/→ rotation walks through (Tab cycles).
const planes = [_][2]usize{
    .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 },
    .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 },
};

pub fn presetBasis(preset: u32) e8.Basis {
    return switch (preset) {
        2 => e8.physicsBasis(),
        3 => e8.coordBasis(),
        4 => e8.g2Basis(),
        5 => e8.f4Basis(),
        6 => e8.lisiRotationBasis(0),
        else => e8.coxeterBasis(),
    };
}

/// Switch preset (also used by the atlas plugin).
pub fn apply(a: *App, preset: u32) void {
    const st = a.pluginState(@This());
    a.preset = preset;
    st.lisi_theta = 0;
    a.basis = presetBasis(preset);
    a.status_dirty = true;
}

pub fn key(a: *App, code: u32) bool {
    const st = a.pluginState(@This());
    switch (code) {
        2, 3, 4, 5, 6, 7 => apply(a, code - 1), // KEY_1..6
        15 => { // Tab
            st.plane = (st.plane + 1) % @as(u32, planes.len);
            a.status_dirty = true;
        },
        105, 106 => { // ←/→: rotate the view basis, or sweep F4↔G2 in preset 6
            const th: f32 = if (code == 105) -0.06 else 0.06;
            if (a.preset == 6) {
                st.lisi_theta += th;
            } else {
                const p = planes[st.plane];
                e8.rotateBasis(&a.basis, p[0], p[1], th);
            }
        },
        20 => st.tumble = !st.tumble, // T
        57 => st.spin = !st.spin, // Space
        19 => { // R: reset view and camera
            apply(a, a.preset);
            a.reset_camera = true;
        },
        else => return false,
    }
    return true;
}

pub fn frame(a: *App) void {
    const st = a.pluginState(@This());
    if (a.preset == 6) {
        // F4↔G2 rotation (0711.0770 Figs 3–4): T animates the sweep.
        if (st.tumble) st.lisi_theta += 0.15 * a.dt;
        a.basis = e8.lisiRotationBasis(st.lisi_theta);
    } else if (st.tumble) {
        e8.rotateBasis(&a.basis, 0, 4, 0.16 * a.dt);
        e8.rotateBasis(&a.basis, 2, 6, 0.11 * a.dt);
        e8.rotateBasis(&a.basis, 1, 7, 0.07 * a.dt);
    }
    if (st.spin)
        app_mod.storeF32(&app_mod.cam_yaw, app_mod.loadF32(&app_mod.cam_yaw) + 0.25 * a.dt);
}

pub fn status(a: *App, buf: []u8) []const u8 {
    const st = a.pluginState(@This());
    const name: []const u8 = switch (a.preset) {
        2 => "physics axes",
        3 => "lattice e1e2e3 (wT,wS spin-boost)",
        4 => "G2 plane (g3,g8) + w depth",
        5 => "F4 graviweak plane",
        6 => "F4<->G2 rotation (arrows sweep, T animates)",
        else => "Coxeter plane",
    };
    const p = planes[st.plane];
    return std.fmt.bufPrint(buf, "{s} · 8D plane e{d}e{d}", .{ name, p[0] + 1, p[1] + 1 }) catch name;
}
