//! The astronomy profile — a star catalog, in the space it actually occupies.
//!
//! Point it at any catalog export (Gaia, SIMBAD, HYG, your own CSV):
//!
//!   zig build -Ddemo=astro run -- gaia.csv
//!
//! It finds the columns by name — ra/dec, parallax (mas) or distance (pc),
//! magnitude, color index (bp_rp, b_v) or effective temperature — turns them into
//! cartesian parsecs, and colors every star by its true blackbody color. The
//! catalog stops being a table of angles and becomes a neighborhood you orbit.
//!
//! The field's own figure comes with it: the Hertzsprung–Russell diagram, drawn
//! live in the panel from the same rows — color against absolute magnitude, the
//! plot that turned stellar astronomy into physics.

const std = @import("std");
const table = @import("../data/table.zig");
const geom = @import("../../geom.zig");
const hud_mod = @import("../../hud.zig");
const desc = @import("../../descriptor.zig");
const app_mod = @import("../../app.zig");
const App = app_mod.App;

pub const name = "Star catalog";
pub const title = "presenter — star catalog (parsecs, blackbody color, HR diagram)";
pub const app_id = "dev.presenter.astro";

pub const dim = 3;

pub const Point = struct {
    v: [3]f32, // parsecs, centered on the observer, scaled to the unit ball
    /// The physics of the star, resolved once at load.
    dist_pc: f32 = 0,
    app_mag: f32 = 0,
    abs_mag: f32 = 0,
    /// Color index (BP−RP or B−V). NaN when the catalog has none.
    color_idx: f32 = 0,
    teff: f32 = 0,
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

const max_stars: usize = 20_000;

var tbl: table.Table = undefined;
var have = false;
var col_ra: ?usize = null;
var col_dec: ?usize = null;
var col_plx: ?usize = null;
var col_dist: ?usize = null;
var col_mag: ?usize = null;
var col_color: ?usize = null;
var col_teff: ?usize = null;
var col_name: ?usize = null;
var pc_per_unit: f32 = 1.0;
var nn: []u16 = &.{};
var max_dist: f32 = 1;

/// Blackbody color from the color index, the (BP−RP → Teff → RGB) chain every
/// sky map uses: hot stars blue, the Sun white-yellow, red dwarfs red.
fn colorFromIndex(ci: f32) [3]f32 {
    const t = std.math.clamp((ci + 0.4) / 2.6, 0, 1); // −0.4 (O) … 2.2 (M)
    // Piecewise through the stellar sequence: O/B → A/F → G → K → M.
    if (t < 0.25) {
        const u = t / 0.25;
        return .{ 0.62 + 0.30 * u, 0.72 + 0.22 * u, 1.00 };
    } else if (t < 0.5) {
        const u = (t - 0.25) / 0.25;
        return .{ 0.92 + 0.08 * u, 0.94 + 0.05 * u, 1.00 - 0.10 * u };
    } else if (t < 0.72) {
        const u = (t - 0.5) / 0.22;
        return .{ 1.00, 0.99 - 0.13 * u, 0.90 - 0.28 * u };
    }
    const u = (t - 0.72) / 0.28;
    return .{ 1.00, 0.86 - 0.35 * u, 0.62 - 0.42 * u };
}

fn tempFromIndex(ci: f32) f32 {
    // Ballesteros' formula — good to a few percent across the main sequence.
    const b_v = std.math.clamp(ci, -0.4, 2.5);
    return 4600.0 * (1.0 / (0.92 * b_v + 1.7) + 1.0 / (0.92 * b_v + 0.62));
}

fn indexFromTemp(teff: f32) f32 {
    // The inverse, close enough for coloring when a catalog gives only Teff.
    const t = std.math.clamp(teff, 2000, 40000);
    return std.math.clamp(1.7 - @log10(t / 4600.0) * 3.6, -0.4, 2.4);
}

/// Find a column by any of the names the field uses for the same quantity.
fn findCol(t: *const table.Table, names: []const []const u8, want_numeric: bool) ?usize {
    for (names) |n| {
        if (t.columnByName(n)) |c| {
            if (!want_numeric or t.columns[c].kind == .numeric) return c;
        }
    }
    // Second pass: a column whose name merely CONTAINS one of the aliases
    // (catalogs love prefixes: `gaia_phot_g_mean_mag`).
    for (names) |n| {
        for (t.columns, 0..) |c, i| {
            if (want_numeric and c.kind != .numeric) continue;
            if (std.ascii.indexOfIgnoreCase(c.name, n) != null) return i;
        }
    }
    return null;
}

pub fn load(gpa: std.mem.Allocator, io: std.Io) ![]Point {
    const path = app_mod.cli.file;
    if (path.len == 0) {
        std.debug.print(
            \\the star-catalog domain needs a catalog:
            \\  zig build -Ddemo=astro run -- gaia.csv
            \\  columns it looks for: ra, dec, parallax (mas) or dist (pc),
            \\  a magnitude, a color index (bp_rp / b_v) or teff, and a name.
            \\
        , .{});
        return error.NoInputFile;
    }
    tbl = try table.load(gpa, io, path, max_stars);
    have = true;
    errdefer {
        tbl.deinit();
        have = false;
    }

    col_ra = findCol(&tbl, &.{ "ra", "raj2000", "right_ascension" }, true);
    col_dec = findCol(&tbl, &.{ "dec", "de", "dej2000", "declination" }, true);
    col_plx = findCol(&tbl, &.{ "parallax", "plx" }, true);
    col_dist = findCol(&tbl, &.{ "dist", "distance", "r_est", "d_pc" }, true);
    col_mag = findCol(&tbl, &.{ "phot_g_mean_mag", "mag", "vmag", "gmag" }, true);
    col_color = findCol(&tbl, &.{ "bp_rp", "b_v", "bv", "color", "ci" }, true);
    col_teff = findCol(&tbl, &.{ "teff", "temperature" }, true);
    col_name = findCol(&tbl, &.{ "name", "proper", "id", "source_id", "hip", "designation" }, false);
    if (col_ra == null or col_dec == null) return error.NoSkyCoordinates;
    if (col_plx == null and col_dist == null) return error.NoDistance;

    const rows = tbl.rows;
    var pts: std.ArrayList(Point) = .empty;
    errdefer pts.deinit(gpa);

    const deg = std.math.pi / 180.0;
    for (0..rows) |r| {
        const ra = tbl.columns[col_ra.?].nums[r];
        const dec = tbl.columns[col_dec.?].nums[r];
        if (std.math.isNan(ra) or std.math.isNan(dec)) continue;

        // Distance: a parallax in milliarcseconds is 1000/plx parsecs. A negative
        // parallax is not a star behind you — it is noise, and it is dropped.
        var d_pc: f32 = 0;
        if (col_dist) |c| d_pc = tbl.columns[c].nums[r];
        if ((std.math.isNan(d_pc) or d_pc <= 0) and col_plx != null) {
            const plx = tbl.columns[col_plx.?].nums[r];
            if (std.math.isNan(plx) or plx <= 0.0001) continue;
            d_pc = 1000.0 / plx;
        }
        if (std.math.isNan(d_pc) or d_pc <= 0) continue;

        const ra_r: f32 = @floatCast(@as(f64, ra) * deg);
        const dec_r: f32 = @floatCast(@as(f64, dec) * deg);
        const x = d_pc * @cos(dec_r) * @cos(ra_r);
        const y = d_pc * @cos(dec_r) * @sin(ra_r);
        const z = d_pc * @sin(dec_r);

        var p: Point = .{ .v = .{ x, y, z }, .dist_pc = d_pc, .row = @intCast(r) };
        p.app_mag = if (col_mag) |c| tbl.columns[c].nums[r] else std.math.nan(f32);
        // The distance modulus: what the star would look like from 10 pc, which
        // is the only magnitude you can compare between two stars.
        p.abs_mag = if (!std.math.isNan(p.app_mag))
            p.app_mag - 5.0 * @log10(d_pc) + 5.0
        else
            std.math.nan(f32);
        p.color_idx = if (col_color) |c| tbl.columns[c].nums[r] else std.math.nan(f32);
        p.teff = if (col_teff) |c| tbl.columns[c].nums[r] else std.math.nan(f32);
        if (std.math.isNan(p.color_idx) and !std.math.isNan(p.teff)) p.color_idx = indexFromTemp(p.teff);
        if (std.math.isNan(p.teff) and !std.math.isNan(p.color_idx)) p.teff = tempFromIndex(p.color_idx);
        try pts.append(gpa, p);
    }
    if (pts.items.len == 0) return error.NoUsableRows;

    const out = try pts.toOwnedSlice(gpa);
    errdefer gpa.free(out);

    // Scale: the observer sits at the origin, the farthest star on the unit ball.
    max_dist = 0;
    for (out) |p| max_dist = @max(max_dist, p.dist_pc);
    pc_per_unit = if (max_dist > 1e-6) max_dist else 1;
    for (out) |*p| {
        for (0..3) |k| p.v[k] /= pc_per_unit;
    }
    radius2 = 1.0;

    // The nearest star to each star — the relation the framework walks, and the
    // one question a catalog is always asked.
    nn = try gpa.alloc(u16, out.len);
    for (out, 0..) |*p, i| {
        var best: usize = i;
        var best_d: f32 = std.math.floatMax(f32);
        for (out, 0..) |*q, j| {
            if (i == j) continue;
            var d: f32 = 0;
            for (0..3) |k| {
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

    buildMenus();
    std.debug.print("catalog: {s} — {d} stars (of {d} rows) · out to {d:.1} pc · color: {s} · magnitudes: {s}\n", .{
        path,
        out.len,
        rows,
        max_dist,
        if (col_color != null) "yes" else if (col_teff != null) "from Teff" else "none",
        if (col_mag != null) "yes" else "none",
    });
    return out;
}

pub fn unload(gpa: std.mem.Allocator) void {
    if (nn.len > 0) gpa.free(nn);
    nn = &.{};
    if (have) {
        tbl.deinit();
        have = false;
    }
}

/// Stars are not bonded to anything: the only lines worth drawing are to the
/// nearest neighbor, and the framework already offers that as a relation.
pub fn buildEdges(gpa: std.mem.Allocator, points: []const Point) ![]const [2]u16 {
    var out: std.ArrayList([2]u16) = .empty;
    errdefer out.deinit(gpa);
    for (points, 0..) |_, i| {
        const j = nn[i];
        if (i < j) try out.append(gpa, .{ @intCast(i), j });
    }
    return out.toOwnedSlice(gpa);
}

// --- projections ---------------------------------------------------------------------------

fn bEquatorial(_: f32) geom.Basis {
    return .{ .{ 1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 1, 0 } }; // z (north) up
}
/// The galactic plane: the disc the Sun sits in, tilted 62.87° from the equator.
fn bGalactic(_: f32) geom.Basis {
    var b: geom.Basis = .{
        .{ -0.0548, -0.8734, -0.4838 }, // x → galactic center
        .{ -0.4694, 0.4448, -0.7630 }, // z → north galactic pole (drawn up)
        .{ 0.8677, 0.1981, -0.4560 },
    };
    geom.orthonormalize(&b);
    return b;
}
fn bTumble(theta: f32) geom.Basis {
    var b = bGalactic(0);
    geom.rotateBasis(&b, 0, 2, theta * 0.6);
    geom.orthonormalize(&b);
    return b;
}

pub const presets = &[_]app_mod.PresetDef{
    .{ .name = "equatorial (RA/Dec)", .basis = bEquatorial },
    .{ .name = "galactic plane", .basis = bGalactic },
    .{ .name = "drift", .basis = bTumble, .animated = true },
};

// --- colors ---------------------------------------------------------------------------------

fn colorByStar(p: *const Point, _: f32) [3]f32 {
    if (std.math.isNan(p.color_idx)) return .{ 0.95, 0.95, 0.92 };
    return colorFromIndex(p.color_idx);
}
fn colorByDistance(p: *const Point, _: f32) [3]f32 {
    const t = std.math.clamp(p.dist_pc / max_dist, 0, 1);
    return .{ 0.25 + 0.75 * t, 0.55 - 0.25 * t, 1.0 - 0.55 * t };
}
fn colorByLuminosity(p: *const Point, _: f32) [3]f32 {
    if (std.math.isNan(p.abs_mag)) return .{ 0.7, 0.7, 0.75 };
    // Absolute magnitude runs BACKWARDS: −5 is a supergiant, +15 a red dwarf.
    const t = std.math.clamp((15.0 - p.abs_mag) / 20.0, 0, 1);
    return .{ 0.2 + 0.8 * t, 0.3 + 0.6 * t, 0.5 + 0.5 * t };
}

var legend_star = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 158, 184, 255 }, .label = "O/B (hot)" },
    .{ .rgb = .{ 235, 240, 255 }, .label = "A/F" },
    .{ .rgb = .{ 255, 252, 230 }, .label = "G (sun-like)" },
    .{ .rgb = .{ 255, 219, 158 }, .label = "K" },
    .{ .rgb = .{ 255, 130, 51 }, .label = "M (cool)" },
};
var legend_dist = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 64, 140, 255 }, .label = "near" },
    .{ .rgb = .{ 255, 77, 115 }, .label = "far" },
};
var legend_lum = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 51, 77, 128 }, .label = "faint (dwarf)" },
    .{ .rgb = .{ 255, 230, 255 }, .label = "luminous (giant)" },
};

