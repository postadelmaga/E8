//! The Lisi E8 domain — the reference implementation of the presenter
//! framework's domain interface. Everything E8/Lisi-specific lives here (and
//! in e8.zig / deck.zon): the framework in src/ knows nothing about roots,
//! triality or arXiv numbers.

const std = @import("std");
const e8 = @import("e8.zig");
const geom = @import("../../geom.zig");
const hud_mod = @import("../../hud.zig");
const desc = @import("../../descriptor.zig");
const app_mod = @import("../../app.zig");
const App = app_mod.App;

pub const name = "Lisi E8";
pub const title = "E8 explorer — Lisi atlas (1..6 presets, P journey, click a root)";
pub const app_id = "dev.e8.explorer";

pub const dim = 8;
pub const n = e8.n_roots;
pub const Point = e8.Root;
/// Max |v|² — every E8 root has norm² 2 (hidden-depth normalization).
pub const radius2: f32 = 2.0;

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

pub fn generate() [n]Point {
    return e8.generate();
}

pub fn buildEdges(gpa: std.mem.Allocator, points: []const Point) ![]const [2]u16 {
    return e8.buildEdges(gpa, points);
}

// --- projections ---------------------------------------------------------------------

fn bCoxeter(_: f32) geom.Basis {
    return e8.coxeterBasis();
}
fn bPhysics(_: f32) geom.Basis {
    return e8.physicsBasis();
}
fn bLattice(_: f32) geom.Basis {
    return e8.coordBasis();
}
fn bG2(_: f32) geom.Basis {
    return e8.g2Basis();
}
fn bF4(_: f32) geom.Basis {
    return e8.f4Basis();
}
fn bRotation(theta: f32) geom.Basis {
    return e8.lisiRotationBasis(theta);
}

pub const presets = &[_]app_mod.PresetDef{
    .{ .name = "Coxeter plane", .basis = bCoxeter },
    .{ .name = "physics axes", .basis = bPhysics },
    .{ .name = "lattice (wT,wS spin-boost)", .basis = bLattice },
    .{ .name = "G2 plane (g3,g8)", .basis = bG2 },
    .{ .name = "F4 graviweak plane", .basis = bF4 },
    .{ .name = "F4<->G2 rotation", .basis = bRotation, .animated = true },
};

// --- color modes ---------------------------------------------------------------------

fn colorOf(comptime mode: e8.ColorMode) *const fn (p: *const Point, hidden_t: f32) [3]f32 {
    return struct {
        fn f(p: *const Point, hidden_t: f32) [3]f32 {
            return e8.rootRgb(p, mode, hidden_t);
        }
    }.f;
}

const LegendIn = hud_mod.Hud.LegendIn;
const legend_physics = [_]LegendIn{
    .{ .rgb = .{ 89, 191, 255 }, .label = "gravity" },
    .{ .rgb = .{ 255, 235, 77 }, .label = "electroweak" },
    .{ .rgb = .{ 158, 140, 217 }, .label = "frame-Higgs" },
    .{ .rgb = .{ 255, 140, 26 }, .label = "gluon" },
    .{ .rgb = .{ 191, 140, 115 }, .label = "xΦ boson" },
    .{ .rgb = .{ 140, 255, 140 }, .label = "lepton" },
    .{ .rgb = .{ 255, 64, 56 }, .label = "quark r" },
    .{ .rgb = .{ 64, 255, 77 }, .label = "g" },
    .{ .rgb = .{ 77, 115, 255 }, .label = "b" },
};
const legend_gen = [_]LegendIn{
    .{ .rgb = .{ 102, 118, 143 }, .label = "bosons (48)" },
    .{ .rgb = .{ 77, 255, 115 }, .label = "gen I (64)" },
    .{ .rgb = .{ 255, 184, 46 }, .label = "gen II (64)" },
    .{ .rgb = .{ 217, 107, 255 }, .label = "gen III (64)" },
};
const legend_so16 = [_]LegendIn{
    .{ .rgb = .{ 102, 179, 255 }, .label = "120 adjoint (so(16))" },
    .{ .rgb = .{ 255, 153, 89 }, .label = "128 spinor (16+)" },
};
const legend_hidden = [_]LegendIn{
    .{ .rgb = .{ 64, 128, 255 }, .label = "in the view plane" },
    .{ .rgb = .{ 255, 100, 64 }, .label = "hidden dimensions" },
};

