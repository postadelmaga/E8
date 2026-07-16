//! The E8 atlas on the GPU, in a browser — `zig build web-gpu` → zig-out/web/gpu/.
//!
//! The software path (`web.zig`) rasterizes every pixel on the tab's ONE thread, and
//! measurement says that is the whole frame: the E8 atlas costs ~150 ms at 1584×990
//! (~6 fps), a 24-point scene costs nearly as much, and the JS blit is ~1 ms of it. The
//! cost is per-pixel work with no thread to put it on. This path does not shave that —
//! it moves it: the figure is drawn by the GPU through Zengine's browser-present
//! instanced mesh seam (`ze_wgpu.MeshPresent`, Zengine issue #88).
//!
//! THE SHAPE. Two base meshes — a UV sphere and a tube — concatenated into one vertex
//! buffer, uploaded once. Per frame the roots become sphere instances and the edges
//! become tube instances (affine rows + colour, 64 bytes each), and the whole atlas
//! goes out as TWO instanced draws. Not 6960 draws: that is the difference the seam
//! was built for.
//!
//! THE E8 IS THE REAL ONE. Nothing here re-derives the polytope. `demos/lisi/e8.zig`
//! is dependency-free (std only) and already carries the tested truth — `generate()`
//! for the 240 roots, `buildEdges` for the 6720 pairs at ⟨a,b⟩ = 1, `coxeterBasis()`
//! for the iconic 30-fold projection, `rootRgb` for Lisi's own class palette. This
//! file is a renderer, not a second opinion; if the counts ever disagree with the unit
//! tests, the tests are right.
//!
//! WHAT IS NOT HERE YET. The HUD (it is drawn at fixed pixel sizes into the software
//! canvas, and belongs on a 2D canvas stacked over this one), the plugins, the deck.
//! This is the scene, proven on the GPU, and the seam it proves is the one the rest
//! will ride in on.

const std = @import("std");
const zw = @import("zicro_wgpu");
const backend = @import("ze_wgpu");
const e8 = @import("demos/lisi/e8.zig");

const c = zw.c;
const Gpu = backend.Gpu;
const Instance = backend.Instance;

const canvas = "#e8";

// --- the browser's side of the ABI ---------------------------------------------------
// No `main`: emscripten calls `_ze_boot` from the page, and the page owns the loop.

extern "c" fn emscripten_set_main_loop(f: *const fn () callconv(.c) void, fps: c_int, loop: c_int) void;
extern "c" fn emscripten_get_now() f64;
extern "c" fn emscripten_console_log(msg: [*:0]const u8) void;
extern "c" fn emscripten_console_error(msg: [*:0]const u8) void;

// Log and panic go to the browser's console, and they have to be replaced rather than
// merely redirected: std's default writes to stderr through `std.Io`, which drags in
// the threaded/posix machinery — code that has no meaning here and does not even
// compile for this target.
pub const std_options: std.Options = .{ .logFn = consoleLog };

fn consoleLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    _ = scope;
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch "(a message too long to print)";
    switch (level) {
        .err, .warn => emscripten_console_error(msg),
        else => emscripten_console_log(msg),
    }
}

pub const panic = std.debug.FullPanic(struct {
    fn f(msg: []const u8, _: ?usize) noreturn {
        var buf: [1024]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "panic: {s}", .{msg}) catch "panic";
        emscripten_console_error(z);
        @trap();
    }
}.f);

// --- state ---------------------------------------------------------------------------

/// 16 MB. The instance stream is the big tenant: 6960 × 64 B ≈ 435 KB, and the two base
/// meshes are a few thousand vertices — the rest is slack so nothing has to grow.
var g_heap: [1 << 24]u8 = undefined;
var g_fba = std.heap.FixedBufferAllocator.init(&g_heap);

const Scene = struct {
    vbuf: c.WGPUBuffer,
    ibuf: c.WGPUBuffer,
    draws: [2]backend.InstancedDraw,
};

