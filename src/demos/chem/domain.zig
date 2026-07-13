//! The chemistry / structural-biology profile.
//!
//! Open a PDB or an XYZ (`-Ddemo=chem run -- 1ubq.pdb`) and the structure comes
//! up as it should: CPK elements, bonds from CONECT where the file declares them
//! and from covalent radii where it does not, chains and residues as filters,
//! B-factors as a ramp — the crystallographer's warning label, painted on.
//!
//! The one tool this field cannot work without is a ruler, so the framework's
//! selection gains a MARK: press M on an atom, select another, and the HUD shows
//! the distance in ångström (and the angle, once two marks are set). That is how
//! you check a hydrogen bond, a coordination sphere, a clash.
//!
//! Coordinates are kept twice: in ångström (for every measurement) and centered
//! and scaled to the unit ball (for the camera the framework flies).

const std = @import("std");
const read = @import("read.zig");
const geom = @import("../../geom.zig");
const hud_mod = @import("../../hud.zig");
const desc = @import("../../descriptor.zig");
const app_mod = @import("../../app.zig");
const App = app_mod.App;

pub const name = "Structure";
pub const title = "presenter — structure (PDB/XYZ, CPK, bonds, M measures)";
pub const app_id = "dev.presenter.chem";

pub const dim = 3;

pub const Point = struct {
    v: [3]f32, // centered/scaled — what the camera sees
    el: read.Element = .c,
    chain_idx: u8 = 0,
    res_idx: u16 = 0,
    hetatm: bool = false,
    backbone: bool = false,
    row: u32 = 0, // index into `atoms` (the ångström truth)
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

const max_atoms: usize = 20_000;
const max_chains: usize = 8;

var st: read.Structure = undefined;
var have = false;
var atoms: []read.Atom = &.{};
/// Å per unit of the drawn scene — every readout multiplies by this.
var ang_per_unit: f32 = 1.0;
var chains: [max_chains]u8 = undefined;
var n_chains: usize = 0;
var bonds: [][2]u16 = &.{};
/// The measuring mark (M), and the last measurement, for the HUD.
var mark: i32 = -1;
var bfac_lo: f32 = 0;
var bfac_hi: f32 = 1;
var n_residues: usize = 0;

// --- loading ---------------------------------------------------------------------------------

pub fn load(gpa: std.mem.Allocator, io: std.Io) ![]Point {
    const path = app_mod.cli.file;
    if (path.len == 0) {
        std.debug.print(
            \\the structure domain needs a file:
            \\  zig build -Ddemo=chem run -- 1ubq.pdb
            \\  zig build -Ddemo=chem run -- caffeine.xyz
            \\
        , .{});
        return error.NoInputFile;
    }
    st = try read.load(gpa, io, path, max_atoms);
    have = true;
    errdefer {
        st.deinit();
        have = false;
    }
    atoms = st.atoms;

    // Bonds: what the file declared, plus what the radii imply. A PDB usually
    // declares only its ligands, so both are needed to draw one molecule.
    const inferred = try read.inferBonds(gpa, atoms);
    defer gpa.free(inferred);
    var list: std.ArrayList([2]u16) = .empty;
    errdefer list.deinit(gpa);
    try list.appendSlice(gpa, st.conect);
    for (inferred) |b| {
        var dup = false;
        for (st.conect) |c| {
            if (c[0] == b[0] and c[1] == b[1]) dup = true;
        }
        if (!dup) try list.append(gpa, b);
    }
    bonds = try list.toOwnedSlice(gpa);

    const pts = try gpa.alloc(Point, atoms.len);
    errdefer gpa.free(pts);

    // Center on the centroid, scale so the farthest atom sits at 1.
    var ctr = [3]f32{ 0, 0, 0 };
    for (atoms) |a| {
        for (0..3) |k| ctr[k] += a.pos[k];
    }
    for (&ctr) |*c| c.* /= @floatFromInt(atoms.len);
    var max_r: f32 = 0;
    for (atoms) |a| {
        var s: f32 = 0;
        for (0..3) |k| {
            const t = a.pos[k] - ctr[k];
            s += t * t;
        }
        max_r = @max(max_r, @sqrt(s));
    }
    ang_per_unit = if (max_r > 1e-6) max_r else 1.0;
    radius2 = 1.0;

    n_chains = 0;
    n_residues = 0;
    bfac_lo = std.math.floatMax(f32);
    bfac_hi = -std.math.floatMax(f32);
    var last_res: i32 = std.math.minInt(i32);
    for (atoms, 0..) |a, i| {
        var ci: u8 = 0;
        var found = false;
        for (chains[0..n_chains], 0..) |c, k| {
            if (c == a.chain) {
                ci = @intCast(k);
                found = true;
            }
        }
        if (!found and n_chains < max_chains) {
            chains[n_chains] = a.chain;
            ci = @intCast(n_chains);
            n_chains += 1;
        }
        if (a.res_seq != last_res) {
            n_residues += 1;
            last_res = a.res_seq;
        }
        bfac_lo = @min(bfac_lo, a.bfactor);
        bfac_hi = @max(bfac_hi, a.bfactor);
        pts[i] = .{
            .v = .{
                (a.pos[0] - ctr[0]) / ang_per_unit,
                (a.pos[1] - ctr[1]) / ang_per_unit,
                (a.pos[2] - ctr[2]) / ang_per_unit,
            },
            .el = a.el,
            .chain_idx = ci,
            .res_idx = @intCast(@mod(a.res_seq, 4096)),
            .hetatm = a.hetatm,
            .backbone = a.backbone,
            .row = @intCast(i),
        };
    }
    if (!(bfac_hi > bfac_lo)) {
        bfac_lo = 0;
        bfac_hi = 1;
    }

    computeInertiaAxes(pts);
    buildMenus();
    std.debug.print("structure: {s} — {d} atoms · {d} bonds · {d} chains · {d} residues · {s}\n", .{
        path, atoms.len, bonds.len, n_chains, n_residues, if (st.is_pdb) "PDB" else "XYZ",
    });
    return pts;
}

pub fn unload(gpa: std.mem.Allocator) void {
    if (bonds.len > 0) gpa.free(bonds);
    bonds = &.{};
    if (have) {
        st.deinit();
        have = false;
    }
    atoms = &.{};
}

pub fn buildEdges(gpa: std.mem.Allocator, points: []const Point) ![]const [2]u16 {
    _ = points;
    return gpa.dupe([2]u16, bonds);
}

// --- projections: orientations of a rigid body ------------------------------------------------

fn bDeposited(_: f32) geom.Basis {
    return .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };
}
/// The molecule's own axes: the principal axes of its atom distribution, so the
/// long axis lies across the screen instead of into it.
var inertia_basis: geom.Basis = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };

