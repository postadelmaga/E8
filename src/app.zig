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
const log = @import("log.zig");
const zrame = @import("zrame");
const geom = @import("geom.zig");
const hud_mod = @import("hud.zig");
const domain = @import("domain.zig");
const descriptor = @import("descriptor.zig");
const platform = @import("platform.zig");
const still_mod = @import("still.zig");

/// The active domain package (see src/domain.zig).
pub const D = domain.D;
pub const dim = domain.dim;

/// The point count is NOT comptime: a generated domain knows it up front, a
/// loaded one (`D.load` — a file the user opened) only after reading the file.
/// Everything downstream sizes off `App.count()`; this is only the ceiling the
/// fixed-size scratch buffers use.
pub const max_points: usize = 100_000;

/// What the user asked for on the command line. A generated domain ignores all
/// of it; a domain that READS A FILE (see demos/data) is configured by it. Main
/// fills this before `loadPoints`; the slices point into the argv the process
/// owns for its whole life.
pub const Cli = struct {
    /// The file to open (the first non-flag argument).
    file: []const u8 = "",
    /// `--coords=a,b,c` — which columns are the coordinates (names or indices).
    coords: []const u8 = "",
    /// `--class=col` — the column whose values become the classes.
    class: []const u8 = "",
    /// `--label=col` — the column that names a point in the HUD.
    label: []const u8 = "",
    /// `--knn=k` — neighbors per point in the graph the framework draws.
    knn: u32 = 6,
    /// `--deck=path` — the slide deck to play. Empty means the domain's own
    /// (`D.deck_path`, then the embedded `D.deck_default`). A demo AUTHORED by the
    /// user is exactly this: someone else's deck over a domain that already exists,
    /// so the deck cannot be a fixed name relative to the working directory.
    deck: []const u8 = "",
    /// `--editor` — open the slide editor at startup. The launcher passes it both
    /// when authoring a new demo and when opening an existing one as an example.
    editor: bool = false,
};
pub var cli: Cli = .{};

/// The point set: `D.load(gpa, io)` when the domain reads it from a file,
/// `D.generate()` when it computes it. Caller owns the returned slice.
pub fn loadPoints(gpa: std.mem.Allocator, io: std.Io) ![]D.Point {
    if (comptime @hasDecl(D, "load")) return D.load(gpa, io);
    const g = D.generate();
    const out = try gpa.alloc(D.Point, g.len);
    @memcpy(out, &g);
    return out;
}

/// Release whatever a loading domain kept alongside the points (its table).
pub fn unloadPoints(gpa: std.mem.Allocator, points: []D.Point) void {
    if (comptime @hasDecl(D, "unload")) D.unload(gpa);
    gpa.free(points);
}