const App = struct {
    gpu: backend.Gpu,
    surface: c.WGPUSurface,
    format: c.WGPUTextureFormat,
    mp: backend.MeshPresent,
    scene: Scene,
    width: u32,
    height: u32,
    yaw: f32 = 0.65,
    pitch: f32 = 0.35,
    dist: f32 = 4.2,
    frames: u64 = 0,
    ema_ms: f32 = 16.0,
    last: f64 = 0,
};

var g_app: ?App = null;
var g_instance: c.WGPUInstance = null;
var g_surface: c.WGPUSurface = null;
var g_adapter: c.WGPUAdapter = null;
var g_try: u8 = 0;
var g_pending_w: u32 = 0;
var g_pending_h: u32 = 0;
var g_err: [256]u8 = undefined;
var g_err_len: usize = 0;

fn fail(msg: []const u8) void {
    const n = @min(msg.len, g_err.len);
    @memcpy(g_err[0..n], msg[0..n]);
    g_err_len = n;
    std.log.err("{s}", .{msg});
}

export fn ze_error() [*c]const u8 {
    g_err[@min(g_err_len, g_err.len - 1)] = 0;
    return &g_err;
}
export fn ze_frames() f64 {
    return @floatFromInt(if (g_app) |a| a.frames else 0);
}
export fn ze_ms() f64 {
    return if (g_app) |a| a.ema_ms else 0;
}

// --- the meshes ----------------------------------------------------------------------

/// A UV sphere and an open tube, concatenated into one stride-8 stream
/// (position, normal, uv). On a unit sphere the position IS the normal; on a tube the
/// normal is the radial direction — which is all the seam's Lambert asks for.
fn buildMeshes(verts: *std.ArrayList(f32), gpa: std.mem.Allocator) !struct { sphere: u32, tube_first: u32, tube: u32 } {
    const seg = 12; // rings/segments: 240 spheres of these is cheap, and round enough
    const sphere_first: u32 = 0;

    var ring: u32 = 0;
    while (ring < seg) : (ring += 1) {
        const p0 = std.math.pi * @as(f32, @floatFromInt(ring)) / seg;
        const p1 = std.math.pi * @as(f32, @floatFromInt(ring + 1)) / seg;
        var s: u32 = 0;
        while (s < seg * 2) : (s += 1) {
            const t0 = std.math.tau * @as(f32, @floatFromInt(s)) / (seg * 2);
            const t1 = std.math.tau * @as(f32, @floatFromInt(s + 1)) / (seg * 2);
            const a = sph(p0, t0);
            const b = sph(p1, t0);
            const d = sph(p0, t1);
            const e = sph(p1, t1);
            try quad(verts, gpa, a, b, e, d);
        }
    }
    const sphere_count: u32 = @intCast(verts.items.len / 8);

    const tube_first: u32 = sphere_count;
    var s: u32 = 0;
    while (s < seg) : (s += 1) {
        const t0 = std.math.tau * @as(f32, @floatFromInt(s)) / seg;
        const t1 = std.math.tau * @as(f32, @floatFromInt(s + 1)) / seg;
        // Local Y ∈ [0,1] is the axis: `Instance.along` stretches it onto an edge.
        const a = [3]f32{ @cos(t0), 0, @sin(t0) };
        const b = [3]f32{ @cos(t0), 1, @sin(t0) };
        const d = [3]f32{ @cos(t1), 0, @sin(t1) };
        const e = [3]f32{ @cos(t1), 1, @sin(t1) };
        try quadN(verts, gpa, a, b, e, d, .{ @cos(t0), 0, @sin(t0) }, .{ @cos(t1), 0, @sin(t1) });
    }
    const tube_count: u32 = @as(u32, @intCast(verts.items.len / 8)) - tube_first;
    _ = sphere_first;
    return .{ .sphere = sphere_count, .tube_first = tube_first, .tube = tube_count };
}

fn sph(phi: f32, theta: f32) [3]f32 {
    return .{ @sin(phi) * @cos(theta), @cos(phi), @sin(phi) * @sin(theta) };
}

