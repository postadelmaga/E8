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
// The OTHER rasterizer. A module name, not a path: build.zig answers it with
// `scene_gpu.zig` for `zig build web-gpu` and with `scene_gpu_off.zig` for
// `zig build web`, so the software build never names a wgpu module and
// `scene.enabled` is comptime false everywhere below. One harness, two devices.
const scene = @import("scene_gpu");

// Only the emscripten build needs these: std's default log/panic reach stderr through
// `std.Io`, which on that target drags in threaded/posix code a tab has no use for and
// which does not compile. The freestanding build keeps the defaults it always had.
pub const std_options: std.Options = if (scene.enabled) .{ .logFn = scene.consoleLog } else .{};
pub const panic = if (scene.enabled) scene.panic_impl else std.debug.FullPanic(std.debug.defaultPanic);
const app_mod = @import("app.zig");
const keys = @import("keys.zig");
const deck_mod = @import("deck.zig");
const deck_write = @import("deck_write.zig");
const slides = @import("plugins/slides.zig");
const panel = @import("plugins/panel.zig");
const webimage = @import("webimage.zig");
const still_mod = @import("still.zig");
const App = app_mod.App;
const D = app_mod.D;

// `wasm_allocator` takes its pages by calling `memory.grow` ITSELF — right for the
// freestanding build, where nothing else owns the heap. On emscripten `malloc` owns it,
// and this build fixes the heap (growth off, so the page's views cannot detach), so
// wasm_allocator's first grow fails, every allocation returns null, and `zicroBoot`
// walks out through one of its `catch return`s WITHOUT A WORD: a window with no size, a
// scene that never boots, and a page that says "no GPU path" while both devices sat
// there unasked. Use libc's, which is the one that owns the memory here.
const gpa = if (scene.enabled) std.heap.c_allocator else std.heap.wasm_allocator;

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

/// Scene render scale, 0..1: the 3D figure is rasterized at this fraction of the
/// display size and upscaled into place, while the HUD stays at full resolution.
/// The whole frame is single-threaded here (native `render_cpu` bands across a
/// pool; a tab has one thread), and it is per-pixel bound — the spheres and the
/// 6720 edges are filled pixel by pixel — so fewer scene pixels is nearly a linear
/// win, and it is the ONE saving that does not touch the text: shrinking the whole
/// buffer ran the status line off the edge, because the HUD is drawn at fixed pixel
/// sizes. 1.0 is every pixel; the page drives it down only when the frames are not
/// there. Clamped so a click still lands on the right root (see `frame`).
var g_scene_scale: f32 = 1.0;
export fn zicroSceneScale(s: f32) void {
    g_scene_scale = std.math.clamp(s, 0.35, 1.0);
}

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

/// A finger, tapped on the figure — and the only ambiguous gesture there is.
///
/// A tap on a ROOT means "tell me about this one". A tap on the empty space around
/// it means "go on" — it is how anyone reads a deck on a phone, and without it the
/// journey is unreachable there, because the keyboard that drives it (P) does not
/// exist. The two cannot be told apart in JavaScript: the browser knows where the
/// finger landed, not what is under it. The app does — after `dispatchFrame` has
/// consumed the pick, `selected` is either a root or −1.
///
/// So the tap is RECORDED here and RESOLVED in `draw`: pick first, then, only if
/// nothing was hit, advance. The first tap on a page nobody has touched yet opens
/// the paper (that is what P does when the panel is closed), which is exactly the
/// way in a phone user needs and the hint bar promises.
var g_tap_pending = false;

export fn zicroTap(x: f32, y: f32) void {
    if (!g_booted) return;
    g_pick = .{ x, y };
    g_tap_pending = true;
}

// --- the file the visitor brings ---------------------------------------------------
//
// Five of the demos exist to open YOUR data — a structure, a catalog, an edge list, a
// table. They ship a sample so the page is never empty (demos/SAMPLES.md), but a sample
// is not the point: the point is the file on your disk, and a browser has one of those.
// It just does not have a filesystem, so the bytes come across instead of a path.
//
// JS asks for a buffer, writes the file into it, and calls `zicroOpenFile`. The buffer
// STAYS: the domain's tables slice into what it parsed, and the app keeps the bytes as
// the source it was opened with. Freeing the previous one here is safe — by then the
// new points are installed, or the sample is back.

