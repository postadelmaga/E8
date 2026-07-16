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
//! TWO BACKENDS, ONE SCENE — and this is not symmetry for its own sake. A Chrome that
//! reports `navigator.gpu` can still answer `requestAdapter` with null (this laptop's
//! does), and then WebGPU-or-nothing means nothing: zero frames, an apology, and the
//! whole point invisible on the machine it was written for. So the adapter chain asks
//! four times, and when it runs out the scene lands on the WebGL2 twin
//! (`ze_wgpu.gles_mesh`, issue #88 follow-up 3) instead of giving up.
//!
//! The two share everything that is not the device: one geometry generator, one orbit,
//! one clock. `InstancedDraw` and `InstPush` are field-for-field identical across the
//! backends (the twin redeclares them so it need not import webgpu.h), and `viewProj`
//! stays WebGPU clip space for BOTH — the es300 shaders are emitted without
//! --keep-coordinate-space, so naga's own adjustment converts z and flips y. See
//! build.zig's `web-gpu` step, which owes the twin its shaders exactly as it owes
//! `rhi_wgpu` the WGSL.
//!
//! WHAT IS NOT HERE YET: the HUD, the plugins and the deck — this path draws the figure,
//! not the tool. Those live in `app.zig` and belong to `web.zig`'s window, and the way
//! to reach them is one file with the rasterizer chosen at comptime, not a second copy
//! of the harness here. Until then this is an honest preview of the figure alone.

const std = @import("std");
const zw = @import("zicro_wgpu");
const backend = @import("ze_wgpu");
const e8 = @import("demos/lisi/e8.zig"); // the roots, the edges, the projection, tested
const gm = backend.gles_mesh; // the WebGL2 twin — `struct {}` off-emscripten

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

/// One instanced draw, in neither backend's dialect. Both declare this shape with these
/// exact fields; keeping our own means the geometry is built once and `run` hands it to
/// whichever device answered, with no branch in the builder.
const Draw = struct {
    first_vertex: u32,
    vertex_count: u32,
    first_instance: u32,
    instance_count: u32,
};

/// The atlas as bytes: the base meshes, the per-instance stream, and how to draw them.
/// No device in sight — this is what both backends are handed.
const Geom = struct {
    verts: []const u8,
    insts: []const u8,
    draws: [2]Draw,
};

/// `Draw` in a backend's own type. Field-for-field, checked by the compiler at each use.
fn drawsAs(comptime T: type, d: [2]Draw) [2]T {
    var out: [2]T = undefined;
    for (d, 0..) |x, i| out[i] = .{
        .first_vertex = x.first_vertex,
        .vertex_count = x.vertex_count,
        .first_instance = x.first_instance,
        .instance_count = x.instance_count,
    };
    return out;
}

/// The camera and the clock, OUTSIDE the backend: whichever device draws, it is the same
/// orbit, and `ze_ms` means the same thing — so the two paths stay comparable.
const Cam = struct {
    width: u32 = 1280,
    height: u32 = 720,
    yaw: f32 = 0.65,
    pitch: f32 = 0.35,
    dist: f32 = 4.2,
    frames: u64 = 0,
    ema_ms: f32 = 16.0,
    last: f64 = 0,
};
var g_cam: Cam = .{};
var g_geom: ?Geom = null;

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
};

