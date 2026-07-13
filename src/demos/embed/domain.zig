//! The embeddings profile — the ML field mode.
//!
//! Feed it the vectors you already have (`vectors.npy`, or any CSV whose numeric
//! columns are the vector) and it gives you the two views an embedding is always
//! read through, side by side and in the same window:
//!
//!   * the principal axes — the honest LINEAR shadow, distances you can trust;
//!   * t-SNE in 3D — the neighborhood view, distances you cannot trust but
//!     clusters you can see.
//!
//! Both live in the same R^16 point: coordinates 0..12 hold the leading
//! principal components, 13..15 hold the t-SNE embedding, and a "projection" is
//! just which of those axes the basis selects. Switching views (keys 1..4) is
//! then a rotation, not a reload — and the same selection, the same neighbors and
//! the same colors follow you across.
//!
//! Neighbors and clusters are computed in the ORIGINAL vector space (cosine for
//! the graph, k-means for the clusters), never in the projection: the whole point
//! is to see where the projection lies about them.
//!
//! Usage:
//!   zig build -Ddemo=embed run -- vectors.npy --label=names.txt
//!   zig build -Ddemo=embed run -- embeddings.csv --class=category --knn=8

const std = @import("std");
const npy = @import("npy.zig");
const reduce = @import("reduce.zig");
const table = @import("../data/table.zig");
const geom = @import("../../geom.zig");
const hud_mod = @import("../../hud.zig");
const desc = @import("../../descriptor.zig");
const app_mod = @import("../../app.zig");
const App = app_mod.App;

pub const name = "Embeddings";
pub const title = "presenter — embeddings (PCA ⇄ t-SNE, cosine neighbors)";
pub const app_id = "dev.presenter.embed";

/// 13 principal components + the 3 t-SNE axes.
pub const dim = 16;
const n_pc_max: usize = 13;
const tsne_axis: usize = 13;

pub const Point = struct {
    v: [dim]f32,
    /// Class (the label column), or the k-means cluster when there is no label.
    cls: u16 = 0,
    cluster: u16 = 0,
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
    @import("../../plugins/slides.zig"),
    @import("../../plugins/editor.zig"),
    @import("../../plugins/panel.zig"),
    @import("../../plugins/inspector.zig"),
    @import("../../plugins/exporter.zig"),
    @import("../../plugins/atmosphere.zig"),
};

const max_rows: usize = 4000; // exact t-SNE and the cosine graph are both O(n²)
const max_classes: usize = 12;
const n_clusters: usize = 8;

// --- the loaded embedding -------------------------------------------------------------------

var gpa_ref: std.mem.Allocator = undefined;
/// The original vectors, row-major — every neighbor and cluster is computed here.
var vec: []f32 = &.{};
var n_rows: usize = 0;
var n_dims: usize = 0; // the embedding's own dimensionality (300, 768, …)
var n_pcs: usize = 0;
/// Labels: one name per point (slices into `label_text` or into the table).
var labels: [][]const u8 = &.{};
var label_text: []u8 = &.{};
var class_of: []u16 = &.{};
var class_names: [][]const u8 = &.{};
var n_classes: usize = 0;
var nn: []u16 = &.{};
var nn_sim: []f32 = &.{};
var norm_of: []f32 = &.{};
var have_tsne = false;
var tbl: ?table.Table = null;

fn classRgb(k: usize) [3]f32 {
    const golden: f32 = 0.61803398875;
    const h = @mod(@as(f32, @floatFromInt(k)) * golden, 1.0);
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

fn cosine(i: usize, j: usize) f32 {
    const a = vec[i * n_dims ..][0..n_dims];
    const b = vec[j * n_dims ..][0..n_dims];
    var d: f32 = 0;
    for (a, b) |x, y| d += x * y;
    const den = norm_of[i] * norm_of[j];
    return if (den > 1e-12) d / den else 0;
}

// --- loading ---------------------------------------------------------------------------------

/// Labels from a plain text file (one per line) — how an .npy ships its names.
fn loadLabelFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    label_text = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024 * 1024));
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, label_text, '\n');
    while (it.next()) |ln| {
        const l = std.mem.trim(u8, ln, " \t\r");
        if (l.len == 0) continue;
        try list.append(gpa, l);
    }
    labels = try list.toOwnedSlice(gpa);
}