var g_file_buf: []u8 = &.{};
var g_name_buf: [128]u8 = undefined;

/// Give JS a buffer of `len` bytes to write a file into. Returns 0 — which in a wasm
/// module's address space is not a valid pointer — when the allocation fails, which is
/// how the page learns the file is bigger than the tab will hold. (The return type is
/// `usize`, not `[*]u8`: a non-null pointer type cannot BE zero, and Zig says so.)
export fn zicroFileBuffer(len: u32) usize {
    const buf = gpa.alloc(u8, len) catch return 0;
    if (g_file_buf.len > 0) gpa.free(g_file_buf);
    g_file_buf = buf;
    return @intFromPtr(buf.ptr);
}

/// The name goes in a fixed buffer: it is only read for its extension (a PDB is not an
/// XYZ) and printed in the panel. 128 bytes is a file name; anything longer is a story.
export fn zicroFileName(ptr: [*]const u8, len: u32) void {
    const n = @min(len, g_name_buf.len);
    @memcpy(g_name_buf[0..n], ptr[0..n]);
    g_file_name = g_name_buf[0..n];
}
var g_file_name: []const u8 = "";

/// Open what was written into the buffer. 0 = the demo is showing it; 1 = it would not
/// load and the sample is back on screen (the page says so — silently reverting to a
/// figure the visitor did not choose is how a tool loses their trust).
export fn zicroOpenFile() u32 {
    if (!g_booted or g_file_buf.len == 0) return 1;
    if (comptime !@hasDecl(D, "sample")) return 1; // this demo generates its points
    g_app.openWebFile(g_file_name, g_file_buf) catch return 1;
    return 0;
}

// --- the editor, in a tab ----------------------------------------------------------
//
// The native editor is its own glass window with its own thread (editor.zig,
// native_only), because zrame's widgets want all five window callbacks and the main
// window spends them on the orbit and the pick. A tab cannot open a second window —
// but it has something the native build does not: a DOM, with real text fields and a
// keyboard that already knows about phones. So on the web the editor is HTML, and the
// wasm's part shrinks to the one idea that made the native editor honest:
//
//   the editor never hands slide structs across a boundary. It produces ZON text, and
//   the app parses that and swaps the deck in — the SAME path F5 takes. "Preview" is
//   therefore not a second renderer that could drift from the real one; it is the real
//   one. What the page shows is exactly what a saved deck.zon would say.
//
// So the wasm exposes three things: the current deck as ZON (to load into the fields),
// a way to hand ZON back (to preview), and the domain's own option tables (so the
// dropdowns are the demo's real presets and colours, not a hardcoded guess).

var g_zon_out: []u8 = &.{};

/// The live deck, serialized to ZON — what the editor opens with. Pointer into wasm
/// memory; `zicroDeckZonLen` gives the length. 0 on failure.
export fn zicroDeckZon() usize {
    if (!g_booted) return 0;
    const sl = g_app.pluginState(slides);
    if (g_zon_out.len > 0) gpa.free(g_zon_out);
    g_zon_out = deck_write.toStringAlloc(gpa, sl.deck) catch {
        g_zon_out = &.{};
        return 0;
    };
    return @intFromPtr(g_zon_out.ptr);
}
export fn zicroDeckZonLen() u32 {
    return @intCast(g_zon_out.len);
}

/// A buffer to write a new deck's ZON into, then `zicroApplyDeck`. Same lend-a-buffer
/// dance as the file open: JS asks for `len` bytes and writes into what it gets back.
var g_deck_buf: []u8 = &.{};
export fn zicroDeckBuffer(len: u32) usize {
    const b = gpa.alloc(u8, len) catch return 0;
    if (g_deck_buf.len > 0) gpa.free(g_deck_buf);
    g_deck_buf = b;
    return @intFromPtr(b.ptr);
}

