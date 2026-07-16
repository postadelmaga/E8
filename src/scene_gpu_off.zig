//! `scene_gpu` for the build that has no GPU to talk to — the software web build.
//!
//! `web.zig` is ONE file with two rasterizers. The alternative was a second copy of the
//! file, and with it a second copy of the window, the input, the plugins and the deck —
//! which is the thing this codebase keeps refusing to do, because two copies of a
//! harness drift and the one nobody is looking at is the one that rots.
//!
//! The choice is made by the BUILD, not by a flag in the source: `web.zig` imports the
//! module named `scene_gpu`, and build.zig points that name at the real thing for
//! `zig build web-gpu` and at this file for `zig build web`. So the software build never
//! names `zicro_wgpu` or `ze_wgpu` at all — it cannot, they are emscripten-only — and
//! `if (scene.enabled)` is comptime false, so Zig never analyses the branch that would.
//!
//! Nothing here is ever called. The declarations exist so the import resolves, and the
//! layout of `Instance` is honest so a stray `@sizeOf` cannot quietly disagree.

const std = @import("std");

/// The one decl that matters: it makes every GPU branch in `web.zig` comptime-dead.
pub const enabled = false;

/// The freestanding build keeps std's defaults — it has always compiled with them, and
/// the console shims exist only because emscripten's std drags posix machinery in.
pub const panic_impl = std.debug.FullPanic(std.debug.defaultPanic);
pub fn consoleLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime fmt: []const u8,
    args: anytype,
) void {
    _ = .{ level, scope, fmt, args };
}

/// 64 bytes — `rhi_wgpu.Instance`: three affine rows and a colour whose alpha is the
/// seam's emissive weight.
pub const Instance = extern struct {
    row0: [4]f32 = .{ 1, 0, 0, 0 },
    row1: [4]f32 = .{ 0, 1, 0, 0 },
    row2: [4]f32 = .{ 0, 0, 1, 0 },
    color: [4]f32 = .{ 1, 1, 1, 1 },
};

pub const Draw = struct {
    first_vertex: u32 = 0,
    vertex_count: u32,
    first_instance: u32 = 0,
    instance_count: u32,
};

pub const Meshes = struct {
    sphere_first: u32 = 0,
    sphere_count: u32 = 0,
    tube_first: u32 = 0,
    tube_count: u32 = 0,
};

pub fn boot(_: [:0]const u8, _: u32, _: u32, _: bool) void {}
pub fn resize(_: u32, _: u32) void {}
pub fn render(_: []const Instance, _: []const Draw, _: [16]f32, _: [4]f64) void {}
pub fn ready() bool {
    return false;
}
pub fn device() u8 {
    return 0;
}
pub fn meshes() Meshes {
    return .{};
}
pub fn errorText() []const u8 {
    return "";
}
pub fn viewProj(_: [3]f32, _: f32, _: f32) [16]f32 {
    return .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
}