/// Classes from the labels themselves: the distinct values, if there are few
/// enough of them to be classes rather than names.
fn classesFromLabels(gpa: std.mem.Allocator) !void {
    if (labels.len == 0) return;
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);
    class_of = try gpa.alloc(u16, n_rows);
    for (0..n_rows) |i| {
        const l = if (i < labels.len) labels[i] else "";
        var found: ?u16 = null;
        for (names.items, 0..) |nm, k| {
            if (std.mem.eql(u8, nm, l)) found = @intCast(k);
        }
        if (found == null) {
            if (names.items.len >= max_classes) { // too many: these are names, not classes
                names.deinit(gpa);
                gpa.free(class_of);
                class_of = &.{};
                return;
            }
            try names.append(gpa, l);
            found = @intCast(names.items.len - 1);
        }
        class_of[i] = found.?;
    }
    class_names = try names.toOwnedSlice(gpa);
    n_classes = class_names.len;
}

pub fn load(gpa: std.mem.Allocator, io: std.Io) ![]Point {
    gpa_ref = gpa;
    const path = app_mod.cli.file;
    if (path.len == 0) {
        std.debug.print(
            \\the embeddings domain needs vectors:
            \\  zig build -Ddemo=embed run -- vectors.npy [--label=names.txt] [--knn=8]
            \\  zig build -Ddemo=embed run -- vectors.csv [--class=col] [--label=col]
            \\
        , .{});
        return error.NoInputFile;
    }

    if (std.mem.endsWith(u8, path, ".npy")) {
        const m = try npy.load(gpa, io, path, max_rows);
        vec = m.data; // we take ownership of the matrix's buffer
        n_rows = m.rows;
        n_dims = m.cols;
        if (app_mod.cli.label.len > 0) try loadLabelFile(gpa, io, app_mod.cli.label);
    } else {
        var t = try table.load(gpa, io, path, max_rows);
        errdefer t.deinit();
        // The vector is every numeric column; the label/class come from the text ones.
        var cols: std.ArrayList(usize) = .empty;
        defer cols.deinit(gpa);
        for (t.columns, 0..) |c, i| {
            if (c.kind == .numeric) try cols.append(gpa, i);
        }
        if (cols.items.len == 0) return error.NoNumericColumns;
        n_rows = t.rows;
        n_dims = cols.items.len;
        vec = try gpa.alloc(f32, n_rows * n_dims);
        for (0..n_rows) |r| {
            for (cols.items, 0..) |c, k| {
                const x = t.columns[c].nums[r];
                vec[r * n_dims + k] = if (std.math.isNan(x)) 0 else x;
            }
        }
        // Labels: the named column, else an id-like column; classes: a small one.
        var label_c: ?usize = if (app_mod.cli.label.len > 0) t.columnByName(app_mod.cli.label) else null;
        var class_c: ?usize = if (app_mod.cli.class.len > 0) t.columnByName(app_mod.cli.class) else null;
        for (t.columns, 0..) |c, i| {
            if (c.kind != .categorical) continue;
            if (class_c == null and c.cats.len >= 2 and c.cats.len <= max_classes) class_c = i;
            if (label_c == null and c.cats.len > max_classes) label_c = i;
        }
        if (label_c == null) label_c = class_c;
        if (label_c) |c| {
            labels = try gpa.alloc([]const u8, n_rows);
            for (0..n_rows) |r| labels[r] = t.cell(r, c);
        }
        if (class_c) |c| {
            class_of = try gpa.alloc(u16, n_rows);
            for (0..n_rows) |r| class_of[r] = @min(t.columns[c].codes[r], max_classes - 1);
            class_names = t.columns[c].cats;
            n_classes = @min(class_names.len, max_classes);
        }
        tbl = t; // keeps the label/class strings alive
    }
    if (n_rows == 0 or n_dims == 0) return error.EmptyEmbedding;
    if (tbl == null and class_of.len == 0) try classesFromLabels(gpa);

    norm_of = try gpa.alloc(f32, n_rows);
    for (0..n_rows) |i| {
        var s: f32 = 0;
        for (vec[i * n_dims ..][0..n_dims]) |x| s += x * x;
        norm_of[i] = @sqrt(s);
    }

    const pts = try gpa.alloc(Point, n_rows);
    errdefer gpa.free(pts);
    for (pts, 0..) |*p, i| {
        p.* = .{ .v = std.mem.zeroes([dim]f32), .row = @intCast(i) };
        if (i < class_of.len) p.cls = class_of[i];
    }

    try principalComponents(gpa, pts);

    // t-SNE: the neighborhood view, on the axes the presets reach for.
    if (n_rows <= reduce.max_tsne) {
        const m = reduce.Matrix{ .data = vec, .n = n_rows, .d = n_dims };
        const y = try reduce.tsne(gpa, m, 30.0, 500, 0x5EED);
        defer gpa.free(y);
        for (pts, 0..) |*p, i| {
            for (0..3) |k| p.v[tsne_axis + k] = y[i][k];
        }
        have_tsne = true;
    } else {
        std.debug.print("t-SNE skipped: {d} rows over the {d} the exact solver takes — PCA views only\n", .{ n_rows, reduce.max_tsne });
    }

    // Clusters (k-means in the original space), and the cosine neighbor table.
    {
        const m = reduce.Matrix{ .data = vec, .n = n_rows, .d = n_dims };
        const cl = try reduce.kmeans(gpa, m, n_clusters, 40, 0xC1A5);
        defer gpa.free(cl);
        for (pts, 0..) |*p, i| p.cluster = cl[i];
    }
    nn = try gpa.alloc(u16, n_rows);
    nn_sim = try gpa.alloc(f32, n_rows);
    for (0..n_rows) |i| {
        var best: usize = i;
        var best_s: f32 = -2;
        for (0..n_rows) |j| {
            if (i == j) continue;
            const s = cosine(i, j);
            if (s > best_s) {
                best_s = s;
                best = j;
            }
        }
        nn[i] = @intCast(best);
        nn_sim[i] = best_s;
    }

    buildMenus();
    std.debug.print("embeddings: {s} — {d} vectors in R^{d} · {d} PCs kept · t-SNE: {s} · classes: {d} · clusters: {d}\n", .{
        path, n_rows, n_dims, n_pcs, if (have_tsne) "yes" else "no", n_classes, n_clusters,
    });
    return pts;
}

