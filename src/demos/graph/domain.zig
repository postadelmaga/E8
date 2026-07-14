//! The networks profile.
//!
//! Open a GraphML or an edge list (`-Ddemo=graph run -- karate.graphml`) and the
//! network gets a geometry: the SPECTRAL layout — the eigenvectors of the graph
//! Laplacian, the coordinates a graph has whether or not anyone draws it. The
//! framework's whole trade (project R^k to 3D, rotate the hidden axes into view)
//! then means something concrete: you are rotating through the spectrum, and the
//! communities that were hiding behind the second eigenvector swing into view.
//!
//! Colors are the three questions a network is always asked: who is central
//! (degree), who belongs together (communities, by label propagation), and what
//! falls apart (connected components).

const std = @import("std");
const read = @import("read.zig");
const log = @import("../../log.zig");
const geom = @import("../../geom.zig");
const hud_mod = @import("../../hud.zig");
const desc = @import("../../descriptor.zig");
const keys = @import("../../keys.zig");
const app_mod = @import("../../app.zig");
const App = app_mod.App;

pub const name = "Network";
pub const title = "presenter — network (spectral layout, communities, centrality)";
pub const app_id = "dev.presenter.graph";

/// The first 8 non-trivial Laplacian eigenvectors: the graph's own coordinates.
pub const dim = 8;

pub const Point = struct {
    v: [dim]f32,
    degree: u16 = 0,
    community: u16 = 0,
    component: u16 = 0,
    row: u32 = 0,
};

pub var radius2: f32 = 1.0;

pub const plugins = .{
    @import("../../plugins/projections.zig"),
    @import("../../plugins/colors.zig"),
    @import("../../plugins/filters.zig"),
    @import("../../plugins/edges.zig"),
    @import("../../plugins/selection.zig"),
    @import("../../plugins/actions.zig"),
    @import("../../plugins/effects.zig"),
    @import("../../plugins/guide.zig"),
    @import("../../plugins/inspector.zig"),
    @import("../../plugins/slides.zig"),
    @import("../../plugins/editor.zig"),
    @import("../../plugins/panel.zig"),
    @import("../../plugins/exporter.zig"),
    @import("../../plugins/atmosphere.zig"),
};

const max_nodes: usize = 8000;
const max_communities: usize = 12;

var g: read.Graph = undefined;
var have = false;
var deg: []u16 = &.{};
var adj_off: []u32 = &.{};
var adj: []u16 = &.{};
var comm: []u16 = &.{};
var comp: []u16 = &.{};
var n_comm: usize = 0;
var n_comp: usize = 0;
var max_degree: u16 = 1;
/// The hub of each node's neighborhood — where H jumps.
var hub: []u16 = &.{};

fn palette(k: usize) [3]f32 {
    const golden: f32 = 0.61803398875;
    const h = @mod(@as(f32, @floatFromInt(k)) * golden + 0.08, 1.0);
    const i: u32 = @intFromFloat(h * 6.0);
    const f = h * 6.0 - @as(f32, @floatFromInt(i));
    const p: f32 = 0.38;
    const q: f32 = 1.0 - 0.62 * f;
    const t: f32 = 0.38 + 0.62 * f;
    return switch (i % 6) {
        0 => .{ 1.0, t, p },
        1 => .{ q, 1.0, p },
        2 => .{ p, 1.0, t },
        3 => .{ p, q, 1.0 },
        4 => .{ t, p, 1.0 },
        else => .{ 1.0, p, q },
    };
}

fn rampRgb(t: f32) [3]f32 {
    const x = std.math.clamp(t, 0, 1);
    if (x < 0.5) {
        const u = x * 2.0;
        return .{ 0.15 * (1 - u) + 0.10 * u, 0.25 * (1 - u) + 0.85 * u, 0.85 * (1 - u) + 0.90 * u };
    }
    const u = (x - 0.5) * 2.0;
    return .{ 0.10 * (1 - u) + 1.00 * u, 0.85 * (1 - u) + 0.92 * u, 0.90 * (1 - u) + 0.30 * u };
}

fn neighbors(i: usize) []const u16 {
    return adj[adj_off[i]..adj_off[i + 1]];
}

// --- loading ------------------------------------------------------------------------------------