fn computeInertiaAxes(pts: []const Point) void {
    var cov = [3][3]f32{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } };
    for (pts) |p| {
        for (0..3) |i| {
            for (0..3) |j| cov[i][j] += p.v[i] * p.v[j];
        }
    }
    for (0..3) |axis| {
        var v = [3]f32{ 0, 0, 0 };
        v[axis] = 1;
        for (0..64) |_| {
            var w = [3]f32{ 0, 0, 0 };
            for (0..3) |i| {
                for (0..3) |j| w[i] += cov[i][j] * v[j];
            }
            for (0..axis) |a| { // stay orthogonal to the axes already found
                var d: f32 = 0;
                for (0..3) |k| d += w[k] * inertia_basis[a][k];
                for (0..3) |k| w[k] -= d * inertia_basis[a][k];
            }
            var len: f32 = 0;
            for (w) |x| len += x * x;
            len = @sqrt(len);
            if (len < 1e-9) break;
            for (0..3) |k| v[k] = w[k] / len;
        }
        inertia_basis[axis] = v;
    }
    geom.orthonormalize(&inertia_basis);
}
fn bInertia(_: f32) geom.Basis {
    return inertia_basis;
}
fn bSpin(theta: f32) geom.Basis {
    var b = inertia_basis;
    geom.rotateBasis(&b, 0, 2, theta);
    geom.orthonormalize(&b);
    return b;
}

pub const presets = &[_]app_mod.PresetDef{
    .{ .name = "as deposited", .basis = bDeposited },
    .{ .name = "principal (inertia) axes", .basis = bInertia },
    .{ .name = "spin", .basis = bSpin, .animated = true },
};

// --- colors ------------------------------------------------------------------------------------

fn colorByElement(p: *const Point, _: f32) [3]f32 {
    return p.el.cpk();
}