pub fn unload(gpa: std.mem.Allocator) void {
    if (vec.len > 0) gpa.free(vec);
    if (norm_of.len > 0) gpa.free(norm_of);
    if (nn.len > 0) gpa.free(nn);
    if (nn_sim.len > 0) gpa.free(nn_sim);
    if (labels.len > 0) gpa.free(labels);
    if (label_text.len > 0) gpa.free(label_text);
    if (class_of.len > 0) gpa.free(class_of);
    // `class_names` points into the table when there is one; it owns its own
    // slice only when the labels themselves became the classes.
    if (tbl) |*t| {
        t.deinit();
        tbl = null;
    } else if (class_names.len > 0) gpa.free(class_names);
    vec = &.{};
    norm_of = &.{};
    nn = &.{};
    nn_sim = &.{};
    labels = &.{};
    label_text = &.{};
    class_of = &.{};
    class_names = &.{};
}

/// The leading principal components of the (mean-centered) vectors, projected
/// into coordinates 0..n_pcs-1 and scaled to the unit ball.
fn principalComponents(gpa: std.mem.Allocator, pts: []Point) !void {
    n_pcs = @min(n_dims, n_pc_max);
    const mean = try gpa.alloc(f32, n_dims);
    defer gpa.free(mean);
    @memset(mean, 0);
    for (0..n_rows) |i| {
        for (0..n_dims) |k| mean[k] += vec[i * n_dims + k];
    }
    for (mean) |*x| x.* /= @floatFromInt(n_rows);

    const work = try gpa.alloc(f32, n_rows * n_dims); // centered copy, deflated in place
    defer gpa.free(work);
    for (0..n_rows) |i| {
        for (0..n_dims) |k| work[i * n_dims + k] = vec[i * n_dims + k] - mean[k];
    }

    const axis = try gpa.alloc(f32, n_dims);
    defer gpa.free(axis);
    const tmp = try gpa.alloc(f32, n_dims);
    defer gpa.free(tmp);

    for (0..n_pcs) |c| {
        // Power iteration on the covariance, implicit: v ← Xᵀ(Xv).
        for (0..n_dims) |k| axis[k] = if (k == c) 1.0 else 0.01;
        for (0..40) |_| {
            @memset(tmp, 0);
            for (0..n_rows) |i| {
                var d: f32 = 0;
                for (0..n_dims) |k| d += work[i * n_dims + k] * axis[k];
                for (0..n_dims) |k| tmp[k] += d * work[i * n_dims + k];
            }
            var len: f32 = 0;
            for (tmp) |x| len += x * x;
            len = @sqrt(len);
            if (len < 1e-12) break;
            for (0..n_dims) |k| axis[k] = tmp[k] / len;
        }
        // Score every point on this axis, then deflate it out of the data.
        for (0..n_rows) |i| {
            var d: f32 = 0;
            for (0..n_dims) |k| d += work[i * n_dims + k] * axis[k];
            pts[i].v[c] = d;
            for (0..n_dims) |k| work[i * n_dims + k] -= d * axis[k];
        }
    }

    var max_r: f32 = 0;
    for (pts) |*p| {
        var s: f32 = 0;
        for (0..n_pcs) |k| s += p.v[k] * p.v[k];
        max_r = @max(max_r, @sqrt(s));
    }
    if (max_r > 1e-9) {
        for (pts) |*p| {
            for (0..n_pcs) |k| p.v[k] /= max_r;
        }
    }
    radius2 = 1.0;
}