var g_app: ?App = null;
/// The twin's state — null until the adapter chain runs out and lands here.
var g_gl: ?gm.MeshPresent = null;
var g_gl_draws: [2]gm.InstancedDraw = undefined;
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
    return @floatFromInt(g_cam.frames);
}
/// Which device is drawing: 2 = WebGPU, 1 = the WebGL2 twin, 0 = neither, yet. The page
/// says so out loud — "WebGPU" over a frame the twin drew would be a readout that lies.
export fn ze_backend() f64 {
    if (g_app != null) return 2;
    if (g_gl != null) return 1;
    return 0;
}
export fn ze_ms() f64 {
    return g_cam.ema_ms;
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

/// The atlas, as bytes, with no device involved — so the WebGPU path and the twin get
/// the SAME 240 roots and 6720 edges, from the same tested module, and a bug can never
/// be "only on the fallback".
///
/// The arrays are not freed: they outlive this call because the twin uploads on init and
/// a context loss would want them again. 6960 × 64 B ≈ 435 KB of the 16 MB heap.
fn buildGeometry(gpa: std.mem.Allocator) !Geom {
    var verts: std.ArrayList(f32) = .empty;
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
        .verts = std.mem.sliceAsBytes(verts.items),
        .insts = std.mem.sliceAsBytes(insts.items),
        .draws = .{
            .{ .first_vertex = 0, .vertex_count = m.sphere, .first_instance = 0, .instance_count = n_sphere },
            .{ .first_vertex = m.tube_first, .vertex_count = m.tube, .first_instance = n_sphere, .instance_count = n_tube },
        },
    };
}

/// The geometry, built once and kept: both backends ask for it, and on this path only
/// one of them will ever get it.
fn geometry() !*const Geom {
    if (g_geom == null) g_geom = try buildGeometry(g_fba.allocator());
    return &g_geom.?;
}

// --- boot ----------------------------------------------------------------------------

/// `?force=gl` on the page. The twin is the path most visitors will actually get, so it
/// has to be reachable on a machine whose adapter answers — otherwise it is only ever
/// tested where it cannot be watched.
var g_force_gl: bool = false;
export fn ze_force_gl() void {
    g_force_gl = true;
}

export fn ze_boot() void {
    if (g_force_gl) return startGl();
    // No WebGPU at all in this browser: straight to the twin, no apology.
    g_instance = c.wgpuCreateInstance(null) orelse return startGl();
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
        // Asked four times, answered null four times. That is not the end of the road:
        // this browser still has WebGL2, and the twin draws the same atlas through it.
        return startGl();
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

/// The WebGL2 twin: the same atlas, the same two instanced draws, no adapter needed.
/// Synchronous, unlike the WebGPU chain above — there is nothing to await.
fn startGl() void {
    const g = geometry() catch |e| {
        var buf: [128]u8 = undefined;
        return fail(std.fmt.bufPrint(&buf, "the atlas did not build: {s}", .{@errorName(e)}) catch "the atlas did not build");
    };

    const w = if (g_pending_w != 0) g_pending_w else g_cam.width;
    const h = if (g_pending_h != 0) g_pending_h else g_cam.height;

    var mp = gm.MeshPresent.init(canvas, w, h) catch
        return fail("no WebGPU adapter would answer, and WebGL2 refused a context too — this browser has no GPU path at all");

    mp.vertexData(g.verts);
    mp.instanceData(g.insts);
    g_gl_draws = drawsAs(gm.InstancedDraw, g.draws);
    g_gl = mp;

    g_cam.width = w;
    g_cam.height = h;
    g_cam.last = emscripten_get_now();
    std.log.info("E8 on the GPU: no WebGPU adapter — the WebGL2 twin has it, {d}x{d}", .{ w, h });
    emscripten_set_main_loop(frame, 0, 0);
}

fn start(device: c.WGPUDevice) !void {
    const queue = c.wgpuDeviceGetQueue(device).?;

    g_surface = zw.surfaceFromCanvas(g_instance, canvas) catch return fail("no surface — the canvas is not there");
    var caps: c.WGPUSurfaceCapabilities = .{};
    _ = c.wgpuSurfaceGetCapabilities(g_surface, g_adapter, &caps);
    const format = if (caps.formatCount > 0) caps.formats[0] else c.WGPUTextureFormat_BGRA8Unorm;

    const w = if (g_pending_w != 0) g_pending_w else g_cam.width;
    const h = if (g_pending_h != 0) g_pending_h else g_cam.height;

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
    };
    const a = &g_app.?;
    g_cam.width = w;
    g_cam.height = h;
    g_cam.last = emscripten_get_now();
    configure(a, w, h);
    a.mp = try backend.MeshPresent.init(&a.gpu, format, w, h);

    const g = try geometry();
    a.scene = .{
        .vbuf = a.gpu.vertexBuffer(g.verts),
        .ibuf = a.gpu.vertexBuffer(g.insts),
        .draws = drawsAs(backend.InstancedDraw, g.draws),
    };
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
    // Before either backend is up, remember it: the device is asked for this size when
    // it arrives, so a resize during the adapter chain is not lost.
    if (g_app == null and g_gl == null) {
        g_pending_w = iw;
        g_pending_h = ih;
        return;
    }
    if (g_cam.width == iw and g_cam.height == ih) return;
    g_cam.width = iw;
    g_cam.height = ih;
    if (g_app) |*a| {
        configure(a, iw, ih);
        a.mp.resize(iw, ih) catch |e| std.log.err("resize: {s}", .{@errorName(e)});
    }
    if (g_gl) |*gl| gl.resize(iw, ih);
}