var color_buf: [3]app_mod.ColorModeDef = undefined;
pub var color_modes: []const app_mod.ColorModeDef = &.{};
var filter_buf: [5]app_mod.FilterDef = undefined;
pub var filters: []const app_mod.FilterDef = &.{};
var relation_buf: [1]app_mod.RelationDef = undefined;
pub var relations: []const app_mod.RelationDef = &.{};

fn fAll(_: *const Point) bool {
    return true;
}
/// What the eye can see from a dark site — the sky humans actually named.
fn fNakedEye(p: *const Point) bool {
    return !std.math.isNan(p.app_mag) and p.app_mag <= 6.0;
}
fn fNear(p: *const Point) bool {
    return p.dist_pc <= 25.0; // the solar neighborhood
}
fn fGiants(p: *const Point) bool {
    return !std.math.isNan(p.abs_mag) and p.abs_mag < 2.0;
}
fn fDwarfs(p: *const Point) bool {
    return !std.math.isNan(p.abs_mag) and p.abs_mag > 8.0;
}

fn buildMenus() void {
    color_buf[0] = .{ .name = "stellar color", .color = colorByStar, .legend = &legend_star };
    color_buf[1] = .{ .name = "distance", .color = colorByDistance, .legend = &legend_dist };
    color_buf[2] = .{ .name = "luminosity", .color = colorByLuminosity, .legend = &legend_lum };
    color_modes = color_buf[0..3];

    filter_buf[0] = .{ .name = "all stars", .pass = fAll };
    filter_buf[1] = .{ .name = "naked eye (m ≤ 6)", .pass = fNakedEye };
    filter_buf[2] = .{ .name = "within 25 pc", .pass = fNear };
    filter_buf[3] = .{ .name = "giants (M < 2)", .pass = fGiants };
    filter_buf[4] = .{ .name = "dwarfs (M > 8)", .pass = fDwarfs };
    filters = filter_buf[0..5];

    relation_buf[0] = .{ .name = "nearest star", .partner = nearestPartner };
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
    .{ .key = 49, .help = "N: jump to the nearest star", .run = actNearest },
};

