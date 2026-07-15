//! The dataset domain — the framework's universal front door.
//!
//! Point it at any delimited table a scientist already has (`-Ddemo=data run --
//! file.csv`) and it becomes an interactive paper about THAT data: the numeric
//! columns are the coordinates of a point in R^k, a categorical column is the
//! class that colors and filters it, a text column is its name. The projections
//! are the ones data actually asks for — the principal axes first, the raw axes
//! next — and the relation the framework walks is the nearest neighbor.
//!
//! Nothing here knows what the numbers MEAN: that is what a field profile adds
//! on top (chemistry, embeddings, astronomy, networks), each one a thin layer
//! that fixes the column mapping and hands the framework its own tools.
//!
//! Usage:
//!   zig build -Ddemo=data run -- iris.csv
//!   zig build -Ddemo=data run -- vecs.tsv --coords=x,y,z,w --class=label --knn=8

const std = @import("std");
const table = @import("table.zig");
const log = @import("../../log.zig");
const webfile = @import("../../webfile.zig");
const geom = @import("../../geom.zig");
const hud_mod = @import("../../hud.zig");
const desc = @import("../../descriptor.zig");
const keys = @import("../../keys.zig");
const app_mod = @import("../../app.zig");
const App = app_mod.App;

pub const name = "Dataset";
pub const title = "presenter — dataset (drag to orbit, click a point, P for the tour)";
pub const app_id = "dev.presenter.data";

/// The coordinate space: up to 16 numeric columns become the axes of R^dim.
/// Unused axes stay zero, so a 3-column table simply lives in a 3D slice of it.
pub const dim = 16;

pub const Point = struct {
    v: [dim]f32,
    /// Category index of the class column (0 when the table has no classes).
    cls: u16 = 0,
    /// Row in the source table — the key to every value the inspector reads out.
    row: u32 = 0,
};

/// Standardized coordinates are scaled so the farthest point sits at 1.
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

// --- the loaded dataset -------------------------------------------------------------------

const max_rows: usize = 20_000; // brute-force kNN is O(n²): keep it interactive
const max_classes: usize = 12; // classes past this fold into "other"
const max_value_modes: usize = 6; // numeric columns offered as a color ramp

var tbl: table.Table = undefined;
var have_table = false;
/// Which table columns became the coordinates, and their names.
var coord_col: [dim]usize = undefined;
var n_coords: usize = 0;
var class_col: ?usize = null;
var label_col: ?usize = null;
/// Per-color-mode normalized column values (0..1), one array per numeric column.
var value_col: [max_value_modes]usize = undefined;
var value_norm: [max_value_modes][]f32 = .{&.{}} ** max_value_modes;
var n_values: usize = 0;
/// The nearest-neighbor partner of every point (the relation the framework walks).
var nn: []u16 = &.{};
/// Principal axes of the standardized coordinates (the default projection).
var pca_basis: geom.Basis = std.mem.zeroes(geom.Basis);
var n_classes: usize = 0;