export fn ze_look(dyaw: f64, dpitch: f64) void {
    g_cam.yaw += @floatCast(dyaw);
    g_cam.pitch = std.math.clamp(g_cam.pitch + @as(f32, @floatCast(dpitch)), -1.45, 1.45);
}

export fn ze_dolly(dz: f64) void {
    g_cam.dist = std.math.clamp(g_cam.dist * (1.0 + @as(f32, @floatCast(dz))), 1.4, 14.0);
}

// --- the frame -----------------------------------------------------------------------

fn frame() callconv(.c) void {
    const now = emscripten_get_now();
    const dt: f32 = @floatCast(now - g_cam.last);
    g_cam.last = now;
    g_cam.ema_ms = g_cam.ema_ms * 0.9 + dt * 0.1;

    const vp = viewProj(&g_cam);

    if (g_gl) |*gl| {
        gl.render(&g_gl_draws, .{ .view_proj = vp }, .{ 0, 0, 0, 1 });
        g_cam.frames += 1;
        return;
    }

    const a = &(g_app orelse return);
    var st: c.WGPUSurfaceTexture = .{};
    c.wgpuSurfaceGetCurrentTexture(a.surface, &st);
    if (st.texture == null) return;
    const view = c.wgpuTextureCreateView(st.texture, null).?;
    defer c.wgpuTextureViewRelease(view);

    a.mp.render(view, a.scene.vbuf, a.scene.ibuf, &a.scene.draws, .{
        .view_proj = vp,
    }, .{ 0, 0, 0, 1 });

    // No present call: on the web the compositor takes the canvas when this returns.
    g_cam.frames += 1;
}

/// Orbit camera → view·projection, column-major, the way the seam's push block wants it.
fn viewProj(a: *const Cam) [16]f32 {
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
    // `w` must come out as +t, the distance along the forward axis: the perspective
    // divide is z/w, and the z below is built assuming exactly that. Signing this row
    // the other way makes w = -t — negative for everything IN FRONT of the camera, so
    // the whole atlas clips away and the canvas stays black at a confident 60 fps.
    // (Which is what it did: this path had never actually been watched on a machine
    // whose adapter answers, so the sign survived a "working" WebGPU build.)

    // proj · view, WebGPU clip space (z ∈ [0,1])
    const p0 = t / aspect;
    const p1 = t;
    const p2 = far / (near - far);
    const p3 = (far * near) / (near - far);

    return .{
        p0 * s[0], p1 * u[0], p2 * -f[0], f[0],
        p0 * s[1], p1 * u[1], p2 * -f[1], f[1],
        p0 * s[2], p1 * u[2], p2 * -f[2], f[2],
        p0 * tx,   p1 * ty,   p2 * tz + p3, -tz,
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
