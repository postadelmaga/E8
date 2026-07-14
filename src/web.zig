//! The interactive paper, in a browser tab.
//!
//! Not a port: the same domain, the same plugins, the same software rasterizer.
//! What changes is who drives the frame. Natively, `main.zig` owns a `while
//! (!win.closed)` loop and hands finished frames to Wayland; here there is no
//! loop to own — the browser calls `zicroFrame` once per animation frame, which
//! calls this window's `on_draw`, and THAT is the frame. So the body of the
//! native loop lives in `draw` below: advance the clock, run the plugins, project
//! R^dim → R³, rasterize, and blit the result straight onto the canvas the
//! browser handed us. No presentRgba round trip, and no frame of lag.
//!
//! What is not here is what a tab does not have (see platform.zig): zengine (so
//! the software path, which was already the default), threads (so one band, which
//! at 240 points and 6720 edges is nothing), a filesystem (so the embedded deck),
//! and a second window (so no editor, no CSV export — both `native_only`).

const std = @import("std");
const zrame = @import("zrame");
const geom = @import("geom.zig");
const hud_mod = @import("hud.zig");
const render_cpu = @import("render_cpu.zig");
const app_mod = @import("app.zig");
const keys = @import("keys.zig");
const App = app_mod.App;
const D = app_mod.D;

const gpa = std.heap.wasm_allocator;

const fovy = std.math.degreesToRadians(45.0);
const point_radius: f32 = 0.045;

var g_win: *zrame.Window = undefined;
var g_hud: hud_mod.Hud = .{};
var g_app: App = undefined;
var g_cpu: render_cpu.Cpu = undefined;
var g_edge_jobs: []render_cpu.Edge = &.{};
var g_dot_jobs: []render_cpu.Dot = &.{};
var g_order: []u16 = &.{};
var g_booted = false;
var g_last_ms: f64 = 0;

// --- input (the same evdev codes the native build binds) ---------------------------

const Drag = struct {
    active: bool = false,
    last_x: f32 = 0,
    last_y: f32 = 0,
    moved: f32 = 0,
};
var drag: Drag = .{};
var g_pick: ?[2]f32 = null;

fn onMouse(_: *zrame.Window, event: zrame.MouseEvent, _: ?*anyopaque) bool {
    switch (event) {
        .motion => |m| {
            if (drag.active) {
                const dx = m.x - drag.last_x;
                const dy = m.y - drag.last_y;
                drag.moved += @abs(dx) + @abs(dy);
                app_mod.addClampF32(&app_mod.cam_yaw, dx * 0.008, -std.math.inf(f32), std.math.inf(f32));
                app_mod.addClampF32(&app_mod.cam_pitch, dy * 0.008, -1.45, 1.45);
            }
            drag.last_x = m.x;
            drag.last_y = m.y;
            return drag.active;
        },
        .button => |b| {
            if (b.button != 272) return false; // BTN_LEFT, as on Wayland
            if (b.state == 1) {
                drag.active = true;
                drag.moved = 0;
                return true;
            }
            if (drag.active) {
                drag.active = false;
                if (drag.moved < 5.0) g_pick = .{ drag.last_x, drag.last_y };
                return true;
            }
            return false;
        },
        .leave => {
            drag.active = false;
            return false;
        },
    }
}

fn onScroll(_: *zrame.Window, axis: u32, value: i32, _: ?*anyopaque) void {
    if (axis != 0 or value == 0) return;
    const m = @exp(@as(f32, @floatFromInt(value)) / 256.0 * 0.02);
    app_mod.mulClampF32(&app_mod.cam_dist, m, 2.0, 24.0);
}