fn chainRgb(k: usize) [3]f32 {
    const golden: f32 = 0.61803398875;
    const h = @mod(@as(f32, @floatFromInt(k)) * golden + 0.15, 1.0);
    const i: u32 = @intFromFloat(h * 6.0);
    const f = h * 6.0 - @as(f32, @floatFromInt(i));
    const q: f32 = 1.0 - 0.6 * f;
    const t: f32 = 0.4 + 0.6 * f;
    return switch (i % 6) {
        0 => .{ 1.0, t, 0.4 },
        1 => .{ q, 1.0, 0.4 },
        2 => .{ 0.4, 1.0, t },
        3 => .{ 0.4, q, 1.0 },
        4 => .{ t, 0.4, 1.0 },
        else => .{ 1.0, 0.4, q },
    };
}

fn colorByChain(p: *const Point, _: f32) [3]f32 {
    if (p.hetatm) return .{ 1.0, 0.75, 0.2 }; // ligands stand out from every chain
    return chainRgb(p.chain_idx);
}

/// The crystallographer's ramp: blue = well ordered, red = the model is guessing.
fn colorByBfactor(p: *const Point, _: f32) [3]f32 {
    const a = atoms[p.row];
    const t = std.math.clamp((a.bfactor - bfac_lo) / (bfac_hi - bfac_lo), 0, 1);
    return .{ 0.15 + 0.85 * t, 0.35 + 0.35 * (1 - t) * t * 2, 1.0 - 0.8 * t };
}

/// Amino-acid chemistry: what the residue DOES, which is what folds it.
fn colorByResidue(p: *const Point, _: f32) [3]f32 {
    const rn = atoms[p.row].res_name;
    const r = std.mem.trim(u8, &rn, " ");
    const hydrophobic = [_][]const u8{ "ALA", "VAL", "LEU", "ILE", "MET", "PHE", "TRP", "PRO", "GLY" };
    const polar = [_][]const u8{ "SER", "THR", "CYS", "TYR", "ASN", "GLN" };
    const acidic = [_][]const u8{ "ASP", "GLU" };
    const basic = [_][]const u8{ "LYS", "ARG", "HIS" };
    for (hydrophobic) |x| {
        if (std.mem.eql(u8, r, x)) return .{ 1.0, 0.82, 0.35 };
    }
    for (polar) |x| {
        if (std.mem.eql(u8, r, x)) return .{ 0.45, 0.95, 0.65 };
    }
    for (acidic) |x| {
        if (std.mem.eql(u8, r, x)) return .{ 1.0, 0.32, 0.30 };
    }
    for (basic) |x| {
        if (std.mem.eql(u8, r, x)) return .{ 0.35, 0.55, 1.0 };
    }
    return .{ 0.62, 0.62, 0.70 }; // water, ligands, nucleotides
}

var legend_elem = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 235, 235, 242 }, .label = "H" },
    .{ .rgb = .{ 89, 97, 107 }, .label = "C" },
    .{ .rgb = .{ 51, 102, 255 }, .label = "N" },
    .{ .rgb = .{ 255, 51, 46 }, .label = "O" },
    .{ .rgb = .{ 255, 217, 51 }, .label = "S" },
    .{ .rgb = .{ 255, 140, 26 }, .label = "P" },
    .{ .rgb = .{ 191, 140, 242 }, .label = "other" },
};
var legend_chain: [max_chains + 1]hud_mod.Hud.LegendIn = undefined;
var chain_labels: [max_chains][8]u8 = undefined;
var legend_bfac = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 38, 89, 255 }, .label = "low B (ordered)" },
    .{ .rgb = .{ 255, 89, 51 }, .label = "high B (mobile)" },
};
var legend_res = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 255, 209, 89 }, .label = "hydrophobic" },
    .{ .rgb = .{ 115, 242, 166 }, .label = "polar" },
    .{ .rgb = .{ 255, 82, 77 }, .label = "acidic" },
    .{ .rgb = .{ 89, 140, 255 }, .label = "basic" },
    .{ .rgb = .{ 158, 158, 179 }, .label = "other/ligand" },
};

var color_buf: [4]app_mod.ColorModeDef = undefined;
pub var color_modes: []const app_mod.ColorModeDef = &.{};
var filter_buf: [5 + max_chains]app_mod.FilterDef = undefined;
pub var filters: []const app_mod.FilterDef = &.{};
var relation_buf: [1]app_mod.RelationDef = undefined;
pub var relations: []const app_mod.RelationDef = &.{};