/// A stable, well-separated hue per class — the same wheel the legend uses.
fn classRgb(k: usize) [3]f32 {
    const golden: f32 = 0.61803398875;
    const h = @mod(@as(f32, @floatFromInt(k)) * golden, 1.0);
    // HSV → RGB at s=0.62, v=1 (bright enough to read on black).
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

/// A perceptual ramp for a numeric column: deep blue → cyan → yellow.
fn rampRgb(t: f32) [3]f32 {
    const x = std.math.clamp(t, 0, 1);
    if (x < 0.5) {
        const u = x * 2.0;
        return .{ 0.15 * (1 - u) + 0.10 * u, 0.25 * (1 - u) + 0.85 * u, 0.85 * (1 - u) + 0.90 * u };
    }
    const u = (x - 0.5) * 2.0;
    return .{ 0.10 * (1 - u) + 1.00 * u, 0.85 * (1 - u) + 0.92 * u, 0.90 * (1 - u) + 0.30 * u };
}

// --- loading ------------------------------------------------------------------------------

/// Parse `--coords=a,b,c`: names (matched against the header) or 0-based indices.
fn pickCoords(t: *const table.Table, spec: []const u8) void {
    n_coords = 0;
    if (spec.len > 0) {
        var it = std.mem.tokenizeScalar(u8, spec, ',');
        while (it.next()) |tok| {
            if (n_coords >= dim) break;
            const col = t.columnByName(tok) orelse (std.fmt.parseInt(usize, tok, 10) catch null);
            if (col) |c| {
                if (c < t.columns.len and t.columns[c].kind == .numeric) {
                    coord_col[n_coords] = c;
                    n_coords += 1;
                }
            }
        }
        if (n_coords > 0) return;
    }
    // Default: every numeric column, in file order.
    for (t.columns, 0..) |c, i| {
        if (c.kind != .numeric or n_coords >= dim) continue;
        coord_col[n_coords] = i;
        n_coords += 1;
    }
}

/// The class column: the one the user named, else the categorical column that
/// looks like a class — few distinct values, repeated across rows. An id column
/// is categorical too, but with one value per row it classifies nothing, so the
/// fewest-categories column wins.
fn pickClass(t: *const table.Table, spec: []const u8) void {
    class_col = null;
    if (spec.len > 0) {
        if (t.columnByName(spec)) |c| {
            if (t.columns[c].kind == .categorical) class_col = c;
            return;
        }
    }
    var best_cats: usize = max_classes + 1;
    for (t.columns, 0..) |c, i| {
        if (c.kind != .categorical) continue;
        if (c.cats.len < 2 or c.cats.len > max_classes) continue;
        if (c.cats.len < best_cats) {
            best_cats = c.cats.len;
            class_col = i;
        }
    }
}

/// The label column names a point: an id/name column — categorical with nearly
/// one value per row — else the class column, else the row number.
fn pickLabel(t: *const table.Table, spec: []const u8) void {
    label_col = null;
    if (spec.len > 0) {
        label_col = t.columnByName(spec);
        if (label_col != null) return;
    }
    var best_cats: usize = 0;
    for (t.columns, 0..) |c, i| {
        if (c.kind != .categorical) continue;
        if (class_col != null and i == class_col.?) continue;
        if (c.cats.len > best_cats) {
            best_cats = c.cats.len;
            label_col = i;
        }
    }
    if (label_col == null) label_col = class_col;
}

/// The dataset this demo opens when it is given nothing else — Fisher's iris: 150 flowers, four measurements, three species.
/// See demos/SAMPLES.md for where it comes from and under what licence.
///
/// It is not a nicety. This demo is a PROFILE: it exists to open a file you bring, and
/// there are two places where nobody can bring one — a browser tab, which has no
/// filesystem, and a launch with no argument, which used to end at `error.NoInputFile`,
/// a message that says what failed and nothing about what to do. Shipping one real
/// dataset means the demo always has something to show, and your file replaces it.
pub const sample_name = "iris.csv";
pub const sample: []const u8 = @embedFile("sample.csv");
/// The column that says what each row IS — without it the class would be guessed.
pub const sample_class = "species";

pub fn load(gpa: std.mem.Allocator, io: std.Io) ![]Point {
    var path = app_mod.cli.file;
    if (path.len == 0) {
        // Nothing was given, so the demo opens what it came with (demos/SAMPLES.md).
        // The bytes are already here — embedded — so `source.readAll` will hand them
        // straight back, on both targets, and no filesystem is consulted at all.
        webfile.set(sample_name, sample);
        app_mod.cli.file = sample_name;
        if (app_mod.cli.class.len == 0) app_mod.cli.class = sample_class;
        path = sample_name;
    }
    tbl = try table.load(gpa, io, path, max_rows);
    have_table = true;
    errdefer {
        tbl.deinit();
        have_table = false;
    }

    pickCoords(&tbl, app_mod.cli.coords);
    if (n_coords == 0) return error.NoNumericColumns;
    pickClass(&tbl, app_mod.cli.class);
    pickLabel(&tbl, app_mod.cli.label);

    const rows = tbl.rows;
    const pts = try gpa.alloc(Point, rows);
    errdefer gpa.free(pts);

    // Standardize each coordinate column (z-score): columns in a real table live
    // on wildly different scales, and a projection of raw units just shows you
    // the biggest unit.
    for (0..rows) |r| {
        pts[r] = .{ .v = std.mem.zeroes([dim]f32), .row = @intCast(r) };
    }
    for (0..n_coords) |k| {
        const col = &tbl.columns[coord_col[k]];
        var mean: f64 = 0;
        var cnt: f64 = 0;
        for (col.nums) |x| {
            if (std.math.isNan(x)) continue;
            mean += x;
            cnt += 1;
        }
        mean = if (cnt > 0) mean / cnt else 0;
        var vari: f64 = 0;
        for (col.nums) |x| {
            if (std.math.isNan(x)) continue;
            vari += (x - mean) * (x - mean);
        }
        const sd: f32 = @floatCast(if (cnt > 1) @sqrt(vari / (cnt - 1)) else 1.0);
        const inv: f32 = if (sd > 1e-9) 1.0 / sd else 1.0;
        for (0..rows) |r| {
            const x = col.nums[r];
            pts[r].v[k] = if (std.math.isNan(x)) 0 else (x - @as(f32, @floatCast(mean))) * inv;
        }
    }

    // Scale so the farthest point sits on the unit sphere: the camera, the point
    // radii and the hidden-depth normalization all assume that.
    var max_r2: f32 = 0;
    for (pts) |*p| {
        var s: f32 = 0;
        for (0..n_coords) |k| s += p.v[k] * p.v[k];
        max_r2 = @max(max_r2, s);
    }
    const scale: f32 = if (max_r2 > 1e-9) 1.0 / @sqrt(max_r2) else 1.0;
    for (pts) |*p| {
        for (0..n_coords) |k| p.v[k] *= scale;
    }
    radius2 = 1.0;

    // Classes.
    if (class_col) |c| {
        const col = &tbl.columns[c];
        n_classes = @min(col.cats.len, max_classes);
        for (pts, 0..) |*p, r| {
            const code = col.codes[r];
            p.cls = if (code < max_classes) code else @intCast(max_classes - 1);
        }
    } else n_classes = 0;

    try buildTables(gpa, pts);
    buildMenus();

    log.print("dataset: {s} — {d} rows · {d} coordinate columns (first: {s}) · classes: {s} ({d}) · labels: {s}\n", .{
        path,
        rows,
        n_coords,
        tbl.columns[coord_col[0]].name,
        if (class_col) |c| tbl.columns[c].name else "none",
        n_classes,
        if (label_col) |c| tbl.columns[c].name else "row number",
    });
    return pts;
}

pub fn unload(gpa: std.mem.Allocator) void {
    if (nn.len > 0) gpa.free(nn);
    nn = &.{};
    for (&value_norm) |*v| {
        if (v.len > 0) gpa.free(v.*);
        v.* = &.{};
    }
    if (have_table) {
        tbl.deinit();
        have_table = false;
    }
}

/// Principal axes (power iteration + deflation on the covariance), the
/// nearest-neighbor table, and the normalized columns the color ramps read.
fn buildTables(gpa: std.mem.Allocator, pts: []Point) !void {
    // Covariance of the standardized coordinates.
    var cov: [dim][dim]f32 = std.mem.zeroes([dim][dim]f32);
    for (pts) |*p| {
        for (0..n_coords) |i| {
            for (0..n_coords) |j| cov[i][j] += p.v[i] * p.v[j];
        }
    }
    const inv_n: f32 = 1.0 / @as(f32, @floatFromInt(@max(pts.len, 1)));
    for (0..n_coords) |i| {
        for (0..n_coords) |j| cov[i][j] *= inv_n;
    }
    for (0..3) |axis| {
        var v: [dim]f32 = std.mem.zeroes([dim]f32);
        // A deterministic, non-degenerate start: each axis leans on its own coord.
        for (0..n_coords) |k| v[k] = if (k == axis % n_coords) 1.0 else 0.35 / @as(f32, @floatFromInt(k + 2));
        for (0..64) |_| {
            var w: [dim]f32 = std.mem.zeroes([dim]f32);
            for (0..n_coords) |i| {
                for (0..n_coords) |j| w[i] += cov[i][j] * v[j];
            }
            // Deflate against the axes already found: keeps them orthogonal.
            for (0..axis) |a| {
                var d: f32 = 0;
                for (0..n_coords) |k| d += w[k] * pca_basis[a][k];
                for (0..n_coords) |k| w[k] -= d * pca_basis[a][k];
            }
            var len: f32 = 0;
            for (0..n_coords) |k| len += w[k] * w[k];
            len = @sqrt(len);
            if (len < 1e-9) break;
            for (0..n_coords) |k| v[k] = w[k] / len;
        }
        pca_basis[axis] = v;
    }
    geom.orthonormalize(&pca_basis);

    // Nearest neighbor of every point (brute force, but `max_rows` bounds it).
    nn = try gpa.alloc(u16, pts.len);
    for (pts, 0..) |*p, i| {
        var best: usize = i;
        var best_d: f32 = std.math.floatMax(f32);
        for (pts, 0..) |*q, j| {
            if (i == j) continue;
            var d: f32 = 0;
            for (0..n_coords) |k| {
                const t = p.v[k] - q.v[k];
                d += t * t;
            }
            if (d < best_d) {
                best_d = d;
                best = j;
            }
        }
        nn[i] = @intCast(best);
    }

    // Normalized values of the first few numeric columns — the color ramps.
    n_values = 0;
    for (tbl.columns, 0..) |*c, ci| {
        if (c.kind != .numeric or n_values >= max_value_modes) continue;
        const arr = try gpa.alloc(f32, tbl.rows);
        var lo: f32 = std.math.floatMax(f32);
        var hi: f32 = -std.math.floatMax(f32);
        for (c.nums) |x| {
            if (std.math.isNan(x)) continue;
            lo = @min(lo, x);
            hi = @max(hi, x);
        }
        const span: f32 = if (hi > lo) hi - lo else 1.0;
        for (c.nums, 0..) |x, r| arr[r] = if (std.math.isNan(x)) 0 else (x - lo) / span;
        value_col[n_values] = ci;
        value_norm[n_values] = arr;
        n_values += 1;
    }
}

// --- projections --------------------------------------------------------------------------

fn axesBasis(offset: usize) geom.Basis {
    var b: geom.Basis = std.mem.zeroes(geom.Basis);
    for (0..3) |r| {
        const k = offset + r;
        b[r][if (k < n_coords) k else (k % @max(n_coords, 1))] = 1;
    }
    geom.orthonormalize(&b);
    return b;
}

fn bPca(_: f32) geom.Basis {
    return pca_basis;
}
fn bAxes123(_: f32) geom.Basis {
    return axesBasis(0);
}
fn bAxes456(_: f32) geom.Basis {
    return axesBasis(3);
}
/// A slow rotation of the principal plane into the hidden coordinates: the
/// honest way to show that a 2D scatter is a shadow of something bigger.
fn bTumble(theta: f32) geom.Basis {
    var b = pca_basis;
    if (n_coords > 3) {
        var k: usize = 3;
        while (k < n_coords) : (k += 1) {
            geom.rotateBasis(&b, k % 3, k, theta * (0.3 + 0.1 * @as(f32, @floatFromInt(k))));
        }
    }
    geom.orthonormalize(&b);
    return b;
}

pub const presets = &[_]app_mod.PresetDef{
    .{ .name = "principal axes (PCA)", .basis = bPca },
    .{ .name = "raw axes 1-2-3", .basis = bAxes123 },
    .{ .name = "raw axes 4-5-6", .basis = bAxes456 },
    .{ .name = "PCA → hidden dims", .basis = bTumble, .animated = true },
};

// --- colors -------------------------------------------------------------------------------

fn colorByClass(p: *const Point, _: f32) [3]f32 {
    if (n_classes == 0) return .{ 0.55, 0.78, 1.0 };
    return classRgb(p.cls);
}

fn colorByDepth(_: *const Point, hidden_t: f32) [3]f32 {
    const t = std.math.clamp(hidden_t, 0, 1);
    return .{ 0.15 + 0.85 * t, 0.35 + 0.25 * (1 - t), 1.0 - 0.75 * t };
}

/// One color mode per numeric column — the fn pointer the framework wants can't
/// close over a runtime index, so the six of them are stamped out at comptime.
fn valueColorFn(comptime k: usize) *const fn (p: *const Point, hidden_t: f32) [3]f32 {
    return struct {
        fn f(p: *const Point, _: f32) [3]f32 {
            if (value_norm[k].len == 0) return .{ 0.6, 0.6, 0.6 };
            return rampRgb(value_norm[k][p.row]);
        }
    }.f;
}

var legend_class: [max_classes]hud_mod.Hud.LegendIn = undefined;
var legend_ramp: [2]hud_mod.Hud.LegendIn = undefined;
var legend_depth = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 64, 128, 255 }, .label = "in the view plane" },
    .{ .rgb = .{ 255, 100, 64 }, .label = "hidden dimensions" },
};

