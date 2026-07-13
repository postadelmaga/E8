//! Geometry demo: the 24-cell — the regular 4-polytope with no 3D analogue,
//! self-dual, vertices = the D4 root system, symmetry group F4. The same
//! polytope whose 24 vertices carry one fermion type's three generations in
//! Lisi's CPTt construction (arXiv:2407.02497 Fig 1) — here it stars on its
//! own. Second consumer of the presenter framework: everything below is data
//! and small functions; the framework does the rest.

const std = @import("std");
const geom = @import("../../geom.zig");
const hud_mod = @import("../../hud.zig");
const desc = @import("../../descriptor.zig");
const app_mod = @import("../../app.zig");
const App = app_mod.App;

pub const name = "24-cell";
pub const title = "24-cell — a guided tour (P journey, click a vertex)";
pub const app_id = "dev.presenter.polytope";

pub const dim = 4;
pub const n = 24;
/// All vertices sit on the unit 3-sphere.
pub const radius2: f32 = 1.0;

pub const deck_path = "deck.zon";
pub const deck_default: [:0]const u8 = @embedFile("deck.zon");

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

/// One of the three inscribed 16-cells (octads), permuted by F4's triality.
pub const Octad = enum(u8) { axis, even, odd };

pub const Point = struct {
    v: [4]f32,
    octad: Octad,
};

pub fn generate() [n]Point {
    var out: [n]Point = undefined;
    var k: usize = 0;
    // 8 "axis" vertices (±1, 0, 0, 0)…
    for (0..4) |i| {
        for ([2]f32{ 1, -1 }) |s| {
            var v = [_]f32{0} ** 4;
            v[i] = s;
            out[k] = .{ .v = v, .octad = .axis };
            k += 1;
        }
    }
    // …and 16 "cube" vertices (±½,±½,±½,±½), split by minus-sign parity.
    var bits: u32 = 0;
    while (bits < 16) : (bits += 1) {
        var v: [4]f32 = undefined;
        for (0..4) |i| v[i] = if (bits >> @intCast(i) & 1 == 1) -0.5 else 0.5;
        out[k] = .{ .v = v, .octad = if (@popCount(bits) % 2 == 0) .even else .odd };
        k += 1;
    }
    return out;
}

pub fn buildEdges(gpa: std.mem.Allocator, points: []const Point) ![]const [2]u16 {
    var edges: std.ArrayList([2]u16) = .empty;
    errdefer edges.deinit(gpa);
    for (0..points.len) |i| {
        for (i + 1..points.len) |j| {
            var d: f32 = 0;
            for (points[i].v, points[j].v) |x, y| d += (x - y) * (x - y);
            if (@abs(d - 1.0) < 1e-4) try edges.append(gpa, .{ @intCast(i), @intCast(j) });
        }
    }
    return edges.toOwnedSlice(gpa); // 96 edges, 8 per vertex
}

// --- projections ---------------------------------------------------------------------

/// F4 Petrie plane of the 24-cell (rotation 2π/12): power iteration on the
/// Coxeter element of F4, whose root polytope this is.
fn petrie() [2][4]f32 {
    const simple = [4][4]f32{
        .{ 0, 1, -1, 0 },
        .{ 0, 0, 1, -1 },
        .{ 0, 0, 0, 1 },
        .{ 0.5, -0.5, -0.5, -0.5 },
    };
    var c: [4][4]f32 = @splat(@splat(0));
    for (0..4) |i| c[i][i] = 1;
    for (simple) |alpha| {
        var n2: f32 = 0;
        for (alpha) |x| n2 += x * x;
        for (&c) |*col| {
            var d: f32 = 0;
            for (col, alpha) |x, y| d += x * y;
            for (0..4) |k| col[k] -= 2.0 * d / n2 * alpha[k];
        }
    }
    var a: [4][4]f32 = undefined;
    for (0..4) |col| {
        for (0..4) |row| a[col][row] = c[col][row] + c[row][col];
        a[col][col] += 2.0;
    }
    var u = [4]f32{ 1, 0, 0, 0 };
    var v = [4]f32{ 0, 1, 0, 0 };
    for (0..400) |_| {
        var nu = [_]f32{0} ** 4;
        var nv = [_]f32{0} ** 4;
        for (0..4) |col| {
            for (0..4) |row| {
                nu[row] += a[col][row] * u[col];
                nv[row] += a[col][row] * v[col];
            }
        }
        var lu: f32 = 0;
        for (nu) |x| lu += x * x;
        lu = @max(@sqrt(lu), 1e-12);
        for (&nu) |*x| x.* /= lu;
        var d: f32 = 0;
        for (nv, nu) |x, y| d += x * y;
        for (0..4) |k| nv[k] -= d * nu[k];
        var lv: f32 = 0;
        for (nv) |x| lv += x * x;
        lv = @max(@sqrt(lv), 1e-12);
        for (&nv) |*x| x.* /= lv;
        u = nu;
        v = nv;
    }
    return .{ u, v };
}