/// Parse the ZON in the buffer and make it the live deck — the F5 path exactly. Shows
/// slide `sel` after, and opens the panel so the preview is visible. Returns 0 if it
/// parsed, 1 if it did not (the old deck stays; the page keeps the text to fix).
export fn zicroApplyDeck(sel: u32) u32 {
    if (!g_booted or g_deck_buf.len == 0) return 1;
    const sl = g_app.pluginState(slides);
    const z = gpa.dupeZ(u8, g_deck_buf) catch return 1;
    defer gpa.free(z);
    const d = deck_mod.parse(gpa, z) catch return 1;
    deck_mod.deinit(gpa, sl.deck);
    sl.deck = d;
    if (d.slides.len == 0) return 0;
    sl.idx = @min(sel, d.slides.len - 1);
    if (!g_app.pluginState(panel).on) panel.setOpen(&g_app, true);
    slides.show(&g_app, sl.idx);
    return 0;
}

/// The domain's own option tables, as JSON — so the editor's dropdowns are the demo's
/// real presets, colour modes, filters and edge relations, and a new domain gets a
/// working editor with no editor change (the native editor reads the same tables).
var g_opts: []u8 = &.{};
const OptBuf = struct {
    l: std.ArrayList(u8) = .empty,
    first: bool = true,
    fn raw(b: *OptBuf, s: []const u8) void {
        b.l.appendSlice(gpa, s) catch {};
    }
    fn str(b: *OptBuf, s: []const u8) void {
        b.l.append(gpa, '"') catch {};
        for (s) |c| {
            if (c == '"' or c == '\\') b.l.append(gpa, '\\') catch {};
            b.l.append(gpa, c) catch {};
        }
        b.l.append(gpa, '"') catch {};
    }
    fn open(b: *OptBuf, label: []const u8, lead_dash: bool) void {
        b.str(label);
        b.raw(":[");
        b.first = true;
        if (lead_dash) b.item("—");
    }
    fn item(b: *OptBuf, n: []const u8) void {
        if (!b.first) b.raw(",");
        b.first = false;
        b.str(n);
    }
};
export fn zicroOptions() usize {
    if (g_opts.len > 0) return @intFromPtr(g_opts.ptr); // built once; the tables are static
    var b: OptBuf = .{};
    b.raw("{");
    // The tables may be comptime arrays or runtime slices depending on the domain, so
    // each is streamed straight into the JSON — no fixed-size intermediary to demand a
    // comptime length the domain does not promise.
    b.open("presets", false);
    for (D.presets) |p| b.item(p.name);
    b.raw("],");
    b.open("colors", true);
    for (D.color_modes) |c| b.item(c.name);
    b.raw("],");
    b.open("filters", true);
    for (D.filters) |f| b.item(f.name);
    b.raw("],");
    b.open("edges", false); // the framework's three, then the domain's relations
    b.item("off");
    b.item("selection");
    b.item("all");
    for (D.relations) |r| b.item(r.name);
    b.raw("]}");
    g_opts = b.l.toOwnedSlice(gpa) catch &.{};
    return @intFromPtr(g_opts.ptr);
}
export fn zicroOptionsLen() u32 {
    return @intCast(g_opts.len);
}

/// The live camera (yaw, pitch, dist) — so the editor's "use current view" writes the
/// angle you actually orbited to, not a guess. Three f32 at the returned pointer.
var g_cam_out: [3]f32 = .{ 0, 0, 0 };
export fn zicroCamera() usize {
    g_cam_out = .{
        app_mod.loadF32(&app_mod.cam_yaw),
        app_mod.loadF32(&app_mod.cam_pitch),
        app_mod.loadF32(&app_mod.cam_dist),
    };
    return @intFromPtr(&g_cam_out);
}