var color_buf: [2 + max_value_modes]app_mod.ColorModeDef = undefined;
pub var color_modes: []const app_mod.ColorModeDef = &.{};

var filter_buf: [1 + max_classes]app_mod.FilterDef = undefined;
pub var filters: []const app_mod.FilterDef = &.{};

var relation_buf: [1]app_mod.RelationDef = undefined;
pub var relations: []const app_mod.RelationDef = &.{};

pub const actions = &[_]app_mod.ActionDef{
    .{ .key = keys.domain_n, .help = "N: hop to the nearest neighbor", .run = actNearest }, // N
};

fn actNearest(a: *App) void {
    if (a.selected >= 0 and nn.len > 0) {
        a.selected = nn[@intCast(a.selected)];
        a.info_dirty = true;
    }
}

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

/// The menus the framework cycles (C, F, E) are built from the table itself:
/// one color mode per numeric column, one filter per class.
fn buildMenus() void {
    var nc: usize = 0;
    color_buf[nc] = .{ .name = if (class_col) |c| tbl.columns[c].name else "class", .color = colorByClass, .legend = blk: {
        for (0..n_classes) |k| {
            const rgb = classRgb(k);
            legend_class[k] = .{
                .rgb = .{
                    @intFromFloat(rgb[0] * 255),
                    @intFromFloat(rgb[1] * 255),
                    @intFromFloat(rgb[2] * 255),
                },
                .label = tbl.columns[class_col.?].cats[k],
            };
        }
        break :blk legend_class[0..n_classes];
    } };
    nc += 1;

    inline for (0..max_value_modes) |k| {
        if (k < n_values) {
            legend_ramp = .{
                .{ .rgb = .{ 38, 64, 217 }, .label = "low" },
                .{ .rgb = .{ 255, 235, 77 }, .label = "high" },
            };
            color_buf[nc] = .{
                .name = tbl.columns[value_col[k]].name,
                .color = valueColorFn(k),
                .legend = &legend_ramp,
            };
            nc += 1;
        }
    }
    color_buf[nc] = .{ .name = "hidden depth", .color = colorByDepth, .legend = &legend_depth };
    nc += 1;
    color_modes = color_buf[0..nc];

    var nf: usize = 0;
    filter_buf[nf] = .{ .name = "all", .pass = filterAll };
    nf += 1;
    inline for (0..max_classes) |k| {
        if (k < n_classes) {
            filter_buf[nf] = .{
                .name = tbl.columns[class_col.?].cats[k],
                .pass = filterClassFn(@intCast(k)),
            };
            nf += 1;
        }
    }
    filters = filter_buf[0..nf];

    relation_buf[0] = .{ .name = "nearest neighbor", .partner = nearestPartner };
    relations = relation_buf[0..1];
}