pub const color_modes = &[_]app_mod.ColorModeDef{
    .{ .name = "physics classes", .color = colorOf(.physics), .legend = &legend_physics },
    .{ .name = "generations (triality)", .color = colorOf(.generation), .legend = &legend_gen },
    .{ .name = "so(16): 120+128", .color = colorOf(.so16), .legend = &legend_so16 },
    .{ .name = "hidden depth", .color = colorOf(.hidden), .legend = &legend_hidden },
};

// --- filters ----------------------------------------------------------------------------

fn fAll(_: *const Point) bool {
    return true;
}
fn fBosons(p: *const Point) bool {
    return p.gen == 0;
}
fn fFermions(p: *const Point) bool {
    return p.gen != 0;
}
fn fGen1(p: *const Point) bool {
    return p.gen == 1;
}
fn fGen2(p: *const Point) bool {
    return p.gen == 2;
}
fn fGen3(p: *const Point) bool {
    return p.gen == 3;
}
fn fLeptons(p: *const Point) bool {
    return p.class == .lepton;
}
fn fQuarks(p: *const Point) bool {
    return p.class == .quark;
}
fn fGraviweak(p: *const Point) bool {
    return p.class == .gravity or p.class == .electroweak or p.class == .frame_higgs;
}
fn fColor(p: *const Point) bool {
    return p.class == .gluon or p.class == .color_x;
}

pub const filters = &[_]app_mod.FilterDef{
    .{ .name = "all 240", .pass = fAll },
    .{ .name = "bosons (48)", .pass = fBosons },
    .{ .name = "fermions (192)", .pass = fFermions },
    .{ .name = "gen I (64)", .pass = fGen1 },
    .{ .name = "gen II (64)", .pass = fGen2 },
    .{ .name = "gen III (64)", .pass = fGen3 },
    .{ .name = "leptons (48)", .pass = fLeptons },
    .{ .name = "quarks (144)", .pass = fQuarks },
    .{ .name = "graviweak d4 (24)", .pass = fGraviweak },
    .{ .name = "color d4 (24)", .pass = fColor },
};

// --- relations & actions -----------------------------------------------------------------

fn trialityPartner(points: []const Point, i: u16) u16 {
    const t = e8.trialityMatrix();
    const tv = e8.trialityApply(&t, points[i].v);
    for (points, 0..) |*s, j| {
        var d: f32 = 0;
        for (s.v, tv) |x, y| d += (x - y) * (x - y);
        if (d < 1e-4) return @intCast(j);
    }
    return i;
}

pub const relations = &[_]app_mod.RelationDef{
    .{ .name = "triality", .partner = trialityPartner },
};

fn actTriality(a: *App) void {
    if (a.selected >= 0 and a.rel.len > 0) {
        a.selected = a.rel[0][@intCast(a.selected)];
        a.info_dirty = true;
    }
}

pub const actions = &[_]app_mod.ActionDef{
    .{ .key = 34, .help = "G: ride the triality orbit", .run = actTriality },
};

// --- descriptors (#6: declarative object definition) --------------------------------------

pub fn descriptor(a: *App, i: usize) desc.Object {
    const p = &a.points[i];
    var d = desc.Object{
        .orbit_rgb = e8.rootRgb(p, .generation, 0),
        .orbit_phase = @as(f32, @floatFromInt(p.gen)) * 2.0 * std.math.pi / 3.0,
    };
    if (p.class == .color_x) {
        // Lisi's new bosons pulse as a wave phased by their w charge.
        d.pulse = .{ .kind = .wave, .rate = 2.2, .amp = 0.55, .phase = p.w * 2.0 * std.math.pi / 3.0 };
    } else if (a.rel.len > 0 and a.rel[0][i] == i) {
        // The 12 triality-fixed roots (W±, four eφ, the gluons) breathe.
        d.pulse = .{ .kind = .breathe, .rate = 1.1, .amp = 0.35 };
    }
    return d;
}