// --- how a star looks ------------------------------------------------------------------------

pub fn descriptor(a: *App, i: usize) desc.Object {
    const p = &a.points[i];
    // Brighter stars are bigger and glow harder — apparent magnitude is a
    // logarithm, so 5 magnitudes are a factor of 100 in flux.
    const m = if (std.math.isNan(p.app_mag)) 6.0 else p.app_mag;
    const flux = std.math.clamp(std.math.pow(f32, 10.0, (6.0 - m) / 5.0), 0.25, 6.0);
    return .{
        .radius = 0.5 + 0.45 * flux,
        .glow = 0.7 + 0.5 * flux,
        .orbit_rgb = colorByStar(p, 0),
        // Hot stars scintillate faster: a cheap, honest cue for temperature.
        .pulse = .{
            .kind = .breathe,
            .rate = 0.8 + 2.0 / @max(p.color_idx + 1.0, 0.4),
            .amp = 0.18,
            .phase = @as(f32, @floatFromInt(i)) * 2.399,
        },
    };
}

fn nameOf(p: *const Point, buf: []u8) []const u8 {
    if (col_name) |c| {
        const s = tbl.cell(p.row, c);
        if (s.len > 0) return s;
    }
    return std.fmt.bufPrint(buf, "star {d}", .{p.row + 1}) catch "star";
}

