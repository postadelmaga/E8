//! E8 Explorer — an interactive research tool for the E8 root system in the
//! spirit of Garrett Lisi's "An Exceptionally Simple Theory of Everything"
//! (arXiv:0711.0770) and his Elementary Particle Explorer.
//!
//! The 240 roots (and their 6720 minimal-angle edges) live in R⁸; the view is an
//! orthonormal 8D→3D projection that you can point at the Coxeter (Petrie) plane
//! — the iconic 30-fold figure — at Lisi-style charge axes, or anywhere else by
//! rotating the basis through the hidden dimensions. Roots are classified per
//! Lisi's Table 9 (arXiv:0711.0770): gravity ω, electroweak W/B, frame-Higgs eφ,
//! gluons, colored xΦ, and three 64-root fermion generations related by the
//! triality rotation of §2.4.2 / the CPTt Group (arXiv:2407.02497).
//!
//! Controls (evdev, printed at startup too):
//!   drag        orbit the 3D camera · scroll: zoom
//!   click       pick the nearest root (details in the HUD; its 56 neighbors light up)
//!   1 / 2 / 3   projection preset: Coxeter plane · physics charge axes · lattice e1e2e3
//!   4 / 5 / 6   paper views: G2 plane (g³,g⁸) · F4 graviweak plane · F4↔G2 rotation
//!               (in preset 6, ←/→ sweep the F4↔G2 angle and T animates it)
//!   ← / →       rotate the view basis through the current 8D plane · Tab: next plane
//!   T           8D tumble (slow rotation through three hidden planes)
//!   Space       3D auto-spin
//!   E           edges: all → triality partners → selection-only → none
//!   C           color mode: physics classes → generations → so(16) split → hidden-depth
//!   F           filter: all → bosons → fermions → gen I/II/III → leptons → quarks → d4 blocks
//!   G           jump the selection to its triality partner (gen I → II → III → I)
//!   P           paper atlas: step through configurations matching figures of
//!               arXiv:0711.0770 and arXiv:2407.02497
//!   R           reset view · X: export e8_roots.csv (full system + projection) · Esc closes
//!
//! Window: zrame glass. Render: zengine GPU mesh raster (emissive spheres +
//! edge tubes + bloom, dmabuf zero-copy) with a software fallback that needs
//! nothing but the CPU. `--cpu` forces the fallback.

const std = @import("std");
const ze = @import("zengine");
const zrame = @import("zrame");
const e8 = @import("e8.zig");
const hud_mod = @import("hud.zig");
const render_cpu = @import("render_cpu.zig");
const render_gpu = @import("render_gpu.zig");

const gpu_w: u32 = 1152;
const gpu_h: u32 = 648;
const fovy = std.math.degreesToRadians(45.0);
const max_instances: u32 = e8.n_roots + e8.n_edges + 16;
const point_radius: f32 = 0.045;
const tube_radius: f32 = 0.009;

// --- shared state: window thread writes, render thread reads ------------------------

var g_yaw: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 0.65)));
var g_pitch: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 0.35)));
var g_dist: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 4.2)));
var g_preset: std.atomic.Value(u32) = .init(1); // pending preset request; 0 = none
var g_tumble: std.atomic.Value(bool) = .init(false);
var g_spin: std.atomic.Value(bool) = .init(false);
var g_edge_mode: std.atomic.Value(u32) = .init(2); // 0 none · 1 selection · 2 all
var g_color_mode: std.atomic.Value(u32) = .init(0);
var g_filter: std.atomic.Value(u32) = .init(0);
var g_rot_mrad: std.atomic.Value(i32) = .init(0); // pending 8D rotation, milliradians
var g_plane: std.atomic.Value(u32) = .init(0); // index into planes[]
var g_export: std.atomic.Value(bool) = .init(false);
var g_tri_jump: std.atomic.Value(bool) = .init(false);
var g_tour: std.atomic.Value(bool) = .init(false);
var g_reset: std.atomic.Value(bool) = .init(false);
var g_click: std.atomic.Value(u64) = .init(0); // packed (x:f32,y:f32) bits
var g_click_flag: std.atomic.Value(bool) = .init(false);
// Staged frame size, for the window thread's hit test of press events.
var g_frame_w: std.atomic.Value(u32) = .init(gpu_w);
var g_frame_h: std.atomic.Value(u32) = .init(gpu_h);

/// The 8D coordinate planes the ←/→ rotation walks through (Tab cycles).
const planes = [_][2]usize{
    .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 },
    .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 },
};

const filter_names = [_][]const u8{
    "all 240",     "bosons (48)",  "fermions (192)",   "gen I (64)",
    "gen II (64)", "gen III (64)", "leptons (48)",     "quarks (144)",
    "graviweak d4 (24)", "color d4 (24)",
};

