//! The scene, drawn by the GPU — `web.zig`'s other rasterizer.
//!
//! WHY THIS IS A MODULE AND NOT A PAGE. The software path rasterizes every pixel on the
//! tab's ONE thread, and measurement says that is the whole frame: the atlas costs
//! ~150 ms at 1584x990 (~6 fps), a 24-point scene costs nearly as much, and the JS blit
//! is ~1 ms of it. This path does not shave that cost, it moves it — the figure goes to
//! the GPU through Zengine's instanced mesh seam (`ze_wgpu.MeshPresent`, issue #88).
//!
//! But only the FIGURE. The tool — the window, the input, the plugins that colour and
//! filter, the deck, the HUD, every key — is `app.zig`'s, and `web.zig` runs it once for
//! BOTH rasterizers, choosing between them at comptime. A second copy of that harness
//! would drift, and the copy nobody is looking at is the one that rots. So this file
//! knows about spheres, tubes and devices, and nothing whatsoever about E8.
//!
//! TWO DEVICES, ONE SEAM. A Chrome that reports `navigator.gpu` can still answer
//! `requestAdapter` with null (this laptop's does, at every feature level), so the chain
//! asks four times and then lands on the WebGL2 twin (`ze_wgpu.gles_mesh`) rather than
//! giving up. Both take the same instances, the same draws and the same `view_proj` —
//! WebGPU clip space for both, because the es300 pair is emitted without
//! --keep-coordinate-space and naga's own adjustment converts z and flips y (build.zig).
//!
//! THE INSTANCES ARE REWRITTEN EVERY FRAME, and that is the point, not laziness: the
//! colours and the filters are live. If the stream were uploaded once, the HUD would say
//! "colors: generations" over a scene still wearing the physics palette — and a readout
//! that lies is worse than no readout.

const std = @import("std");
const zw = @import("zicro_wgpu");
const backend = @import("ze_wgpu");
const gm = backend.gles_mesh; // the WebGL2 twin — `struct {}` off-emscripten

const c = zw.c;
pub const Instance = backend.Instance;

/// The switch `web.zig` reads. See `scene_gpu_off.zig` — the build picks which of the
/// two answers to the name `scene_gpu`, so the software build never names a wgpu module.
pub const enabled = true;

/// One instanced draw, in neither backend's dialect — both declare this shape with these
/// exact fields, so the caller builds it once and `render` hands it to whichever device
/// answered.
pub const Draw = struct {
    first_vertex: u32 = 0,
    vertex_count: u32,
    first_instance: u32 = 0,
    instance_count: u32,
};

fn drawsAs(comptime T: type, d: []const Draw, out: []T) []T {
    for (d, 0..) |x, i| out[i] = .{
        .first_vertex = x.first_vertex,
        .vertex_count = x.vertex_count,
        .first_instance = x.first_instance,
        .instance_count = x.instance_count,
    };
    return out[0..d.len];
}

/// Where each base mesh sits in the one vertex buffer — the caller needs these to say
/// "this run of instances is spheres, that one is tubes".
pub const Meshes = struct {
    sphere_first: u32 = 0,
    sphere_count: u32 = 0,
    tube_first: u32 = 0,
    tube_count: u32 = 0,
};

var g_meshes: Meshes = .{};
var g_ready = false;

const Wgpu = struct {
    gpu: backend.Gpu,
    surface: c.WGPUSurface,
    format: c.WGPUTextureFormat,
    mp: backend.MeshPresent,
    vbuf: c.WGPUBuffer,
    ibuf: c.WGPUBuffer = null,
    icap: u32 = 0, // instances the stream buffer currently holds
};
var g_wgpu: ?Wgpu = null;
var g_gl: ?gm.MeshPresent = null;

var g_instance: c.WGPUInstance = null;
var g_surface: c.WGPUSurface = null;
var g_adapter: c.WGPUAdapter = null;
var g_try: u8 = 0;
var g_canvas: [:0]const u8 = "#e8gpu";
var g_w: u32 = 1280;
var g_h: u32 = 720;