/// The domain names the plugins it wants; the TARGET decides which of them can
/// exist. A plugin that opens a second window, spawns a thread or writes a file
/// (the editor, the CSV export) marks itself `native_only` and is not in the
/// registry of a web build — the domain does not have to know there is one.
pub const plugin_list = blk: {
    if (!platform.web) break :blk D.plugins;
    var kept: []const type = &.{};
    for (D.plugins) |P| {
        if (@hasDecl(P, "native_only") and P.native_only) continue;
        kept = kept ++ [_]type{P};
    }
    var out: [kept.len]type = undefined;
    for (kept, 0..) |P, i| out[i] = P;
    const frozen = out;
    break :blk frozen;
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

/// The camera atomics have TWO writers — the window thread (drag, scroll) and
/// the render thread (spin, kiosk easing) — so a load→modify→store pair loses
/// whichever update lands between the load and the store. Relative updates go
/// through these CAS loops instead; absolute sets can keep `storeF32`.
pub fn addClampF32(a: *std.atomic.Value(u32), d: f32, lo: f32, hi: f32) void {
    var old = a.load(.monotonic);
    while (true) {
        const new: u32 = @bitCast(std.math.clamp(@as(f32, @bitCast(old)) + d, lo, hi));
        old = a.cmpxchgWeak(old, new, .monotonic, .monotonic) orelse return;
    }
}

pub fn mulClampF32(a: *std.atomic.Value(u32), m: f32, lo: f32, hi: f32) void {
    var old = a.load(.monotonic);
    while (true) {
        const new: u32 = @bitCast(std.math.clamp(@as(f32, @bitCast(old)) * m, lo, hi));
        old = a.cmpxchgWeak(old, new, .monotonic, .monotonic) orelse return;
    }
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
    /// The zengine device, when one could be created (`*render_gpu.Gpu3d`, opaque
    /// here). Only main.zig — which owns the renderers — knows what it is: the
    /// seam is deliberately untyped so that `app.zig`, and every plugin through
    /// it, does not import zengine. That is what lets the web build exist at all:
    /// a browser tab has no Vulkan, and now nothing in the framework asks for it.
    gpu: ?*anyopaque = null,

    // The point system (immutable after startup). Sized at RUNTIME: a generated
    // domain knows its count at comptime, a loaded one (a file the user opened)
    // only after reading it, and the framework must not care which.
    points: []D.Point,
    edges: []const [2]u16,
    /// CSR adjacency over `edges` (degrees vary by domain).
    nbr_off: []u32 = &.{},
    nbr: []u16 = &.{},
    /// Tabulated relation partner maps, one per D.relations entry.
    rel: [][]u16 = &.{},

    // View.
    basis: geom.Basis,
    preset: u32 = 0,
    reset_camera: bool = false,
    /// Re-orthonormalize the basis every frame (drift correction for the
    /// incremental rotations). A plugin that deliberately scales the basis —
    /// the Big Bang's Kasner shear — turns it off while its mode runs.
    renorm_basis: bool = true,

    // Per-frame data, one entry per point (allocated by `initTables`).
    dt: f32 = 0,
    anim: f32 = 0,
    p3: [][3]f32 = &.{},
    hidden: []f32 = &.{},
    scr: [][3]f32 = &.{},
    vis: []bool = &.{},
    visuals: []Visual = &.{},

    // Interaction.
    selected: i32 = -1,
    pick: ?[2]f32 = null,
    reserve_w: u32 = 0,
    status_dirty: bool = true,
    info_dirty: bool = true,

    /// The picture a slide put on screen, if any: while it is set the still IS
    /// the frame and the 3D scene is not drawn (src/still.zig). Owned by the
    /// slides plugin.
    still: ?*const still_mod.Still = null,
    /// The file the point system currently comes from, when a slide changed it
    /// (owned). Empty means "still the one the demo was opened with".
    source: []u8 = &.{},
    /// The file on the command line — what `source` falls back to.
    opened_with: []const u8 = "",
    /// Raised by `reloadPoints`: the point count changed under the renderer, so
    /// main.zig must re-size the buffers it allocated for the old one.
    points_changed: bool = false,

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

    /// How many points the loaded system has.
    pub fn count(a: *const App) usize {
        return a.points.len;
    }

    /// Allocate the per-point buffers and build the adjacency and relation
    /// tables — call once after `points` and `edges` are set.
    pub fn initTables(a: *App) !void {
        const np = a.points.len;
        a.p3 = try a.gpa.alloc([3]f32, np);
        a.hidden = try a.gpa.alloc(f32, np);
        a.scr = try a.gpa.alloc([3]f32, np);
        a.vis = try a.gpa.alloc(bool, np);
        a.visuals = try a.gpa.alloc(Visual, np);
        @memset(a.vis, false);
        // `post` hooks (the point card's neighbourhood map) read the visuals of the
        // frame before theirs — on the first frame there isn't one.
        @memset(a.visuals, .{});
        // The depth sort walks EVERY index, visible or not: garbage z (a NaN,
        // in particular) would hand pdq a comparator that is not a strict weak
        // order.
        @memset(a.scr, .{ 0, 0, 0 });

        var deg = try a.gpa.alloc(u32, np);
        defer a.gpa.free(deg);
        @memset(deg, 0);
        for (a.edges) |e| {
            deg[e[0]] += 1;
            deg[e[1]] += 1;
        }
        a.nbr_off = try a.gpa.alloc(u32, np + 1);
        a.nbr_off[0] = 0;
        for (0..np) |i| a.nbr_off[i + 1] = a.nbr_off[i] + deg[i];
        a.nbr = try a.gpa.alloc(u16, a.nbr_off[np]);
        @memset(deg, 0);
        for (a.edges) |e| {
            a.nbr[a.nbr_off[e[0]] + deg[e[0]]] = e[1];
            a.nbr[a.nbr_off[e[1]] + deg[e[1]]] = e[0];
            deg[e[0]] += 1;
            deg[e[1]] += 1;
        }
        a.rel = try a.gpa.alloc([]u16, D.relations.len);
        for (D.relations, 0..) |rd, r| {
            a.rel[r] = try a.gpa.alloc(u16, np);
            for (0..np) |i| a.rel[r][i] = rd.partner(a.points, @intCast(i));
        }
    }

    /// The file the points on screen came from.
    pub fn sourceName(a: *const App) []const u8 {
        return if (a.source.len > 0) a.source else a.opened_with;
    }

    /// Read `file` into the point system and rebuild everything sized by it.
    /// Assumes the previous system is already gone (see `reloadPoints`).
    fn install(a: *App, file: []const u8) !void {
        const owned = try a.gpa.dupe(u8, file);
        errdefer a.gpa.free(owned);
        // The domain takes its path from the command line — that was the only
        // place a file could come from until a slide could name one.
        cli.file = owned;

        const points = try D.load(a.gpa, a.io);
        errdefer unloadPoints(a.gpa, points);
        const edges = try D.buildEdges(a.gpa, points);
        errdefer a.gpa.free(edges);
        a.points = points;
        a.edges = edges;
        try a.initTables();

        if (a.source.len > 0) a.gpa.free(a.source);
        a.source = owned;
    }

    /// Swap the point system for the one in `file` — the same domain reading a
    /// different molecule, a different catalog. This is what a slide's `.data`
    /// does, and it is more than a convenience: a deck that can change what it is
    /// looking at, between slides, in one window, is the difference between a
    /// demo and a talk.
    ///
    /// Everything sized by the point count is rebuilt: the framework's tables
    /// here, each plugin's in its `reload` hook, the renderer's buffers in
    /// main.zig (which watches `points_changed`). The selection cannot survive —
    /// point 71 of a caffeine molecule is not point 71 of a protein.
    ///
    /// A domain keeps ONE table (`load`/`unload` are a singleton), so the old
    /// system must go before the new one is read: there is no instant where both
    /// exist. A file that then fails to load would leave an empty window — so the
    /// previous file goes back, and that one is known to load, because it is what
    /// was on screen a moment ago.
    pub fn reloadPoints(a: *App, file: []const u8) !void {
        if (comptime !@hasDecl(D, "load")) return error.DomainGeneratesItsPoints;
        // A slide that swaps the data swaps a FILE, and a tab has none — the deck a
        // browser plays is the embedded one, whose points came with it. The guard is
        // comptime so the branch is not merely skipped but never ANALYZED: below is
        // `std.fs.max_path_bytes`, and wasm32-freestanding has no PATH_MAX to give it
        // (the error names std/Io/Dir.zig and no file anyone wrote — see deck.zig).
        if (comptime platform.web) return error.NoDataFilesInATab;
        if (std.mem.eql(u8, a.sourceName(), file)) return; // already showing it

        var prev_buf: [std.fs.max_path_bytes]u8 = undefined;
        const prev_name = a.sourceName();
        if (prev_name.len > prev_buf.len) return error.NameTooLong;
        const prev = prev_buf[0..prev_name.len];
        @memcpy(prev, prev_name);

        a.selected = -1;
        a.info_dirty = true;
        a.deinitTables();
        unloadPoints(a.gpa, a.points);
        a.gpa.free(a.edges);
        a.points = &.{};
        a.edges = &.{};

        install(a, file) catch |e| {
            install(a, prev) catch |e2| {
                log.print(
                    "the deck asked for \"{s}\" ({s}), and \"{s}\" will not load back ({s}) — nothing left to show\n",
                    .{ file, @errorName(e), prev, @errorName(e2) },
                );
                std.process.exit(1);
            };
            a.points_changed = true;
            dispatchReload(a);
            return e;
        };
        a.points_changed = true;
        a.status_dirty = true;
        dispatchReload(a);
    }

    pub fn deinitSource(a: *App) void {
        if (a.source.len > 0) a.gpa.free(a.source);
        a.source = &.{};
    }

    pub fn deinitTables(a: *App) void {
        for (a.rel) |t| a.gpa.free(t);
        a.gpa.free(a.rel);
        a.gpa.free(a.nbr);
        a.gpa.free(a.nbr_off);
        a.gpa.free(a.visuals);
        a.gpa.free(a.vis);
        a.gpa.free(a.scr);
        a.gpa.free(a.hidden);
        a.gpa.free(a.p3);
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

/// The point system was replaced (`reloadPoints`): a plugin holding anything
/// sized by the point count — a per-point mask, a per-relation link list —
/// rebuilds it here. A plugin with no such state does not implement the hook and
/// pays nothing.
pub fn dispatchReload(a: *App) void {
    inline for (plugin_list) |P| {
        if (comptime @hasDecl(P, "reload")) P.reload(a);
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
            var tmp: [128]u8 = undefined;
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