// --- projections: which axes the basis picks --------------------------------------------------

fn pickAxes(a: usize, b: usize, c: usize) geom.Basis {
    var basis: geom.Basis = std.mem.zeroes(geom.Basis);
    basis[0][a] = 1;
    basis[1][b] = 1;
    basis[2][c] = 1;
    return basis;
}

fn bPca123(_: f32) geom.Basis {
    return pickAxes(0, 1, @min(2, dim - 1));
}
fn bPca456(_: f32) geom.Basis {
    return pickAxes(@min(3, n_pcs -| 1), @min(4, n_pcs -| 1), @min(5, n_pcs -| 1));
}
fn bTsne(_: f32) geom.Basis {
    if (!have_tsne) return bPca123(0);
    return pickAxes(tsne_axis, tsne_axis + 1, tsne_axis + 2);
}
/// The honest transition: rotate the principal plane through the components the
/// scatter is hiding. If the cloud reshuffles, PC1–PC2 was not the whole story.
fn bDeep(theta: f32) geom.Basis {
    var b = bPca123(0);
    var k: usize = 3;
    while (k < n_pcs) : (k += 1) {
        geom.rotateBasis(&b, k % 3, k, theta * (0.25 + 0.08 * @as(f32, @floatFromInt(k))));
    }
    geom.orthonormalize(&b);
    return b;
}

pub const presets = &[_]app_mod.PresetDef{
    .{ .name = "PCA 1-2-3", .basis = bPca123 },
    .{ .name = "t-SNE (3D)", .basis = bTsne },
    .{ .name = "PCA 4-5-6", .basis = bPca456 },
    .{ .name = "PCA → deeper components", .basis = bDeep, .animated = true },
};

// --- colors, filters, relations ----------------------------------------------------------------

fn colorByClass(p: *const Point, _: f32) [3]f32 {
    if (n_classes == 0) return .{ 0.55, 0.78, 1.0 };
    return classRgb(p.cls);
}
fn colorByCluster(p: *const Point, _: f32) [3]f32 {
    return classRgb(p.cluster + 3); // offset: clusters never wear the class colors
}
fn colorByNorm(p: *const Point, _: f32) [3]f32 {
    if (norm_of.len == 0) return .{ 0.6, 0.6, 0.6 };
    var hi: f32 = 1e-9;
    for (norm_of) |x| hi = @max(hi, x);
    return rampRgb(norm_of[p.row] / hi);
}
fn colorByAgreement(p: *const Point, _: f32) [3]f32 {
    // Does the point's nearest neighbor share its class? Green yes, red no —
    // the cheapest read on whether the embedding encodes the labels at all.
    if (n_classes == 0 or nn.len == 0) return .{ 0.6, 0.6, 0.6 };
    const j = nn[p.row];
    return if (class_of.len > j and class_of[p.row] == class_of[j])
        .{ 0.35, 1.0, 0.45 }
    else
        .{ 1.0, 0.32, 0.28 };
}