var g_err: [256]u8 = undefined;
var g_err_len: usize = 0;

/// The base meshes live here: cut once at boot, uploaded once, never grown.
var g_mesh_heap: [1 << 18]u8 = undefined;

fn fail(msg: []const u8) void {
    const n = @min(msg.len, g_err.len);
    @memcpy(g_err[0..n], msg[0..n]);
    g_err_len = n;
    std.log.err("{s}", .{msg});
}

// --- the console -----------------------------------------------------------------------
// Log and panic have to be REPLACED for this target, not merely redirected: std's default
// writes to stderr through `std.Io`, which drags in the threaded/posix machinery — code
// that has no meaning in a tab and does not even compile here. `web.zig` installs these
// as its root decls when this module is the live one.

extern "c" fn emscripten_console_log(msg: [*:0]const u8) void;
extern "c" fn emscripten_console_error(msg: [*:0]const u8) void;

pub fn consoleLog(
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

pub const panic_impl = std.debug.FullPanic(struct {
    fn f(msg: []const u8, _: ?usize) noreturn {
        var buf: [1024]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "panic: {s}", .{msg}) catch "panic";
        emscripten_console_error(z);
        @trap();
    }
}.f);

/// The last thing that went wrong, or "" — the page shows it rather than a blank canvas.
pub fn errorText() []const u8 {
    return g_err[0..g_err_len];
}

/// True once a device is up and `render` will actually draw. The adapter chain is async,
/// so the first frames answer false and the caller simply skips the scene.
pub fn ready() bool {
    return g_ready;
}

/// 2 = WebGPU, 1 = the WebGL2 twin, 0 = neither, yet. The readout names the device that
/// actually drew; "WebGPU" over a frame the twin made would be a lie.
pub fn device() u8 {
    if (g_wgpu != null) return 2;
    if (g_gl != null) return 1;
    return 0;
}

pub fn meshes() Meshes {
    return g_meshes;
}

// --- boot ----------------------------------------------------------------------------

/// Start the chain. Returns immediately: WebGPU's adapter and device arrive by callback,
/// and `ready()` turns true whenever one of the two devices has come up.
pub fn boot(canvas: [:0]const u8, w: u32, h: u32, force_gl: bool) void {
    g_canvas = canvas;
    g_w = @max(w, 1);
    g_h = @max(h, 1);
    if (force_gl) return startGl();
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
        // this browser still has WebGL2, and the twin draws the same scene through it.
        return startGl();
    }
    g_adapter = adapter;
    const desc = c.WGPUDeviceDescriptor{ .uncapturedErrorCallbackInfo = .{ .callback = onGpuError } };
    _ = c.wgpuAdapterRequestDevice(adapter, &desc, .{ .mode = c.WGPUCallbackMode_AllowSpontaneous, .callback = onDevice });
}

fn onDevice(status: c.WGPURequestDeviceStatus, dev: c.WGPUDevice, _: c.WGPUStringView, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (status != c.WGPURequestDeviceStatus_Success) {
        // A device refusal is not a dead end either — the twin is still there.
        std.log.warn("the adapter refused to give a device; falling to WebGL2", .{});
        return startGl();
    }
    startWgpu(dev) catch |e| {
        var buf: [128]u8 = undefined;
        fail(std.fmt.bufPrint(&buf, "the scene did not come up: {s}", .{@errorName(e)}) catch "the scene did not come up");
    };
}

fn onGpuError(_: [*c]const ?*c.struct_WGPUDeviceImpl, kind: c.WGPUErrorType, msg: c.WGPUStringView, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const text = if (msg.data) |d| d[0..msg.length] else "(no message)";
    std.log.err("wgpu error {d}: {s}", .{ kind, text });
}