fn fAll(_: *const Point) bool {
    return true;
}
fn fNoH(p: *const Point) bool {
    return p.el != .h;
}
fn fBackbone(p: *const Point) bool {
    return p.backbone;
}
fn fLigands(p: *const Point) bool {
    return p.hetatm;
}
fn fPolymer(p: *const Point) bool {
    return !p.hetatm;
}
fn fChainFn(comptime k: u8) *const fn (p: *const Point) bool {
    return struct {
        fn f(p: *const Point) bool {
            return !p.hetatm and p.chain_idx == k;
        }
    }.f;
}

fn buildMenus() void {
    var nc: usize = 0;
    color_buf[nc] = .{ .name = "elements (CPK)", .color = colorByElement, .legend = &legend_elem };
    nc += 1;
    if (st.is_pdb) {
        for (0..n_chains) |k| {
            const rgb = chainRgb(k);
            const s = std.fmt.bufPrint(&chain_labels[k], "chain {c}", .{chains[k]}) catch "chain";
            legend_chain[k] = .{
                .rgb = .{ @intFromFloat(rgb[0] * 255), @intFromFloat(rgb[1] * 255), @intFromFloat(rgb[2] * 255) },
                .label = s,
            };
        }
        legend_chain[n_chains] = .{ .rgb = .{ 255, 191, 51 }, .label = "ligand/hetero" };
        color_buf[nc] = .{ .name = "chains", .color = colorByChain, .legend = legend_chain[0 .. n_chains + 1] };
        nc += 1;
        color_buf[nc] = .{ .name = "residue chemistry", .color = colorByResidue, .legend = &legend_res };
        nc += 1;
        color_buf[nc] = .{ .name = "B-factor", .color = colorByBfactor, .legend = &legend_bfac };
        nc += 1;
    }
    color_modes = color_buf[0..nc];

    var nf: usize = 0;
    filter_buf[nf] = .{ .name = "all atoms", .pass = fAll };
    nf += 1;
    filter_buf[nf] = .{ .name = "heavy atoms (no H)", .pass = fNoH };
    nf += 1;
    if (st.is_pdb) {
        filter_buf[nf] = .{ .name = "backbone", .pass = fBackbone };
        nf += 1;
        filter_buf[nf] = .{ .name = "ligands / hetero", .pass = fLigands };
        nf += 1;
        filter_buf[nf] = .{ .name = "polymer only", .pass = fPolymer };
        nf += 1;
        inline for (0..max_chains) |k| {
            if (k < n_chains) {
                filter_buf[nf] = .{ .name = chain_labels[k][0..7], .pass = fChainFn(@intCast(k)) };
                nf += 1;
            }
        }
    }
    filters = filter_buf[0..nf];

    relation_buf[0] = .{ .name = "bonded neighbor", .partner = bondedPartner };
    relations = relation_buf[0..1];
}

/// The relation the framework walks: the first bonded neighbor (so the orbit
/// flare runs along the molecule, not across space).
fn bondedPartner(_: []const Point, i: u16) u16 {
    for (bonds) |b| {
        if (b[0] == i) return b[1];
        if (b[1] == i) return b[0];
    }
    return i;
}

// --- the ruler (M) -------------------------------------------------------------------------------

fn distanceAng(i: usize, j: usize) f32 {
    var s: f32 = 0;
    for (0..3) |k| {
        const t = atoms[i].pos[k] - atoms[j].pos[k];
        s += t * t;
    }
    return @sqrt(s);
}

fn actMark(a: *App) void {
    if (a.selected < 0) {
        mark = -1;
    } else if (mark == a.selected) {
        mark = -1; // press M on the mark again to drop it
    } else {
        mark = a.selected;
    }
    a.info_dirty = true;
    a.status_dirty = true;
}

pub const actions = &[_]app_mod.ActionDef{
    .{ .key = 50, .help = "M: mark this atom (then select another to measure the distance)", .run = actMark },
};

pub fn status(a: *App, buf: []u8) []const u8 {
    _ = a;
    if (mark < 0) return "";
    const i: usize = @intCast(mark);
    var nb: [8]u8 = undefined;
    return std.fmt.bufPrint(buf, "mark: {s}{d}", .{
        atomName(i, &nb),
        atoms[i].res_seq,
    }) catch "mark";
}

// --- readouts --------------------------------------------------------------------------------------

fn atomName(i: usize, buf: []u8) []const u8 {
    const nm = std.mem.trim(u8, &atoms[i].atom_name, " ");
    if (nm.len > 0) return nm;
    return std.fmt.bufPrint(buf, "{s}", .{atoms[i].el.symbol()}) catch "atom";
}