var legend_class: [max_classes]hud_mod.Hud.LegendIn = undefined;
var legend_cluster: [n_clusters]hud_mod.Hud.LegendIn = undefined;
var cluster_labels: [n_clusters][8]u8 = undefined;
var legend_norm = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 38, 64, 217 }, .label = "short vector" },
    .{ .rgb = .{ 255, 235, 77 }, .label = "long vector" },
};
var legend_agree = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 89, 255, 115 }, .label = "neighbor shares the class" },
    .{ .rgb = .{ 255, 82, 71 }, .label = "neighbor disagrees" },
};

var color_buf: [4]app_mod.ColorModeDef = undefined;
pub var color_modes: []const app_mod.ColorModeDef = &.{};
var filter_buf: [1 + max_classes]app_mod.FilterDef = undefined;
pub var filters: []const app_mod.FilterDef = &.{};
var relation_buf: [1]app_mod.RelationDef = undefined;
pub var relations: []const app_mod.RelationDef = &.{};

fn filterAll(_: *const Point) bool {
    return true;
}
fn filterClassFn(comptime k: u16) *const fn (p: *const Point) bool {
    return struct {
        fn f(p: *const Point) bool {
            return p.cls == k;
        }
    }.f;
}

fn buildMenus() void {
    for (0..n_classes) |k| {
        const rgb = classRgb(k);
        legend_class[k] = .{
            .rgb = .{ @intFromFloat(rgb[0] * 255), @intFromFloat(rgb[1] * 255), @intFromFloat(rgb[2] * 255) },
            .label = if (k < class_names.len) class_names[k] else "class",
        };
    }
    for (0..n_clusters) |k| {
        const rgb = classRgb(k + 3);
        const s = std.fmt.bufPrint(&cluster_labels[k], "k{d}", .{k}) catch "k";
        legend_cluster[k] = .{
            .rgb = .{ @intFromFloat(rgb[0] * 255), @intFromFloat(rgb[1] * 255), @intFromFloat(rgb[2] * 255) },
            .label = s,
        };
    }

    var nc: usize = 0;
    if (n_classes > 0) {
        color_buf[nc] = .{ .name = "labels", .color = colorByClass, .legend = legend_class[0..n_classes] };
        nc += 1;
    }
    color_buf[nc] = .{ .name = "k-means clusters", .color = colorByCluster, .legend = &legend_cluster };
    nc += 1;
    if (n_classes > 0) {
        color_buf[nc] = .{ .name = "neighbor agreement", .color = colorByAgreement, .legend = &legend_agree };
        nc += 1;
    }
    color_buf[nc] = .{ .name = "vector norm", .color = colorByNorm, .legend = &legend_norm };
    nc += 1;
    color_modes = color_buf[0..nc];

    var nf: usize = 0;
    filter_buf[nf] = .{ .name = "all", .pass = filterAll };
    nf += 1;
    inline for (0..max_classes) |k| {
        if (k < n_classes) {
            filter_buf[nf] = .{
                .name = if (k < class_names.len) class_names[k] else "class",
                .pass = filterClassFn(@intCast(k)),
            };
            nf += 1;
        }
    }
    filters = filter_buf[0..nf];

    relation_buf[0] = .{ .name = "nearest neighbor (cosine)", .partner = nearestPartner };
    relations = relation_buf[0..1];
}

fn nearestPartner(_: []const Point, i: u16) u16 {
    if (i < nn.len) return nn[i];
    return i;
}

fn actNearest(a: *App) void {
    if (a.selected >= 0 and nn.len > 0) {
        a.selected = nn[@intCast(a.selected)];
        a.info_dirty = true;
    }
}

pub const actions = &[_]app_mod.ActionDef{
    .{ .key = 49, .help = "N: hop to the nearest neighbor (cosine)", .run = actNearest },
};

// --- edges: the cosine k-NN graph ---------------------------------------------------------------

