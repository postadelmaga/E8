//! The application core seam: shared state (`App`), the per-root/per-edge
//! visual contracts, and the comptime plugin registry.
//!
//! The explorer is plugin-first: every feature — projections, colors, filters,
//! selection, effects, edge modes, the paper atlas, the particle panel, the
//! CSV exporter — is a self-contained module in `src/plugins/`, listed once in
//! `plugin_list`. The core (main.zig) owns only the window, the camera, the
//! 8D→3D projection and the two rasterizers; everything else reaches the frame
//! through optional hooks, dispatched statically (`inline for` + `@hasDecl`,
//! zero indirection):
//!
//!   init(a)                  once, after the root system is built
//!   key(a, code) bool        evdev keycode on the render thread; true = handled
//!                            (first plugin to claim a key wins — registry order)
//!   frame(a)                 per frame, BEFORE the 8D→3D projection
//!   post(a)                  per frame, after p3/scr/vis are valid (picking, HUD)
//!   visual(a, i, *Visual)    per root, chained in registry order — later
//!                            plugins override earlier ones
//!   edgePairs(a) []const [2]u16   which lines to draw (first plugin wins)
//!   edgeVisual(a, i, j) ?EdgeVisual  style for one line; null skips it
//!   status(a, buf) []const u8     contribution to the HUD status line
//!
//! A new feature = one file in src/plugins/ + one line in `plugin_list`.
//! Plugin state is plain data in `P.State` (no atomics — key/frame/post/visual
//! all run on the render thread); cross-thread traffic stays in the core.

const std = @import("std");
const zrame = @import("zrame");
const e8 = @import("e8.zig");
const hud_mod = @import("hud.zig");

// --- the plugin registry ---------------------------------------------------------------
// Order matters twice: key dispatch stops at the first handler, and the visual
// chain applies in order (selection overrides filters, effects override both).

pub const plugin_list = .{
    @import("plugins/projections.zig"),
    @import("plugins/colors.zig"),
    @import("plugins/filters.zig"),
    @import("plugins/edges.zig"),
    @import("plugins/selection.zig"),
    @import("plugins/effects.zig"),
    @import("plugins/slides.zig"),
    @import("plugins/panel.zig"),
    @import("plugins/exporter.zig"),
};

/// One field per plugin, named by its `id`, typed by its `State` (or void).
pub const PluginStates = blk: {
    var names: [plugin_list.len][]const u8 = undefined;
    var types: [plugin_list.len]type = undefined;
    var attrs: [plugin_list.len]std.builtin.Type.StructField.Attributes = undefined;
    for (plugin_list, 0..) |P, i| {
        const T: type = if (@hasDecl(P, "State")) P.State else void;
        const dflt: T = if (T == void) {} else T{};
        names[i] = P.id;
        types[i] = T;
        attrs[i] = .{ .default_value_ptr = &dflt };
    }
    break :blk @Struct(.auto, null, &names, &types, &attrs);
};

/// A plugin's own state: `const st = app.state(@This());` from inside a hook.
pub fn StateOf(comptime P: type) type {
    return if (@hasDecl(P, "State")) P.State else void;
}

// --- window geometry ---------------------------------------------------------------------

/// GPU frame size; the CPU path follows the live window instead.
pub const frame_w: u32 = 1152;
pub const frame_h: u32 = 648;
/// Base window size: the frame plus glass bands for the HUD.
pub const win_w: u32 = frame_w + 48;
pub const win_h: u32 = frame_h + 120;

// --- visual contracts --------------------------------------------------------------------

/// How one root is drawn this frame. Both rasterizers consume the same struct:
/// the GPU maps `glow` to emissive (bloom amplifies it), the CPU maps `bright`
/// to disc shading and draws `halo`/`ring` as additive overlays.
pub const Visual = struct {
    color: [3]f32 = .{ 1, 1, 1 },
    /// Filter verdict — false renders dimmed and mutes effects.
    pass: bool = true,
    /// GPU emissive multiplier.
    glow: f32 = 0.85,
    /// CPU disc brightness multiplier.
    bright: f32 = 1.0,
    /// Multiplier on the base point radius.
    radius: f32 = 1.0,
    halo: ?Halo = null,
    ring: ?[3]f32 = null,
};

pub const Halo = struct {
    rgb: [3]f32,
    /// Screen radius = disc radius × this (+ a few px).
    radius_mul: f32,
    /// Additive intensity, 0..255 scale.
    k: f32,
};

/// How one edge line is drawn. `glow` feeds the GPU tube emissive, `k` the CPU
/// additive intensity, `width` scales the GPU tube radius.
pub const EdgeVisual = struct {
    color: [3]f32,
    glow: f32 = 0.16,
    k: f32 = 30.0,
    width: f32 = 1.0,
};

// --- cross-thread input (window thread → render thread) ---------------------------------

/// Camera orbit state, written by the window thread's mouse handlers and read
/// by the core each frame. Plugins may write it too (spin, reset).
pub var cam_yaw: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 0.65)));
pub var cam_pitch: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 0.35)));
pub var cam_dist: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 4.2)));