fn nearestPartner(_: []const Point, i: u16) u16 {
    if (i < nn.len) return nn[i];
    return i;
}

// --- edges: the k-nearest-neighbor graph ---------------------------------------------------

pub fn buildEdges(gpa: std.mem.Allocator, points: []const Point) ![]const [2]u16 {
    const k = @min(@max(app_mod.cli.knn, 1), 16);
    var out: std.ArrayList([2]u16) = .empty;
    errdefer out.deinit(gpa);
    var best: [16]struct { d: f32, j: usize } = undefined;
    for (points, 0..) |*p, i| {
        var filled: usize = 0;
        var worst: usize = 0; // the farthest of the k kept, updated on replacement
        for (points, 0..) |*q, j| {
            if (i == j) continue;
            var d: f32 = 0;
            for (0..n_coords) |c| {
                const t = p.v[c] - q.v[c];
                d += t * t;
            }
            if (filled < k) {
                best[filled] = .{ .d = d, .j = j };
                if (best[filled].d > best[worst].d) worst = filled;
                filled += 1;
                continue;
            }
            // Replace the worst of the k kept so far; only then rescan for the new worst.
            if (d >= best[worst].d) continue;
            best[worst] = .{ .d = d, .j = j };
            worst = 0;
            for (1..k) |m| {
                if (best[m].d > best[worst].d) worst = m;
            }
        }
        for (best[0..filled]) |b| {
            // One edge per pair: the lower index owns it.
            if (i < b.j) try out.append(gpa, .{ @intCast(i), @intCast(b.j) });
        }
    }
    return out.toOwnedSlice(gpa);
}