pub fn load(gpa: std.mem.Allocator, io: std.Io) ![]Point {
    const path = app_mod.cli.file;
    if (path.len == 0) {
        log.print(
            \\the network domain needs a graph:
            \\  zig build -Ddemo=graph run -- karate.graphml
            \\  zig build -Ddemo=graph run -- edges.txt      (one "a b" per line)
            \\
        , .{});
        return error.NoInputFile;
    }
    g = try read.load(gpa, io, path, max_nodes);
    have = true;
    errdefer {
        g.deinit();
        have = false;
    }
    const n = g.names.len;

    // CSR adjacency: the layout, the communities and the components all walk it.
    deg = try gpa.alloc(u16, n);
    @memset(deg, 0);
    for (g.edges) |e| {
        deg[e[0]] += 1;
        deg[e[1]] += 1;
    }
    adj_off = try gpa.alloc(u32, n + 1);
    adj_off[0] = 0;
    for (0..n) |i| adj_off[i + 1] = adj_off[i] + deg[i];
    adj = try gpa.alloc(u16, adj_off[n]);
    var fill = try gpa.alloc(u32, n);
    defer gpa.free(fill);
    @memset(fill, 0);
    for (g.edges) |e| {
        adj[adj_off[e[0]] + fill[e[0]]] = e[1];
        adj[adj_off[e[1]] + fill[e[1]]] = e[0];
        fill[e[0]] += 1;
        fill[e[1]] += 1;
    }
    max_degree = 1;
    for (deg) |d| max_degree = @max(max_degree, d);

    const pts = try gpa.alloc(Point, n);
    errdefer gpa.free(pts);
    for (pts, 0..) |*p, i| {
        p.* = .{ .v = std.mem.zeroes([dim]f32), .degree = deg[i], .row = @intCast(i) };
    }

    try spectralLayout(gpa, pts);
    try communities(gpa, pts);
    try components(gpa, pts);

    hub = try gpa.alloc(u16, n);
    for (0..n) |i| {
        var best: u16 = @intCast(i);
        var best_d: u16 = 0;
        for (neighbors(i)) |j| {
            if (deg[j] > best_d) {
                best_d = deg[j];
                best = j;
            }
        }
        hub[i] = best;
    }

    buildMenus();
    log.print("network: {s} — {d} nodes · {d} edges · {d} communities · {d} components · max degree {d}\n", .{
        path, n, g.edges.len, n_comm, n_comp, max_degree,
    });
    return pts;
}

pub fn unload(gpa: std.mem.Allocator) void {
    if (deg.len > 0) gpa.free(deg);
    if (adj_off.len > 0) gpa.free(adj_off);
    if (adj.len > 0) gpa.free(adj);
    if (comm.len > 0) gpa.free(comm);
    if (comp.len > 0) gpa.free(comp);
    if (hub.len > 0) gpa.free(hub);
    deg = &.{};
    adj_off = &.{};
    adj = &.{};
    comm = &.{};
    comp = &.{};
    hub = &.{};
    if (have) {
        g.deinit();
        have = false;
    }
}

pub fn buildEdges(gpa: std.mem.Allocator, points: []const Point) ![]const [2]u16 {
    _ = points;
    return gpa.dupe([2]u16, g.edges);
}