fn push(verts: *std.ArrayList(f32), gpa: std.mem.Allocator, p: [3]f32, n: [3]f32) !void {
    try verts.appendSlice(gpa, &.{ p[0], p[1], p[2], n[0], n[1], n[2], 0, 0 });
}

/// A quad on the unit sphere: position doubles as normal.
fn quad(verts: *std.ArrayList(f32), gpa: std.mem.Allocator, a: [3]f32, b: [3]f32, cc: [3]f32, d: [3]f32) !void {
    try push(verts, gpa, a, a);
    try push(verts, gpa, b, b);
    try push(verts, gpa, cc, cc);
    try push(verts, gpa, a, a);
    try push(verts, gpa, cc, cc);
    try push(verts, gpa, d, d);
}

/// A quad on the tube wall: the normal is radial and shared down each edge.
fn quadN(verts: *std.ArrayList(f32), gpa: std.mem.Allocator, a: [3]f32, b: [3]f32, cc: [3]f32, d: [3]f32, n0: [3]f32, n1: [3]f32) !void {
    try push(verts, gpa, a, n0);
    try push(verts, gpa, b, n0);
    try push(verts, gpa, cc, n1);
    try push(verts, gpa, a, n0);
    try push(verts, gpa, cc, n1);
    try push(verts, gpa, d, n1);
}

// --- the scene -----------------------------------------------------------------------

fn buildScene(gpu: *backend.Gpu, gpa: std.mem.Allocator) !Scene {
    var verts: std.ArrayList(f32) = .empty;
    defer verts.deinit(gpa);
    const m = try buildMeshes(&verts, gpa);

    // The real thing: the tested module's roots, edges, projection and palette.
    const roots = e8.generate();
    const edges = try e8.buildEdges(gpa, &roots);
    defer gpa.free(edges);
    // The module's own invariants, restated at the boundary: a wrong E8 is not a
    // smaller demo, it is a bug, and it should say so before it draws anything.
    if (roots.len != e8.n_roots or edges.len != e8.n_edges) return error.NotE8;

    const basis = e8.coxeterBasis();
    var pos: [e8.n_roots][3]f32 = undefined;
    for (&roots, 0..) |*r, i| pos[i] = e8.project(&basis, r.v);

    var insts: std.ArrayList(Instance) = .empty;
    defer insts.deinit(gpa);

    // Roots first: `draws[0]` is the sphere run, so its instances lead the buffer.
    for (&roots, 0..) |*r, i| {
        const rgb = e8.rootRgb(r, .physics, 0);
        // Alpha is the seam's EMISSIVE weight — a root of Lisi's atlas glows.
        try insts.append(gpa, Instance.at(pos[i], 0.055, .{ rgb[0], rgb[1], rgb[2], 0.75 }));
    }
    const n_sphere: u32 = @intCast(insts.items.len);

    for (edges) |ed| {
        const a = pos[ed[0]];
        const b = pos[ed[1]];
        const d = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
        const len = @sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
        if (len < 1e-6) continue;
        try insts.append(gpa, Instance.along(a, d, 0.006, len, .{ 0.32, 0.45, 0.85, 0.25 }));
    }
    const n_tube: u32 = @as(u32, @intCast(insts.items.len)) - n_sphere;

    return .{
        .vbuf = gpu.vertexBuffer(std.mem.sliceAsBytes(verts.items)),
        .ibuf = gpu.vertexBuffer(std.mem.sliceAsBytes(insts.items)),
        .draws = .{
            .{ .first_vertex = 0, .vertex_count = m.sphere, .first_instance = 0, .instance_count = n_sphere },
            .{ .first_vertex = m.tube_first, .vertex_count = m.tube, .first_instance = n_sphere, .instance_count = n_tube },
        },
    };
}

// --- boot ----------------------------------------------------------------------------

