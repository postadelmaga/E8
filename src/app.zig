//! The presenter framework's core seam: shared state (`App`), the visual
//! contracts, the domain interface types, and the comptime plugin registry.
//!
//! The framework is domain-agnostic. A domain package (src/demos/<name>/,
//! selected by `-Ddemo=`) supplies the points, their classifications and
//! stories, the projections, the slide deck and the plugin list; the core
//! (main.zig) owns only the window, the camera, the dim-D → 3D projection and
//! the two rasterizers. Features reach the frame through optional hooks,
//! dispatched statically (`inline for` + `@hasDecl`, zero indirection):
//!
//!   init(a) / deinit(a)      once, around the app's life
//!   key(a, code) bool        evdev keycode on the render thread; true = handled
//!   frame(a)                 per frame, BEFORE the projection
//!   post(a)                  per frame, after screen positions are valid
//!   visual(a, i, *Visual)    per point, chained in registry order
//!   edgePairs(a) / edgeVisual(a, i, j)   which lines to draw and how
//!   status(a, buf)           contribution to the HUD status line
//!
//! A new feature = one file + one line in the domain's `plugins` tuple.
//! Plugin state is plain data in `P.State` (hooks run on the render thread);
//! cross-thread traffic stays here (camera atomics, key queue).

const std = @import("std");
const zrame = @import("zrame");
const geom = @import("geom.zig");
const hud_mod = @import("hud.zig");
const domain = @import("domain.zig");
const descriptor = @import("descriptor.zig");
const render_gpu = @import("render_gpu.zig");

/// The active domain package (see src/domain.zig).
pub const D = domain.D;
pub const n = domain.n;
pub const dim = domain.dim;

pub const plugin_list = D.plugins;

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

pub fn StateOf(comptime P: type) type {
    return if (@hasDecl(P, "State")) P.State else void;
}

// --- the domain interface types ----------------------------------------------------------
// A domain exports (see demos/lisi/domain.zig for the reference):
//   name/title/app_id: []const u8 · dim/n: comptime ints · Point (with .v)
//   radius2: f32 — max |v|² (hidden-depth normalization)
//   generate() [n]Point · buildEdges(gpa, points) ![]const [2]u16
//   presets: []const PresetDef · color_modes: []const ColorModeDef
//   filters: []const FilterDef · relations: []const RelationDef
//   actions: []const ActionDef · plugins: tuple of plugin modules
//   descriptor(a, i) descriptor.Object — how a point looks/behaves
//   describe(a, i, buf) []const u8 — one-line HUD detail
//   story(a) void — fill the side panel for the selection (or overview)
//   inspect(a, i, tbuf, bbuf) struct{...} — popup text
//   figure(a, id, dots) usize — inline panel diagram
//   exportCsv(a) !void
//   deck_path: []const u8 · deck_default: [:0]const u8

pub const PresetDef = struct {
    name: []const u8,
    /// Basis for this preset; `theta` sweeps animated presets, ignored else.
    basis: *const fn (theta: f32) geom.Basis,
    animated: bool = false,
};

pub const ColorModeDef = struct {
    name: []const u8,
    color: *const fn (p: *const D.Point, hidden_t: f32) [3]f32,
    legend: []const hud_mod.Hud.LegendIn,
};

pub const FilterDef = struct {
    name: []const u8,
    pass: *const fn (p: *const D.Point) bool,
};

/// A partner map over the points (triality, chain succession, duality…): the
/// framework tabulates it, draws it as an edge mode, walks it as an orbit.
pub const RelationDef = struct {
    name: []const u8,
    partner: *const fn (points: []const D.Point, i: u16) u16,
};

pub const ActionDef = struct {
    key: u32,
    help: []const u8,
    run: *const fn (a: *App) void,
};

// --- window geometry ---------------------------------------------------------------------

pub const frame_w: u32 = 1152;
pub const frame_h: u32 = 648;
pub const win_w: u32 = frame_w + 48;
pub const win_h: u32 = frame_h + 120;

// --- visual contracts --------------------------------------------------------------------

pub const Visual = struct {
    color: [3]f32 = .{ 1, 1, 1 },
    pass: bool = true,
    glow: f32 = 0.85,
    bright: f32 = 1.0,
    radius: f32 = 1.0,
    halo: ?Halo = null,
    ring: ?[3]f32 = null,
};

pub const Halo = struct {
    rgb: [3]f32,
    radius_mul: f32,
    k: f32,
};

pub const EdgeVisual = struct {
    color: [3]f32,
    glow: f32 = 0.16,
    k: f32 = 30.0,
    width: f32 = 1.0,
};

// --- cross-thread input ------------------------------------------------------------------

pub var cam_yaw: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 0.65)));
pub var cam_pitch: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 0.35)));
pub var cam_dist: std.atomic.Value(u32) = .init(@bitCast(@as(f32, 4.2)));