fn spectralClass(ci: f32) []const u8 {
    if (std.math.isNan(ci)) return "?";
    if (ci < -0.02) return "B";
    if (ci < 0.30) return "A";
    if (ci < 0.58) return "F";
    if (ci < 0.81) return "G";
    if (ci < 1.40) return "K";
    return "M";
}

pub fn describe(a: *App, i: usize, buf: []u8) []const u8 {
    const p = &a.points[i];
    var nb: [64]u8 = undefined;
    return std.fmt.bufPrint(buf, "{s} · {d:.1} pc · m={d:.2} M={d:.2} · {s}-type · N jumps to its nearest star", .{
        nameOf(p, &nb),
        p.dist_pc,
        p.app_mag,
        p.abs_mag,
        spectralClass(p.color_idx),
    }) catch "star";
}

pub fn story(a: *App) void {
    const hud = a.hud;
    if (a.selected < 0) {
        var buf: [720]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{d} stars, placed in parsecs: right ascension and declination give the direction, the parallax gives the distance (d = 1000/π mas), and the observer sits at the origin. Negative parallaxes — noise, not stars behind you — were dropped.
            \\Color is the star's real color, from its color index through the blackbody sequence: blue O/B, white A/F, yellow G like the Sun, orange K, red M. Size follows apparent magnitude.
            \\1: the equatorial frame. 2: the galactic plane — the disc we live in tilts into place, and the crowd of the Milky Way lines up.
            \\The figure is the Hertzsprung–Russell diagram, drawn from these very rows: color against absolute magnitude. The main sequence is the diagonal; the giants sit above it.
        , .{a.points.len}) catch "";
        hud.setPanel("The catalog", body, app_mod.cli.file);
        return;
    }
    const p = &a.points[@intCast(a.selected)];
    var nb: [64]u8 = undefined;
    var tb: [96]u8 = undefined;
    const t = std.fmt.bufPrint(&tb, "{s}", .{nameOf(p, &nb)}) catch "star";
    var bb: [720]u8 = undefined;
    var w: std.Io.Writer = .fixed(&bb);
    w.print("distance: {d:.2} pc ({d:.2} light-years)\napparent magnitude: {d:.2}\nabsolute magnitude: {d:.2}\ncolor index: {d:.2} → {s}-type, T ≈ {d:.0} K\n\n", .{
        p.dist_pc,
        p.dist_pc * 3.2616,
        p.app_mag,
        p.abs_mag,
        p.color_idx,
        spectralClass(p.color_idx),
        p.teff,
    }) catch {};
    if (nn.len > 0) {
        const j = nn[@intCast(a.selected)];
        const q = &a.points[j];
        var d: f32 = 0;
        for (0..3) |k| {
            const dd = (p.v[k] - q.v[k]) * pc_per_unit;
            d += dd * dd;
        }
        var nb2: [64]u8 = undefined;
        w.print("nearest star: {s}, {d:.2} pc away (N jumps to it)", .{ nameOf(q, &nb2), @sqrt(d) }) catch {};
    }
    hud.setPanel(t, w.buffered(), "");
}