// --- descriptors, stories, readouts ---------------------------------------------------------

pub fn descriptor(a: *App, i: usize) desc.Object {
    const p = &a.points[i];
    return .{
        .orbit_rgb = classRgb(p.cls),
        .orbit_phase = @as(f32, @floatFromInt(p.cls)) * 0.7,
    };
}

/// The point's name: its label column, or its row number.
fn labelOf(p: *const Point, buf: []u8) []const u8 {
    if (label_col) |c| {
        const s = tbl.cell(p.row, c);
        if (s.len > 0) return s;
    }
    return std.fmt.bufPrint(buf, "row {d}", .{p.row + 1}) catch "row";
}

fn classOf(p: *const Point) []const u8 {
    const c = class_col orelse return "";
    const col = &tbl.columns[c];
    if (p.cls < col.cats.len) return col.cats[p.cls];
    return "";
}

pub fn describe(a: *App, i: usize, buf: []u8) []const u8 {
    const p = &a.points[i];
    var lbuf: [96]u8 = undefined;
    const cls = classOf(p);
    return std.fmt.bufPrint(buf, "{s}{s}{s} · nearest: {s}", .{
        labelOf(p, &lbuf),
        if (cls.len > 0) " — " else "",
        cls,
        blk: {
            const j = if (nn.len > 0) nn[i] else @as(u16, @intCast(i));
            var nbuf: [96]u8 = undefined;
            const s = labelOf(&a.points[j], &nbuf);
            break :blk if (s.len < 40) s else s[0..40];
        },
    }) catch "point";
}