pub fn loadF32(a: *std.atomic.Value(u32)) f32 {
    return @bitCast(a.load(.monotonic));
}
pub fn storeF32(a: *std.atomic.Value(u32), v: f32) void {
    a.store(@bitCast(v), .monotonic);
}

var key_ring: [32]u32 = undefined;
var key_head: std.atomic.Value(u32) = .init(0);
var key_tail: std.atomic.Value(u32) = .init(0);

pub fn pushKey(code: u32) void {
    const h = key_head.load(.monotonic);
    if (h -% key_tail.load(.acquire) >= key_ring.len) return;
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
    /// The zengine device, when one could be created. The main view uses it
    /// only with `--gpu`; plugins (the inspector's mini-scene) can always ask
    /// it for an extra `View`. Null when Vulkan/dmabuf is unavailable.
    gpu: ?*render_gpu.Gpu3d = null,

    // The point system (immutable after startup).
    points: [n]D.Point,
    edges: []const [2]u16,
    /// CSR adjacency over `edges` (degrees vary by domain).
    nbr_off: [n + 1]u32 = undefined,
    nbr: []u16 = &.{},
    /// Tabulated relation partner maps, one per D.relations entry.
    rel: [][]u16 = &.{},

    // View.
    basis: geom.Basis,
    preset: u32 = 0,
    reset_camera: bool = false,

    // Per-frame data.
    dt: f32 = 0,
    anim: f32 = 0,
    p3: [n][3]f32 = undefined,
    hidden: [n]f32 = undefined,
    scr: [n][3]f32 = undefined,
    vis: [n]bool = undefined,
    visuals: [n]Visual = undefined,

    // Interaction.
    selected: i32 = -1,
    pick: ?[2]f32 = null,
    reserve_w: u32 = 0,
    status_dirty: bool = true,
    info_dirty: bool = true,

    state: PluginStates = .{},

    pub fn pluginState(a: *App, comptime P: type) *StateOf(P) {
        return &@field(a.state, P.id);
    }

    /// Lattice neighbors of point `i` (from the domain's edge list).
    pub fn neighbors(a: *const App, i: usize) []const u16 {
        return a.nbr[a.nbr_off[i]..a.nbr_off[i + 1]];
    }

    /// The point's descriptor (delegates to the domain).
    pub fn objectOf(a: *App, i: usize) descriptor.Object {
        return D.descriptor(a, i);
    }

    /// Build adjacency and relation tables — call once after `edges` is set.
    pub fn initTables(a: *App) !void {
        var deg = try a.gpa.alloc(u32, n);
        defer a.gpa.free(deg);
        @memset(deg, 0);
        for (a.edges) |e| {
            deg[e[0]] += 1;
            deg[e[1]] += 1;
        }
        a.nbr_off[0] = 0;
        for (0..n) |i| a.nbr_off[i + 1] = a.nbr_off[i] + deg[i];
        a.nbr = try a.gpa.alloc(u16, a.nbr_off[n]);
        @memset(deg, 0);
        for (a.edges) |e| {
            a.nbr[a.nbr_off[e[0]] + deg[e[0]]] = e[1];
            a.nbr[a.nbr_off[e[1]] + deg[e[1]]] = e[0];
            deg[e[0]] += 1;
            deg[e[1]] += 1;
        }
        a.rel = try a.gpa.alloc([]u16, D.relations.len);
        for (D.relations, 0..) |rd, r| {
            a.rel[r] = try a.gpa.alloc(u16, n);
            for (0..n) |i| a.rel[r][i] = rd.partner(&a.points, @intCast(i));
        }
    }

    pub fn deinitTables(a: *App) void {
        for (a.rel) |t| a.gpa.free(t);
        a.gpa.free(a.rel);
        a.gpa.free(a.nbr);
    }
};

// --- static dispatch ---------------------------------------------------------------------

pub fn dispatchInit(a: *App) void {
    inline for (plugin_list) |P| {
        if (comptime @hasDecl(P, "init")) P.init(a);
    }
}

pub fn dispatchDeinit(a: *App) void {
    inline for (plugin_list) |P| {
        if (comptime @hasDecl(P, "deinit")) P.deinit(a);
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

pub fn edgePairs(a: *App) []const [2]u16 {
    inline for (plugin_list) |P| {
        if (comptime @hasDecl(P, "edgePairs")) return P.edgePairs(a);
    }
    return &.{};
}

pub fn edgeVisual(a: *App, ai: u16, bi: u16) ?EdgeVisual {
    inline for (plugin_list) |P| {
        if (comptime @hasDecl(P, "edgeVisual")) return P.edgeVisual(a, ai, bi);
    }
    return null;
}

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