/// Curated configurations matching figures in Lisi's papers (key P steps
/// through them; the description lands in the HUD detail line).
const Tour = struct {
    desc: []const u8,
    preset: u32,
    color: u32, // e8.ColorMode
    edge: u32, // 0 none · 1 selection · 2 all · 3 triality
    filter: u32,
    tumble: bool = false,
};
const tours = [_]Tour{
    .{ .desc = "0711.0770 Fig 2 — E8 Petrie plane, lines between triality partners", .preset = 1, .color = 0, .edge = 3, .filter = 0 },
    .{ .desc = "0711.0770 Table 2 — G2 strong charges: gluon hexagon, quark triangles", .preset = 4, .color = 0, .edge = 0, .filter = 0 },
    .{ .desc = "0711.0770 Tables 5-6 — F4 graviweak plane with triality links", .preset = 5, .color = 1, .edge = 3, .filter = 0 },
    .{ .desc = "0711.0770 Figs 3-4 — rotating F4 <-> G2 (E6 = central 72 at the G2 end)", .preset = 6, .color = 0, .edge = 0, .filter = 0, .tumble = true },
    .{ .desc = "0711.0770 sec 2.4.1 — new xPhi bosons, split in depth by their w charge", .preset = 4, .color = 0, .edge = 0, .filter = 9 },
    .{ .desc = "2407.02497 Tables 1-2 — spin(1,3) boost/spin weights (lattice e1 = wT, e2 = wS)", .preset = 3, .color = 2, .edge = 0, .filter = 0 },
    .{ .desc = "2407.02497 Fig 2 — 192 fermion states, 3 generations joined by triality", .preset = 2, .color = 1, .edge = 3, .filter = 2 },
};