pub fn loadF32(a: *std.atomic.Value(u32)) f32 {
    return @bitCast(a.load(.monotonic));
}
pub fn storeF32(a: *std.atomic.Value(u32), v: f32) void {
    a.store(@bitCast(v), .monotonic);
}

/// SPSC key queue: the window thread pushes evdev codes, the render thread
/// drains them into `dispatchKey` — so plugin key handlers run on the render
/// thread and plugin state needs no atomics.
var key_ring: [32]u32 = undefined;
var key_head: std.atomic.Value(u32) = .init(0);
var key_tail: std.atomic.Value(u32) = .init(0);

pub fn pushKey(code: u32) void {
    const h = key_head.load(.monotonic);
    if (h -% key_tail.load(.acquire) >= key_ring.len) return; // full: drop
    key_ring[h % key_ring.len] = code;
    key_head.store(h +% 1, .release);
}

pub fn popKey() ?u32 {
    const t = key_tail.load(.monotonic);
    if (t == key_head.load(.acquire)) return null;
    const code = key_ring[t % key_ring.len];
    key_tail.store(t +% 1, .release);
    return code;
}

// --- the shared state --------------------------------------------------------------------

pub const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    win: *zrame.Window,
    hud: *hud_mod.Hud,

    // The root system (immutable after startup).
    roots: [e8.n_roots]e8.Root,
    edges: []const [2]u16,
    neighbors: [e8.n_roots][56]u16,
    triality: [e8.n_roots]u16,

    // View.
    basis: e8.Basis,
    preset: u32 = 1,
    /// Set by a plugin (R); the core resets the orbit camera and clears it.
    reset_camera: bool = false,

    // Per-frame data, core-written before `post`/draw.
    dt: f32 = 0,
    anim: f32 = 0,
    p3: [e8.n_roots][3]f32 = undefined,
    hidden: [e8.n_roots]f32 = undefined,
    /// Screen x, y + view depth; only valid where `vis` is true.
    scr: [e8.n_roots][3]f32 = undefined,
    vis: [e8.n_roots]bool = undefined,
    /// Resolved visual per root (core fills via `rootVisual` before drawing).
    visuals: [e8.n_roots]Visual = undefined,

    // Interaction.
    selected: i32 = -1,
    /// Pending click in frame-local pixels (core sets, selection consumes).
    pick: ?[2]f32 = null,
    /// Horizontal glass to reserve beside the frame (panel plugin).
    reserve_w: u32 = 0,
    status_dirty: bool = true,
    info_dirty: bool = true,

    state: PluginStates = .{},

    /// A plugin's own state slot.
    pub fn pluginState(a: *App, comptime P: type) *StateOf(P) {
        return &@field(a.state, P.id);
    }
};

// --- static dispatch ---------------------------------------------------------------------

pub fn dispatchInit(a: *App) void {
    inline for (plugin_list) |P| {
        if (comptime @hasDecl(P, "init")) P.init(a);
    }
}

pub fn dispatchKey(a: *App, code: u32) bool {
    inline for (plugin_list) |P| {
        if (comptime @hasDecl(P, "key")) {
            if (P.key(a, code)) return true;
        }
    }
    return false;
}

pub fn dispatchFrame(a: *App) void {
    inline for (plugin_list) |P| {
        if (comptime @hasDecl(P, "frame")) P.frame(a);
    }
}

pub fn dispatchPost(a: *App) void {
    inline for (plugin_list) |P| {
        if (comptime @hasDecl(P, "post")) P.post(a);
    }
}

pub fn rootVisual(a: *App, i: usize) Visual {
    var v: Visual = .{};
    inline for (plugin_list) |P| {
        if (comptime @hasDecl(P, "visual")) P.visual(a, i, &v);
    }
    return v;
}

/// The line set to draw this frame — first plugin that owns edges wins.
pub fn edgePairs(a: *App) []const [2]u16 {
    inline for (plugin_list) |P| {
        if (comptime @hasDecl(P, "edgePairs")) return P.edgePairs(a);
    }
    return &.{};
}

/// Style for one line; null skips it (e.g. selection-only mode).
pub fn edgeVisual(a: *App, ai: u16, bi: u16) ?EdgeVisual {
    inline for (plugin_list) |P| {
        if (comptime @hasDecl(P, "edgeVisual")) return P.edgeVisual(a, ai, bi);
    }
    return null;
}

/// Assemble the HUD status line from every plugin's contribution.
pub fn buildStatus(a: *App, buf: []u8) []const u8 {
    const sep = " · ";
    var len: usize = 0;
    inline for (plugin_list) |P| {
        if (comptime @hasDecl(P, "status")) {
            var tmp: [96]u8 = undefined;
            const s = P.status(a, &tmp);
            if (s.len > 0 and len + s.len + sep.len <= buf.len) {
                if (len > 0) {
                    @memcpy(buf[len..][0..sep.len], sep);
                    len += sep.len;
                }
                @memcpy(buf[len..][0..s.len], s);
                len += s.len;
            }
        }
    }
    return buf[0..len];
}