pub fn buildEdges(gpa: std.mem.Allocator, points: []const Point) ![]const [2]u16 {
    _ = points;
    const k = @min(@max(app_mod.cli.knn, 1), 16);
    var out: std.ArrayList([2]u16) = .empty;
    errdefer out.deinit(gpa);
    var best: [16]struct { s: f32, j: usize } = undefined;
    for (0..n_rows) |i| {
        var filled: usize = 0;
        for (0..n_rows) |j| {
            if (i == j) continue;
            const s = cosine(i, j);
            if (filled < k) {
                best[filled] = .{ .s = s, .j = j };
                filled += 1;
                continue;
            }
            var worst: usize = 0;
            for (1..k) |m| {
                if (best[m].s < best[worst].s) worst = m;
            }
            if (s > best[worst].s) best[worst] = .{ .s = s, .j = j };
        }
        for (best[0..filled]) |b| {
            if (i < b.j) try out.append(gpa, .{ @intCast(i), @intCast(b.j) });
        }
    }
    return out.toOwnedSlice(gpa);
}

// --- descriptors, stories, readouts ---------------------------------------------------------------

pub fn descriptor(a: *App, i: usize) desc.Object {
    const p = &a.points[i];
    return .{
        .orbit_rgb = classRgb(p.cls),
        .orbit_phase = @as(f32, @floatFromInt(p.cls)) * 0.7,
    };
}

fn labelOf(i: usize, buf: []u8) []const u8 {
    if (i < labels.len and labels[i].len > 0) return labels[i];
    return std.fmt.bufPrint(buf, "vector {d}", .{i}) catch "vector";
}

fn classOf(i: usize) []const u8 {
    if (n_classes == 0 or i >= class_of.len) return "";
    const k = class_of[i];
    return if (k < class_names.len) class_names[k] else "";
}

pub fn describe(a: *App, i: usize, buf: []u8) []const u8 {
    _ = a;
    var lb: [96]u8 = undefined;
    var nb: [96]u8 = undefined;
    const cls = classOf(i);
    return std.fmt.bufPrint(buf, "{s}{s}{s} · nearest: {s} (cos {d:.3})", .{
        labelOf(i, &lb),
        if (cls.len > 0) " — " else "",
        cls,
        labelOf(if (nn.len > 0) nn[i] else i, &nb),
        if (nn_sim.len > 0) nn_sim[i] else 0,
    }) catch "vector";
}

pub fn story(a: *App) void {
    const hud = a.hud;
    if (a.selected < 0) {
        var buf: [720]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{d} vectors in R^{d}. The same point carries two views: coordinates 1..{d} are the leading principal components, 14..16 are the t-SNE embedding — so keys 1..4 SWITCH VIEW without reloading, and your selection, its neighbors and the colors follow you across.
            \\PCA is the linear shadow: distances mean something, clusters may overlap. t-SNE is the opposite bargain: the clusters are real, the distances between them are not. Read them together.
            \\The lines are the k-nearest-neighbor graph in the ORIGINAL space, by cosine. A long line on screen is the projection lying to you there.
            \\C: labels, k-means clusters, neighbor agreement, vector norm. N hops to the nearest neighbor.
        , .{ n_rows, n_dims, n_pcs }) catch "";
        hud.setPanel("The embedding", body, app_mod.cli.file);
        return;
    }
    const i: usize = @intCast(a.selected);
    var tb: [96]u8 = undefined;
    var lb: [96]u8 = undefined;
    const t = std.fmt.bufPrint(&tb, "{s}", .{labelOf(i, &lb)}) catch "vector";
    var bb: [720]u8 = undefined;
    var w: std.Io.Writer = .fixed(&bb);
    const cls = classOf(i);
    if (cls.len > 0) w.print("label: {s}\n", .{cls}) catch {};
    w.print("k-means cluster: k{d}\n‖v‖ = {d:.3}\n\nNearest neighbors (cosine, in the full space):\n", .{
        a.points[i].cluster,
        if (i < norm_of.len) norm_of[i] else 0,
    }) catch {};
    // The five nearest — the readout an embedding is actually debugged with.
    var shown: usize = 0;
    var used: [5]usize = undefined;
    while (shown < 5) : (shown += 1) {
        var best: ?usize = null;
        var best_s: f32 = -2;
        for (0..n_rows) |j| {
            if (j == i) continue;
            var seen = false;
            for (used[0..shown]) |u| {
                if (u == j) seen = true;
            }
            if (seen) continue;
            const s = cosine(i, j);
            if (s > best_s) {
                best_s = s;
                best = j;
            }
        }
        const j = best orelse break;
        used[shown] = j;
        var nb: [96]u8 = undefined;
        w.print("  {d:.3}  {s}\n", .{ best_s, labelOf(j, &nb) }) catch break;
    }
    hud.setPanel(t, w.buffered(), "");
}