// --- text: describe / story / inspect ------------------------------------------------------

fn fmtHalf(buf: []u8, v: f32) []const u8 {
    if (v == 0) return std.fmt.bufPrint(buf, "0", .{}) catch "0";
    if (v == 0.5) return std.fmt.bufPrint(buf, "½", .{}) catch "";
    if (v == -0.5) return std.fmt.bufPrint(buf, "-½", .{}) catch "";
    return std.fmt.bufPrint(buf, "{d:.0}", .{v}) catch "";
}

pub fn describe(a: *App, i: usize, buf: []u8) []const u8 {
    const r = &a.points[i];
    var cbuf: [9][8]u8 = undefined;
    var coords: [8][]const u8 = undefined;
    for (0..8) |k| coords[k] = fmtHalf(&cbuf[k], r.v[k]);
    const partner: usize = if (a.rel.len > 0) a.rel[0][i] else i;
    return std.fmt.bufPrint(buf, "root #{d}: {s} · {s} [{s}] · ({s},{s},{s},{s},{s},{s},{s},{s}) · λ3={d:.2} λ8={d:.2} w={s} B−L={d:.2} · {s} · G→#{d}", .{
        i,
        e8.genName(r.gen),
        r.class.name(),
        r.color.name(),
        coords[0], coords[1], coords[2], coords[3],
        coords[4], coords[5], coords[6], coords[7],
        r.t3,
        r.t8,
        fmtHalf(&cbuf[8], r.w),
        r.bl,
        if (r.integer) "so(16) adjoint" else "16⁺ spinor",
        partner,
    }) catch "";
}