fn baseMeshVerts() ![]const f32 {
    var fba = std.heap.FixedBufferAllocator.init(&g_mesh_heap);
    var verts: std.ArrayList(f32) = .empty;
    g_meshes = try buildMeshes(&verts, fba.allocator());
    return verts.items;
}

fn startWgpu(dev: c.WGPUDevice) !void {
    const verts = try baseMeshVerts();
    const queue = c.wgpuDeviceGetQueue(dev).?;
    g_surface = zw.surfaceFromCanvas(g_instance, g_canvas) catch return fail("no surface — the canvas is not there");
    var caps: c.WGPUSurfaceCapabilities = .{};
    _ = c.wgpuSurfaceGetCapabilities(g_surface, g_adapter, &caps);
    const format = if (caps.formatCount > 0) caps.formats[0] else c.WGPUTextureFormat_BGRA8Unorm;

    var gpu: backend.Gpu = .{ .dev = .{
        .instance = g_instance,
        .adapter = g_adapter,
        .device = dev,
        .queue = queue,
        .spirv = false,
    } };

    g_wgpu = .{
        .gpu = gpu,
        .surface = g_surface,
        .format = format,
        .mp = undefined,
        .vbuf = gpu.vertexBuffer(std.mem.sliceAsBytes(verts)),
    };
    const a = &g_wgpu.?;
    configure(a, g_w, g_h);
    // glow = 0: no bloom. Not for cost — because the WebGL2 twin has no bloom pass, and
    // the two devices agreeing matters more than either looking its best. The instance
    // alpha already carries the emissive weight this will feed when the twin grows one
    // (issue #88, follow-up 2).
    a.mp = try backend.MeshPresent.init(&a.gpu, std.heap.c_allocator, format, g_w, g_h, 0.0);
    g_ready = true;
    std.log.info("scene: WebGPU, {d}x{d}", .{ g_w, g_h });
}

fn startGl() void {
    const verts = baseMeshVerts() catch return fail("the base meshes did not build");
    var mp = gm.MeshPresent.init(g_canvas, g_w, g_h) catch
        return fail("no WebGPU adapter would answer, and WebGL2 refused a context too — this browser has no GPU path at all");
    mp.vertexData(std.mem.sliceAsBytes(verts));
    g_gl = mp;
    g_ready = true;
    std.log.info("scene: no WebGPU adapter — the WebGL2 twin has it, {d}x{d}", .{ g_w, g_h });
}

