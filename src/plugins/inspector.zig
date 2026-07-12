//! The point inspector (click a point): a separate frameless zrame window —
//! transparent smoked glass with compositor blur — with supplementary,
//! domain-written information and a live mini-scene of the selection: the
//! system dimmed, the point and its relation orbit lit, slowly orbiting.
//!
//! The scene is a zengine `View` on the app's device (emissive spheres, edge
//! tubes, HDR bloom, presented zero-copy as a dmabuf) — the main window may
//! still be on the software path; the popup asks the device for its own view
//! either way. Without a zengine device it falls back to the additive
//! software raster, so the popup always works.
//!
//! Esc follows the window-focus hierarchy: in the popup it closes the popup
//! (close_on_esc); in the main window it works through the panel → app layering.

const std = @import("std");
const ze = @import("zengine");
const zrame = @import("zrame");
const hud_mod = @import("../hud.zig");
const render_cpu = @import("../render_cpu.zig");
const render_gpu = @import("../render_gpu.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const D = app_mod.D;

pub const id = "inspector";

const pop_w: u32 = 460;
const pop_h: u32 = 500;
const scene_w: u32 = 428;
const scene_h: u32 = 250;

/// Text shared with the popup's window thread (its on_draw reads it).
pub const Shared = struct {
    held: std.atomic.Value(bool) = .init(false),
    title: [96]u8 = undefined,
    tlen: usize = 0,
    body: [512]u8 = undefined,
    blen: usize = 0,

    fn lock(s: *Shared) void {
        while (s.held.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn unlock(s: *Shared) void {
        s.held.store(false, .release);
    }
};

pub const State = struct {
    win: ?*zrame.Window = null,
    thread: ?std.Thread = null,
    /// zengine view for the mini-scene; null → software fallback.
    view: ?*render_gpu.View = null,
    instances: []ze.gpu_mesh.Instance = &.{},
    frame_no: u64 = 0,
    cpu: ?render_cpu.Cpu = null,
    shared: Shared = .{},
    last_sel: i32 = -1,
    yaw: f32 = 0.8,
};

/// Scene budget: every point as a sphere + the orbit polygon as tubes.
const max_scene_instances: u32 = app_mod.n + 8;
const point_radius: f32 = 0.045;
const tube_radius: f32 = 0.012;

fn popupLoop(w: *zrame.Window) void {
    w.run() catch {};
}

/// zrame's on_draw gives no window pointer, but the font lives on the window;
/// stash the popup window once it exists (its own thread reads it after init).
var g_popup_win: std.atomic.Value(?*zrame.Window) = .init(null);

fn popupDraw(canvas: *zrame.Canvas, content: zrame.Rect, user: ?*anyopaque) void {
    const sh: *Shared = @ptrCast(@alignCast(user.?));
    const win = g_popup_win.load(.acquire) orelse return;
    const font = win.textFont() catch return;
    var title: [96]u8 = undefined;
    var body: [512]u8 = undefined;
    var tn: usize = 0;
    var bn: usize = 0;
    if (!sh.held.swap(true, .acquire)) {
        tn = sh.tlen;
        bn = sh.blen;
        @memcpy(title[0..tn], sh.title[0..tn]);
        @memcpy(body[0..bn], sh.body[0..bn]);
        sh.unlock();
    }
    const x0: i32 = @intCast(content.x + 16);
    const pw: i32 = @as(i32, @intCast(content.w)) - 32;
    if (tn > 0)
        _ = hud_mod.Hud.drawWrapped(canvas, font, x0, @intCast(content.y + 26), pw, 15, .bold, zrame.Color.rgba(235, 220, 160, 0.95), title[0..tn], 20);
    if (bn > 0) {
        const scene_top = content.y + (content.h - scene_h) / 2;
        const by: i32 = @intCast(scene_top + scene_h + 24);
        _ = hud_mod.Hud.drawWrapped(canvas, font, x0, by, pw, 12, .regular, zrame.Color.rgba(200, 206, 214, 0.92), body[0..bn], 16);
    }
}

pub fn post(a: *App) void {
    const st = a.pluginState(@This());
    if (st.win) |w| {
        if (w.closed) close(a);
    }
    if (a.selected != st.last_sel) {
        st.last_sel = a.selected;
        if (a.selected >= 0) {
            open(a);
            updateText(a);
        } else close(a);
    }
    if (st.win != null) renderScene(a);
}

pub fn deinit(a: *App) void {
    close(a);
    const st = a.pluginState(@This());
    if (st.view) |v| v.destroy();
    if (st.instances.len > 0) a.gpa.free(st.instances);
    if (st.cpu) |*c| c.deinit();
}

fn open(a: *App) void {
    const st = a.pluginState(@This());
    if (st.win != null) return;
    const w = zrame.Window.init(a.gpa, .{
        .title = "inspector",
        .app_id = "dev.presenter.inspector",
        .width = pop_w,
        .height = pop_h,
        .context_menu = false,
        // Esc in this window's focus closes just the popup — the outermost
        // layer of the focused window, per the window hierarchy.
        .close_on_esc = true,
        .on_draw = popupDraw,
        .user = &st.shared,
    }) catch |e| {
        std.debug.print("inspector window unavailable: {s}\n", .{@errorName(e)});
        return;
    };
    g_popup_win.store(w, .release);
    st.thread = std.Thread.spawn(.{}, popupLoop, .{w}) catch null;
    st.win = w;
    // Prefer a zengine view (bloom, emissive spheres, tubes); fall back to the
    // software raster when there is no device.
    if (st.view == null) {
        if (a.gpu) |g| {
            st.view = g.createView(scene_w, scene_h, max_scene_instances, 0.6) catch |e| blk: {
                std.debug.print("inspector: zengine view unavailable ({s}) — software scene\n", .{@errorName(e)});
                break :blk null;
            };
            if (st.view != null and st.instances.len == 0)
                st.instances = a.gpa.alloc(ze.gpu_mesh.Instance, max_scene_instances) catch &.{};
        }
    }
    if (st.view == null and st.cpu == null) st.cpu = .{ .gpa = a.gpa };
}

fn close(a: *App) void {
    const st = a.pluginState(@This());
    const w = st.win orelse return;
    w.close();
    if (st.thread) |t| t.join();
    g_popup_win.store(null, .release);
    w.deinit();
    st.win = null;
    st.thread = null;
}

fn updateText(a: *App) void {
    const st = a.pluginState(@This());
    st.shared.lock();
    defer st.shared.unlock();
    const txt = D.inspect(a, @intCast(a.selected), &st.shared.title, &st.shared.body);
    st.shared.tlen = txt.title_len;
    st.shared.blen = txt.body_len;
}

/// A slow-orbiting mini-scene: every point dim, the selection and its
/// relation orbit lit in the descriptors' orbit colors.
fn renderScene(a: *App) void {
    const st = a.pluginState(@This());
    if (st.view != null) return renderSceneGpu(a);
    renderSceneCpu(a);
}

/// Camera for the mini-scene: a slow orbit around the system.
fn sceneEye(st: *State, dt: f32) [3]f32 {
    st.yaw += dt * 0.5;
    const dist: f32 = 4.2;
    return .{ dist * @cos(0.3) * @cos(st.yaw), dist * @sin(0.3), dist * @cos(0.3) * @sin(st.yaw) };
}

/// The orbit of the selection under the domain's first relation.
fn orbitOf(a: *App, sel: usize) [3]usize {
    var orbit = [3]usize{ sel, sel, sel };
    if (a.rel.len > 0) {
        orbit[1] = a.rel[0][sel];
        orbit[2] = a.rel[0][orbit[1]];
    }
    return orbit;
}

/// zengine path: emissive spheres for every point (dim), the selection and its
/// relation orbit lit, the orbit polygon as glowing tubes. Bloom does the rest.
fn renderSceneGpu(a: *App) void {
    const st = a.pluginState(@This());
    const w = st.win orelse return;
    const v = st.view orelse return;
    const g = a.gpu orelse return;
    if (st.instances.len == 0) return;
    const sel: usize = @intCast(st.last_sel);
    const orbit = orbitOf(a, sel);
    const eye = sceneEye(st, a.dt);

    var count: usize = 0;
    const terr = 2.0 * 4.2 * std.math.tan(0.4) / @as(f32, @floatFromInt(scene_h)) * 1.5;
    for (0..app_mod.n) |i| {
        var is_orbit = false;
        for (orbit) |o| {
            if (o == i) is_orbit = true;
        }
        const d = a.objectOf(i);
        var c: [3]f32 = undefined;
        var rad: f32 = point_radius;
        var glow: f32 = 0.05; // the rest of the system: barely lit context
        if (is_orbit) {
            const k = 0.55 + 0.75 * @max(0.0, @sin(a.anim * 2.6 - d.orbit_phase));
            c = d.orbit_rgb;
            rad = point_radius * (1.7 + 0.5 * k);
            glow = 1.4 + 2.4 * k;
            if (i == sel) glow += 1.2;
        } else {
            c = D.color_modes[0].color(&a.points[i], 0);
            for (&c) |*x| x.* *= 0.5;
        }
        st.instances[count] = .{
            .model = .{
                rad,          0,            0,            0,
                0,            rad,          0,            0,
                0,            0,            rad,          0,
                a.p3[i][0],   a.p3[i][1],   a.p3[i][2],   1,
            },
            .target_error = terr,
            .ref_range = g.sphere_range,
            .material = .{
                .base_color = .{ c[0] * 0.5, c[1] * 0.5, c[2] * 0.5 },
                .emissive = .{ c[0] * glow, c[1] * glow, c[2] * glow },
                .roughness = 0.38,
                .metallic = 0.0,
            },
        };
        count += 1;
    }
    // The orbit polygon, as luminous tubes.
    for (0..3) |k| {
        const ea = orbit[k];
        const eb = orbit[(k + 1) % 3];
        if (ea == eb) continue;
        const pa = a.p3[ea];
        const pb = a.p3[eb];
        const mid = [3]f32{ (pa[0] + pb[0]) * 0.5, (pa[1] + pb[1]) * 0.5, (pa[2] + pb[2]) * 0.5 };
        const dv = [3]f32{ (pb[0] - pa[0]) * 0.5, (pb[1] - pa[1]) * 0.5, (pb[2] - pa[2]) * 0.5 };
        const hl = @sqrt(dot(dv, dv));
        if (hl < 1e-5) continue;
        const dz = [3]f32{ dv[0] / hl, dv[1] / hl, dv[2] / hl };
        const ref = if (@abs(dz[1]) < 0.9) [3]f32{ 0, 1, 0 } else [3]f32{ 1, 0, 0 };
        const ax = norm(cross(dz, ref));
        const ay = cross(dz, ax);
        st.instances[count] = .{
            .model = .{
                ax[0] * tube_radius, ax[1] * tube_radius, ax[2] * tube_radius, 0,
                ay[0] * tube_radius, ay[1] * tube_radius, ay[2] * tube_radius, 0,
                dz[0] * hl,          dz[1] * hl,          dz[2] * hl,          0,
                mid[0],              mid[1],              mid[2],              1,
            },
            .target_error = terr,
            .ref_range = g.tube_range,
            .material = .{
                .base_color = .{ 0.3, 0.3, 0.3 },
                .emissive = .{ 0.9, 0.9, 0.9 },
                .roughness = 0.6,
                .metallic = 0.0,
            },
        };
        count += 1;
    }

    const proj = perspective(0.8, @as(f32, @floatFromInt(scene_w)) / @as(f32, @floatFromInt(scene_h)), 0.1, 100.0);
    const view_proj = matMul(proj, lookAt(eye, .{ 0, 0, 0 }, .{ 0, 1, 0 }));
    const img = &v.imgs[st.frame_no & 1];
    v.raster.render(.{
        .view_proj = view_proj,
        .instances = st.instances[0..count],
        .resident_pages = g.total_pages,
        .eye = eye,
        .sun_dir = .{ 0.4, 0.8, 0.45 },
        .clear_color = .{ 0.031, 0.036, 0.062, 1.0 },
        .shadows = false,
        .z_near = 0.1,
        .z_far = 100.0,
    }, img) catch {
        // Drop to the software scene for good.
        v.destroy();
        st.view = null;
        if (st.cpu == null) st.cpu = .{ .gpa = a.gpa };
        return;
    };
    if (!w.presentDmabuf(
        @intCast(st.frame_no & 1),
        img.fd,
        img.width,
        img.height,
        img.stride,
        ze.gpu.vk.drm_fourcc_abgr8888,
        ze.gpu.vk.drm_modifier_linear,
    )) {
        v.destroy();
        st.view = null;
        if (st.cpu == null) st.cpu = .{ .gpa = a.gpa };
        return;
    }
    st.frame_no += 1;
}

fn renderSceneCpu(a: *App) void {
    const st = a.pluginState(@This());
    const w = st.win orelse return;
    const cpu = &st.cpu.?;
    cpu.ensure(scene_w, scene_h) catch return;
    cpu.clear();
    const eye = sceneEye(st, a.dt);
    const fwd = norm(.{ -eye[0], -eye[1], -eye[2] });
    const right = norm(cross(fwd, .{ 0, 1, 0 }));
    const up = cross(right, fwd);
    const focal = @as(f32, @floatFromInt(scene_h)) * 0.5 / std.math.tan(0.4);
    const cx = @as(f32, @floatFromInt(scene_w)) * 0.5;
    const cy = @as(f32, @floatFromInt(scene_h)) * 0.5;
    var scr: [app_mod.n][3]f32 = undefined;
    var vis: [app_mod.n]bool = undefined;
    for (a.p3, 0..) |p, i| {
        const rel = [3]f32{ p[0] - eye[0], p[1] - eye[1], p[2] - eye[2] };
        const vz = dot(rel, fwd);
        vis[i] = vz > 0.15;
        if (!vis[i]) continue;
        scr[i] = .{ cx + focal * dot(rel, right) / vz, cy - focal * dot(rel, up) / vz, vz };
    }
    const sel: usize = @intCast(st.last_sel);
    const orbit = orbitOf(a, sel);
    // Orbit polygon as luminous edges.
    var jobs: [3]render_cpu.Edge = undefined;
    var nj: usize = 0;
    for (0..3) |k| {
        const ea = orbit[k];
        const eb = orbit[(k + 1) % 3];
        if (ea == eb or !vis[ea] or !vis[eb]) continue;
        jobs[nj] = .{
            .x0 = scr[ea][0],
            .y0 = scr[ea][1],
            .x1 = scr[eb][0],
            .y1 = scr[eb][1],
            .rgb = .{ 1, 1, 1 },
            .k0 = 90,
            .k1 = 90,
        };
        nj += 1;
    }
    var no_threads: [0]std.Thread = .{};
    cpu.drawEdges(jobs[0..nj], &no_threads);
    for (0..app_mod.n) |i| {
        if (!vis[i]) continue;
        const rad = std.math.clamp(0.035 * focal / scr[i][2], 1.0, 9.0);
        var is_orbit = false;
        for (orbit) |o| {
            if (o == i) is_orbit = true;
        }
        if (is_orbit) {
            const gc = a.objectOf(i).orbit_rgb;
            cpu.halo(scr[i][0], scr[i][1], rad * 4.0 + 6.0, gc, 40.0);
            cpu.disc(scr[i][0], scr[i][1], rad * 1.6, gc, 1.3);
            if (i == sel) cpu.ring(scr[i][0], scr[i][1], rad * 1.6 + 4.0, .{ 1, 1, 1 });
        } else {
            const c = D.color_modes[0].color(&a.points[i], 0);
            cpu.disc(scr[i][0], scr[i][1], rad * 0.6, .{ c[0] * 0.35, c[1] * 0.35, c[2] * 0.35 }, 1.0);
        }
    }
    w.presentRgba(scene_w, scene_h, cpu.fb);
}

fn matMul(x: [16]f32, y: [16]f32) [16]f32 {
    var c: [16]f32 = undefined;
    for (0..4) |col| {
        for (0..4) |row| {
            var s: f32 = 0;
            for (0..4) |k| s += x[k * 4 + row] * y[col * 4 + k];
            c[col * 4 + row] = s;
        }
    }
    return c;
}

fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) [16]f32 {
    const f = 1.0 / std.math.tan(fov_y * 0.5);
    var m = [_]f32{0} ** 16;
    m[0] = f / aspect;
    m[5] = -f; // Vulkan clip space: y down
    m[10] = far / (near - far);
    m[11] = -1;
    m[14] = (near * far) / (near - far);
    return m;
}

fn lookAt(eye: [3]f32, at: [3]f32, up: [3]f32) [16]f32 {
    const fwd = norm(.{ at[0] - eye[0], at[1] - eye[1], at[2] - eye[2] });
    const right = norm(cross(fwd, up));
    const u = cross(right, fwd);
    return .{
        right[0],         u[0],         -fwd[0],       0,
        right[1],         u[1],         -fwd[1],       0,
        right[2],         u[2],         -fwd[2],       0,
        -dot(right, eye), -dot(u, eye), dot(fwd, eye), 1,
    };
}

fn dot(x: [3]f32, y: [3]f32) f32 {
    return x[0] * y[0] + x[1] * y[1] + x[2] * y[2];
}
fn cross(x: [3]f32, y: [3]f32) [3]f32 {
    return .{ x[1] * y[2] - x[2] * y[1], x[2] * y[0] - x[0] * y[2], x[0] * y[1] - x[1] * y[0] };
}
fn norm(v: [3]f32) [3]f32 {
    const l = @max(@sqrt(dot(v, v)), 1e-12);
    return .{ v[0] / l, v[1] / l, v[2] / l };
}
