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

const pop_w: u32 = 700;
const pop_h: u32 = 860;
const scene_w: u32 = 640;
const scene_h: u32 = 380;
/// zrame centers a `video_fit = .native` frame in the content rect, so the scene
/// sits in the middle and the two text bands around it are equal: the card reads
/// centered when each band centers its own block.
const band: i32 = (@as(i32, pop_h) - @as(i32, scene_h)) / 2;
const pad: i32 = 22;

/// Text that FITS. A domain writes its own inspect text and the framework has no
/// say in how much of it there is — the M-theory demo spends five lines on a root
/// and prints its ten integer coordinates — so the card cannot assume a size and
/// hope. It measures at the preferred size and steps down until the block fits its
/// band, which is what keeps long text inside the card instead of spilling over
/// the scene. (The window itself cannot grow: zrame fixes its size at creation.)
/// {point size, line height}, largest first.
const title_steps = .{ .{ 23, 30 }, .{ 20, 26 }, .{ 18, 24 } };
const body_steps = .{ .{ 19, 26 }, .{ 17, 23 }, .{ 15, 21 }, .{ 14, 19 } };

/// Draw `txt` centered in the band [`band_top`, +`band`], at the largest of
/// `steps` whose wrapped block fits — the smallest one if none do (a block a
/// little tall beats a block that is not there). The type stays comptime because
/// `drawWrapped` takes its size and style that way.
fn drawFitted(
    canvas: *zrame.Canvas,
    font: anytype,
    x: i32,
    band_top: i32,
    w: i32,
    comptime steps: anytype,
    comptime style: @TypeOf(.enum_literal),
    color: zrame.Color,
    txt: []const u8,
) void {
    const avail = band - 2 * pad;
    inline for (steps, 0..) |s, k| {
        const h = hud_mod.Hud.wrappedHeight(font, w, s[0], style, txt, s[1]);
        if (h <= avail or k == steps.len - 1) {
            const y = band_top + @divTrunc(band - h, 2) + s[0];
            _ = hud_mod.Hud.drawWrapped(canvas, font, x, y, w, s[0], style, color, txt, s[1]);
            return;
        }
    }
}

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
    /// Scratch for the software mini-scene, one entry per point.
    scr: [][3]f32 = &.{},
    vis: []bool = &.{},
    shared: Shared = .{},
    last_sel: i32 = -1,
    yaw: f32 = 0.8,
};

/// Scene budget: every point as a sphere + the orbit polygon as tubes.
fn maxSceneInstances(a: *App) u32 {
    const extra: usize = if (@hasDecl(D, "extra_parts")) D.extra_parts else 0;
    return @intCast(a.count() + 8 + extra);
}
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
    const x0: i32 = @as(i32, @intCast(content.x)) + pad;
    const pw: i32 = @as(i32, @intCast(content.w)) - 2 * pad;
    const top: i32 = @intCast(content.y);
    // The scene lands centered in the content rect (zrame's rule); the title
    // block centers in the band above it, the description in the band below.
    const scene_top = top + @divTrunc(@as(i32, @intCast(content.h)) - @as(i32, scene_h), 2);
    if (tn > 0)
        drawFitted(canvas, font, x0, top, pw, title_steps, .bold, zrame.Color.rgba(240, 226, 170, 0.97), title[0..tn]);
    if (bn > 0)
        drawFitted(canvas, font, x0, scene_top + @as(i32, scene_h), pw, body_steps, .regular, zrame.Color.rgba(216, 223, 233, 0.96), body[0..bn]);
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
    if (st.scr.len > 0) a.gpa.free(st.scr);
    if (st.vis.len > 0) a.gpa.free(st.vis);
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
        // Nearly opaque: the main window sits right behind the popup, and a
        // frosted-but-see-through card made the text fight the figure.
        .style = .{ .glass = zrame.Color.rgba(15, 16, 26, 0.94), .sheen = 0.16, .specular = 0.2 },
        // The mini-scene is a PANEL inside the card, not the card's whole content:
        // it is presented at its native size, centered, so the two text bands
        // around it stay glass. (A window whose content IS the render wants the
        // default, .fill.)
        .video_fit = .native,
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
            st.view = g.createView(scene_w, scene_h, maxSceneInstances(a), 0.6) catch |e| blk: {
                std.debug.print("inspector: zengine view unavailable ({s}) — software scene\n", .{@errorName(e)});
                break :blk null;
            };
            if (st.view != null and st.instances.len == 0)
                st.instances = a.gpa.alloc(ze.gpu_mesh.Instance, maxSceneInstances(a)) catch &.{};
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
    const dist: f32 = 3.8;
    return .{ dist * @cos(0.3) * @cos(st.yaw), dist * @sin(0.3), dist * @cos(0.3) * @sin(st.yaw) };
}