fn bPetrie(_: f32) geom.Basis {
    const p = petrie();
    return .{ p[0], p[1], .{ 0, 0, 0, 1 } };
}

fn bFront(_: f32) geom.Basis {
    return .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
    };
}

/// The famous isoclinic double rotation: equal-angle turns in two orthogonal
/// planes at once — only possible in four dimensions.
fn bIsoclinic(theta: f32) geom.Basis {
    var b = bFront(0);
    geom.rotateBasis(&b, 0, 3, theta);
    geom.rotateBasis(&b, 1, 2, theta);
    return b;
}

pub const presets = &[_]app_mod.PresetDef{
    .{ .name = "Petrie plane (12-gon)", .basis = bPetrie },
    .{ .name = "front cell", .basis = bFront },
    .{ .name = "isoclinic rotation", .basis = bIsoclinic, .animated = true },
};

// --- colors, filters, relations, actions ---------------------------------------------

fn octadRgb(o: Octad) [3]f32 {
    return switch (o) {
        .axis => .{ 0.35, 0.80, 1.0 },
        .even => .{ 1.0, 0.72, 0.20 },
        .odd => .{ 0.85, 0.42, 1.0 },
    };
}

fn cOctads(p: *const Point, _: f32) [3]f32 {
    return octadRgb(p.octad);
}
fn cHidden(_: *const Point, hidden_t: f32) [3]f32 {
    const t = std.math.clamp(hidden_t, 0, 1);
    return .{ 0.15 + 0.85 * t, 0.35 + 0.25 * (1 - t), 1.0 - 0.75 * t };
}

const legend_octads = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 89, 204, 255 }, .label = "axis 16-cell" },
    .{ .rgb = .{ 255, 184, 51 }, .label = "even 16-cell" },
    .{ .rgb = .{ 217, 107, 255 }, .label = "odd 16-cell" },
};
const legend_hidden = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 64, 128, 255 }, .label = "near the view space" },
    .{ .rgb = .{ 255, 100, 64 }, .label = "4th dimension" },
};

pub const color_modes = &[_]app_mod.ColorModeDef{
    .{ .name = "three 16-cells", .color = cOctads, .legend = &legend_octads },
    .{ .name = "hidden depth", .color = cHidden, .legend = &legend_hidden },
};

fn fAll(_: *const Point) bool {
    return true;
}
fn fAxis(p: *const Point) bool {
    return p.octad == .axis;
}
fn fEven(p: *const Point) bool {
    return p.octad == .even;
}
fn fOdd(p: *const Point) bool {
    return p.octad == .odd;
}

pub const filters = &[_]app_mod.FilterDef{
    .{ .name = "all 24", .pass = fAll },
    .{ .name = "axis 16-cell (8)", .pass = fAxis },
    .{ .name = "even 16-cell (8)", .pass = fEven },
    .{ .name = "odd 16-cell (8)", .pass = fOdd },
};

fn antipode(points: []const Point, i: u16) u16 {
    for (points, 0..) |*s, j| {
        var d: f32 = 0;
        for (s.v, points[i].v) |x, y| d += (x + y) * (x + y);
        if (d < 1e-6) return @intCast(j);
    }
    return i;
}

pub const relations = &[_]app_mod.RelationDef{
    .{ .name = "antipode", .partner = antipode },
};

fn actAntipode(a: *App) void {
    if (a.selected >= 0 and a.rel.len > 0) {
        a.selected = a.rel[0][@intCast(a.selected)];
        a.info_dirty = true;
    }
}

pub const actions = &[_]app_mod.ActionDef{
    .{ .key = 34, .help = "G: jump to the antipodal vertex", .run = actAntipode },
};

pub fn descriptor(a: *App, i: usize) desc.Object {
    const p = &a.points[i];
    return .{
        .orbit_rgb = octadRgb(p.octad),
        .orbit_phase = @as(f32, @floatFromInt(@intFromEnum(p.octad))) * 2.0 * std.math.pi / 3.0,
        .pulse = if (p.octad == .axis) .{ .kind = .breathe, .rate = 1.0, .amp = 0.25 } else null,
    };
}

// --- text -----------------------------------------------------------------------------

pub fn describe(a: *App, i: usize, buf: []u8) []const u8 {
    const p = &a.points[i];
    const partner: usize = if (a.rel.len > 0) a.rel[0][i] else i;
    return std.fmt.bufPrint(buf, "vertex #{d}: {s} 16-cell · ({d:.1},{d:.1},{d:.1},{d:.1}) · 8 neighbors · antipode #{d} (G)", .{
        i, @tagName(p.octad), p.v[0], p.v[1], p.v[2], p.v[3], partner,
    }) catch "";
}