pub fn story(a: *App) void {
    const hud = a.hud;
    if (a.selected < 0) {
        hud.setPanel(
            "E8 — 240 roots as elementary particles",
            "Coordinates 1-4 host the graviweak so(7,1): gravity ω on 1-2, electroweak W/B1 on 3-4, and the 16 frame-Higgs eφ roots across the two pairs. Coordinate 5 is Lisi's w u(1); su(3) color acts on 6-8.\nThe 112 integer roots are the so(16) adjoint, the 128 spinors its chiral 16⁺. The 192 fermions form three 64-blocks — generations I (8s+), II (8s−), III (8v) — related by the triality rotation T.\nClick a root for its story. G hops its triality orbit, P plays the paper journey.",
            "A.G. Lisi, \"An Exceptionally Simple Theory of Everything\", arXiv:0711.0770 (Table 9). — \"C, P, T, and Triality\", arXiv:2407.02497.",
        );
        return;
    }
    const r = &a.points[@intCast(a.selected)];
    switch (r.class) {
        .gravity => hud.setPanel(
            "ω — gravitational spin connection",
            "One of the 4 roots of D2G ⊂ so(7,1) on coordinates 1-2: the so(3,1)-valued spin connection of general relativity, written as a gauge field alongside the electroweak sector. Its Cartan axes (½ωL³, ½ωR³) are two of the four graviweak directions.\nUnder the triality rotation the ω roots mix with B1 and the frame-Higgs — in this theory gravity is not a spectator to the generation structure.",
            "0711.0770 §2.2 (graviweak F4) & Table 9. Lisi, Smolin, Speziale, arXiv:1004.4866 (graviweak unification).",
        ),
        .electroweak => hud.setPanel(
            "W/B1 — electroweak bosons",
            "Roots of su(2)L × su(2)R on coordinates 3-4. W± sit on the W³ axis that Lisi's triality matrix deliberately leaves invariant — they are two of the 12 triality-fixed roots — while B1 cycles with the gravitational ω under T.\nB1 joins w and B2 in the Pati-Salam mix that produces weak hypercharge.",
            "0711.0770 §2.2, §2.4.2 (T chosen to fix W³) & Table 9.",
        ),
        .frame_higgs => hud.setPanel(
            "eφ — frame-Higgs",
            "16 roots spanning 4×(2+2̄) inside so(7,1): the gravitational frame e (vierbein) multiplied by the electroweak Higgs φ. One simple bivector carries both — this is how E8 fits gravity and the Higgs into a single connection. Only 4+4 of the 16 algebraic elements are physical degrees of freedom, a restriction Lisi flags as not yet understood.\nFour eφ roots are triality-fixed; the rest mix with ω and B1 under T.",
            "0711.0770 §2.2 & §2.4.1. Lisi, Smolin, Speziale, arXiv:1004.4866.",
        ),
        .gluon => hud.setPanel(
            "g — gluon",
            "The su(3) adjoint root hexagon on coordinates 6-8, read off the (λ3, λ8) weights. Gluons carry no w charge and all six are triality-fixed: the strong force is generation-blind, which is why the hexagon never moves in the triality-linked figures.\nThe G2 preset is Lisi's picture: gluons on the hexagon, quark and antiquark triangles around it, leptons at the center.",
            "0711.0770 §2.1 (G2 strong charges) & Table 2.",
        ),
        .color_x => hud.setPanel(
            "xΦ — new colored boson (Lisi's prediction)",
            "18 roots in 3×(3+3̄): a w-charged x joined to a colored Higgs Φ, in exact analogy with how eφ joins frame and Higgs. It couples leptons to quarks, so it predicts proton decay — the classic grand-unification signature — and a presumably large mass keeps it unobserved. Not in the Standard Model.\nThe w charge (−1, +1, 0) splits it into x1Φ, x2Φ, x3Φ, one per fermion generation — watch them pulse in sequence.",
            "0711.0770 §2.4.1 (new particles) & Table 9.",
        ),
        .lepton, .quark => {
            var tbuf: [96]u8 = undefined;
            var bbuf: [720]u8 = undefined;
            const kind: []const u8 = if (r.class == .quark) "quark" else "lepton";
            const t = std.fmt.bufPrint(&tbuf, "{s} [{s}] — generation {s}", .{
                kind,
                r.color.name(),
                switch (r.gen) {
                    1 => "I",
                    2 => "II",
                    else => "III",
                },
            }) catch kind;
            const block: []const u8 = switch (r.gen) {
                1 => "Generation I is the (8s+,8s+') spinor block — νe, e, u, d — the 64 spinor roots with an even number of minus signs on the graviweak coordinates.",
                2 => "Generation II is the (8s−,8s−') spinor block — νμ, μ, c, s — the 64 spinor roots with an odd number of minus signs on the graviweak coordinates.",
                else => "Generation III is the (8v,8v') block — ντ, τ, t, b — 64 INTEGER roots living inside the so(16) adjoint rather than the spinor: Lisi's boldest identification.",
            };
            const typ: []const u8 = if (r.class == .quark)
                "Its su(3) weight is a fundamental 3/3̄ state — a quark slot, tinted by its color."
            else
                "It is an su(3) color singlet — a lepton slot.";
            const body = std.fmt.bufPrint(&bbuf, "{s}\n{s}\nGenerations II and III carry correct quantum numbers only through the triality rotation T (press G to walk the orbit) — Lisi's own caveat, and the heart of the Distler-Garibaldi objection. Across the three generations, the 24 states of this fermion type form one of the 8 disjoint 24-cells on which the CPTt Group acts.", .{ block, typ }) catch block;
            hud.setPanel(
                t,
                body,
                "0711.0770 Table 9 & §2.4.2 (triality). 2407.02497 §6-7 (CPTt Group, 24-cells). Distler & Garibaldi, arXiv:0905.2658 (critique).",
            );
        },
    }
}

pub const InspectText = struct { title_len: usize, body_len: usize };