fn onKey(_: *zrame.Window, key: u32, state: u32, _: ?*anyopaque) void {
    if (state == 0) return;
    // No key queue and no second thread to hand it to: the browser delivers keys
    // on the same thread the frame runs on, so a key IS handled here.
    if (app_mod.dispatchKey(&g_app, key)) return;
    _ = keys.escape; // Esc has nothing to close in a tab: the window is the page
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
fn norm3(v: [3]f32) [3]f32 {
    const l = @max(@sqrt(dot3(v, v)), 1e-12);
    return .{ v[0] / l, v[1] / l, v[2] / l };
}

/// One frame — the body of main.zig's loop, called by the browser.
fn draw(canvas: *zrame.Canvas, content: zrame.Rect, user: ?*anyopaque) void {
    if (!g_booted) return;
    const hud: *hud_mod.Hud = @ptrCast(@alignCast(user.?));

    // The scene fills the content rect, minus the panel's gutter and the two HUD
    // bands — the same layout the native build computes from the window size.
    const rw = std.math.clamp(content.w -| 16 -| g_app.reserve_w, 320, 1920) / 4 * 4;
    const rh = std.math.clamp(content.h -| 110, 240, 1200) / 4 * 4;
    hud.frame_w.store(rw, .monotonic);
    hud.frame_h.store(rh, .monotonic);

    g_app.dt = 1.0 / 60.0; // the browser paces us; a frame is a frame
    g_app.anim += g_app.dt;
    g_app.pick = g_pick;
    g_pick = null;

    app_mod.dispatchFrame(&g_app);
    if (g_app.reset_camera) {
        g_app.reset_camera = false;
        app_mod.storeF32(&app_mod.cam_yaw, 0.65);
        app_mod.storeF32(&app_mod.cam_pitch, 0.35);
        app_mod.storeF32(&app_mod.cam_dist, 4.2);
    }
    if (g_app.renorm_basis) geom.orthonormalize(&g_app.basis);

    const n_pts = g_app.count();
    for (g_app.points, 0..) |*r, i| {
        const p = geom.project(&g_app.basis, r.v);
        g_app.p3[i] = p;
        const vis2 = dot3(p, p);
        g_app.hidden[i] = @sqrt(std.math.clamp(D.radius2 - vis2, 0.0, D.radius2)) / @sqrt(D.radius2);
    }

    const yaw = app_mod.loadF32(&app_mod.cam_yaw);
    const pitch = app_mod.loadF32(&app_mod.cam_pitch);
    const dist = app_mod.loadF32(&app_mod.cam_dist);
    const eye = [3]f32{
        dist * @cos(pitch) * @cos(yaw),
        dist * @sin(pitch),
        dist * @cos(pitch) * @sin(yaw),
    };
    const fwd = norm3(.{ -eye[0], -eye[1], -eye[2] });
    const right = norm3(cross3(fwd, .{ 0, 1, 0 }));
    const up = cross3(right, fwd);
    const focal = @as(f32, @floatFromInt(rh)) * 0.5 / std.math.tan(fovy * 0.5);
    const cx = @as(f32, @floatFromInt(rw)) * 0.5;
    const cy = @as(f32, @floatFromInt(rh)) * 0.5;

    // The scene is blitted at this origin, so a click in canvas space has to be
    // measured from it or the pick would land on a different root.
    const ox: f32 = @floatFromInt(content.x + (content.w -| g_app.reserve_w -| rw) / 2);
    const oy: f32 = @floatFromInt(content.y + 78);
    if (g_app.pick) |xy| g_app.pick = .{ xy[0] - ox, xy[1] - oy };

    for (g_app.p3, 0..) |p, i| {
        const rel = [3]f32{ p[0] - eye[0], p[1] - eye[1], p[2] - eye[2] };
        const vz = dot3(rel, fwd);
        if (vz < 0.15) {
            g_app.vis[i] = false;
            continue;
        }
        g_app.vis[i] = true;
        g_app.scr[i] = .{
            cx + focal * dot3(rel, right) / vz,
            cy - focal * dot3(rel, up) / vz,
            vz,
        };
    }

    app_mod.dispatchPost(&g_app);
    g_app.info_dirty = false;
    for (0..n_pts) |i| g_app.visuals[i] = app_mod.rootVisual(&g_app, i);
    const pairs = app_mod.edgePairs(&g_app);

    g_cpu.ensure(rw, rh) catch return;
    g_cpu.clear();
    var n_jobs: usize = 0;
    for (pairs) |ed| {
        if (n_jobs == g_edge_jobs.len) break;
        const a = ed[0];
        const b = ed[1];
        if (!g_app.vis[a] or !g_app.vis[b]) continue;
        const ev = app_mod.edgeVisual(&g_app, a, b) orelse continue;
        g_edge_jobs[n_jobs] = .{
            .x0 = g_app.scr[a][0],
            .y0 = g_app.scr[a][1],
            .x1 = g_app.scr[b][0],
            .y1 = g_app.scr[b][1],
            .rgb = ev.color,
            .k0 = ev.k * std.math.clamp(3.4 / g_app.scr[a][2], 0.25, 1.5),
            .k1 = ev.k * std.math.clamp(3.4 / g_app.scr[b][2], 0.25, 1.5),
        };
        n_jobs += 1;
    }
    g_cpu.drawEdges(g_edge_jobs[0..n_jobs]);

    for (0..n_pts) |i| g_order[i] = @intCast(i);
    const S = struct {
        fn farFirst(zz: [][3]f32, lhs: u16, rhs: u16) bool {
            return zz[lhs][2] > zz[rhs][2];
        }
    };
    std.sort.pdq(u16, g_order, g_app.scr, S.farFirst);
    var n_dots: usize = 0;
    for (g_order) |i| {
        if (!g_app.vis[i]) continue;
        const v = &g_app.visuals[i];
        const rad = std.math.clamp(point_radius * focal / g_app.scr[i][2], 1.6, 15.0) * v.radius;
        var d = render_cpu.Dot{
            .x = g_app.scr[i][0],
            .y = g_app.scr[i][1],
            .rad = rad,
            .rgb = v.color,
            .bright = v.bright,
        };
        if (v.halo) |h| {
            d.halo_r = rad * h.radius_mul + 6.0;
            d.halo_rgb = h.rgb;
            d.halo_k = h.k;
        }
        if (v.ring) |rgb| {
            d.ring_r = rad + 4.0;
            d.ring_rgb = rgb;
        }
        g_dot_jobs[n_dots] = d;
        n_dots += 1;
    }
    g_cpu.drawDots(g_dot_jobs[0..n_dots]);

    // The frame goes straight onto the browser's canvas, under the HUD.
    canvas.blitRgba(@intFromFloat(ox), @intFromFloat(oy), g_cpu.fb, rw, rh, .{});
    hud_mod.Hud.onDraw(canvas, content, hud);

    // The status line, at the same half-second the native build uses.
    if (g_app.anim - g_last_status > 0.5 or g_app.status_dirty) {
        g_last_status = g_app.anim;
        var buf: [256]u8 = undefined;
        hud.setLine1(app_mod.buildStatus(&g_app, &buf));
        g_app.status_dirty = false;
    }
}
var g_last_status: f32 = 0;

/// wasm has no main: JS calls this once.
export fn zicroBoot() void {
    if (g_booted) return;

    const points = app_mod.loadPoints(gpa, undefined) catch return; // generated: no io
    const edges = D.buildEdges(gpa, points) catch return;

    g_win = zrame.Window.init(gpa, .{
        .title = D.title,
        .app_id = D.app_id,
        .width = 1200,
        .height = 760,
        // NO titlebar in a tab. The browser window IS the window — a glass frame
        // here would be a window drawn inside a window, complete with a border,
        // a shadow and rounded corners eating the figure's edges. Asking for no
        // titlebar makes zrame's web backend collapse the chrome to an opaque,
        // full-canvas fill of `style.glass`.
        .titlebar = false,
        // And that fill is EXACTLY the black the rasterizer clears the scene to. Any
        // other colour, however dark, redraws the frame it was meant to remove: the
        // figure's buffer becomes a card of one black laid on a desk of another, and
        // the seam between them is a border again — just a quieter one.
        .style = .{ .glass = zrame.Color.rgba(0, 0, 0, 1.0) },
        .close_on_esc = false,
        .on_key = onKey,
        .on_scroll = onScroll,
        .on_mouse = onMouse,
        .on_draw = draw,
        .user = &g_hud,
    }) catch return;
    g_hud.win = g_win;

    g_app = .{
        .gpa = gpa,
        .io = undefined, // a tab reads no files: nothing in the web registry uses it
        .win = g_win,
        .hud = &g_hud,
        .points = points,
        .edges = edges,
        .basis = D.presets[0].basis(0),
    };
    g_app.initTables() catch return;

    g_cpu = .{ .gpa = gpa };
    const max_pairs = @max(edges.len, points.len);
    g_edge_jobs = gpa.alloc(render_cpu.Edge, max_pairs + 64) catch return;
    g_dot_jobs = gpa.alloc(render_cpu.Dot, points.len) catch return;
    g_order = gpa.alloc(u16, points.len) catch return;

    app_mod.dispatchInit(&g_app);
    g_booted = true;
}
