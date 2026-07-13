//! Presenter framework core — window + input plumbing, the orbit camera, the
//! dim-D → 3D projection, and the two rasterizers (zengine GPU mesh raster
//! with bloom, multithreaded additive software fallback). Everything else is
//! a plugin supplied by the active domain package (src/demos/<demo>/,
//! selected with -Ddemo=; the Lisi E8 interactive paper is the default and
//! reference domain). See src/app.zig for the hook contract.

const std = @import("std");
const ze = @import("zengine");
const zrame = @import("zrame");
const geom = @import("geom.zig");
const hud_mod = @import("hud.zig");
const render_cpu = @import("render_cpu.zig");
const render_gpu = @import("render_gpu.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const D = app_mod.D;

const gpu_w = app_mod.frame_w;
const gpu_h = app_mod.frame_h;
const fovy = std.math.degreesToRadians(45.0);
const point_radius: f32 = 0.045;
const tube_radius: f32 = 0.009;

// --- window-thread input (forwarded to the render thread) ---------------------------

var g_click: std.atomic.Value(u64) = .init(0); // packed (x:f32,y:f32) bits
var g_click_flag: std.atomic.Value(bool) = .init(false);
// Staged frame size, for the window thread's hit test of press events.
var g_frame_w: std.atomic.Value(u32) = .init(gpu_w);
var g_frame_h: std.atomic.Value(u32) = .init(gpu_h);

const Drag = struct {
    active: bool = false,
    last_x: f32 = 0,
    last_y: f32 = 0,
    moved: f32 = 0,
};
var drag: Drag = .{}; // window thread only

fn onMouse(_: *zrame.Window, event: zrame.MouseEvent, _: ?*anyopaque) bool {
    switch (event) {
        .motion => |m| {
            if (drag.active) {
                const dx = m.x - drag.last_x;
                const dy = m.y - drag.last_y;
                drag.moved += @abs(dx) + @abs(dy);
                app_mod.storeF32(&app_mod.cam_yaw, app_mod.loadF32(&app_mod.cam_yaw) + dx * 0.008);
                app_mod.storeF32(&app_mod.cam_pitch, std.math.clamp(
                    app_mod.loadF32(&app_mod.cam_pitch) + dy * 0.008,
                    -1.45,
                    1.45,
                ));
                drag.last_x = m.x;
                drag.last_y = m.y;
                return true;
            }
            drag.last_x = m.x;
            drag.last_y = m.y;
            return false;
        },
        .button => |b| {
            if (b.button != 272) return false; // BTN_LEFT
            if (b.state == 1) {
                const fw: f32 = @floatFromInt(g_frame_w.load(.monotonic));
                const fh: f32 = @floatFromInt(g_frame_h.load(.monotonic));
                if (drag.last_x >= 0 and drag.last_y >= 0 and drag.last_x < fw and drag.last_y < fh) {
                    drag.active = true;
                    drag.moved = 0;
                    return true; // ours: don't let the glass start a window move
                }
                return false;
            }
            if (drag.active) {
                drag.active = false;
                if (drag.moved < 5.0) { // a click, not a drag → pick
                    const xb: u64 = @as(u32, @bitCast(drag.last_x));
                    const yb: u64 = @as(u32, @bitCast(drag.last_y));
                    g_click.store(xb << 32 | yb, .monotonic);
                    g_click_flag.store(true, .monotonic);
                }
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
    const d = app_mod.loadF32(&app_mod.cam_dist) * @exp(@as(f32, @floatFromInt(value)) / 256.0 * 0.02);
    app_mod.storeF32(&app_mod.cam_dist, std.math.clamp(d, 2.0, 24.0));
}

fn onKey(_: *zrame.Window, key: u32, state: u32, _: ?*anyopaque) void {
    if (state == 0) return;
    app_mod.pushKey(key); // plugins handle keys on the render thread
}

fn windowLoop(win: *zrame.Window) void {
    win.run() catch {};
}

// --- column-major mat4 helpers (as in zengine's mesh_view) ---------------------------

fn matMul(a: [16]f32, b: [16]f32) [16]f32 {
    var c: [16]f32 = undefined;
    for (0..4) |col| {
        for (0..4) |row| {
            var s: f32 = 0;
            for (0..4) |k| s += a[k * 4 + row] * b[col * 4 + k];
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
    const fwd = norm3(.{ at[0] - eye[0], at[1] - eye[1], at[2] - eye[2] });
    const right = norm3(cross3(fwd, up));
    const u = cross3(right, fwd);
    return .{
        right[0],          u[0],          -fwd[0],        0,
        right[1],          u[1],          -fwd[1],        0,
        right[2],          u[2],          -fwd[2],        0,
        -dot3(right, eye), -dot3(u, eye), dot3(fwd, eye), 1,
    };
}

fn norm3(v: [3]f32) [3]f32 {
    const l = @max(@sqrt(dot3(v, v)), 1e-12);
    return .{ v[0] / l, v[1] / l, v[2] / l };
}
fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The software renderer is the default: it is fast enough (multithreaded),
    // adapts to the live window size, and is immune to compositor quirks.
    // `--gpu` opts into zengine's mesh raster (emissive spheres + bloom).
    var use_gpu = false;
    // The iterator outlives the parse: `app_mod.cli` keeps slices into argv, and
    // a domain that reads a file consults them all the way through startup.
    var arg_it = try std.process.Args.Iterator.initAllocator(init.args, gpa);
    defer arg_it.deinit();
    {
        _ = arg_it.skip();
        while (arg_it.next()) |raw| {
            const a = std.mem.sliceTo(raw, 0);
            if (std.mem.eql(u8, a, "--gpu")) {
                use_gpu = true;
            } else if (std.mem.startsWith(u8, a, "--coords=")) {
                app_mod.cli.coords = a["--coords=".len..];
            } else if (std.mem.startsWith(u8, a, "--class=")) {
                app_mod.cli.class = a["--class=".len..];
            } else if (std.mem.startsWith(u8, a, "--label=")) {
                app_mod.cli.label = a["--label=".len..];
            } else if (std.mem.startsWith(u8, a, "--knn=")) {
                app_mod.cli.knn = std.fmt.parseInt(u32, a["--knn=".len..], 10) catch 6;
            } else if (std.mem.startsWith(u8, a, "--deck=")) {
                app_mod.cli.deck = a["--deck=".len..];
            } else if (std.mem.eql(u8, a, "--editor")) {
                app_mod.cli.editor = true;
            } else if (!std.mem.startsWith(u8, a, "--")) {
                app_mod.cli.file = a;
            }
        }
    }

    // --- the point system (domain-supplied: generated, or read from a file) --------
    const points = try app_mod.loadPoints(gpa, io);
    defer app_mod.unloadPoints(gpa, points);
    const n_pts = points.len;
    const edges = try D.buildEdges(gpa, points);
    defer gpa.free(edges);
    const max_instances: u32 = @intCast(n_pts + edges.len + 16);

    std.debug.print(
        \\{s} — {d} points, {d} edges (presenter framework)
        \\  H opens the shortcut card — every key this build binds, this demo's included.
        \\  P next slide · Backspace back · K kiosk · F fullscreen · Esc closes the top layer
        \\  drag orbit · scroll zoom · click pick (opens the inspector) · 1..{d} presets
        \\
    , .{ D.name, n_pts, edges.len, D.presets.len });
    for (D.actions) |act| std.debug.print("  {s}\n", .{act.help});

    // --- window --------------------------------------------------------------------
    var hud: hud_mod.Hud = .{};
    const win = try zrame.Window.init(gpa, .{
        .title = D.title,
        .app_id = D.app_id,
        .width = app_mod.win_w,
        .height = app_mod.win_h,
        // Esc is layered: the slides plugin closes the panel first, the app last.
        .close_on_esc = false,
        .on_key = onKey,
        .on_scroll = onScroll,
        .on_mouse = onMouse,
        .on_draw = hud_mod.Hud.onDraw,
        .user = &hud,
    });
    defer win.deinit();
    hud.win = win;
    var win_thread = try std.Thread.spawn(.{}, windowLoop, .{win});

    // --- the app seam: shared state + plugins -----------------------------------------
    var app = App{
        .gpa = gpa,
        .io = io,
        .win = win,
        .hud = &hud,
        .points = points,
        .edges = edges,
        .basis = D.presets[0].basis(0),
    };
    try app.initTables();
    defer app.deinitTables();

    // --- renderers -------------------------------------------------------------------
    // The zengine device is created whenever Vulkan/dmabuf allows it, even when
    // the main window renders in software: plugins (the inspector's mini-scene)
    // ask it for their own `View`.
    var gpu3d: ?*render_gpu.Gpu3d = render_gpu.Gpu3d.create(gpa, io) catch |e| blk: {
        std.debug.print("zengine unavailable ({s}) — software render everywhere\n", .{@errorName(e)});
        break :blk null;
    };
    var main_view: ?*render_gpu.View = null;
    if (use_gpu) {
        if (gpu3d) |g| main_view = g.createView(gpu_w, gpu_h, max_instances, 0.45) catch |e| blk: {
            std.debug.print("GPU view unavailable ({s}) — software render\n", .{@errorName(e)});
            break :blk null;
        };
    }
    defer {
        if (main_view) |v| v.destroy();
        if (gpu3d) |g| g.destroy();
    }
    var cpu = render_cpu.Cpu{ .gpa = gpa };
    defer cpu.deinit();
    var instances: []ze.gpu_mesh.Instance = try gpa.alloc(ze.gpu_mesh.Instance, max_instances);
    defer gpa.free(instances);
    const edge_jobs = try gpa.alloc(render_cpu.Edge, edges.len + 64);
    defer gpa.free(edge_jobs);
    const workers = @max(std.Thread.getCpuCount() catch 4, 2);
    const threads = try gpa.alloc(std.Thread, workers - 1);
    defer gpa.free(threads);
    std.debug.print("render path: {s} · zengine device: {s}\n", .{
        if (main_view != null) "GPU (zengine mesh raster + bloom, dmabuf)" else "CPU (software)",
        if (gpu3d != null) "yes (inspector scenes use it)" else "no",
    });

    // Plugins can now reach the zengine device (the inspector renders its
    // mini-scene on it even when the main window is on the software path).
    app.gpu = gpu3d;
    app_mod.dispatchInit(&app);

    const order = try gpa.alloc(u16, n_pts); // CPU painter's order
    defer gpa.free(order);
    // GPU resize debounce: rebuild the raster once the size settles.
    var gpu_want_w: u32 = gpu_w;
    var gpu_want_h: u32 = gpu_h;
    var gpu_want_since: f32 = 0;

    var frame_no: u64 = 0;
    var fps_frames: u32 = 0;
    var fps_last: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &fps_last);
    var prev_ts = fps_last;

    while (!win.closed) {
        var now: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &now);
        app.dt = @floatCast(@as(f64, @floatFromInt(now.sec - prev_ts.sec)) +
            @as(f64, @floatFromInt(now.nsec - prev_ts.nsec)) / 1e9);
        prev_ts = now;
        // Animation clock for the effects (wraps hourly, f32-safe).
        app.anim = @as(f32, @floatFromInt(@mod(now.sec, 3600))) +
            @as(f32, @floatFromInt(now.nsec)) / 1e9;
        hud.tick(@as(i128, now.sec) * 1_000_000_000 + now.nsec);

        // --- input → plugins -----------------------------------------------------------
        while (app_mod.popKey()) |code| _ = app_mod.dispatchKey(&app, code);
        if (g_click_flag.swap(false, .monotonic)) {
            const packed_xy = g_click.load(.monotonic);
            app.pick = .{
                @bitCast(@as(u32, @truncate(packed_xy >> 32))),
                @bitCast(@as(u32, @truncate(packed_xy))),
            };
        }
        app_mod.dispatchFrame(&app);
        if (app.reset_camera) {
            app.reset_camera = false;
            app_mod.storeF32(&app_mod.cam_yaw, 0.65);
            app_mod.storeF32(&app_mod.cam_pitch, 0.35);
            app_mod.storeF32(&app_mod.cam_dist, 4.2);
        }
        geom.orthonormalize(&app.basis);

        // --- project dim-D → 3D ------------------------------------------------------
        for (app.points, 0..) |*r, i| {
            const p = geom.project(&app.basis, r.v);
            app.p3[i] = p;
            const vis2 = dot3(p, p);
            app.hidden[i] = @sqrt(std.math.clamp(D.radius2 - vis2, 0.0, D.radius2)) / @sqrt(D.radius2);
        }

        // --- camera --------------------------------------------------------------------
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

        // Render resolution: both paths follow the window, minus whatever
        // glass a plugin reserved (the particle panel).
        var rw: u32 = gpu_w;
        var rh: u32 = gpu_h;
        {
            const cw = hud.content_w.load(.monotonic);
            const ch = hud.content_h.load(.monotonic);
            if (cw > 0) rw = std.math.clamp(cw -| 16 -| app.reserve_w, 320, 1600) / 16 * 16;
            if (ch > 0) rh = std.math.clamp(ch -| 110, 240, 1000) / 16 * 16;
        }
        if (main_view) |v| {
            if (rw != v.w or rh != v.h) {
                // Debounce, then rebuild just the main VIEW at the settled size
                // (the device and the popup's view are untouched; zrame
                // recreates the slot wl_buffers when the size changes).
                if (gpu_want_w != rw or gpu_want_h != rh) {
                    gpu_want_w = rw;
                    gpu_want_h = rh;
                    gpu_want_since = app.anim;
                } else if (app.anim - gpu_want_since > 0.35) {
                    v.destroy();
                    main_view = gpu3d.?.createView(rw, rh, max_instances, 0.45) catch |e| blk: {
                        std.debug.print("GPU resize failed ({s}) — software render\n", .{@errorName(e)});
                        break :blk null;
                    };
                }
            }
            if (main_view) |v2| {
                rw = v2.w;
                rh = v2.h;
            }
        }
        g_frame_w.store(rw, .monotonic);
        g_frame_h.store(rh, .monotonic);
        hud.frame_w.store(rw, .monotonic);
        hud.frame_h.store(rh, .monotonic);
        const focal = @as(f32, @floatFromInt(rh)) * 0.5 / std.math.tan(fovy * 0.5);
        const cx = @as(f32, @floatFromInt(rw)) * 0.5;
        const cy = @as(f32, @floatFromInt(rh)) * 0.5;

        // Screen positions (used by the CPU rasterizer and by picking).
        for (app.p3, 0..) |p, i| {
            const rel = [3]f32{ p[0] - eye[0], p[1] - eye[1], p[2] - eye[2] };
            const vz = dot3(rel, fwd);
            if (vz < 0.15) {
                app.vis[i] = false;
                continue;
            }
            app.vis[i] = true;
            app.scr[i] = .{
                cx + focal * dot3(rel, right) / vz,
                cy - focal * dot3(rel, up) / vz,
                vz,
            };
        }

        // --- plugins: picking, HUD text, panel ------------------------------------------
        app_mod.dispatchPost(&app);
        app.info_dirty = false;

        // --- resolve visuals -------------------------------------------------------------
        for (0..n_pts) |i| app.visuals[i] = app_mod.rootVisual(&app, i);
        const pairs = app_mod.edgePairs(&app);

        // --- draw ---------------------------------------------------------------------------
        if (main_view) |mv| {
            var count: usize = 0;
            const terr = 2.0 * dist * std.math.tan(fovy * 0.5) / @as(f32, @floatFromInt(rh)) * 1.5;
            for (0..n_pts) |i| {
                const v = &app.visuals[i];
                const rad = point_radius * v.radius;
                instances[count] = .{
                    .model = .{
                        rad, 0, 0, 0,
                        0, rad, 0, 0,
                        0, 0, rad, 0,
                        app.p3[i][0], app.p3[i][1], app.p3[i][2], 1,
                    },
                    .target_error = terr,
                    .ref_range = gpu3d.?.sphere_range,
                    .material = .{
                        .base_color = .{ v.color[0] * 0.6, v.color[1] * 0.6, v.color[2] * 0.6 },
                        .emissive = .{ v.color[0] * v.glow, v.color[1] * v.glow, v.color[2] * v.glow },
                        .roughness = 0.38,
                        .metallic = 0.0,
                    },
                };
                count += 1;
            }
            for (pairs) |ed| {
                const ev = app_mod.edgeVisual(&app, ed[0], ed[1]) orelse continue;
                const a = ed[0];
                const b = ed[1];
                const mid = [3]f32{
                    (app.p3[a][0] + app.p3[b][0]) * 0.5,
                    (app.p3[a][1] + app.p3[b][1]) * 0.5,
                    (app.p3[a][2] + app.p3[b][2]) * 0.5,
                };
                const d = [3]f32{
                    (app.p3[b][0] - app.p3[a][0]) * 0.5,
                    (app.p3[b][1] - app.p3[a][1]) * 0.5,
                    (app.p3[b][2] - app.p3[a][2]) * 0.5,
                };
                const hl = @sqrt(dot3(d, d));
                if (hl < 1e-5) continue;
                const dz = [3]f32{ d[0] / hl, d[1] / hl, d[2] / hl };
                const ref = if (@abs(dz[1]) < 0.9) [3]f32{ 0, 1, 0 } else [3]f32{ 1, 0, 0 };
                const ax = norm3(cross3(dz, ref));
                const ay = cross3(dz, ax);
                const rt = tube_radius * ev.width;
                instances[count] = .{
                    .model = .{
                        ax[0] * rt, ax[1] * rt, ax[2] * rt, 0,
                        ay[0] * rt, ay[1] * rt, ay[2] * rt, 0,
                        dz[0] * hl, dz[1] * hl, dz[2] * hl, 0,
                        mid[0],     mid[1],     mid[2],     1,
                    },
                    .target_error = terr,
                    .ref_range = gpu3d.?.tube_range,
                    .material = .{
                        .base_color = .{ ev.color[0] * 0.3, ev.color[1] * 0.3, ev.color[2] * 0.3 },
                        .emissive = .{ ev.color[0] * ev.glow, ev.color[1] * ev.glow, ev.color[2] * ev.glow },
                        .roughness = 0.6,
                        .metallic = 0.0,
                    },
                };
                count += 1;
            }

            while (win.videoBusy() and !win.closed) {
                var ts = std.os.linux.timespec{ .sec = 0, .nsec = 200_000 };
                _ = std.os.linux.nanosleep(&ts, null);
            }
            const proj = perspective(fovy, @as(f32, @floatFromInt(rw)) / @as(f32, @floatFromInt(rh)), 0.1, 100.0);
            const view_proj = matMul(proj, lookAt(eye, .{ 0, 0, 0 }, .{ 0, 1, 0 }));
            const img = &mv.imgs[frame_no & 1];
            var gpu_ok = true;
            mv.raster.render(.{
                .view_proj = view_proj,
                .instances = instances[0..count],
                .resident_pages = gpu3d.?.total_pages,
                .eye = eye,
                .sun_dir = .{ 0.4, 0.8, 0.45 },
                // Black, like the software path: a particle is only as visible as
                // the space behind it is empty, and the old blue-grey deep-space
                // wash was eating the darkest classes.
                .clear_color = .{ 0.0, 0.0, 0.0, 1.0 },
                .shadows = false,
                .z_near = 0.1,
                .z_far = 100.0,
            }, img) catch |e| {
                std.debug.print("GPU render failed ({s}) — software render from here on\n", .{@errorName(e)});
                gpu_ok = false;
            };
            if (gpu_ok and !win.presentDmabuf(
                @intCast(frame_no & 1),
                img.fd,
                img.width,
                img.height,
                img.stride,
                ze.gpu.vk.drm_fourcc_abgr8888,
                ze.gpu.vk.drm_modifier_linear,
            )) {
                std.debug.print("compositor without dmabuf — software render from here on\n", .{});
                gpu_ok = false;
            }
            if (!gpu_ok) {
                main_view.?.destroy();
                main_view = null; // the device stays for the inspector's scenes
            }
        } else {
            // --- software path ---------------------------------------------------------
            try cpu.ensure(rw, rh);
            cpu.clear();
            var n_jobs: usize = 0;
            for (pairs) |ed| {
                const a = ed[0];
                const b = ed[1];
                if (!app.vis[a] or !app.vis[b]) continue;
                const ev = app_mod.edgeVisual(&app, a, b) orelse continue;
                edge_jobs[n_jobs] = .{
                    .x0 = app.scr[a][0],
                    .y0 = app.scr[a][1],
                    .x1 = app.scr[b][0],
                    .y1 = app.scr[b][1],
                    .rgb = ev.color,
                    .k0 = ev.k * std.math.clamp(3.4 / app.scr[a][2], 0.25, 1.5),
                    .k1 = ev.k * std.math.clamp(3.4 / app.scr[b][2], 0.25, 1.5),
                };
                n_jobs += 1;
            }
            cpu.drawEdges(edge_jobs[0..n_jobs], threads);
            // Points back-to-front.
            for (0..n_pts) |i| order[i] = @intCast(i);
            const S = struct {
                fn farFirst(zz: [][3]f32, lhs: u16, rhs: u16) bool {
                    return zz[lhs][2] > zz[rhs][2];
                }
            };
            std.sort.pdq(u16, order, app.scr, S.farFirst);
            for (order) |i| {
                if (!app.vis[i]) continue;
                const v = &app.visuals[i];
                const rad = std.math.clamp(point_radius * focal / app.scr[i][2], 1.6, 15.0) * v.radius;
                if (v.halo) |h|
                    cpu.halo(app.scr[i][0], app.scr[i][1], rad * h.radius_mul + 6.0, h.rgb, h.k);
                cpu.disc(app.scr[i][0], app.scr[i][1], rad, v.color, v.bright);
                if (v.ring) |rgb|
                    cpu.ring(app.scr[i][0], app.scr[i][1], rad + 4.0, rgb);
            }
            win.presentRgba(rw, rh, cpu.fb);
            // Pace the software path: no point rendering faster than the display.
            var ts = std.os.linux.timespec{ .sec = 0, .nsec = 4_000_000 };
            _ = std.os.linux.nanosleep(&ts, null);
        }
        frame_no += 1;

        // --- HUD status line -----------------------------------------------------------
        fps_frames += 1;
        const el = @as(f64, @floatFromInt(now.sec - fps_last.sec)) +
            @as(f64, @floatFromInt(now.nsec - fps_last.nsec)) / 1e9;
        if (el >= 0.5 or app.status_dirty) {
            var buf: [160]u8 = undefined;
            hud.setLine1(app_mod.buildStatus(&app, &buf));
            app.status_dirty = false;
            fps_frames = 0;
            fps_last = now;
        }
    }
    app_mod.dispatchDeinit(&app);
    win_thread.join();
}