pub const InspectText = struct { title_len: usize, body_len: usize };

pub fn inspect(a: *App, i: usize, tbuf: *[96]u8, bbuf: *[512]u8) InspectText {
    const p = &a.points[i];
    var nb: [64]u8 = undefined;
    const t = std.fmt.bufPrint(tbuf, "{s} — {s}-type", .{ nameOf(p, &nb), spectralClass(p.color_idx) }) catch "";
    var w: std.Io.Writer = .fixed(bbuf);
    w.print("{d:.2} pc away ({d:.1} ly). Apparent magnitude {d:.2}; from the standard 10 pc it would shine at {d:.2}.\n\nT ≈ {d:.0} K — that is the color you are looking at, not a palette choice.\n\n", .{
        p.dist_pc,
        p.dist_pc * 3.2616,
        p.app_mag,
        p.abs_mag,
        p.teff,
    }) catch {};
    if (!std.math.isNan(p.abs_mag)) {
        const line = if (p.abs_mag < 0)
            "Absolute magnitude under 0: a giant or supergiant — it sits above the main sequence in the HR diagram."
        else if (p.abs_mag > 8)
            "Absolute magnitude over 8: a dwarf, the kind of star that makes up most of the galaxy and none of the sky."
        else
            "It sits on the main sequence: fusing hydrogen, where a star spends most of its life.";
        w.print("{s}", .{line}) catch {};
    }
    return .{ .title_len = t.len, .body_len = w.buffered().len };
}