/// The system's own points would be black on the black scene: they wear the
/// same glass atmosphere the main view gives its dark points.
const atmosphere = @import("atmosphere.zig");
const twinkle = atmosphere.twinkle;

fn glassTint(base: [3]f32, k: f32) [3]f32 {
    return atmosphere.glassTint(base, 0.7, k);
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
    for (0..a.count()) |i| {
        var is_orbit = false;
        for (orbit) |o| {
            if (o == i) is_orbit = true;
        }
        const d = a.objectOf(i);
        var c: [3]f32 = undefined;
        var rad: f32 = point_radius;
        var glow: f32 = 0.05;
        if (is_orbit) {
            const k = 0.55 + 0.75 * @max(0.0, @sin(a.anim * 2.6 - d.orbit_phase));
            c = d.orbit_rgb;
            rad = point_radius * (1.7 + 0.5 * k);
            glow = 1.4 + 2.4 * k;
            if (i == sel) glow += 1.2;
        } else {
            const k = twinkle(a.anim, i);
            c = glassTint(D.color_modes[0].color(&a.points[i], 0), k);
            rad = point_radius * (0.85 + 0.3 * k);
            glow = 0.30 + 0.55 * k;
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

    // The domain's own mesh, if it has one to show. The framework places nothing
    // and colors nothing here — it just makes room for the science's own object.
    // (For the M-theory demo this is the Calabi–Yau the selected root is curled
    // up inside; the framework does not know that, and does not need to.)
    if (comptime @hasDecl(D, "sceneExtra")) {
        for (g.extra_ranges, 0..) |range, part| {
            const x = D.sceneExtra(a, sel, part) orelse continue;
            st.instances[count] = .{
                .model = x.model,
                .target_error = terr,
                .ref_range = range,
                .material = .{
                    .base_color = x.base_color,
                    .emissive = x.emissive,
                    .roughness = x.roughness,
                    .metallic = x.metallic,
                },
            };
            count += 1;
        }
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
        .clear_color = .{ 0, 0, 0, 1.0 },
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
    if (st.scr.len != a.count()) {
        if (st.scr.len > 0) a.gpa.free(st.scr);
        if (st.vis.len > 0) a.gpa.free(st.vis);
        st.scr = a.gpa.alloc([3]f32, a.count()) catch return;
        st.vis = a.gpa.alloc(bool, a.count()) catch return;
    }
    const eye = sceneEye(st, a.dt);
    const fwd = norm(.{ -eye[0], -eye[1], -eye[2] });
    const right = norm(cross(fwd, .{ 0, 1, 0 }));
    const up = cross(right, fwd);
    const focal = @as(f32, @floatFromInt(scene_h)) * 0.5 / std.math.tan(0.4);
    const cx = @as(f32, @floatFromInt(scene_w)) * 0.5;
    const cy = @as(f32, @floatFromInt(scene_h)) * 0.5;
    const scr = st.scr;
    const vis = st.vis;
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
    for (0..a.count()) |i| {
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
            const k = twinkle(a.anim, i);
            const c = glassTint(D.color_modes[0].color(&a.points[i], 0), k);
            cpu.halo(scr[i][0], scr[i][1], rad * 2.4 + 3.0, c, 10.0 * k);
            cpu.disc(scr[i][0], scr[i][1], rad * 0.7, c, 0.7 + 0.5 * k);
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