/// The spectral embedding: the eigenvectors of the normalized Laplacian, from
/// the second up. Power iteration on (2I − L̃) — whose top eigenvectors are L̃'s
/// bottom ones — with the trivial vector (√degree) and the axes already found
/// deflated out at every step. That first non-trivial vector is the Fiedler
/// vector: the cut the graph makes if you force it to make one.
fn spectralLayout(gpa: std.mem.Allocator, pts: []Point) !void {
    const n = pts.len;
    const axes = try gpa.alloc(f32, dim * n);
    defer gpa.free(axes);
    const trivial = try gpa.alloc(f32, n); // √d, the eigenvector of eigenvalue 0
    defer gpa.free(trivial);
    var tnorm: f32 = 0;
    for (0..n) |i| {
        trivial[i] = @sqrt(@as(f32, @floatFromInt(@max(deg[i], 1))));
        tnorm += trivial[i] * trivial[i];
    }
    tnorm = @sqrt(@max(tnorm, 1e-12));
    for (trivial) |*x| x.* /= tnorm;

    const v = try gpa.alloc(f32, n);
    defer gpa.free(v);
    const w = try gpa.alloc(f32, n);
    defer gpa.free(w);

    var prng = std.Random.DefaultPrng.init(0x5EED_6009);
    const rnd = prng.random();

    for (0..dim) |axis| {
        for (0..n) |i| v[i] = rnd.floatNorm(f32);
        for (0..200) |_| {
            // w = (2I − L̃)v, with L̃ = I − D^-½ A D^-½.
            for (0..n) |i| {
                var s: f32 = 0;
                const di = @sqrt(@as(f32, @floatFromInt(@max(deg[i], 1))));
                for (neighbors(i)) |j| {
                    const dj = @sqrt(@as(f32, @floatFromInt(@max(deg[j], 1))));
                    s += v[j] / (di * dj);
                }
                w[i] = v[i] + s; // (2I − (I − S))v = (I + S)v
            }
            // Deflate the trivial vector and every axis already taken.
            var d: f32 = 0;
            for (0..n) |i| d += w[i] * trivial[i];
            for (0..n) |i| w[i] -= d * trivial[i];
            for (0..axis) |a| {
                var e: f32 = 0;
                for (0..n) |i| e += w[i] * axes[a * n + i];
                for (0..n) |i| w[i] -= e * axes[a * n + i];
            }
            var len: f32 = 0;
            for (w) |x| len += x * x;
            len = @sqrt(len);
            if (len < 1e-9) break;
            for (0..n) |i| v[i] = w[i] / len;
        }
        @memcpy(axes[axis * n ..][0..n], v);
        for (0..n) |i| pts[i].v[axis] = v[i];
    }

    // The eigenvectors come out unit-norm, so a big graph draws a tiny cloud:
    // scale to the unit ball like every other domain.
    var max_r: f32 = 0;
    for (pts) |*p| {
        var s: f32 = 0;
        for (0..dim) |k| s += p.v[k] * p.v[k];
        max_r = @max(max_r, @sqrt(s));
    }
    if (max_r > 1e-9) {
        for (pts) |*p| {
            for (0..dim) |k| p.v[k] /= max_r;
        }
    }
    radius2 = 1.0;
}

/// Communities by label propagation: every node takes the label most of its
/// neighbors carry, until nothing moves. No parameter, no resolution to tune —
/// and on the graphs people actually publish it recovers the modules Louvain
/// finds.
fn communities(gpa: std.mem.Allocator, pts: []Point) !void {
    const n = pts.len;
    comm = try gpa.alloc(u16, n);
    for (0..n) |i| comm[i] = @intCast(i);
    var count = try gpa.alloc(u16, n);
    defer gpa.free(count);
    var order = try gpa.alloc(u32, n);
    defer gpa.free(order);
    for (0..n) |i| order[i] = @intCast(i);
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();

    for (0..20) |_| {
        rnd.shuffle(u32, order);
        var moved = false;
        for (order) |oi| {
            const i: usize = oi;
            const nb = neighbors(i);
            if (nb.len == 0) continue;
            @memset(count, 0);
            var best: u16 = comm[i];
            var best_n: u16 = 0;
            for (nb) |j| {
                const c = comm[j];
                count[c] += 1;
                if (count[c] > best_n) {
                    best_n = count[c];
                    best = c;
                }
            }
            if (best != comm[i]) {
                comm[i] = best;
                moved = true;
            }
        }
        if (!moved) break;
    }

    // Relabel to 0..n_comm-1, biggest first, and fold the tail into the last slot.
    var sizes = try gpa.alloc(u32, n);
    defer gpa.free(sizes);
    @memset(sizes, 0);
    for (comm) |c| sizes[c] += 1;
    var rank = try gpa.alloc(u16, n);
    defer gpa.free(rank);
    @memset(rank, std.math.maxInt(u16));
    n_comm = 0;
    while (n_comm < max_communities) {
        var best: ?usize = null;
        var best_size: u32 = 0;
        for (0..n) |c| {
            if (sizes[c] > best_size and rank[c] == std.math.maxInt(u16)) {
                best_size = sizes[c];
                best = c;
            }
        }
        const b = best orelse break;
        if (best_size == 0) break;
        rank[b] = @intCast(n_comm);
        n_comm += 1;
    }
    for (pts, 0..) |*p, i| {
        const r = rank[comm[i]];
        p.community = if (r == std.math.maxInt(u16)) @intCast(@max(n_comm, 1) - 1) else r;
        comm[i] = p.community;
    }
    if (n_comm == 0) n_comm = 1;
}