fn residueOf(i: usize, buf: []u8) []const u8 {
    const rn = std.mem.trim(u8, &atoms[i].res_name, " ");
    if (rn.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}{d}{s}{c}", .{
        rn,
        atoms[i].res_seq,
        if (atoms[i].chain != ' ') " chain " else "",
        if (atoms[i].chain != ' ') atoms[i].chain else ' ',
    }) catch rn;
}

pub fn descriptor(a: *App, i: usize) desc.Object {
    const p = &a.points[i];
    var d = desc.Object{
        .orbit_rgb = p.el.cpk(),
        .radius = switch (p.el) {
            .h => 0.55,
            .c, .n, .o => 0.9,
            else => 1.15,
        },
    };
    // The mark breathes: you always know where your ruler's other end is.
    if (mark >= 0 and i == @as(usize, @intCast(mark))) {
        d.pulse = .{ .kind = .breathe, .rate = 2.2, .amp = 0.5 };
        d.glow = 2.0;
    }
    return d;
}

pub fn describe(a: *App, i: usize, buf: []u8) []const u8 {
    var nb: [8]u8 = undefined;
    var rb: [32]u8 = undefined;
    const res = residueOf(i, &rb);
    if (mark >= 0 and mark != a.selected) {
        const m: usize = @intCast(mark);
        var mb: [8]u8 = undefined;
        return std.fmt.bufPrint(buf, "{s} ({s}) {s}{s} · distance to {s}: {d:.2} Å", .{
            atoms[i].el.symbol(),
            atomName(i, &nb),
            res,
            if (res.len > 0) "" else "",
            atomName(m, &mb),
            distanceAng(i, m),
        }) catch "atom";
    }
    return std.fmt.bufPrint(buf, "{s} ({s}) {s} · B = {d:.1} · M marks it for a distance", .{
        atoms[i].el.symbol(),
        atomName(i, &nb),
        res,
        atoms[i].bfactor,
    }) catch "atom";
}

pub fn story(a: *App) void {
    const hud = a.hud;
    if (a.selected < 0) {
        var buf: [720]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{d} atoms, {d} bonds{s}. Bonds the file declared (CONECT) are drawn as given; the rest are inferred from covalent radii — r₁ + r₂ + 0.4 Å, the tolerance every viewer uses.
            \\C: elements (CPK), chains, residue chemistry, B-factor. F filters heavy atoms, the backbone, the ligands, one chain at a time.
            \\Click an atom for its row. Press M to mark it, then click another: the HUD reads out the distance in ångström — hydrogen bonds, coordination spheres, clashes.
        , .{
            atoms.len,
            bonds.len,
            if (st.is_pdb) " from a PDB" else " from an XYZ",
        }) catch "";
        var tbuf: [96]u8 = undefined;
        const t = if (st.title.len > 0)
            std.fmt.bufPrint(&tbuf, "{s}", .{st.title[0..@min(st.title.len, 90)]}) catch "Structure"
        else
            "Structure";
        hud.setPanel(t, body, app_mod.cli.file);
        return;
    }
    const i: usize = @intCast(a.selected);
    var nb: [8]u8 = undefined;
    var rb: [32]u8 = undefined;
    var tb: [96]u8 = undefined;
    const t = std.fmt.bufPrint(&tb, "{s} {s} {s}", .{
        atoms[i].el.symbol(),
        atomName(i, &nb),
        residueOf(i, &rb),
    }) catch "atom";

    var bb: [720]u8 = undefined;
    var w: std.Io.Writer = .fixed(&bb);
    w.print("element: {s} · B-factor: {d:.1}\nposition: ({d:.2}, {d:.2}, {d:.2}) Å\n\nbonded to:\n", .{
        atoms[i].el.symbol(),
        atoms[i].bfactor,
        atoms[i].pos[0],
        atoms[i].pos[1],
        atoms[i].pos[2],
    }) catch {};
    for (bonds) |b| {
        const j: ?usize = if (b[0] == i) b[1] else if (b[1] == i) b[0] else null;
        if (j) |k| {
            var nb2: [8]u8 = undefined;
            w.print("  {s} ({s}) — {d:.2} Å\n", .{
                atoms[k].el.symbol(),
                atomName(k, &nb2),
                distanceAng(i, k),
            }) catch break;
        }
    }
    if (mark >= 0 and mark != a.selected) {
        const m: usize = @intCast(mark);
        var mb: [8]u8 = undefined;
        var mrb: [32]u8 = undefined;
        w.print("\nmark: {s} {s}\ndistance: {d:.2} Å", .{
            atomName(m, &mb),
            residueOf(m, &mrb),
            distanceAng(i, m),
        }) catch {};
    }
    hud.setPanel(t, w.buffered(), "");
}