fn passesFilter(r: *const e8.Root, filter: u32) bool {
    return switch (filter) {
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

fn loadF32(a: *std.atomic.Value(u32)) f32 {
    return @bitCast(a.load(.monotonic));
}
fn storeF32(a: *std.atomic.Value(u32), v: f32) void {
    a.store(@bitCast(v), .monotonic);
}

// --- window-thread input ------------------------------------------------------------

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
                storeF32(&g_yaw, loadF32(&g_yaw) + dx * 0.008);
                storeF32(&g_pitch, std.math.clamp(loadF32(&g_pitch) + dy * 0.008, -1.45, 1.45));
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
    const d = loadF32(&g_dist) * @exp(@as(f32, @floatFromInt(value)) / 256.0 * 0.02);
    storeF32(&g_dist, std.math.clamp(d, 2.0, 24.0));
}

fn onKey(_: *zrame.Window, key: u32, state: u32, _: ?*anyopaque) void {
    if (state == 0) return;
    switch (key) {
        2, 3, 4, 5, 6, 7 => g_preset.store(key - 1, .monotonic), // KEY_1..6
        20 => g_tumble.store(!g_tumble.load(.monotonic), .monotonic), // T
        57 => g_spin.store(!g_spin.load(.monotonic), .monotonic), // Space
        // E: all → triality → selection → none → all
        18 => g_edge_mode.store(switch (g_edge_mode.load(.monotonic)) {
            2 => @as(u32, 3),
            3 => 1,
            1 => 0,
            else => 2,
        }, .monotonic),
        25 => g_tour.store(true, .monotonic), // P: paper atlas
        46 => g_color_mode.store((g_color_mode.load(.monotonic) + 1) % 4, .monotonic), // C
        34 => g_tri_jump.store(true, .monotonic), // G: selection → triality partner
        33 => g_filter.store((g_filter.load(.monotonic) + 1) % @as(u32, filter_names.len), .monotonic), // F
        15 => g_plane.store((g_plane.load(.monotonic) + 1) % @as(u32, planes.len), .monotonic), // Tab
        105 => _ = g_rot_mrad.fetchAdd(-60, .monotonic), // ←
        106 => _ = g_rot_mrad.fetchAdd(60, .monotonic), // →
        19 => g_reset.store(true, .monotonic), // R
        45 => g_export.store(true, .monotonic), // X
        else => {},
    }
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

fn presetBasis(preset: u32) e8.Basis {
    return switch (preset) {
        2 => e8.physicsBasis(),
        3 => e8.coordBasis(),
        4 => e8.g2Basis(),
        5 => e8.f4Basis(),
        6 => e8.lisiRotationBasis(0),
        else => e8.coxeterBasis(),
    };
}

/// Root color under the current mode, dimmed when filtered out.
fn rootColor(r: *const e8.Root, mode: u32, hidden_t: f32, pass: bool) [3]f32 {
    var c = e8.rootRgb(r, @enumFromInt(mode), hidden_t);
    if (!pass) {
        c[0] *= 0.13;
        c[1] *= 0.13;
        c[2] *= 0.13;
    }
    return c;
}

/// Emissive pulse for the theory's special particles. The 18 xΦ bosons — Lisi's
/// new-particle prediction (proton decay mediators) — pulse as a wave phased by
/// their w charge, so the x1/x2/x3 generations light up in sequence; the 12
/// triality-fixed roots (W±, four eφ, the gluon hexagon) breathe slowly.
/// Everything else stays at 1.
fn specialPulse(r: *const e8.Root, self_partner: bool, t: f32) f32 {
    if (r.class == .color_x) return 0.85 + 0.55 * @sin(t * 2.2 + r.w * 2.0 * std.math.pi / 3.0);
    if (self_partner) return 0.90 + 0.35 * @sin(t * 1.1);
    return 1.0;
}

/// Lighthouse pulse that runs around a selected triality orbit: each generation
/// peaks in turn (phase 2π·gen/3), making the I → II → III cycle visible.
fn orbitPulse(gen: u8, t: f32) f32 {
    const ph = @as(f32, @floatFromInt(gen)) * 2.0 * std.math.pi / 3.0;
    return 0.55 + 0.75 * @max(0.0, @sin(t * 2.6 - ph));
}

fn fmtHalf(buf: []u8, v: f32) []const u8 {
    // Roots only ever hold 0, ±½, ±1 — print them the way a physicist writes them.
    if (v == 0) return std.fmt.bufPrint(buf, "0", .{}) catch "0";
    if (v == 0.5) return std.fmt.bufPrint(buf, "½", .{}) catch "";
    if (v == -0.5) return std.fmt.bufPrint(buf, "-½", .{}) catch "";
    return std.fmt.bufPrint(buf, "{d:.0}", .{v}) catch "";
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_alloc: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_alloc.deinit();
    const gpa = debug_alloc.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // The software renderer is the default: it is fast enough (multithreaded),
    // adapts to the live window size, and is immune to the dmabuf/fractional-
    // scale placement quirk. `--gpu` opts into zengine's mesh raster (emissive
    // spheres + bloom) — best on scale-1 displays.
    var use_gpu = false;
    {
        var arg_it = try std.process.Args.Iterator.initAllocator(init.args, gpa);
        defer arg_it.deinit();
        _ = arg_it.skip();
        while (arg_it.next()) |a| {
            if (std.mem.eql(u8, std.mem.sliceTo(a, 0), "--gpu")) use_gpu = true;
        }
    }

    // --- the root system ---------------------------------------------------------
    const roots = e8.generate();
    const edges = try e8.buildEdges(gpa, &roots);
    defer gpa.free(edges);
    // Per-root neighbor lists (56 each) for the selection halo.
    var neighbors: [e8.n_roots][56]u16 = undefined;
    {
        var deg = [_]u8{0} ** e8.n_roots;
        for (edges) |e| {
            neighbors[e[0]][deg[e[0]]] = e[1];
            neighbors[e[1]][deg[e[1]]] = e[0];
            deg[e[0]] += 1;
            deg[e[1]] += 1;
        }
    }
    // Triality partner of every root (Lisi §2.4.2): G cycles gen I → II → III.
    const triality = e8.buildTriality(&roots);
    // Triality-orbit links, drawable as an edge mode ("lines drawn between
    // triality partners" — 0711.0770 Fig 2, 2407.02497 Figs 1–2). Each 3-cycle
    // contributes its three sides once; the 12 fixed roots contribute none.
    var tri_edges_store: [e8.n_roots][2]u16 = undefined;
    var n_tri_edges: usize = 0;
    for (triality, 0..) |j, i| {
        if (j != i) {
            tri_edges_store[n_tri_edges] = .{ @intCast(i), j };
            n_tri_edges += 1;
        }
    }
    const tri_edges = tri_edges_store[0..n_tri_edges];
    var basis = e8.coxeterBasis();
    var cur_preset: u32 = 1;
    var lisi_theta: f32 = 0; // F4↔G2 sweep angle, preset 6
    var tour_idx: usize = tours.len - 1;

    std.debug.print(
        \\E8 Explorer — 240 roots, 6720 edges (Lisi Table 9 labeling + triality)
        \\  drag orbit · scroll zoom · click pick · 1/2/3 Coxeter|physics|lattice
        \\  4/5/6 G2 plane | F4 plane | F4<->G2 rotation · P paper atlas
        \\  ←/→ rotate 8D plane (Tab cycles; sweeps F4<->G2 in preset 6) · T tumble
        \\  Space spin · E edges (all|triality|selection|off) · C colors · F filter
        \\  G triality partner · R reset · X export CSV · Esc quit
        \\
    , .{});

    // --- window --------------------------------------------------------------------
    var hud: hud_mod.Hud = .{};
    const win = try zrame.Window.init(gpa, .{
        .title = "E8 explorer — Lisi atlas (1..6 presets, P paper tour, click a root)",
        .app_id = "dev.e8.explorer",
        .width = gpu_w + 48,
        .height = gpu_h + 120,
        .on_key = onKey,
        .on_scroll = onScroll,
        .on_mouse = onMouse,
        .on_draw = hud_mod.Hud.onDraw,
        .user = &hud,
    });
    defer win.deinit();
    hud.win = win;
    var win_thread = try std.Thread.spawn(.{}, windowLoop, .{win});

    // --- renderers -------------------------------------------------------------------
    var gpu3d: ?*render_gpu.Gpu3d = null;
    if (use_gpu) {
        gpu3d = render_gpu.Gpu3d.create(gpa, io, gpu_w, gpu_h, max_instances) catch |e| blk: {
            std.debug.print("GPU path unavailable ({s}) — software render\n", .{@errorName(e)});
            break :blk null;
        };
    }
    defer if (gpu3d) |g| g.destroy();
    var cpu = render_cpu.Cpu{ .gpa = gpa };
    defer cpu.deinit();
    var instances: []ze.gpu_mesh.Instance = try gpa.alloc(ze.gpu_mesh.Instance, max_instances);
    defer gpa.free(instances);
    const edge_jobs = try gpa.alloc(render_cpu.Edge, e8.n_edges + 56);
    defer gpa.free(edge_jobs);
    const workers = @max(std.Thread.getCpuCount() catch 4, 2);
    const threads = try gpa.alloc(std.Thread, workers - 1);
    defer gpa.free(threads);
    std.debug.print("render path: {s}\n", .{if (gpu3d != null) "GPU (zengine mesh raster + bloom, dmabuf)" else "CPU (software)"});

    // --- per-frame scratch -----------------------------------------------------------
    var p3: [e8.n_roots][3]f32 = undefined; // projected world position
    var hidden: [e8.n_roots]f32 = undefined; // |component outside the basis| / √2
    var scr: [e8.n_roots][3]f32 = undefined; // CPU path: screen x,y + view depth
    var vis: [e8.n_roots]bool = undefined;
    var order: [e8.n_roots]u16 = undefined;
    var selected: i32 = -1;

    var frame_no: u64 = 0;
    var fps_frames: u32 = 0;
    var fps_last: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &fps_last);
    var prev_ts = fps_last;
    var status_dirty = true;
    var info_dirty = true;
    var legend_mode: u32 = 99;

    while (!win.closed) {
        var now: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(.MONOTONIC, &now);
        const dt: f32 = @floatCast(@as(f64, @floatFromInt(now.sec - prev_ts.sec)) +
            @as(f64, @floatFromInt(now.nsec - prev_ts.nsec)) / 1e9);
        prev_ts = now;
        hud.tick(@as(i128, now.sec) * 1_000_000_000 + now.nsec);
        // Animation clock for the particle effects (wraps hourly, f32-safe).
        const anim: f32 = @as(f32, @floatFromInt(@mod(now.sec, 3600))) +
            @as(f32, @floatFromInt(now.nsec)) / 1e9;

        // --- consume input -----------------------------------------------------------
        if (g_reset.swap(false, .monotonic)) {
            lisi_theta = 0;
            basis = presetBasis(cur_preset);
            storeF32(&g_yaw, 0.65);
            storeF32(&g_pitch, 0.35);
            storeF32(&g_dist, 4.2);
            status_dirty = true;
        }
        const preset_req = g_preset.swap(0, .monotonic);
        if (preset_req != 0) {
            cur_preset = preset_req;
            lisi_theta = 0;
            basis = presetBasis(cur_preset);
            status_dirty = true;
        }
        // P: step through the paper atlas — a figure-matched view + colors +
        // edges + filter, with the reference in the HUD detail line.
        if (g_tour.swap(false, .monotonic)) {
            tour_idx = (tour_idx + 1) % tours.len;
            const t = &tours[tour_idx];
            cur_preset = t.preset;
            lisi_theta = 0;
            basis = presetBasis(t.preset);
            g_color_mode.store(t.color, .monotonic);
            g_edge_mode.store(t.edge, .monotonic);
            g_filter.store(t.filter, .monotonic);
            g_tumble.store(t.tumble, .monotonic);
            hud.setLine2(t.desc);
            status_dirty = true;
        }
        const rot = g_rot_mrad.swap(0, .monotonic);
        const plane = planes[g_plane.load(.monotonic)];
        if (cur_preset == 6) {
            // F4↔G2 rotation (0711.0770 Figs 3–4): ←/→ sweep θ, T animates.
            if (rot != 0) lisi_theta += @as(f32, @floatFromInt(rot)) / 1000.0;
            if (g_tumble.load(.monotonic)) lisi_theta += 0.15 * dt;
            basis = e8.lisiRotationBasis(lisi_theta);
        } else {
            if (rot != 0)
                e8.rotateBasis(&basis, plane[0], plane[1], @as(f32, @floatFromInt(rot)) / 1000.0);
            if (g_tumble.load(.monotonic)) {
                e8.rotateBasis(&basis, 0, 4, 0.16 * dt);
                e8.rotateBasis(&basis, 2, 6, 0.11 * dt);
                e8.rotateBasis(&basis, 1, 7, 0.07 * dt);
            }
        }
        if (g_spin.load(.monotonic))
            storeF32(&g_yaw, loadF32(&g_yaw) + 0.25 * dt);
        e8.orthonormalize(&basis);

        const edge_mode = g_edge_mode.load(.monotonic);
        const color_mode = g_color_mode.load(.monotonic);
        const filter = g_filter.load(.monotonic);
        // Mode 3 swaps the 6720 lattice edges for the 228 triality-orbit links.
        const draw_edges: []const [2]u16 = if (edge_mode == 3) tri_edges else edges;

        // --- project 8D → 3D ---------------------------------------------------------
        for (&roots, 0..) |*r, i| {
            const p = e8.project(&basis, r.v);
            p3[i] = p;
            const vis2 = dot3(p, p);
            hidden[i] = @sqrt(std.math.clamp(2.0 - vis2, 0.0, 2.0)) / @sqrt(2.0);
        }

        // --- camera --------------------------------------------------------------------
        const yaw = loadF32(&g_yaw);
        const pitch = loadF32(&g_pitch);
        const dist = loadF32(&g_dist);
        const eye = [3]f32{
            dist * @cos(pitch) * @cos(yaw),
            dist * @sin(pitch),
            dist * @cos(pitch) * @sin(yaw),
        };
        const fwd = norm3(.{ -eye[0], -eye[1], -eye[2] });
        const right = norm3(cross3(fwd, .{ 0, 1, 0 }));
        const up = cross3(right, fwd);

        // Render resolution: the GPU path is fixed; the CPU path follows the window.
        var rw: u32 = gpu_w;
        var rh: u32 = gpu_h;
        if (gpu3d == null) {
            const cw = hud.content_w.load(.monotonic);
            const ch = hud.content_h.load(.monotonic);
            if (cw > 0) rw = std.math.clamp(cw -| 16, 320, 1600) / 16 * 16;
            if (ch > 0) rh = std.math.clamp(ch -| 110, 240, 1000) / 16 * 16;
        }
        g_frame_w.store(rw, .monotonic);
        g_frame_h.store(rh, .monotonic);
        const focal = @as(f32, @floatFromInt(rh)) * 0.5 / std.math.tan(fovy * 0.5);
        const cx = @as(f32, @floatFromInt(rw)) * 0.5;
        const cy = @as(f32, @floatFromInt(rh)) * 0.5;

        // Screen positions (used by both the CPU rasterizer and picking).
        for (p3, 0..) |p, i| {
            const rel = [3]f32{ p[0] - eye[0], p[1] - eye[1], p[2] - eye[2] };
            const vz = dot3(rel, fwd);
            if (vz < 0.15) {
                vis[i] = false;
                continue;
            }
            vis[i] = true;
            scr[i] = .{
                cx + focal * dot3(rel, right) / vz,
                cy - focal * dot3(rel, up) / vz,
                vz,
            };
        }

        // --- picking ---------------------------------------------------------------------
        if (g_click_flag.swap(false, .monotonic)) {
            const packed_xy = g_click.load(.monotonic);
            const mx: f32 = @bitCast(@as(u32, @truncate(packed_xy >> 32)));
            const my: f32 = @bitCast(@as(u32, @truncate(packed_xy)));
            var best: i32 = -1;
            var best_d: f32 = 18.0 * 18.0;
            var best_z: f32 = 1e30;
            for (scr, 0..) |s, i| {
                if (!vis[i]) continue;
                const dx = s[0] - mx;
                const dy = s[1] - my;
                const d2 = dx * dx + dy * dy;
                if (d2 < best_d and (d2 < best_d * 0.5 or s[2] < best_z)) {
                    best = @intCast(i);
                    best_d = d2;
                    best_z = s[2];
                }
            }
            selected = if (best == selected) -1 else best; // click again to deselect
            info_dirty = true;
        }

        // --- triality jump -----------------------------------------------------------
        if (g_tri_jump.swap(false, .monotonic) and selected >= 0) {
            selected = triality[@intCast(selected)];
            info_dirty = true;
        }

        // --- CSV export --------------------------------------------------------------------
        if (g_export.swap(false, .monotonic)) {
            const csv = try e8.buildCsv(gpa, &roots, &basis);
            defer gpa.free(csv);
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "e8_roots.csv", .data = csv }) catch |e| {
                std.debug.print("export failed: {s}\n", .{@errorName(e)});
            };
            std.debug.print("exported e8_roots.csv ({d} roots, current projection)\n", .{e8.n_roots});
        }

        // --- draw ---------------------------------------------------------------------------
        const sel_u: usize = if (selected >= 0) @intCast(selected) else 0;
        if (gpu3d) |g| {
            var count: usize = 0;
            const terr = 2.0 * dist * std.math.tan(fovy * 0.5) / @as(f32, @floatFromInt(rh)) * 1.5;
            // Root spheres.
            for (&roots, 0..) |*r, i| {
                const pass = passesFilter(r, filter);
                const is_sel = selected >= 0 and i == sel_u;
                const is_orbit = selected >= 0 and !is_sel and
                    (i == triality[sel_u] or i == triality[triality[sel_u]]);
                var is_nn = false;
                if (selected >= 0 and !is_sel) {
                    for (neighbors[sel_u]) |n| {
                        if (n == i) {
                            is_nn = true;
                            break;
                        }
                    }
                }
                var c = rootColor(r, color_mode, hidden[i], pass);
                const pulse = specialPulse(r, triality[i] == i, anim);
                var rad: f32 = if (is_sel) point_radius * 1.9 else if (is_nn) point_radius * 1.25 else point_radius;
                var glow: f32 = if (is_sel) 2.2 + 0.7 * @sin(anim * 3.0) else if (is_nn) 1.5 else if (pass) 0.85 else 0.04;
                if (pass and !is_sel and !is_orbit) {
                    // xΦ wave / triality-fixed breathing (bloom does the rest).
                    glow *= pulse;
                    rad *= 0.96 + 0.06 * pulse;
                }
                if (is_orbit) {
                    // The selection's triality partners flare in generation
                    // colors, peaking in I → II → III order.
                    const gc = e8.rootRgb(r, .generation, 0);
                    const k = orbitPulse(r.gen, anim);
                    c = .{ 0.35 * c[0] + 0.65 * gc[0], 0.35 * c[1] + 0.65 * gc[1], 0.35 * c[2] + 0.65 * gc[2] };
                    glow = 1.1 + 1.9 * k;
                    rad = point_radius * (1.35 + 0.35 * k);
                }
                instances[count] = .{
                    .model = .{
                        rad, 0, 0, 0,
                        0, rad, 0, 0,
                        0, 0, rad, 0,
                        p3[i][0], p3[i][1], p3[i][2], 1,
                    },
                    .target_error = terr,
                    .ref_range = g.sphere_range,
                    .material = .{
                        .base_color = .{ c[0] * 0.6, c[1] * 0.6, c[2] * 0.6 },
                        .emissive = .{ c[0] * glow, c[1] * glow, c[2] * glow },
                        .roughness = 0.38,
                        .metallic = 0.0,
                    },
                };
                count += 1;
            }
            // Edge tubes.
            if (edge_mode != 0) {
                for (draw_edges) |ed| {
                    const a = ed[0];
                    const b = ed[1];
                    const involves_sel = selected >= 0 and (a == sel_u or b == sel_u);
                    if (edge_mode == 1 and !involves_sel) continue;
                    const pa = passesFilter(&roots[a], filter);
                    const pb = passesFilter(&roots[b], filter);
                    const mid = [3]f32{
                        (p3[a][0] + p3[b][0]) * 0.5,
                        (p3[a][1] + p3[b][1]) * 0.5,
                        (p3[a][2] + p3[b][2]) * 0.5,
                    };
                    const d = [3]f32{
                        (p3[b][0] - p3[a][0]) * 0.5,
                        (p3[b][1] - p3[a][1]) * 0.5,
                        (p3[b][2] - p3[a][2]) * 0.5,
                    };
                    const hl = @sqrt(dot3(d, d));
                    if (hl < 1e-5) continue;
                    const dz = [3]f32{ d[0] / hl, d[1] / hl, d[2] / hl };
                    const ref = if (@abs(dz[1]) < 0.9) [3]f32{ 0, 1, 0 } else [3]f32{ 1, 0, 0 };
                    const ax = norm3(cross3(dz, ref));
                    const ay = cross3(dz, ax);
                    const ca = rootColor(&roots[a], color_mode, hidden[a], pa);
                    const cb2 = rootColor(&roots[b], color_mode, hidden[b], pb);
                    var c = [3]f32{ (ca[0] + cb2[0]) * 0.5, (ca[1] + cb2[1]) * 0.5, (ca[2] + cb2[2]) * 0.5 };
                    // The few triality links glow brighter than the edge bundle.
                    const base_glow: f32 = if (edge_mode == 3) 0.45 else 0.16;
                    var glow: f32 = if (pa and pb) base_glow else 0.015;
                    if (involves_sel) {
                        c = .{ 1, 1, 1 };
                        glow = 1.1;
                    }
                    const rt: f32 = if (involves_sel) tube_radius * 1.6 else tube_radius;
                    instances[count] = .{
                        .model = .{
                            ax[0] * rt, ax[1] * rt, ax[2] * rt, 0,
                            ay[0] * rt, ay[1] * rt, ay[2] * rt, 0,
                            dz[0] * hl, dz[1] * hl, dz[2] * hl, 0,
                            mid[0],     mid[1],     mid[2],     1,
                        },
                        .target_error = terr,
                        .ref_range = g.tube_range,
                        .material = .{
                            .base_color = .{ c[0] * 0.3, c[1] * 0.3, c[2] * 0.3 },
                            .emissive = .{ c[0] * glow, c[1] * glow, c[2] * glow },
                            .roughness = 0.6,
                            .metallic = 0.0,
                        },
                    };
                    count += 1;
                }
            }

            while (win.videoBusy() and !win.closed) {
                var ts = std.os.linux.timespec{ .sec = 0, .nsec = 200_000 };
                _ = std.os.linux.nanosleep(&ts, null);
            }
            const proj = perspective(fovy, @as(f32, @floatFromInt(gpu_w)) / gpu_h, 0.1, 100.0);
            const view_proj = matMul(proj, lookAt(eye, .{ 0, 0, 0 }, .{ 0, 1, 0 }));
            const img = &g.imgs[frame_no & 1];
            var gpu_ok = true;
            g.raster.render(.{
                .view_proj = view_proj,
                .instances = instances[0..count],
                .resident_pages = g.total_pages,
                .eye = eye,
                .sun_dir = .{ 0.4, 0.8, 0.45 },
                // Midpoint of the software path's deep-space gradient, so the
                // two render paths read as the same scene.
                .clear_color = .{ 0.039, 0.047, 0.082, 1.0 },
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
                gpu3d.?.destroy();
                gpu3d = null;
            }
        } else {
            // --- software path ---------------------------------------------------------
            try cpu.ensure(rw, rh);
            cpu.clear();
            var n_jobs: usize = 0;
            if (edge_mode == 2 or edge_mode == 3) {
                const full: f32 = if (edge_mode == 3) 80.0 else 30.0;
                for (draw_edges) |ed| {
                    const a = ed[0];
                    const b = ed[1];
                    if (!vis[a] or !vis[b]) continue;
                    const pa = passesFilter(&roots[a], filter);
                    const pb = passesFilter(&roots[b], filter);
                    const ca = rootColor(&roots[a], color_mode, hidden[a], pa);
                    const cb2 = rootColor(&roots[b], color_mode, hidden[b], pb);
                    const base: f32 = if (pa and pb) full else 4.0;
                    edge_jobs[n_jobs] = .{
                        .x0 = scr[a][0],
                        .y0 = scr[a][1],
                        .x1 = scr[b][0],
                        .y1 = scr[b][1],
                        .rgb = .{ (ca[0] + cb2[0]) * 0.5, (ca[1] + cb2[1]) * 0.5, (ca[2] + cb2[2]) * 0.5 },
                        .k0 = base * std.math.clamp(3.4 / scr[a][2], 0.25, 1.5),
                        .k1 = base * std.math.clamp(3.4 / scr[b][2], 0.25, 1.5),
                    };
                    n_jobs += 1;
                }
            }
            // Selection halo edges on top of the bundle — in triality mode the
            // halo follows the orbit links, matching the GPU path's highlight.
            if (selected >= 0 and edge_mode != 0 and vis[sel_u]) {
                const halo_set: []const u16 = if (edge_mode == 3)
                    &.{ triality[sel_u], triality[triality[sel_u]] }
                else
                    &neighbors[sel_u];
                for (halo_set) |n| {
                    if (n == sel_u or !vis[n]) continue;
                    edge_jobs[n_jobs] = .{
                        .x0 = scr[sel_u][0],
                        .y0 = scr[sel_u][1],
                        .x1 = scr[n][0],
                        .y1 = scr[n][1],
                        .rgb = .{ 1, 1, 1 },
                        .k0 = 130,
                        .k1 = 90,
                    };
                    n_jobs += 1;
                }
            }
            cpu.drawEdges(edge_jobs[0..n_jobs], threads);
            // Points back-to-front.
            for (0..e8.n_roots) |i| order[i] = @intCast(i);
            const S = struct {
                fn farFirst(zz: *const [e8.n_roots][3]f32, lhs: u16, rhs: u16) bool {
                    return zz[lhs][2] > zz[rhs][2];
                }
            };
            std.sort.pdq(u16, &order, &scr, S.farFirst);
            for (order) |i| {
                if (!vis[i]) continue;
                const r = &roots[i];
                const pass = passesFilter(r, filter);
                const c = rootColor(r, color_mode, hidden[i], pass);
                var rad = std.math.clamp(point_radius * focal / scr[i][2], 1.6, 15.0);
                const is_sel = selected >= 0 and i == sel_u;
                const is_orbit = selected >= 0 and !is_sel and
                    (i == triality[sel_u] or i == triality[triality[sel_u]]);
                var is_nn = false;
                if (selected >= 0 and !is_sel) {
                    for (neighbors[sel_u]) |n| {
                        if (n == i) {
                            is_nn = true;
                            break;
                        }
                    }
                }
                const pulse = specialPulse(r, triality[i] == i, anim);
                var bright: f32 = if (is_nn) 1.25 else 1.0;
                if (pass and !is_sel and !is_orbit and pulse != 1.0) {
                    // Special particles glow-pulse: soft additive halo under the
                    // disc — the software stand-in for the GPU path's bloom.
                    // Same gating and radius modulation as the GPU spheres.
                    bright *= 0.75 + 0.35 * pulse;
                    rad *= 0.96 + 0.06 * pulse;
                    cpu.halo(scr[i][0], scr[i][1], rad * 3.0, c, 22.0 * (pulse - 0.25));
                }
                if (is_orbit) {
                    // Triality partners of the selection flare in generation
                    // colors, peaking in I → II → III order.
                    const gc = e8.rootRgb(r, .generation, 0);
                    const k = orbitPulse(r.gen, anim);
                    cpu.halo(scr[i][0], scr[i][1], rad * 4.0 + 6.0, gc, 34.0 * k);
                    cpu.ring(scr[i][0], scr[i][1], rad + 3.0, gc);
                    bright = 1.1 + 0.5 * k;
                }
                cpu.disc(scr[i][0], scr[i][1], rad, c, bright);
                if (is_sel) {
                    cpu.halo(scr[i][0], scr[i][1], rad * 4.5 + 8.0, .{ 1, 1, 1 }, 16.0 + 8.0 * @sin(anim * 3.0));
                    cpu.ring(scr[i][0], scr[i][1], rad + 4.0, .{ 1, 1, 1 });
                }
            }
            win.presentRgba(rw, rh, cpu.fb);
            // Pace the software path: no point rendering faster than the display.
            var ts = std.os.linux.timespec{ .sec = 0, .nsec = 4_000_000 };
            _ = std.os.linux.nanosleep(&ts, null);
        }
        frame_no += 1;

        // --- HUD -------------------------------------------------------------------------
        fps_frames += 1;
        const el = @as(f64, @floatFromInt(now.sec - fps_last.sec)) +
            @as(f64, @floatFromInt(now.nsec - fps_last.nsec)) / 1e9;
        if (el >= 0.5 or status_dirty) {
            var buf: [160]u8 = undefined;
            const preset_name: []const u8 = switch (cur_preset) {
                2 => "physics axes",
                3 => "lattice e1e2e3 (wT,wS spin-boost)",
                4 => "G2 plane (g3,g8) + w depth",
                5 => "F4 graviweak plane",
                6 => "F4<->G2 rotation (arrows sweep, T animates)",
                else => "Coxeter plane",
            };
            const edge_name: []const u8 = switch (edge_mode) {
                0 => "off",
                1 => "selection",
                3 => "triality",
                else => "all 6720",
            };
            const pl = planes[g_plane.load(.monotonic)];
            hud.setLine1(std.fmt.bufPrint(&buf, "{s} · colors: {s} · edges: {s} · filter: {s} · 8D plane e{d}e{d}", .{
                preset_name,
                @as(e8.ColorMode, @enumFromInt(color_mode)).name(),
                edge_name,
                filter_names[filter],
                pl[0] + 1,
                pl[1] + 1,
            }) catch "");
            status_dirty = false;
            fps_frames = 0;
            fps_last = now;
        }
        if (info_dirty) {
            info_dirty = false;
            if (selected < 0) {
                hud.setLine2("click a root to inspect it — G hops the triality orbit, X exports CSV");
            } else {
                const r = &roots[sel_u];
                var buf: [200]u8 = undefined;
                var cbuf: [9][8]u8 = undefined;
                var coords: [8][]const u8 = undefined;
                for (0..8) |k| coords[k] = fmtHalf(&cbuf[k], r.v[k]);
                hud.setLine2(std.fmt.bufPrint(&buf, "root #{d}: {s} · {s} [{s}] · ({s},{s},{s},{s},{s},{s},{s},{s}) · λ3={d:.2} λ8={d:.2} w={s} B−L={d:.2} · {s} · G→#{d}", .{
                    sel_u,
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
                    triality[sel_u],
                }) catch "");
            }
        }
        if (legend_mode != color_mode) {
            legend_mode = color_mode;
            switch (color_mode) {
                0 => hud.setLegend(&.{
                    .{ .rgb = .{ 89, 191, 255 }, .label = "gravity" },
                    .{ .rgb = .{ 255, 235, 77 }, .label = "electroweak" },
                    .{ .rgb = .{ 158, 140, 217 }, .label = "frame-Higgs" },
                    .{ .rgb = .{ 255, 140, 26 }, .label = "gluon" },
                    .{ .rgb = .{ 191, 140, 115 }, .label = "xΦ boson" },
                    .{ .rgb = .{ 140, 255, 140 }, .label = "lepton" },
                    .{ .rgb = .{ 255, 64, 56 }, .label = "quark r" },
                    .{ .rgb = .{ 64, 255, 77 }, .label = "g" },
                    .{ .rgb = .{ 77, 115, 255 }, .label = "b" },
                }),
                1 => hud.setLegend(&.{
                    .{ .rgb = .{ 102, 118, 143 }, .label = "bosons (48)" },
                    .{ .rgb = .{ 77, 255, 115 }, .label = "gen I (64)" },
                    .{ .rgb = .{ 255, 184, 46 }, .label = "gen II (64)" },
                    .{ .rgb = .{ 217, 107, 255 }, .label = "gen III (64)" },
                }),
                2 => hud.setLegend(&.{
                    .{ .rgb = .{ 102, 179, 255 }, .label = "120 adjoint (so(16))" },
                    .{ .rgb = .{ 255, 153, 89 }, .label = "128 spinor (16+)" },
                }),
                else => hud.setLegend(&.{
                    .{ .rgb = .{ 64, 128, 255 }, .label = "in the view plane" },
                    .{ .rgb = .{ 255, 100, 64 }, .label = "hidden dimensions" },
                }),
            }
        }
    }
    win_thread.join();
}