pub fn inspect(a: *App, i: usize, tbuf: *[96]u8, bbuf: *[512]u8) InspectText {
    const r = &a.points[i];
    const t = std.fmt.bufPrint(tbuf, "root #{d} — {s} · {s} [{s}]", .{
        i, e8.genName(r.gen), r.class.name(), r.color.name(),
    }) catch "";
    const p1: usize = if (a.rel.len > 0) a.rel[0][i] else i;
    const p2: usize = if (a.rel.len > 0) a.rel[0][p1] else i;
    const blurb: []const u8 = switch (r.class) {
        .gravity => "Gravitational so(3,1) spin connection — one gauge field among the others in the graviweak so(7,1).",
        .electroweak => "su(2)L × su(2)R electroweak root; W± are triality-fixed, B1 cycles with gravity under T.",
        .frame_higgs => "Frame ⊗ Higgs bivector eφ ∈ 4×(2+2̄): gravity and the Higgs in one connection.",
        .gluon => "su(3) adjoint root — triality-fixed: the strong force is generation-blind.",
        .color_x => "Lisi's new-particle prediction xΦ ∈ 3×(3+3̄): couples leptons to quarks → proton decay.",
        .lepton => "Color-singlet fermion slot; its 24 CPTt states across the generations form one 24-cell.",
        .quark => "Fundamental 3/3̄ fermion slot; its 24 CPTt states across the generations form one 24-cell.",
    };
    const b = std.fmt.bufPrint(bbuf, "{s}\n\nOne of the 240 roots of E8, a {s}.\nTriality orbit #{d} → #{d} → #{d} — lit in the scene; G rides it in the main window.\n\nrefs: 0711.0770 Table 9 · 2407.02497", .{
        blurb,
        if (r.integer) "so(16) adjoint direction" else "16⁺ spinor weight",
        i, p1, p2,
    }) catch "";
    return .{ .title_len = t.len, .body_len = b.len };
}

// --- inline figures -------------------------------------------------------------------------

pub fn figure(a: *App, fig_id: []const u8, dots: []hud_mod.FigDot) usize {
    var n_dots: usize = 0;
    for (a.points) |*r| {
        var x: f32 = 0;
        var y: f32 = 0;
        var rgb: [3]f32 = undefined;
        if (std.mem.eql(u8, fig_id, "g2")) {
            x = r.t3;
            y = r.t8 * @sqrt(3.0) * 0.85;
            rgb = e8.rootRgb(r, .physics, 0);
        } else if (std.mem.eql(u8, fig_id, "f4")) {
            const p = e8.f4Petrie();
            x = e8.dot8(p[0], .{ r.v[0], r.v[1], r.v[2], r.v[3], 0, 0, 0, 0 }) / 1.5;
            y = e8.dot8(p[1], .{ r.v[0], r.v[1], r.v[2], r.v[3], 0, 0, 0, 0 }) / 1.5;
            rgb = e8.rootRgb(r, .generation, 0);
        } else if (std.mem.eql(u8, fig_id, "spin13")) {
            x = r.v[0] * 0.9;
            y = r.v[1] * 0.9;
            rgb = e8.rootRgb(r, .physics, 0);
        } else return 0;
        var dup = false;
        for (dots[0..n_dots]) |d| {
            if (@abs(d.x - x) < 0.03 and @abs(d.y - y) < 0.03) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        dots[n_dots] = .{
            .x = std.math.clamp(x, -1, 1),
            .y = std.math.clamp(y, -1, 1),
            .rgb = .{
                @intFromFloat(std.math.clamp(rgb[0], 0, 1) * 255),
                @intFromFloat(std.math.clamp(rgb[1], 0, 1) * 255),
                @intFromFloat(std.math.clamp(rgb[2], 0, 1) * 255),
            },
        };
        n_dots += 1;
        if (n_dots == dots.len) break;
    }
    return n_dots;
}

// --- export ----------------------------------------------------------------------------------

pub fn exportCsv(a: *App) !void {
    const csv = try e8.buildCsv(a.gpa, a.points, &a.basis);
    defer a.gpa.free(csv);
    try std.Io.Dir.cwd().writeFile(a.io, .{ .sub_path = "e8_roots.csv", .data = csv });
    std.debug.print("exported e8_roots.csv ({d} roots, current projection)\n", .{a.count()});
}