/// A picture the browser decoded, for a slide's `image` field. The page decodes it
/// (the browser has a decoder; a tab has no stb_image) and hands over straight RGBA;
/// this registers it under `name`, which is what the slide names. The name and its
/// RGBA are written into a buffer lent by `zicroDeckBuffer`, laid out as: the name,
/// then the pixels, and JS passes where the split is. Returns 0 on success.
export fn zicroAddImage(name_len: u32, w: u32, h: u32) u32 {
    if (!g_booted or g_deck_buf.len == 0) return 1;
    const nl: usize = name_len;
    const need = @as(usize, w) * h * 4;
    if (nl + need > g_deck_buf.len) return 1;
    const name = g_deck_buf[0..nl];
    const rgba = g_deck_buf[nl .. nl + need];
    webimage.put(name, w, h, rgba) catch return 1;
    return 0;
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

    // The browser's rAF clock, so the FPS readout is real and timed toasts
    // expire — main.zig does the same with the native clock.
    hud.tick(@as(i128, zrame.widget.nowMs()) * 1_000_000);

    // The scene fills the content rect, minus the panel's gutter and the two HUD
    // bands — the same layout the native build computes from the window size.
    const rw = std.math.clamp(content.w -| 16 -| g_app.reserve_w, 320, 1920) / 4 * 4;
    const rh = std.math.clamp(content.h -| 110, 240, 1200) / 4 * 4;
    hud.frame_w.store(rw, .monotonic);
    hud.frame_h.store(rh, .monotonic);

    // A file the visitor dropped can have any number of points — 34 nodes or 100,000
    // stars — and the rasterizer's buffers were sized for the ones that came before.
    // main.zig watches the same flag for the same reason; a frame drawn before this
    // would write a new catalog through buffers cut for the old one.
    if (g_app.points_changed) {
        g_app.points_changed = false;
        const n = g_app.count();
        const pairs = @max(g_app.edges.len, n);
        g_edge_jobs = gpa.realloc(g_edge_jobs, pairs + 64) catch return;
        g_dot_jobs = gpa.realloc(g_dot_jobs, n) catch return;
        g_order = gpa.realloc(g_order, n) catch return;
    }

    g_app.dt = 1.0 / 60.0; // the browser paces us; a frame is a frame
    g_app.anim += g_app.dt;
    g_app.pick = g_pick;
    g_pick = null;

    app_mod.dispatchFrame(&g_app);

    // The tap, resolved: the pick has been consumed, so `selected` now answers the
    // question JavaScript could not. A root under the finger → it is inspected and
    // that is all. Nothing under it → the finger meant "next", and P is the very key
    // the deck already listens to (opening the panel if this is the first one).
    if (g_tap_pending) {
        g_tap_pending = false;
        if (g_app.selected < 0) _ = app_mod.dispatchKey(&g_app, keys.present);
    }

    if (g_app.reset_camera) {
        g_app.reset_camera = false;
        app_mod.storeF32(&app_mod.cam_yaw, 0.65);
        app_mod.storeF32(&app_mod.cam_pitch, 0.35);
        app_mod.storeF32(&app_mod.cam_dist, 4.2);
    }
    if (g_app.renorm_basis) geom.orthonormalize(&g_app.basis);

    // A picture slide: the still IS the scene. It is composed into the software frame
    // and blitted where the 3D would have gone; the panel keeps narrating beside it.
    // No point is projected or rasterized on these frames — the same short-circuit the
    // native loop takes (main.zig), minus the video-plane teardown a tab never had.
    if (g_app.still) |pic| {
        g_cpu.ensure(rw, rh) catch return;
        still_mod.compose(pic, g_cpu.fb, rw, rh);
        const sox: f32 = @floatFromInt(content.x + (content.w -| g_app.reserve_w -| rw) / 2);
        const soy: f32 = @floatFromInt(content.y + 78);
        canvas.blitRgba(@intFromFloat(sox), @intFromFloat(soy), g_cpu.fb, rw, rh, .{});
        hud_mod.Hud.onDraw(canvas, content, hud);
        if (g_app.anim - g_last_status > 0.5 or g_app.status_dirty) {
            g_last_status = g_app.anim;
            var buf: [256]u8 = undefined;
            hud.setLine1(app_mod.buildStatus(&g_app, &buf));
            g_app.status_dirty = false;
        }
        return;
    }

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
    // The scene rasterizes into a buffer `scale` the display size and is upscaled
    // into the rw×rh slot on the way to the canvas; everything below works in that
    // smaller space (projection, radii, the pick), so nothing has to know it is not
    // 1:1 except the one blit that puts it back. `sw`/`sh` are kept at least 2 so the
    // focal and centre never divide by a degenerate size.
    // The GPU draws at 1:1 and does not need the governor: the whole reason that knob
    // exists is that the software path pays per pixel on one thread. Keeping scale at 1
    // here also keeps `scr` — which the pick and the labels read — in the same space the
    // GPU rasterizes, so a click lands on the root the finger is over.
    const scale = if (scene.enabled) 1.0 else std.math.clamp(g_scene_scale, 0.35, 1.0);
    const sw: u32 = @max(2, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(rw)) * scale))));
    const sh: u32 = @max(2, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(rh)) * scale))));

    const focal = @as(f32, @floatFromInt(sh)) * 0.5 / std.math.tan(fovy * 0.5);
    const cx = @as(f32, @floatFromInt(sw)) * 0.5;
    const cy = @as(f32, @floatFromInt(sh)) * 0.5;

    // The scene is blitted at this origin, so a click in canvas space has to be
    // measured from it AND scaled into the render buffer, or the pick would land on
    // a different root than the one the finger is over.
    const ox: f32 = @floatFromInt(content.x + (content.w -| g_app.reserve_w -| rw) / 2);
    const oy: f32 = @floatFromInt(content.y + 78);
    if (g_app.pick) |xy| g_app.pick = .{ (xy[0] - ox) * scale, (xy[1] - oy) * scale };

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

    if (scene.enabled) {
        gpuScene(eye, rw, rh, ox, oy, n_pts, pairs);
        hud_mod.Hud.onDraw(canvas, content, hud);
        if (g_app.anim - g_last_status > 0.5 or g_app.status_dirty) {
            g_last_status = g_app.anim;
            var buf: [256]u8 = undefined;
            hud.setLine1(app_mod.buildStatus(&g_app, &buf));
            g_app.status_dirty = false;
        }
        return;
    }

    g_cpu.ensure(sw, sh) catch return;
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

    // Upscale the sw×sh scene into the full rw×rh slot on the way to the canvas
    // (a plain nearest blit — the scene is opaque, so there is nothing to blend),
    // then the HUD lands on top at full resolution. When scale == 1 this is the
    // identity and costs the same as the old 1:1 blit.
    canvas.blitImage(@intFromFloat(ox), @intFromFloat(oy), rw, rh, g_cpu.fb, sw, sh);
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