/// Connected components — what falls apart when you are not looking.
fn components(gpa: std.mem.Allocator, pts: []Point) !void {
    const n = pts.len;
    n_comp = 0;
    // Every node is pushed at most once (it is marked first), so n entries hold
    // the worst case.
    const stack = try gpa.alloc(u16, n);
    defer gpa.free(stack);
    for (pts) |*p| p.component = std.math.maxInt(u16);
    for (0..n) |s| {
        if (pts[s].component != std.math.maxInt(u16)) continue;
        const c: u16 = @intCast(@min(n_comp, max_communities - 1));
        var top: usize = 0;
        stack[top] = @intCast(s);
        top += 1;
        pts[s].component = c;
        while (top > 0) {
            top -= 1;
            const i = stack[top];
            for (neighbors(i)) |j| {
                if (pts[j].component != std.math.maxInt(u16)) continue;
                pts[j].component = c;
                stack[top] = j;
                top += 1;
            }
        }
        n_comp += 1;
    }
}

// --- projections: which slice of the spectrum ------------------------------------------------

fn pickAxes(a: usize, b: usize, c: usize) geom.Basis {
    var basis: geom.Basis = std.mem.zeroes(geom.Basis);
    basis[0][@min(a, dim - 1)] = 1;
    basis[1][@min(b, dim - 1)] = 1;
    basis[2][@min(c, dim - 1)] = 1;
    return basis;
}

fn bFiedler(_: f32) geom.Basis {
    return pickAxes(0, 1, 2);
}
fn bDeeper(_: f32) geom.Basis {
    return pickAxes(3, 4, 5);
}
fn bSpectrum(theta: f32) geom.Basis {
    var b = pickAxes(0, 1, 2);
    for (3..dim) |k| geom.rotateBasis(&b, k % 3, k, theta * (0.3 + 0.07 * @as(f32, @floatFromInt(k))));
    geom.orthonormalize(&b);
    return b;
}

pub const presets = &[_]app_mod.PresetDef{
    .{ .name = "spectral 1-2-3 (Fiedler)", .basis = bFiedler },
    .{ .name = "spectral 4-5-6", .basis = bDeeper },
    .{ .name = "through the spectrum", .basis = bSpectrum, .animated = true },
};

// --- colors, filters, relations -------------------------------------------------------------

fn colorByDegree(p: *const Point, _: f32) [3]f32 {
    const t = @log(1.0 + @as(f32, @floatFromInt(p.degree))) / @log(1.0 + @as(f32, @floatFromInt(max_degree)));
    return rampRgb(t);
}
fn colorByCommunity(p: *const Point, _: f32) [3]f32 {
    return palette(p.community);
}
fn colorByComponent(p: *const Point, _: f32) [3]f32 {
    if (n_comp <= 1) return .{ 0.55, 0.78, 1.0 };
    return palette(p.component + 5);
}

var legend_deg = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 38, 64, 217 }, .label = "leaf" },
    .{ .rgb = .{ 255, 235, 77 }, .label = "hub" },
};
var legend_comm: [max_communities]hud_mod.Hud.LegendIn = undefined;
var comm_labels: [max_communities][12]u8 = undefined;
var legend_comp = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 140, 199, 255 }, .label = "one component per color" },
};

var color_buf: [3]app_mod.ColorModeDef = undefined;
pub var color_modes: []const app_mod.ColorModeDef = &.{};
var filter_buf: [3 + max_communities]app_mod.FilterDef = undefined;
pub var filters: []const app_mod.FilterDef = &.{};
var relation_buf: [1]app_mod.RelationDef = undefined;
pub var relations: []const app_mod.RelationDef = &.{};

fn fAll(_: *const Point) bool {
    return true;
}
fn fHubs(p: *const Point) bool {
    // The top decile by degree — where a network's function actually sits.
    return @as(f32, @floatFromInt(p.degree)) >= 0.5 * @as(f32, @floatFromInt(max_degree));
}
fn fGiant(p: *const Point) bool {
    return p.component == 0;
}
fn fCommFn(comptime k: u16) *const fn (p: *const Point) bool {
    return struct {
        fn f(p: *const Point) bool {
            return p.community == k;
        }
    }.f;
}

