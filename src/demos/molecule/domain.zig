//! Molecular-biology demo: caffeine (C8H10N4O2), a ball-and-stick model driven
//! by the same presenter framework as the E8 paper. Third consumer, proving
//! the framework is domain-agnostic: points are atoms in R³, "edges" are
//! covalent bonds inferred from distance, classifications are chemical
//! elements, the deck narrates the structure. No framework changes needed.
//!
//! Coordinates are the PubChem CID 2519 3D conformer (Å), recentered.

const std = @import("std");
const geom = @import("../../geom.zig");
const hud_mod = @import("../../hud.zig");
const desc = @import("../../descriptor.zig");
const app_mod = @import("../../app.zig");
const App = app_mod.App;

pub const name = "Caffeine";
pub const title = "Caffeine C8H10N4O2 — molecular tour (P journey, click an atom)";
pub const app_id = "dev.presenter.molecule";

pub const dim = 3;
/// Non-hydrogen atoms of caffeine (8 C + 4 N + 2 O). Hydrogens omitted for a
/// clean ball-and-stick — the framework has no opinion, this is the domain's.
pub const n = 14;
pub const radius2: f32 = 9.0; // recentered coords fit within |v| ≲ 3 Å

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

pub const Element = enum(u8) { c, n, o };

pub const Point = struct {
    v: [3]f32,
    el: Element,
    /// True for the two fused-ring nitrogens/carbons of the purine core that
    /// carry the methyl groups — highlighted as the pharmacophore.
    core: bool,
};

// Heavy-atom skeleton of caffeine (PubChem CID 2519 conformer, Å, recentered
// on the centroid). Enough for a faithful ball-and-stick of the purine rings.
const raw = [n]struct { x: f32, y: f32, z: f32, el: Element, core: bool }{
    .{ .x = 0.47, .y = -1.35, .z = 0.01, .el = .n, .core = true }, // N1
    .{ .x = 1.14, .y = -0.18, .z = 0.02, .el = .c, .core = true }, // C2
    .{ .x = 0.49, .y = 1.04, .z = 0.01, .el = .n, .core = true }, // N3
    .{ .x = -0.90, .y = 1.09, .z = 0.00, .el = .c, .core = true }, // C4
    .{ .x = -1.65, .y = -0.08, .z = -0.01, .el = .c, .core = true }, // C5
    .{ .x = -0.93, .y = -1.33, .z = -0.01, .el = .c, .core = true }, // C6
    .{ .x = -1.72, .y = 2.20, .z = 0.01, .el = .n, .core = true }, // N7
    .{ .x = -2.95, .y = 1.72, .z = 0.00, .el = .c, .core = false }, // C8
    .{ .x = -2.99, .y = 0.37, .z = -0.02, .el = .n, .core = true }, // N9
    .{ .x = 2.36, .y = -0.21, .z = 0.03, .el = .o, .core = false }, // O2
    .{ .x = -1.52, .y = -2.39, .z = -0.02, .el = .o, .core = false }, // O6
    .{ .x = 1.20, .y = -2.60, .z = 0.02, .el = .c, .core = false }, // N1-CH3
    .{ .x = 1.25, .y = 2.28, .z = 0.02, .el = .c, .core = false }, // N3-CH3
    .{ .x = -4.20, .y = -0.40, .z = -0.03, .el = .c, .core = false }, // N9-CH3
};

pub fn generate() [n]Point {
    var out: [n]Point = undefined;
    for (raw, 0..) |a, i| out[i] = .{ .v = .{ a.x, a.y, a.z }, .el = a.el, .core = a.core };
    return out;
}

/// Covalent bonds = heavy-atom pairs closer than 1.8 Å.
pub fn buildEdges(gpa: std.mem.Allocator, points: []const Point) ![]const [2]u16 {
    var edges: std.ArrayList([2]u16) = .empty;
    errdefer edges.deinit(gpa);
    for (0..points.len) |i| {
        for (i + 1..points.len) |j| {
            var d: f32 = 0;
            for (points[i].v, points[j].v) |x, y| d += (x - y) * (x - y);
            if (d < 1.8 * 1.8) try edges.append(gpa, .{ @intCast(i), @intCast(j) });
        }
    }
    return edges.toOwnedSlice(gpa);
}

// --- projections ---------------------------------------------------------------------

fn bFront(_: f32) geom.Basis {
    return .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
}
fn bSpin(theta: f32) geom.Basis {
    var b = bFront(0);
    geom.rotateBasis(&b, 0, 2, theta);
    return b;
}