pub fn story(a: *App) void {
    if (a.selected < 0) {
        a.hud.setPanel(
            "The 24-cell",
            "24 vertices, 96 edges, 96 triangles, 24 octahedral cells — the only regular convex polytope with no 3D analogue, and it is SELF-DUAL: its cell centers are again a 24-cell.\nIts vertices are the D4 root system; its symmetry group is F4, order 1152. The 24 split into three inscribed 16-cells, permuted by triality.\nClick a vertex, ride G to its antipode, or press P for the guided tour.",
            "H.S.M. Coxeter, Regular Polytopes, ch. VIII. Lisi arXiv:2407.02497 Fig 1 (the 24-cell as three fermion generations).",
        );
        return;
    }
    const p = &a.points[@intCast(a.selected)];
    var tbuf: [64]u8 = undefined;
    const t = std.fmt.bufPrint(&tbuf, "vertex of the {s} 16-cell", .{@tagName(p.octad)}) catch "vertex";
    a.hud.setPanel(
        t,
        switch (p.octad) {
            .axis => "One of the 8 unit vectors (±1,0,0,0)… — a cross-polytope (16-cell) on its own. Together with the two half-integer octads it makes the 24-cell: remove it and the 16 remaining vertices form a hypercube (the 24-cell = 16-cell + tesseract, vertex-wise).\nIts 8 neighbors are exactly the nearest half-integer vertices.",
            .even => "One of the 8 half-integer vertices (±½,±½,±½,±½) with an EVEN number of minus signs — a 16-cell inscribed diagonally. F4's triality rotates this octad into the axis and odd octads.\nIn Lisi's CPTt picture these 8 slots are one generation's CPT cube.",
            .odd => "One of the 8 half-integer vertices (±½,±½,±½,±½) with an ODD number of minus signs — the third inscribed 16-cell, triality partner of the other two.\nIn Lisi's CPTt picture these 8 slots are one generation's CPT cube.",
        },
        "Coxeter, Regular Polytopes §8.2. 2407.02497 §7.",
    );
}

pub const InspectText = struct { title_len: usize, body_len: usize };

pub fn inspect(a: *App, i: usize, tbuf: *[96]u8, bbuf: *[512]u8) InspectText {
    const p = &a.points[i];
    const t = std.fmt.bufPrint(tbuf, "vertex #{d} — {s} 16-cell", .{ i, @tagName(p.octad) }) catch "";
    const anti: usize = if (a.rel.len > 0) a.rel[0][i] else i;
    const b = std.fmt.bufPrint(bbuf, "coords ({d:.2}, {d:.2}, {d:.2}, {d:.2}) on the unit 3-sphere\n8 neighbors at 60° · antipode #{d} (lit in the scene)\nThe 24-cell tiles R⁴ by translation; its Voronoi cell is itself — the densest lattice packing in 4D (D4).\nrefs: Coxeter, Regular Polytopes; 2407.02497 Fig 1", .{
        p.v[0], p.v[1], p.v[2], p.v[3], anti,
    }) catch "";
    return .{ .title_len = t.len, .body_len = b.len };
}

pub fn figure(a: *App, fig_id: []const u8, dots: []hud_mod.FigDot) usize {
    if (!std.mem.eql(u8, fig_id, "petrie")) return 0;
    const p = petrie();
    var n_dots: usize = 0;
    for (a.points) |*pt| {
        var x: f32 = 0;
        var y: f32 = 0;
        for (0..4) |k| {
            x += p[0][k] * pt.v[k];
            y += p[1][k] * pt.v[k];
        }
        const c = octadRgb(pt.octad);
        dots[n_dots] = .{ .x = x * 0.95, .y = y * 0.95, .rgb = .{
            @intFromFloat(c[0] * 255),
            @intFromFloat(c[1] * 255),
            @intFromFloat(c[2] * 255),
        } };
        n_dots += 1;
        if (n_dots == dots.len) break;
    }
    return n_dots;
}

pub fn exportCsv(a: *App) !void {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a.gpa);
    try out.appendSlice(a.gpa, "index,octad,x1,x2,x3,x4,px,py,pz\n");
    var buf: [160]u8 = undefined;
    for (a.points, 0..) |*p, i| {
        const pr = geom.project(&a.basis, p.v);
        const line = try std.fmt.bufPrint(&buf, "{d},{s},{d},{d},{d},{d},{d:.6},{d:.6},{d:.6}\n", .{
            i, @tagName(p.octad), p.v[0], p.v[1], p.v[2], p.v[3], pr[0], pr[1], pr[2],
        });
        try out.appendSlice(a.gpa, line);
    }
    const csv = try out.toOwnedSlice(a.gpa);
    defer a.gpa.free(csv);
    try std.Io.Dir.cwd().writeFile(a.io, .{ .sub_path = "polytope.csv", .data = csv });
    std.debug.print("exported polytope.csv\n", .{});
}