pub const InspectText = struct { title_len: usize, body_len: usize };

pub fn inspect(a: *App, i: usize, tbuf: *[96]u8, bbuf: *[512]u8) InspectText {
    const p = &a.points[i];
    var lb: [96]u8 = undefined;
    const cls = classOf(i);
    const t = std.fmt.bufPrint(tbuf, "{s}{s}{s}", .{
        labelOf(i, &lb),
        if (cls.len > 0) " — " else "",
        cls,
    }) catch "";
    var w: std.Io.Writer = .fixed(bbuf);
    var nb: [96]u8 = undefined;
    w.print("A vector in R^{d}, drawn at its principal-component (and t-SNE) coordinates.\n\nNearest neighbor: {s} — cosine {d:.3}\nk-means cluster: k{d} · ‖v‖ = {d:.3}\n\nThe lit orbit is the hop chain: N follows it.", .{
        n_dims,
        labelOf(if (nn.len > 0) nn[i] else i, &nb),
        if (nn_sim.len > 0) nn_sim[i] else 0,
        p.cluster,
        if (i < norm_of.len) norm_of[i] else 0,
    }) catch {};
    return .{ .title_len = t.len, .body_len = w.buffered().len };
}

/// The panel diagram: the t-SNE map (or the principal plane when t-SNE was
/// skipped), sampled — the 2D figure this field puts in every paper.
pub fn figure(a: *App, fig_id: []const u8, dots: []hud_mod.FigDot) usize {
    if (!std.mem.eql(u8, fig_id, "map")) return 0;
    const ax: usize = if (have_tsne and std.mem.eql(u8, fig_id, "map")) tsne_axis else 0;
    var n_dots: usize = 0;
    const step = @max(a.points.len / dots.len, 1);
    var i: usize = 0;
    while (i < a.points.len and n_dots < dots.len) : (i += step) {
        const p = &a.points[i];
        const rgb = if (n_classes > 0) classRgb(p.cls) else classRgb(p.cluster + 3);
        dots[n_dots] = .{
            .x = std.math.clamp(p.v[ax], -1, 1),
            .y = std.math.clamp(p.v[ax + 1], -1, 1),
            .rgb = .{ @intFromFloat(rgb[0] * 255), @intFromFloat(rgb[1] * 255), @intFromFloat(rgb[2] * 255) },
        };
        n_dots += 1;
    }
    return n_dots;
}

/// X: the labels, the class, the cluster, the t-SNE coordinates and the current
/// projection — everything this window computed, back in a CSV.
pub fn exportCsv(a: *App) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a.gpa);
    try out.appendSlice(a.gpa, "index,label,class,cluster,nn,nn_cosine,tsne_x,tsne_y,tsne_z,view_x,view_y,view_z\n");
    var buf: [320]u8 = undefined;
    for (a.points, 0..) |*p, i| {
        var lb: [96]u8 = undefined;
        var nb: [96]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{d},{s},{s},{d},{s},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4},{d:.4}\n", .{
            i,
            labelOf(i, &lb),
            classOf(i),
            p.cluster,
            labelOf(if (nn.len > 0) nn[i] else i, &nb),
            if (nn_sim.len > 0) nn_sim[i] else 0,
            p.v[tsne_axis],
            p.v[tsne_axis + 1],
            p.v[tsne_axis + 2],
            a.p3[i][0],
            a.p3[i][1],
            a.p3[i][2],
        });
        try out.appendSlice(a.gpa, line);
    }
    try std.Io.Dir.cwd().writeFile(a.io, .{ .sub_path = "embedding_view.csv", .data = out.items });
    std.debug.print("exported embedding_view.csv ({d} vectors)\n", .{a.count()});
}

pub const deck_path = "deck.zon";
pub const deck_default: [:0]const u8 = @embedFile("deck.zon");