pub const presets = &[_]app_mod.PresetDef{
    .{ .name = "molecular plane", .basis = bFront },
    .{ .name = "turntable", .basis = bSpin, .animated = true },
};

// --- colors, filters -----------------------------------------------------------------

fn cpk(e: Element) [3]f32 {
    return switch (e) {
        .c => .{ 0.30, 0.32, 0.36 }, // carbon: dark grey (brightened for emissive)
        .n => .{ 0.22, 0.35, 0.95 }, // nitrogen: blue
        .o => .{ 0.95, 0.22, 0.20 }, // oxygen: red
    };
}
fn cElement(p: *const Point, _: f32) [3]f32 {
    var c = cpk(p.el);
    if (p.el == .c) for (&c) |*x| {
        x.* += 0.35;
    };
    return c;
}
fn cCore(p: *const Point, _: f32) [3]f32 {
    return if (p.core) .{ 1.0, 0.75, 0.2 } else .{ 0.35, 0.4, 0.5 };
}

const legend_cpk = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 160, 165, 175 }, .label = "carbon" },
    .{ .rgb = .{ 56, 89, 242 }, .label = "nitrogen" },
    .{ .rgb = .{ 242, 56, 51 }, .label = "oxygen" },
};
const legend_core = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 255, 191, 51 }, .label = "purine core" },
    .{ .rgb = .{ 89, 102, 128 }, .label = "substituent" },
};

pub const color_modes = &[_]app_mod.ColorModeDef{
    .{ .name = "CPK elements", .color = cElement, .legend = &legend_cpk },
    .{ .name = "purine core", .color = cCore, .legend = &legend_core },
};

fn fAll(_: *const Point) bool {
    return true;
}
fn fC(p: *const Point) bool {
    return p.el == .c;
}
fn fN(p: *const Point) bool {
    return p.el == .n;
}
fn fO(p: *const Point) bool {
    return p.el == .o;
}
fn fCore(p: *const Point) bool {
    return p.core;
}

pub const filters = &[_]app_mod.FilterDef{
    .{ .name = "all atoms", .pass = fAll },
    .{ .name = "carbon", .pass = fC },
    .{ .name = "nitrogen", .pass = fN },
    .{ .name = "oxygen", .pass = fO },
    .{ .name = "purine core", .pass = fCore },
};

// No natural pairing relation for a molecule; the "next bonded neighbor" makes
// a handy walk (G steps along the skeleton).
fn nextBonded(points: []const Point, i: u16) u16 {
    var best: u16 = i;
    var best_d: f32 = 1e30;
    for (points, 0..) |*s, j| {
        if (j == i) continue;
        var d: f32 = 0;
        for (s.v, points[i].v) |x, y| d += (x - y) * (x - y);
        // Prefer the closest atom with a higher index — a deterministic walk.
        if (d < 1.8 * 1.8 and j > i and d < best_d) {
            best = @intCast(j);
            best_d = d;
        }
    }
    if (best == i) return 0; // wrap to the start
    return best;
}

pub const relations = &[_]app_mod.RelationDef{
    .{ .name = "backbone", .partner = nextBonded },
};

fn actWalk(a: *App) void {
    if (a.selected >= 0 and a.rel.len > 0) {
        a.selected = a.rel[0][@intCast(a.selected)];
        a.info_dirty = true;
    }
}

pub const actions = &[_]app_mod.ActionDef{
    .{ .key = 34, .help = "G: walk to the next bonded atom", .run = actWalk },
};

pub fn descriptor(a: *App, i: usize) desc.Object {
    const p = &a.points[i];
    // van-der-Waals-ish radii, scaled down for ball-and-stick.
    const r: f32 = switch (p.el) {
        .c => 1.5,
        .n => 1.4,
        .o => 1.35,
    };
    return .{
        .radius = r,
        .orbit_rgb = .{ 1.0, 0.75, 0.2 },
        // The pharmacophore core gently breathes.
        .pulse = if (p.core) .{ .kind = .breathe, .rate = 0.9, .amp = 0.22 } else null,
    };
}

// --- text -----------------------------------------------------------------------------

fn elName(e: Element) []const u8 {
    return switch (e) {
        .c => "carbon",
        .n => "nitrogen",
        .o => "oxygen",
    };
}

pub fn describe(a: *App, i: usize, buf: []u8) []const u8 {
    const p = &a.points[i];
    return std.fmt.bufPrint(buf, "atom #{d}: {s}{s} · ({d:.2},{d:.2},{d:.2}) Å · {d} bonds · G walks the skeleton", .{
        i, elName(p.el), if (p.core) " (purine core)" else "", p.v[0], p.v[1], p.v[2], a.neighbors(i).len,
    }) catch "";
}