/// The figure, as instances rather than pixels — the same points, the same edges, and
/// the same colours the plugins just chose. This reads `g_app.visuals` and `edgePairs`,
/// exactly as the software rasterizer does two screens down; that is the whole point of
/// there being one `draw` and not two. Nothing here decides anything about E8.
/// The emissive weights the atlas was drawn at. 6720 edges each glowing at full weight
/// is not a brighter figure, it is a white one — the edges are a mesh, and their glow
/// adds up along every line of sight.
const root_glow: f32 = 0.75;
const edge_glow: f32 = 0.25;

fn gpuScene(eye: [3]f32, rw: u32, rh: u32, ox: f32, oy: f32, n_pts: usize, pairs: []const [2]u16) void {
    // The canvas follows the same slot the software build blits into, so the panel keeps
    // its gutter and the figure sits where it always sat. JS reads this and moves the
    // GPU canvas; the wasm never touches the DOM.
    g_scene_rect = .{
        @intFromFloat(@max(ox, 0)),
        @intFromFloat(@max(oy, 0)),
        rw,
        rh,
    };
    scene.resize(rw, rh);
    if (!scene.ready()) return; // the adapter chain has not answered yet

    const aspect = @as(f32, @floatFromInt(rw)) / @as(f32, @floatFromInt(@max(rh, 1)));
    const vp = scene.viewProj(eye, aspect, fovy);

    var n: usize = 0;
    for (0..n_pts) |i| {
        if (!g_app.vis[i]) continue;
        if (n == g_insts.len) break;
        const v = &g_app.visuals[i];
        // Alpha is the seam's EMISSIVE weight — NOT an opacity, and not `bright` either.
        // `bright` is the software rasterizer's own gain and runs past 1; fed in raw it
        // drives the emissive to saturation and the atlas comes out white. Scale it to
        // the weight the figure was drawn at, and a bright root still glows more.
        g_insts[n] = scene.Instance.at(g_app.p3[i], point_radius * v.radius, .{
            v.color[0], v.color[1], v.color[2], std.math.clamp(v.bright, 0.0, 1.0) * root_glow,
        });
        n += 1;
    }
    const n_sphere: u32 = @intCast(n);

    for (pairs) |ed| {
        if (n == g_insts.len) break;
        const a = ed[0];
        const b = ed[1];
        if (!g_app.vis[a] or !g_app.vis[b]) continue;
        const ev = app_mod.edgeVisual(&g_app, a, b) orelse continue;
        const p = g_app.p3[a];
        const q = g_app.p3[b];
        const d = [3]f32{ q[0] - p[0], q[1] - p[1], q[2] - p[2] };
        const len = @sqrt(dot3(d, d));
        if (len < 1e-6) continue;
        g_insts[n] = scene.Instance.along(p, d, 0.006, len, .{
            ev.color[0], ev.color[1], ev.color[2], std.math.clamp(ev.k, 0.0, 1.0) * edge_glow,
        });
        n += 1;
    }
    const n_tube: u32 = @as(u32, @intCast(n)) - n_sphere;

    const m = scene.meshes();
    const draws = [_]scene.Draw{
        .{ .first_vertex = m.sphere_first, .vertex_count = m.sphere_count, .first_instance = 0, .instance_count = n_sphere },
        .{ .first_vertex = m.tube_first, .vertex_count = m.tube_count, .first_instance = n_sphere, .instance_count = n_tube },
    };
    scene.render(g_insts[0..n], &draws, vp, .{ 0, 0, 0, 1 });
}