fn buildMenus() void {
    for (0..n_comm) |k| {
        const rgb = palette(k);
        const s = std.fmt.bufPrint(&comm_labels[k], "community {d}", .{k}) catch "community";
        legend_comm[k] = .{
            .rgb = .{ @intFromFloat(rgb[0] * 255), @intFromFloat(rgb[1] * 255), @intFromFloat(rgb[2] * 255) },
            .label = s,
        };
    }
    color_buf[0] = .{ .name = "communities", .color = colorByCommunity, .legend = legend_comm[0..n_comm] };
    color_buf[1] = .{ .name = "degree", .color = colorByDegree, .legend = &legend_deg };
    color_buf[2] = .{ .name = "components", .color = colorByComponent, .legend = &legend_comp };
    color_modes = color_buf[0..3];

    var nf: usize = 0;
    filter_buf[nf] = .{ .name = "all nodes", .pass = fAll };
    nf += 1;
    filter_buf[nf] = .{ .name = "hubs", .pass = fHubs };
    nf += 1;
    filter_buf[nf] = .{ .name = "giant component", .pass = fGiant };
    nf += 1;
    inline for (0..max_communities) |k| {
        if (k < n_comm) {
            filter_buf[nf] = .{ .name = comm_labels[k][0..11], .pass = fCommFn(@intCast(k)) };
            nf += 1;
        }
    }
    filters = filter_buf[0..nf];

    relation_buf[0] = .{ .name = "hub of the neighborhood", .partner = hubPartner };
    relations = relation_buf[0..1];
}

fn hubPartner(_: []const Point, i: u16) u16 {
    if (i < hub.len) return hub[i];
    return i;
}

fn actHub(a: *App) void {
    if (a.selected >= 0 and hub.len > 0) {
        a.selected = hub[@intCast(a.selected)];
        a.info_dirty = true;
    }
}

pub const actions = &[_]app_mod.ActionDef{
    .{ .key = keys.domain_j, .help = "J: climb to the hub of this node's neighborhood", .run = actHub },
};

// --- readouts ---------------------------------------------------------------------------------

/// The local clustering coefficient: of the pairs of my neighbors, how many are
/// themselves connected? The number that separates a clique from a star.
fn clustering(i: usize) f32 {
    const nb = neighbors(i);
    if (nb.len < 2) return 0;
    var links: usize = 0;
    for (nb, 0..) |a, x| {
        for (nb[x + 1 ..]) |b| {
            for (neighbors(a)) |c| {
                if (c == b) links += 1;
            }
        }
    }
    const pairs = nb.len * (nb.len - 1) / 2;
    return @as(f32, @floatFromInt(links)) / @as(f32, @floatFromInt(pairs));
}

pub fn descriptor(a: *App, i: usize) desc.Object {
    const p = &a.points[i];
    const t = @as(f32, @floatFromInt(p.degree)) / @as(f32, @floatFromInt(max_degree));
    return .{
        .orbit_rgb = palette(p.community),
        .orbit_phase = @as(f32, @floatFromInt(p.community)) * 0.6,
        // Hubs are bigger: centrality is the one thing a network drawing must show.
        .radius = 0.75 + 1.6 * t,
        .glow = 0.8 + 0.9 * t,
    };
}

fn nameOf(i: usize) []const u8 {
    if (i < g.names.len) return g.names[i];
    return "node";
}

pub fn describe(a: *App, i: usize, buf: []u8) []const u8 {
    const p = &a.points[i];
    return std.fmt.bufPrint(buf, "{s} · degree {d} · community {d} · clustering {d:.2} · J climbs to {s}", .{
        nameOf(i),
        p.degree,
        p.community,
        clustering(i),
        nameOf(if (hub.len > 0) hub[i] else i),
    }) catch "node";
}

pub fn story(a: *App) void {
    const hud = a.hud;
    if (a.selected < 0) {
        var buf: [720]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{d} nodes, {d} edges, {d} connected component(s). The positions are not a drawing anyone chose: they are the graph's own SPECTRUM — the eigenvectors of the normalized Laplacian, from the second up. Axis 1 is the Fiedler vector, the cut the graph makes if forced to make one.
            \\So rotating the hidden axes (←/→, or the animated preset) walks you through the spectrum: the split that hides behind eigenvector 4 swings into view like any other rotation.
            \\C: communities (label propagation), degree, components. S: hubs, the giant component, one community at a time. J climbs from a node to the hub of its neighborhood.
        , .{ a.points.len, g.edges.len, n_comp }) catch "";
        hud.setPanel("The network", body, app_mod.cli.file);
        return;
    }
    const i: usize = @intCast(a.selected);
    const p = &a.points[i];
    var tb: [96]u8 = undefined;
    const t = std.fmt.bufPrint(&tb, "{s}", .{nameOf(i)}) catch "node";
    var bb: [720]u8 = undefined;
    var w: std.Io.Writer = .fixed(&bb);
    w.print("degree: {d} (max in this graph: {d})\ncommunity: {d} · component: {d}\nclustering coefficient: {d:.2}\n\nneighbors:\n", .{
        p.degree, max_degree, p.community, p.component, clustering(i),
    }) catch {};
    for (neighbors(i), 0..) |j, k| {
        if (k >= 8) {
            w.print("  … and {d} more\n", .{neighbors(i).len - 8}) catch {};
            break;
        }
        w.print("  {s} (degree {d})\n", .{ nameOf(j), deg[j] }) catch break;
    }
    hud.setPanel(t, w.buffered(), "");
}