/// The Hertzsprung–Russell diagram, from the catalog's own rows: color index
/// across, absolute magnitude up (inverted — brighter is higher, as it is drawn
/// in every textbook since 1911).
pub fn figure(a: *App, fig_id: []const u8, dots: []hud_mod.FigDot) usize {
    if (!std.mem.eql(u8, fig_id, "hr")) return 0;
    var n_dots: usize = 0;
    const step = @max(a.points.len / dots.len, 1);
    var i: usize = 0;
    while (i < a.points.len and n_dots < dots.len) : (i += step) {
        const p = &a.points[i];
        if (std.math.isNan(p.abs_mag) or std.math.isNan(p.color_idx)) continue;
        const x = std.math.clamp((p.color_idx + 0.4) / 2.6, 0, 1) * 2.0 - 1.0;
        const y = std.math.clamp((12.0 - p.abs_mag) / 20.0, 0, 1) * 2.0 - 1.0;
        const rgb = colorFromIndex(p.color_idx);
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
    try out.appendSlice(a.gpa, "name,dist_pc,app_mag,abs_mag,color_index,teff_K,x_pc,y_pc,z_pc\n");
    var buf: [256]u8 = undefined;
    for (a.points) |*p| {
        var nb: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{s},{d:.3},{d:.3},{d:.3},{d:.3},{d:.0},{d:.3},{d:.3},{d:.3}\n", .{
            nameOf(p, &nb),
            p.dist_pc,
            p.app_mag,
            p.abs_mag,
            p.color_idx,
            p.teff,
            p.v[0] * pc_per_unit,
            p.v[1] * pc_per_unit,
            p.v[2] * pc_per_unit,
        });
        try out.appendSlice(a.gpa, line);
    }
    try std.Io.Dir.cwd().writeFile(a.io, .{ .sub_path = "catalog_stars.csv", .data = out.items });
    std.debug.print("exported catalog_stars.csv ({d} stars, cartesian parsecs)\n", .{a.count()});
}

pub const deck_path = "deck.zon";
pub const deck_default: [:0]const u8 = @embedFile("deck.zon");