export fn ze_boot() void {
    g_instance = c.wgpuCreateInstance(null) orelse
        return fail("this browser has no WebGPU — the instanced mesh path has no WebGL2 twin (Zengine issue #88, follow-up 3)");
    const opts = c.WGPURequestAdapterOptions{ .powerPreference = c.WGPUPowerPreference_HighPerformance };
    _ = c.wgpuInstanceRequestAdapter(g_instance, &opts, .{
        .mode = c.WGPUCallbackMode_AllowSpontaneous,
        .callback = onAdapter,
    });
}

fn onAdapter(status: c.WGPURequestAdapterStatus, adapter: c.WGPUAdapter, _: c.WGPUStringView, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (status != c.WGPURequestAdapterStatus_Success) {
        // Ask less each time rather than give up: a laptop with a weak GPU still draws
        // this, and a browser behind a flag often answers the second or third ask.
        g_try += 1;
        const next: ?c.WGPURequestAdapterOptions = switch (g_try) {
            1 => .{},
            2 => .{ .featureLevel = c.WGPUFeatureLevel_Compatibility },
            3 => .{ .forceFallbackAdapter = 1 },
            else => null,
        };
        if (next) |o| {
            _ = c.wgpuInstanceRequestAdapter(g_instance, &o, .{ .mode = c.WGPUCallbackMode_AllowSpontaneous, .callback = onAdapter });
            return;
        }
        return fail("no WebGPU adapter would answer — on Linux try chrome://flags/#enable-unsafe-webgpu and #enable-vulkan");
    }
    g_adapter = adapter;
    const desc = c.WGPUDeviceDescriptor{
        .uncapturedErrorCallbackInfo = .{ .callback = onGpuError },
    };
    _ = c.wgpuAdapterRequestDevice(adapter, &desc, .{ .mode = c.WGPUCallbackMode_AllowSpontaneous, .callback = onDevice });
}

fn onDevice(status: c.WGPURequestDeviceStatus, device: c.WGPUDevice, _: c.WGPUStringView, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (status != c.WGPURequestDeviceStatus_Success) return fail("the GPU adapter refused to give a device");
    start(device) catch |e| {
        var buf: [128]u8 = undefined;
        fail(std.fmt.bufPrint(&buf, "the atlas did not come up: {s}", .{@errorName(e)}) catch "the atlas did not come up");
    };
}

fn onGpuError(_: [*c]const ?*c.struct_WGPUDeviceImpl, kind: c.WGPUErrorType, msg: c.WGPUStringView, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const text = if (msg.data) |d| d[0..msg.length] else "(no message)";
    std.log.err("wgpu error {d}: {s}", .{ kind, text });
}

fn start(device: c.WGPUDevice) !void {
    const gpa = g_fba.allocator();
    const queue = c.wgpuDeviceGetQueue(device).?;

    g_surface = zw.surfaceFromCanvas(g_instance, canvas) catch return fail("no surface — the canvas is not there");
    var caps: c.WGPUSurfaceCapabilities = .{};
    _ = c.wgpuSurfaceGetCapabilities(g_surface, g_adapter, &caps);
    const format = if (caps.formatCount > 0) caps.formats[0] else c.WGPUTextureFormat_BGRA8Unorm;

    const w = if (g_pending_w != 0) g_pending_w else 1280;
    const h = if (g_pending_h != 0) g_pending_h else 720;

    g_app = .{
        .gpu = .{ .dev = .{
            .instance = g_instance,
            .adapter = g_adapter,
            .device = device,
            .queue = queue,
            .spirv = false,
        } },
        .surface = g_surface,
        .format = format,
        .mp = undefined,
        .scene = undefined,
        .width = w,
        .height = h,
        .last = emscripten_get_now(),
    };
    const a = &g_app.?;
    configure(a, w, h);
    a.mp = try backend.MeshPresent.init(&a.gpu, format, w, h);
    a.scene = try buildScene(&a.gpu, gpa);
    std.log.info("E8 on the GPU: 240 roots + 6720 edges in 2 instanced draws, {d}x{d}", .{ w, h });
    emscripten_set_main_loop(frame, 0, 0);
}