/// wasm has no main: JS calls this once.
export fn zicroBoot() void {
    if (g_booted) return;

    webimage.init(gpa); // the registry a slide's picture is looked up in (webimage.zig)

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
        //
        // On the GPU build the same reasoning inverts: the figure is not in this buffer
        // at all, it is on the WebGPU canvas UNDERNEATH. So the fill has to be nothing —
        // alpha 0, a hole the scene shows through — and the HUD, drawn at fixed pixel
        // sizes into this canvas, stays crisp over it whatever the figure below costs.
        .style = .{ .glass = zrame.Color.rgba(0, 0, 0, if (scene.enabled) 0.0 else 1.0) },
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

    if (scene.enabled) {
        // The adapter chain is async, so this only starts it: `scene.ready()` turns true
        // some frames later, and until it does `draw` simply skips the figure and the
        // HUD narrates over black. The size is provisional — `draw` corrects it from the
        // real layout on the first frame.
        g_insts = gpa.alloc(scene.Instance, points.len + max_pairs) catch return;
        scene.boot("#e8gpu", 1200, 760, g_force_gl);
    }

    app_mod.dispatchInit(&g_app);
    g_booted = true;
}

/// The instance stream, rebuilt every frame from whatever the plugins decided this tick.
var g_insts: []scene.Instance = &.{};
/// `?force=gl` on the page: reach the twin even where an adapter answers, or it is only
/// ever exercised where it cannot be watched.
var g_force_gl = false;
export fn zicroForceGl() void {
    g_force_gl = true;
}
/// Where the figure goes, in canvas pixels: x, y, w, h. The GPU canvas is a DOM element
/// of its own, so JS reads this each frame and lays it exactly over the slot the software
/// build blits into — same layout, same gutter for the panel, whichever device draws.
var g_scene_rect: [4]u32 = .{ 0, 0, 0, 0 };
export fn zicroSceneRect() [*]const u32 {
    return &g_scene_rect;
}
/// 2 = WebGPU, 1 = the WebGL2 twin, 0 = neither yet.
export fn zicroSceneDevice() u32 {
    return scene.device();
}