pub const InspectText = struct { title_len: usize, body_len: usize };

pub fn inspect(a: *App, i: usize, tbuf: *[96]u8, bbuf: *[512]u8) InspectText {
    var nb: [8]u8 = undefined;
    var rb: [32]u8 = undefined;
    const t = std.fmt.bufPrint(tbuf, "{s} {s} — {s}", .{
        atoms[i].el.symbol(),
        atomName(i, &nb),
        residueOf(i, &rb),
    }) catch "";
    var w: std.Io.Writer = .fixed(bbuf);
    var n_bonds: usize = 0;
    for (bonds) |b| {
        if (b[0] == i or b[1] == i) n_bonds += 1;
    }
    w.print("{s} — {d} bond{s}, B-factor {d:.1}.\n\n", .{
        atoms[i].el.symbol(),
        n_bonds,
        if (n_bonds == 1) "" else "s",
        atoms[i].bfactor,
    }) catch {};
    if (atoms[i].hetatm)
        w.print("A HETATM: a ligand, an ion or a water — not part of the polymer.\n", .{}) catch {}
    else if (atoms[i].backbone)
        w.print("A backbone atom: it carries the fold, not the chemistry.\n", .{}) catch {};
    if (mark >= 0 and mark != @as(i32, @intCast(i))) {
        var mb: [8]u8 = undefined;
        w.print("\nDistance to the mark ({s}): {d:.2} Å.", .{
            atomName(@intCast(mark), &mb),
            distanceAng(i, @intCast(mark)),
        }) catch {};
    } else {
        w.print("\nPress M to mark it, then click another atom to measure.", .{}) catch {};
    }
    _ = a;
    return .{ .title_len = t.len, .body_len = w.buffered().len };
}

/// The panel figure: B-factor along the sequence — the plot every structure paper
/// prints next to the ribbon.
pub fn figure(a: *App, fig_id: []const u8, dots: []hud_mod.FigDot) usize {
    if (!std.mem.eql(u8, fig_id, "bfactor")) return 0;
    var n_dots: usize = 0;
    const step = @max(atoms.len / dots.len, 1);
    var i: usize = 0;
    while (i < atoms.len and n_dots < dots.len) : (i += step) {
        const t = std.math.clamp((atoms[i].bfactor - bfac_lo) / (bfac_hi - bfac_lo), 0, 1);
        const x = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(atoms.len)) * 2.0 - 1.0;
        const rgb = colorByBfactor(&a.points[i], 0);
        dots[n_dots] = .{
            .x = x,
            .y = t * 1.6 - 0.8,
            .rgb = .{ @intFromFloat(rgb[0] * 255), @intFromFloat(rgb[1] * 255), @intFromFloat(rgb[2] * 255) },
        };
        n_dots += 1;
    }
    return n_dots;
}

pub fn exportCsv(a: *App) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a.gpa);
    try out.appendSlice(a.gpa, "index,element,atom,residue,res_seq,chain,hetatm,x,y,z,bfactor,bonds\n");
    var buf: [256]u8 = undefined;
    for (atoms, 0..) |at, i| {
        var nb: [8]u8 = undefined;
        var deg: usize = 0;
        for (bonds) |b| {
            if (b[0] == i or b[1] == i) deg += 1;
        }
        const line = try std.fmt.bufPrint(&buf, "{d},{s},{s},{s},{d},{c},{},{d:.3},{d:.3},{d:.3},{d:.2},{d}\n", .{
            i,
            at.el.symbol(),
            atomName(i, &nb),
            std.mem.trim(u8, &at.res_name, " "),
            at.res_seq,
            if (at.chain == ' ') '-' else at.chain,
            at.hetatm,
            at.pos[0],
            at.pos[1],
            at.pos[2],
            at.bfactor,
            deg,
        });
        try out.appendSlice(a.gpa, line);
    }
    try std.Io.Dir.cwd().writeFile(a.io, .{ .sub_path = "structure_atoms.csv", .data = out.items });
    std.debug.print("exported structure_atoms.csv ({d} atoms)\n", .{atoms.len});
}

pub const deck_path = "deck.zon";
pub const deck_default: [:0]const u8 = @embedFile("deck.zon");