pub fn story(a: *App) void {
    const hud = a.hud;
    if (a.selected < 0) {
        var buf: [720]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{d} rows of {s}, each one a point in R^{d} built from the numeric columns — standardized, so no column shouts louder than the others just because of its units.
            \\The default projection is the principal plane: the two directions along which the data actually varies. 1..4 switch projection, ←/→ rotate the hidden coordinates into view.
            \\{s}
            \\Click a point for its row. N hops to its nearest neighbor; the lines are the k-nearest-neighbor graph (E cycles them).
        , .{
            tbl.rows,
            app_mod.cli.file,
            n_coords,
            if (class_col) |c| blk: {
                var cb: [96]u8 = undefined;
                break :blk std.fmt.bufPrint(&cb, "Colors are the '{s}' column ({d} classes); C cycles a ramp per numeric column, S filters one class at a time.", .{ tbl.columns[c].name, n_classes }) catch "";
            } else "The table has no categorical column, so color falls back to the numeric ramps (C cycles them).",
        }) catch "";
        hud.setPanel("The dataset", body, app_mod.cli.file);
        return;
    }
    const p = &a.points[@intCast(a.selected)];
    var tbuf: [96]u8 = undefined;
    var lbuf: [96]u8 = undefined;
    const t = std.fmt.bufPrint(&tbuf, "{s}", .{labelOf(p, &lbuf)}) catch "point";
    var bbuf: [720]u8 = undefined;
    var w: std.Io.Writer = .fixed(&bbuf);
    const cls = classOf(p);
    if (cls.len > 0) w.print("class: {s}\n\n", .{cls}) catch {};
    for (0..n_coords) |k| {
        const col = &tbl.columns[coord_col[k]];
        w.print("{s} = {s}\n", .{ col.name, tbl.cell(p.row, coord_col[k]) }) catch {};
    }
    hud.setPanel(t, w.buffered(), "");
}