pub fn story(a: *App) void {
    if (a.selected < 0) {
        a.hud.setPanel(
            "Caffeine (C8H10N4O2)",
            "The world's most consumed psychoactive molecule — a purine alkaloid. Its fused five- and six-membered rings (the purine core, highlighted) are a near-perfect mimic of adenosine, which is how it works: it blocks adenosine receptors in the brain, holding off drowsiness.\nThree methyl groups hang off the core nitrogens. Click any atom, walk the skeleton with G, or press P for the tour. (Hydrogens are omitted for clarity.)",
            "Geometry: PubChem CID 2519 3D conformer. Structure: any organic-chemistry text, purine numbering.",
        );
        return;
    }
    const p = &a.points[@intCast(a.selected)];
    var tbuf: [64]u8 = undefined;
    const t = std.fmt.bufPrint(&tbuf, "{s} atom{s}", .{ elName(p.el), if (p.core) " · purine core" else "" }) catch "atom";
    a.hud.setPanel(
        t,
        switch (p.el) {
            .n => "A ring nitrogen. Caffeine's four nitrogens are what make it a purine and let it dock into adenosine receptors; the three methylated ones (N1, N3, N7) distinguish caffeine from its cousins theobromine and theophylline.",
            .o => "A carbonyl oxygen (C=O). The two carbonyls at C2 and C6 are hydrogen-bond acceptors — part of how caffeine recognizes its target.",
            .c => if (p.core)
                "A ring carbon of the fused purine system. The rigid, planar bicyclic core is what mimics adenosine's shape."
            else
                "A methyl carbon (CH3). Which nitrogens carry methyls sets caffeine apart from theobromine (cocoa) and theophylline (tea).",
        },
        "PubChem CID 2519. Fredholm et al., Pharmacol. Rev. 51 (1999) 83 (mechanism).",
    );
}

pub const InspectText = struct { title_len: usize, body_len: usize };

pub fn inspect(a: *App, i: usize, tbuf: *[96]u8, bbuf: *[512]u8) InspectText {
    const p = &a.points[i];
    const t = std.fmt.bufPrint(tbuf, "atom #{d} — {s}{s}", .{ i, elName(p.el), if (p.core) " (core)" else "" }) catch "";
    const b = std.fmt.bufPrint(bbuf, "position ({d:.2}, {d:.2}, {d:.2}) Å\n{d} covalent bonds (< 1.8 Å, lit in the scene)\n{s}\nCaffeine's purine core mimics adenosine; the molecule is an adenosine-receptor antagonist.\nrefs: PubChem CID 2519 · Fredholm 1999", .{
        p.v[0], p.v[1], p.v[2], a.neighbors(i).len,
        switch (p.el) {
            .n => "Nitrogen — ring atom, hydrogen-bond donor/acceptor.",
            .o => "Oxygen — carbonyl acceptor.",
            .c => "Carbon — ring or methyl.",
        },
    }) catch "";
    return .{ .title_len = t.len, .body_len = b.len };
}

pub fn figure(a: *App, fig_id: []const u8, dots: []hud_mod.FigDot) usize {
    if (!std.mem.eql(u8, fig_id, "skeleton")) return 0;
    var n_dots: usize = 0;
    for (a.points) |*p| {
        const c = cpk(p.el);
        dots[n_dots] = .{ .x = p.v[0] / 3.0, .y = p.v[1] / 3.0, .rgb = .{
            @intFromFloat(std.math.clamp(c[0] + 0.35, 0, 1) * 255),
            @intFromFloat(std.math.clamp(c[1] + 0.2, 0, 1) * 255),
            @intFromFloat(std.math.clamp(c[2] + 0.2, 0, 1) * 255),
        } };
        n_dots += 1;
        if (n_dots == dots.len) break;
    }
    return n_dots;
}

pub fn exportCsv(a: *App) !void {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a.gpa);
    try out.appendSlice(a.gpa, "index,element,core,x,y,z\n");
    var buf: [128]u8 = undefined;
    for (a.points, 0..) |*p, i| {
        const line = try std.fmt.bufPrint(&buf, "{d},{s},{},{d},{d},{d}\n", .{
            i, elName(p.el), p.core, p.v[0], p.v[1], p.v[2],
        });
        try out.appendSlice(a.gpa, line);
    }
    const csv = try out.toOwnedSlice(a.gpa);
    defer a.gpa.free(csv);
    try std.Io.Dir.cwd().writeFile(a.io, .{ .sub_path = "caffeine.csv", .data = csv });
    std.debug.print("exported caffeine.csv\n", .{});
}