fn configure(a: *Wgpu, w: u32, h: u32) void {
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

pub fn resize(w: u32, h: u32) void {
    const iw = @max(w, 1);
    const ih = @max(h, 1);
    if (g_w == iw and g_h == ih) return;
    g_w = iw;
    g_h = ih;
    if (g_wgpu) |*a| {
        configure(a, iw, ih);
        a.mp.resize(iw, ih) catch |e| std.log.err("resize: {s}", .{@errorName(e)});
    }
    if (g_gl) |*gl| gl.resize(iw, ih);
}

// --- the frame -----------------------------------------------------------------------

/// The instance stream, big enough for this frame. A dropped file can carry 34 nodes or
/// 100,000 stars and the buffer was cut for whatever came before, so it grows (and only
/// grows) rather than truncating the catalogue to whatever last fitted.
fn ensureInstances(a: *Wgpu, n: u32) void {
    if (a.ibuf != null and a.icap >= n) return;
    if (a.ibuf) |old| c.wgpuBufferRelease(old);
    const cap = @max(n + n / 2, 1024);
    a.ibuf = c.wgpuDeviceCreateBuffer(a.gpu.dev.device, &.{
        .usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst,
        .size = @as(u64, cap) * @sizeOf(Instance),
    }).?;
    a.icap = cap;
}

/// One frame: the instances as the caller built them this tick, the draws that slice
/// them, and the camera. Silently does nothing before a device is up.
pub fn render(insts: []const Instance, draws: []const Draw, view_proj: [16]f32, clear: [4]f64) void {
    if (!g_ready or draws.len == 0 or insts.len == 0) return;

    var dbuf: [8]gm.InstancedDraw = undefined;
    var wbuf: [8]backend.InstancedDraw = undefined;
    if (draws.len > dbuf.len) return;
    const bytes = std.mem.sliceAsBytes(insts);

    if (g_gl) |*gl| {
        gl.instanceData(bytes);
        // The twin takes f32 (GLES clear colours are floats); WebGPU's descriptor is f64.
        const c32 = [4]f32{
            @floatCast(clear[0]), @floatCast(clear[1]),
            @floatCast(clear[2]), @floatCast(clear[3]),
        };
        // The twin's render now takes the frame it draws into (Zengine's depth-contract
        // seam); this renderer stands alone on its canvas, so the frame is its own —
        // framebuffer 0, cleared here, its depth nobody else's to share.
        _ = gl.render(gl.ownFrame(), drawsAs(gm.InstancedDraw, draws, &dbuf), .{ .view_proj = view_proj }, c32);
        return;
    }

    const a = &(g_wgpu orelse return);
    ensureInstances(a, @intCast(insts.len));
    c.wgpuQueueWriteBuffer(a.gpu.dev.queue, a.ibuf, 0, bytes.ptr, bytes.len);

    var st: c.WGPUSurfaceTexture = .{};
    c.wgpuSurfaceGetCurrentTexture(a.surface, &st);
    if (st.texture == null) return;
    const view = c.wgpuTextureCreateView(st.texture, null).?;
    defer c.wgpuTextureViewRelease(view);

    // Same depth-contract seam as the twin above: the frame is this renderer's own —
    // the swap-chain view it just took, with the MeshPresent's private depth behind it.
    _ = a.mp.render(a.mp.ownFrame(view), a.vbuf, a.ibuf, drawsAs(backend.InstancedDraw, draws, &wbuf), .{
        .view_proj = view_proj,
    }, clear);
    // No present call: on the web the compositor takes the canvas when this returns.
}

/// Orbit camera → view·projection, column-major, the way the seam's push block wants it.
///
/// `w` must come out as +t, the distance along the forward axis: the perspective divide
/// is z/w, and the z below is built assuming exactly that. Signing that row the other way
/// makes w = -t — negative for everything IN FRONT of the camera, so the whole scene
/// clips away and the canvas stays black at a confident 60 fps. It did, for as long as
/// this path went unwatched on a machine whose adapter answers.
pub fn viewProj(eye: [3]f32, aspect: f32, fovy: f32) [16]f32 {
    const f = norm(.{ -eye[0], -eye[1], -eye[2] }); // the target is the origin
    const s = norm(cross(f, .{ 0, 1, 0 }));
    const u = cross(s, f);

    const near: f32 = 0.05;
    const far: f32 = 100.0;
    const t = 1.0 / @tan(fovy * 0.5);

    const tx = -dot(s, eye);
    const ty = -dot(u, eye);
    const tz = dot(f, eye);

    const p0 = t / @max(aspect, 1e-6);
    const p1 = t;
    const p2 = far / (near - far);
    const p3 = (far * near) / (near - far);

    return .{
        p0 * s[0], p1 * u[0], p2 * -f[0],   f[0],
        p0 * s[1], p1 * u[1], p2 * -f[1],   f[1],
        p0 * s[2], p1 * u[2], p2 * -f[2],   f[2],
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

// --- the meshes ----------------------------------------------------------------------

/// A UV sphere and an open tube, concatenated into one stride-8 stream
/// (position, normal, uv). On a unit sphere the position IS the normal; on a tube the
/// normal is the radial direction — which is all the seam's Lambert asks for.
fn buildMeshes(verts: *std.ArrayList(f32), gpa: std.mem.Allocator) !Meshes {
    const seg = 12; // rings/segments: 240 spheres of these is cheap, and round enough

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
    return .{
        .sphere_first = 0,
        .sphere_count = sphere_count,
        .tube_first = tube_first,
        .tube_count = tube_count,
    };
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