pub const InspectText = struct { title_len: usize, body_len: usize };

pub fn inspect(a: *App, i: usize, tbuf: *[96]u8, bbuf: *[512]u8) InspectText {
    const p = &a.points[i];
    var lbuf: [96]u8 = undefined;
    const cls = classOf(p);
    const t = std.fmt.bufPrint(tbuf, "{s}{s}{s}", .{
        labelOf(p, &lbuf),
        if (cls.len > 0) " — " else "",
        cls,
    }) catch "";

    var w: std.Io.Writer = .fixed(bbuf);
    // The columns that made the point, then who it sits next to.
    for (0..@min(n_coords, 6)) |k| {
        w.print("{s}: {s}\n", .{
            tbl.columns[coord_col[k]].name,
            tbl.cell(p.row, coord_col[k]),
        }) catch break;
    }
    if (nn.len > 0) {
        var nbuf: [96]u8 = undefined;
        w.print("\nNearest neighbor: {s} (N hops to it; the lit orbit is the hop chain).", .{
            labelOf(&a.points[nn[i]], &nbuf),
        }) catch {};
    }
    return .{ .title_len = t.len, .body_len = w.buffered().len };
}

/// The inline panel figure: the selected point's class on the principal plane.
pub fn figure(a: *App, fig_id: []const u8, dots: []hud_mod.FigDot) usize {
    if (!std.mem.eql(u8, fig_id, "pca")) return 0;
    var n_dots: usize = 0;
    const step = @max(a.points.len / dots.len, 1);
    var i: usize = 0;
    while (i < a.points.len and n_dots < dots.len) : (i += step) {
        const p = &a.points[i];
        var x: f32 = 0;
        var y: f32 = 0;
        for (0..n_coords) |k| {
            x += pca_basis[0][k] * p.v[k];
            y += pca_basis[1][k] * p.v[k];
        }
        const rgb = classRgb(p.cls);
        dots[n_dots] = .{
            .x = std.math.clamp(x * 1.6, -1, 1),
            .y = std.math.clamp(y * 1.6, -1, 1),
            .rgb = .{
                @intFromFloat(rgb[0] * 255),
                @intFromFloat(rgb[1] * 255),
                @intFromFloat(rgb[2] * 255),
            },
        };
        n_dots += 1;
    }
    return n_dots;
}

/// X: the table back out with the projected coordinates appended — the round
/// trip a scientist needs to take the view into their own tools.
pub fn exportCsv(a: *App) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a.gpa);
    for (tbl.columns, 0..) |c, i| {
        if (i > 0) try out.append(a.gpa, ',');
        try out.appendSlice(a.gpa, c.name);
    }
    try out.appendSlice(a.gpa, ",x,y,z\n");
    var buf: [128]u8 = undefined;
    for (a.points, 0..) |*p, i| {
        for (0..tbl.n_cols) |c| {
            if (c > 0) try out.append(a.gpa, ',');
            try out.appendSlice(a.gpa, tbl.cell(p.row, c));
        }
        const line = try std.fmt.bufPrint(&buf, ",{d:.4},{d:.4},{d:.4}\n", .{
            a.p3[i][0], a.p3[i][1], a.p3[i][2],
        });
        try out.appendSlice(a.gpa, line);
    }
    try std.Io.Dir.cwd().writeFile(a.io, .{ .sub_path = "dataset_view.csv", .data = out.items });
    log.print("exported dataset_view.csv ({d} rows + the current projection)\n", .{a.count()});
}

pub const deck_path = "deck.zon";
pub const deck_default: [:0]const u8 = @embedFile("deck.zon");