pub const InspectText = struct { title_len: usize, body_len: usize };

pub fn inspect(a: *App, i: usize, tbuf: *[96]u8, bbuf: *[512]u8) InspectText {
    const p = &a.points[i];
    const t = std.fmt.bufPrint(tbuf, "{s} — degree {d}", .{ nameOf(i), p.degree }) catch "";
    var w: std.Io.Writer = .fixed(bbuf);
    w.print("Community {d} of {d}, component {d}. Clustering {d:.2}: {s}\n\nThe lit orbit is the climb H takes — from here to the hub of the neighborhood ({s}, degree {d}).\n\nPosition is spectral: the node's coordinates in the Laplacian's eigenvectors, not a force layout anyone tuned.", .{
        p.community,
        n_comm,
        p.component,
        clustering(i),
        if (clustering(i) > 0.5) "its neighbors know each other — a clique" else "its neighbors barely know each other — a broker",
        nameOf(if (hub.len > 0) hub[i] else i),
        if (hub.len > 0) deg[hub[i]] else 0,
    }) catch {};
    return .{ .title_len = t.len, .body_len = w.buffered().len };
}

/// The degree distribution — the first plot of every network paper, and the one
/// that says whether the graph is scale-free or just random.
pub fn figure(a: *App, fig_id: []const u8, dots: []hud_mod.FigDot) usize {
    if (!std.mem.eql(u8, fig_id, "degrees")) return 0;
    var hist: [64]u32 = .{0} ** 64;
    for (a.points) |p| {
        const b = @min(p.degree, 63);
        hist[b] += 1;
    }
    var hi: u32 = 1;
    for (hist) |h| hi = @max(hi, h);
    var n_dots: usize = 0;
    for (hist, 0..) |h, d| {
        if (h == 0 or n_dots >= dots.len) continue;
        const x = @as(f32, @floatFromInt(d)) / 63.0 * 2.0 - 1.0;
        const y = @log(1.0 + @as(f32, @floatFromInt(h))) / @log(1.0 + @as(f32, @floatFromInt(hi))) * 1.6 - 0.8;
        const rgb = rampRgb(@as(f32, @floatFromInt(d)) / @as(f32, @floatFromInt(max_degree)));
        dots[n_dots] = .{
            .x = x,
            .y = y,
            .rgb = .{ @intFromFloat(rgb[0] * 255), @intFromFloat(rgb[1] * 255), @intFromFloat(rgb[2] * 255) },
        };
        n_dots += 1;
    }
    return n_dots;
}

pub fn exportCsv(a: *App) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a.gpa);
    try out.appendSlice(a.gpa, "node,degree,community,component,clustering,spec1,spec2,spec3,view_x,view_y,view_z\n");
    var buf: [256]u8 = undefined;
    for (a.points, 0..) |*p, i| {
        const line = try std.fmt.bufPrint(&buf, "{s},{d},{d},{d},{d:.3},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4}\n", .{
            nameOf(i),      p.degree,   p.community, p.component, clustering(i),
            p.v[0],         p.v[1],     p.v[2],      a.p3[i][0],  a.p3[i][1],
            a.p3[i][2],
        });
        try out.appendSlice(a.gpa, line);
    }
    try std.Io.Dir.cwd().writeFile(a.io, .{ .sub_path = "network_nodes.csv", .data = out.items });
    log.print("exported network_nodes.csv ({d} nodes)\n", .{a.count()});
}

pub const deck_path = "deck.zon";
pub const deck_default: [:0]const u8 = @embedFile("deck.zon");