fn configure(a: *App, w: u32, h: u32) void {
    c.wgpuSurfaceConfigure(a.surface, &.{
        .device = a.gpu.dev.device,
        .format = a.format,
        .usage = c.WGPUTextureUsage_RenderAttachment,
        .width = w,
        .height = h,
        .presentMode = c.WGPUPresentMode_Fifo,
        .alphaMode = c.WGPUCompositeAlphaMode_Opaque,
    });
}

export fn ze_resize(w: f64, h: f64) void {
    const iw: u32 = @intFromFloat(@max(w, 1));
    const ih: u32 = @intFromFloat(@max(h, 1));
    const a = &(g_app orelse {
        g_pending_w = iw;
        g_pending_h = ih;
        return;
    });
    if (a.width == iw and a.height == ih) return;
    a.width = iw;
    a.height = ih;
    configure(a, iw, ih);
    a.mp.resize(iw, ih) catch |e| std.log.err("resize: {s}", .{@errorName(e)});
}

export fn ze_look(dyaw: f64, dpitch: f64) void {
    const a = &(g_app orelse return);
    a.yaw += @floatCast(dyaw);
    a.pitch = std.math.clamp(a.pitch + @as(f32, @floatCast(dpitch)), -1.45, 1.45);
}

export fn ze_dolly(dz: f64) void {
    const a = &(g_app orelse return);
    a.dist = std.math.clamp(a.dist * (1.0 + @as(f32, @floatCast(dz))), 1.4, 14.0);
}

// --- the frame -----------------------------------------------------------------------

fn frame() callconv(.c) void {
    const a = &(g_app orelse return);
    const now = emscripten_get_now();
    const dt: f32 = @floatCast(now - a.last);
    a.last = now;
    a.ema_ms = a.ema_ms * 0.9 + dt * 0.1;

    var st: c.WGPUSurfaceTexture = .{};
    c.wgpuSurfaceGetCurrentTexture(a.surface, &st);
    if (st.texture == null) return;
    const view = c.wgpuTextureCreateView(st.texture, null).?;
    defer c.wgpuTextureViewRelease(view);

    a.mp.render(view, a.scene.vbuf, a.scene.ibuf, &a.scene.draws, .{
        .view_proj = viewProj(a),
    }, .{ 0, 0, 0, 1 });

    // No present call: on the web the compositor takes the canvas when this returns.
    a.frames += 1;
}

/// Orbit camera → view·projection, column-major, the way the seam's push block wants it.
fn viewProj(a: *const App) [16]f32 {
    const eye = [3]f32{
        a.dist * @cos(a.pitch) * @cos(a.yaw),
        a.dist * @sin(a.pitch),
        a.dist * @cos(a.pitch) * @sin(a.yaw),
    };
    const f = norm(.{ -eye[0], -eye[1], -eye[2] });
    const s = norm(cross(f, .{ 0, 1, 0 }));
    const u = cross(s, f);

    const aspect = @as(f32, @floatFromInt(a.width)) / @as(f32, @floatFromInt(@max(a.height, 1)));
    const fovy: f32 = 0.9;
    const near: f32 = 0.05;
    const far: f32 = 100.0;
    const t = 1.0 / @tan(fovy * 0.5);

    // view (row-vector form folded into the columns below)
    const tx = -dot(s, eye);
    const ty = -dot(u, eye);
    const tz = dot(f, eye);

    // proj · view, WebGPU clip space (z ∈ [0,1])
    const p0 = t / aspect;
    const p1 = t;
    const p2 = far / (near - far);
    const p3 = (far * near) / (near - far);

    return .{
        p0 * s[0], p1 * u[0], p2 * -f[0], -f[0],
        p0 * s[1], p1 * u[1], p2 * -f[1], -f[1],
        p0 * s[2], p1 * u[2], p2 * -f[2], -f[2],
        p0 * tx,   p1 * ty,   p2 * tz + p3, tz,
    };
}

fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}
fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}
fn norm(v: [3]f32) [3]f32 {
    const l = @max(@sqrt(dot(v, v)), 1e-12);
    return .{ v[0] / l, v[1] / l, v[2] / l };
}
