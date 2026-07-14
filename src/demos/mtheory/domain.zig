//! The M-theory domain — E10, and what Lisi's E8 becomes inside it.
//!
//! Fourth consumer of the presenter framework, and the first one that reuses
//! another: its level-0 points ARE the Lisi demo's 240 roots, imported from
//! `demos/lisi/e8.zig` with their particle assignments intact. Everything above
//! level 0 is new — the two directions E10 adds to E8, and the infinite tower of
//! excitations they open up.
//!
//! The story the demo tells, in four moves (the four things the deck walks you
//! through, and the four keys that matter):
//!
//!   1. THE METRIC CHANGES.  E8 is Euclidean and compact: 240 roots, all the same
//!      length, and that is the whole group. E10's lattice is LORENTZIAN — it has
//!      a light cone — and it is infinite. Color mode "Lorentzian vs Euclidean"
//!      shows the difference directly: out along a tower the roots get visibly
//!      longer on screen while the algebra insists they all still have norm 2.
//!   2. THE ENERGY LEVEL (− / +).  You cannot load E10 into memory; you generate
//!      it by level. Level 0 is Lisi's 240 particles. Raise the level and rings
//!      sprout outward along the two new directions.
//!   3. THE PARTICLES BECOME STRINGS.  A point of the string tower is the SAME
//!      particle, n rungs up — an excitation. They vibrate here in proportion to
//!      their level, because in string theory that is where the mass comes from.
//!   4. THE BIG BANG (B).  Damour–Nicolai: run time back to t = 0 and the ten
//!      scale factors of eleven-dimensional supergravity bounce chaotically off
//!      the walls of E10's Weyl chamber. The projection is sheared by the live
//!      Kasner exponents, ordinary space fades out, and what is left is E10.
//!
//!   A. Lisi, arXiv:0711.0770.  Damour–Henneaux–Nicolai, CQG 20 (2003) R145.
//!   Damour–Nicolai, arXiv:0705.2643.  Damour–Henneaux–Nicolai, PRL 89, 221601
//!   ("E10 and a small tension expansion of M theory").

const std = @import("std");
const e8 = @import("../lisi/e8.zig");
const e10 = @import("e10.zig");
const geom = @import("../../geom.zig");
const hud_mod = @import("../../hud.zig");
const desc = @import("../../descriptor.zig");
const keys = @import("../../keys.zig");
const app_mod = @import("../../app.zig");
const filters_p = @import("../../plugins/filters.zig");
const cinema = @import("cinema.zig");
const calabi = @import("calabi.zig");
const het = @import("heterotic.zig");
const App = app_mod.App;

pub const name = "M-theory E10";
pub const title = "E10 — M-theory beyond Lisi's E8 (−/+ energy level, B big bang, P journey)";
pub const app_id = "dev.presenter.mtheory";

pub const dim = e10.dim;
pub const Point = e10.Root;
/// Max |v|² on screen. A level-3 root is one 2 and seven 1s: 4 + 7 = 11.
pub const radius2: f32 = 11.0;

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
    @import("../../plugins/guide.zig"),
    @import("../../plugins/inspector.zig"),
    @import("../../plugins/slides.zig"),
    @import("../../plugins/editor.zig"),
    @import("../../plugins/panel.zig"),
    @import("../../plugins/exporter.zig"),
    @import("../../plugins/atmosphere.zig"),
    // Last, so the Big Bang overrides every other visual while it runs.
    @import("cinema.zig"),
};

/// The framework's dynamic point source: E10 has no fixed size, and the level the
/// enumeration runs to decides how many roots there are.
pub fn load(gpa: std.mem.Allocator, io: std.Io) ![]Point {
    _ = io;
    return e10.generateAlloc(gpa);
}

/// Two kinds of line, and both mean something.
///
///   • THE ARROWS OF THE ALGEBRA: two roots joined when they differ by a SIMPLE
///     root. Those are the edges of the Dynkin structure itself. The nine
///     symmetry walls move you within a level; the tenth — the 3-form — is the
///     only one that moves you BETWEEN levels, which is why the fields of
///     M-theory stack the way they do.
///   • LISI'S FIGURE: the E8 sub-system's own 60° edges, ⟨α,β⟩ = 1 — the same
///     6720 lines the E8 demo draws, still there, now embedded in something larger.
pub fn buildEdges(gpa: std.mem.Allocator, points: []const Point) ![]const [2]u16 {
    var out: std.ArrayList([2]u16) = .empty;
    errdefer out.deinit(gpa);

    // Lisi's figure first: the 60° pairs live entirely inside the 240-root
    // E8 sub-system, so only those pairs are worth the inner product.
    for (points, 0..) |a, i| {
        if (!a.in_e8) continue;
        for (points[i + 1 ..], i + 1..) |b, j| {
            if (b.in_e8 and e10.ip(a.w, b.w) == 1)
                try out.append(gpa, .{ @intCast(i), @intCast(j) });
        }
    }

    // The arrows of the algebra: two roots differ by a simple root exactly when
    // w + α is itself a root, so index the (exact, integer) coordinates once and
    // each wall is a lookup instead of a sweep over every pair. A pair is found
    // from one end only — α and −α are never both simple.
    var by_w: std.AutoHashMap([10]i32, u16) = .init(gpa);
    defer by_w.deinit();
    try by_w.ensureTotalCapacity(@intCast(points.len));
    for (points, 0..) |p, i| by_w.putAssumeCapacity(p.w, @intCast(i));
    for (points, 0..) |a, i| {
        for (e10.simple) |alpha| {
            var t: [10]i32 = undefined;
            for (&t, a.w, alpha) |*x, p, q| x.* = p + q;
            const j = by_w.get(t) orelse continue;
            // Already drawn as one of Lisi's 60° edges above.
            if (a.in_e8 and points[j].in_e8 and e10.ip(a.w, points[j].w) == 1) continue;
            const lo = @min(i, j);
            const hi = @max(i, j);
            try out.append(gpa, .{ @intCast(lo), @intCast(hi) });
        }
    }
    return out.toOwnedSlice(gpa);
}

// --- projections -----------------------------------------------------------------------

/// Lisi's own Coxeter plane, transported into E10's coordinates (see e10.zig).
/// The E8 sub-system draws his exact 30-fold figure; every other root of E10 lands
/// where the same linear map sends it.
fn bE8(_: f32) geom.Basis {
    return .{ e10.coxeterRow(0), e10.coxeterRow(1), e10.coxeterRow(2) };
}

/// THE picture. Horizontal: Lisi's Coxeter plane. Vertical: the LEVEL — so the
/// fields of eleven-dimensional supergravity stack up as layers you can count.
/// The metric (gravity) is the middle plane; one step out on either side is the
/// 3-form the M2-brane carries; two steps, the 6-form of the M5-brane; three, the
/// dual graviton. This is M-theory's field content, drawn.
fn bLevels(_: f32) geom.Basis {
    return .{ e10.coxeterRow(0), e10.coxeterRow(1), e10.levelRow(1.25) };
}

/// The light cone. The metric here is Lorentzian, and rotating a timelike
/// direction into view is what that means — a motion with no counterpart in E8,
/// where every direction is alike.
fn bLightcone(theta: f32) geom.Basis {
    var b: geom.Basis = .{ e10.coxeterRow(0), e10.coxeterRow(1), e10.timeRow(0.8) };
    geom.rotateBasis(&b, 0, 9, theta);
    return b;
}

/// A slow sweep of the level axis against a hidden β direction: the layers shear
/// through each other and you can see how they interlock.
fn bSweep(theta: f32) geom.Basis {
    var b = bLevels(0);
    geom.rotateBasis(&b, 2, 7, theta * 0.6);
    geom.rotateBasis(&b, 4, 9, theta * 0.3);
    return b;
}

pub const presets = &[_]app_mod.PresetDef{
    .{ .name = "level decomposition (M-theory fields)", .basis = bLevels },
    .{ .name = "E8 core (Lisi's Coxeter plane)", .basis = bE8 },
    .{ .name = "light cone", .basis = bLightcone, .animated = true },
    .{ .name = "hyperbolic sweep", .basis = bSweep, .animated = true },
};

// --- colors ----------------------------------------------------------------------------

fn classRgb(c: e8.Class) [3]f32 {
    return switch (c) {
        .gravity => .{ 0.55, 0.85, 1.0 },
        .electroweak => .{ 1.0, 0.45, 0.45 },
        .frame_higgs => .{ 1.0, 0.85, 0.35 },
        .gluon => .{ 1.0, 0.60, 0.20 },
        .color_x => .{ 0.75, 0.45, 1.0 },
        .lepton => .{ 0.45, 1.0, 0.65 },
        .quark => .{ 0.35, 0.65, 1.0 },
    };
}

fn fieldRgb(f: e10.Field) [3]f32 {
    return switch (f) {
        .metric => .{ 0.45, 0.85, 1.0 }, // gravity
        .three_form => .{ 1.0, 0.72, 0.25 }, // the M2-brane
        .six_form => .{ 0.95, 0.35, 0.85 }, // the M5-brane
        .dual_graviton => .{ 0.60, 1.0, 0.55 }, // beyond supergravity
    };
}

/// The demo's main color: which FIELD of M-theory a root is part of.
fn cField(p: *const Point, _: f32) [3]f32 {
    return fieldRgb(p.field);
}

/// Lisi's E8, lit up inside E10. The 240 keep their particle colors; everything
/// else in the algebra goes to a dim slate, so you can see the shape of what E8
/// is a small corner OF.
fn cLisi(p: *const Point, _: f32) [3]f32 {
    if (p.core < 0) return .{ 0.20, 0.23, 0.30 };
    return classRgb(p.class);
}

/// The punchline of the whole demo, in one ramp: every point here has Lorentzian
/// norm exactly 2 — the algebra says they are all the same size — while the length
/// the EYE measures runs away from 2. In E8 those two numbers agree everywhere.
/// They part company here, and the gap between them is the light cone.
fn cLorentz(p: *const Point, _: f32) [3]f32 {
    const gap = std.math.clamp((e10.euclid2(p.v) - 2.0) / 9.0, 0, 1);
    return .{ 0.30 + 0.70 * gap, 0.90 - 0.75 * gap, 1.0 - 0.85 * gap };
}

/// How deep into E10 a root sits: the height, i.e. how many simple roots it takes
/// to build. E8's roots stop at height 29; E10's do not stop.
fn cHeight(p: *const Point, _: f32) [3]f32 {
    const h = std.math.clamp(@abs(@as(f32, @floatFromInt(p.height))) / 30.0, 0, 1);
    return .{ 0.25 + 0.75 * h, 0.80 - 0.50 * h, 1.0 - 0.40 * h };
}

/// The Calabi-Yau as a FILTER. Roll up six dimensions and the manifold's SU(3)
/// holonomy is embedded in E8; what commutes with it survives, and what does not,
/// does not. Green: E6, the force that lives. Grey: the six roots the geometry
/// eats. Gold and violet: the 162 that become matter and antimatter in E6's 27.
/// Everything outside Lisi's E8 has no fate here at all — it is not in a gauge
/// group the manifold can act on.
fn cCalabi(p: *const Point, _: f32) [3]f32 {
    const f = fateOf(p) orelse return .{ 0.16, 0.18, 0.24 };
    return fateRgb(f);
}

fn cHidden(_: *const Point, hidden_t: f32) [3]f32 {
    const t = std.math.clamp(hidden_t, 0, 1);
    return .{ 0.15 + 0.85 * t, 0.35 + 0.25 * (1 - t), 1.0 - 0.75 * t };
}

const legend_field = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 115, 217, 255 }, .label = "ℓ=0 · metric — gravity (90)" },
    .{ .rgb = .{ 255, 184, 64 }, .label = "ℓ=±1 · 3-form — the M2-brane (120)" },
    .{ .rgb = .{ 242, 89, 217 }, .label = "ℓ=±2 · 6-form — the M5-brane (210)" },
    .{ .rgb = .{ 153, 255, 140 }, .label = "ℓ=±3 · dual graviton (360)" },
};
const legend_lisi = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 140, 217, 255 }, .label = "gravity ω" },
    .{ .rgb = .{ 255, 115, 115 }, .label = "electroweak W/B" },
    .{ .rgb = .{ 255, 217, 89 }, .label = "frame-Higgs eφ" },
    .{ .rgb = .{ 255, 153, 51 }, .label = "gluon" },
    .{ .rgb = .{ 191, 115, 255 }, .label = "colored xΦ" },
    .{ .rgb = .{ 115, 255, 166 }, .label = "lepton" },
    .{ .rgb = .{ 89, 166, 255 }, .label = "quark" },
    .{ .rgb = .{ 51, 59, 77 }, .label = "not in E8 — the rest of E10" },
};
const legend_calabi = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 102, 255, 158 }, .label = "E6 — the force that survives (72)" },
    .{ .rgb = .{ 140, 148, 166 }, .label = "SU(3) holonomy — eaten (6)" },
    .{ .rgb = .{ 255, 199, 71 }, .label = "(27,3) — matter (81)" },
    .{ .rgb = .{ 179, 115, 255 }, .label = "(27̄,3̄) — antimatter (81)" },
    .{ .rgb = .{ 41, 46, 61 }, .label = "not in E8 — no gauge group to break" },
};
const legend_lorentz = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 77, 230, 255 }, .label = "Euclidean length² = 2" },
    .{ .rgb = .{ 255, 38, 38 }, .label = "long on screen — norm still 2" },
};
const legend_height = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 64, 204, 255 }, .label = "a simple root" },
    .{ .rgb = .{ 255, 77, 153 }, .label = "deep in E10" },
};
const legend_hidden = [_]hud_mod.Hud.LegendIn{
    .{ .rgb = .{ 64, 128, 255 }, .label = "near the view space" },
    .{ .rgb = .{ 255, 100, 64 }, .label = "hidden dimensions" },
};

pub const color_modes = &[_]app_mod.ColorModeDef{
    .{ .name = "M-theory fields (level)", .color = cField, .legend = &legend_field },
    .{ .name = "Lisi's E8 inside E10", .color = cLisi, .legend = &legend_lisi },
    .{ .name = "the Calabi-Yau breaks E8 → E6", .color = cCalabi, .legend = &legend_calabi },
    .{ .name = "Lorentzian vs Euclidean", .color = cLorentz, .legend = &legend_lorentz },
    .{ .name = "height in E10", .color = cHeight, .legend = &legend_height },
    .{ .name = "hidden depth", .color = cHidden, .legend = &legend_hidden },
};

// --- the energy-level slider -------------------------------------------------------------
//
// E10 is infinite, so the roots are generated by LEVEL — and the level is not an
// arbitrary shell, it is a FIELD. So the slider does not zoom: it unveils the
// content of M-theory one field at a time. − and + walk it.

fn fMetric(p: *const Point) bool {
    return p.level == 0;
}
fn fThreeForm(p: *const Point) bool {
    return @abs(p.level) <= 1;
}
fn fSixForm(p: *const Point) bool {
    return @abs(p.level) <= 2;
}
fn fAll(_: *const Point) bool {
    return true;
}
fn fE8(p: *const Point) bool {
    return p.in_e8;
}
fn fBeyond(p: *const Point) bool {
    return !p.in_e8;
}

fn fSurvives(p: *const Point) bool {
    const f = fateOf(p) orelse return false;
    return f == .e6;
}
fn fMatter(p: *const Point) bool {
    const f = fateOf(p) orelse return false;
    return f == .matter or f == .antimatter;
}

pub const filters = &[_]app_mod.FilterDef{
    .{ .name = "ℓ=0 — the metric: gravity (90)", .pass = fMetric },
    .{ .name = "+ the 3-form: M2-branes (330)", .pass = fThreeForm },
    .{ .name = "+ the 6-form: M5-branes (750)", .pass = fSixForm },
    .{ .name = "+ the dual graviton — all 1470", .pass = fAll },
    .{ .name = "Lisi's E8 only (240)", .pass = fE8 },
    .{ .name = "everything E8 cannot see (1230)", .pass = fBeyond },
    .{ .name = "survives the Calabi-Yau: E6 (72)", .pass = fSurvives },
    .{ .name = "becomes matter: the 27 (162)", .pass = fMatter },
};

/// How many of the filters above are the level slider (the rest isolate a sector).
const n_levels: u32 = 4;

fn actLevelUp(a: *App) void {
    const st = a.pluginState(filters_p);
    st.filter = @min(st.filter + 1, n_levels - 1);
    a.status_dirty = true;
}

fn actLevelDown(a: *App) void {
    const st = a.pluginState(filters_p);
    st.filter = if (st.filter == 0 or st.filter >= n_levels) 0 else st.filter - 1;
    a.status_dirty = true;
}

/// The 3-form ladder: apply the tenth simple root — the ONLY one that changes the
/// level. Ride it with G and you climb the fields of M-theory, from the metric to
/// the M2's 3-form to the M5's 6-form to the dual graviton, one brane at a time.
fn ladder(points: []const Point, i: u16) u16 {
    const p = &points[i];
    var want: [10]i32 = undefined;
    for (&want, p.w, e10.simple[9]) |*x, a, b| x.* = a + b;
    for (points, 0..) |q, j| {
        if (std.mem.eql(i32, &q.w, &want)) return @intCast(j);
    }
    return i;
}

pub const relations = &[_]app_mod.RelationDef{
    .{ .name = "3-form ladder", .partner = ladder },
};

fn actLadder(a: *App) void {
    if (a.selected >= 0 and a.rel.len > 0) {
        a.selected = a.rel[0][@intCast(a.selected)];
        a.info_dirty = true;
    }
}

pub const actions = &[_]app_mod.ActionDef{
    .{ .key = keys.domain_b, .help = "B: the Big Bang — wind time back to t = 0 (the E10 billiard); ←/→ rotation is parked while it runs", .run = cinema.toggle },
    .{ .key = keys.domain_plus, .help = "+: raise the level — unveil the next field of M-theory", .run = actLevelUp },
    .{ .key = keys.domain_minus, .help = "-: lower the level", .run = actLevelDown },
    .{ .key = keys.domain_g, .help = "G: climb the 3-form ladder (metric → M2 → M5 → dual graviton)", .run = actLadder },
};

// --- how a root looks and behaves --------------------------------------------------------

/// A root of E10 is not a static point. The higher its level, the higher the brane
/// it charges — and the faster it vibrates here. The metric sits still; the 3-form
/// breathes; the dual graviton shakes.
pub fn descriptor(a: *App, i: usize) desc.Object {
    const p = &a.points[i];
    const lvl: f32 = @floatFromInt(@abs(p.level));
    return .{
        .radius = if (p.core >= 0) 1.15 else 1.0 - 0.10 * lvl,
        .glow = if (p.core >= 0) 1.2 else 1.0 - 0.10 * lvl,
        .pulse = if (p.level == 0) null else .{
            .kind = .wave,
            .rate = 0.7 + 1.4 * lvl,
            .amp = 0.16 + 0.12 * lvl,
            .phase = @as(f32, @floatFromInt(p.height)) * 0.21,
        },
        .orbit_rgb = fieldRgb(p.field),
        .orbit_phase = lvl * 2.0 * std.math.pi / 3.0,
    };
}

// --- the Calabi-Yau ----------------------------------------------------------------------
//
// Roll up six of the ten dimensions and their shape decides what survives of E8.
// The manifold's SU(3) holonomy is embedded in the gauge group (the standard
// embedding), and what commutes with it is E6 — so of Lisi's 240 roots, 72 stay
// gauge bosons, 6 are eaten by the geometry, and 162 become matter and antimatter
// in E6's 27. That census is computed in `heterotic.zig`, from inner products, and
// the tests assert it: 72 / 6 / 81 / 81.
//
// The mesh is the quintic itself (`calabi.zig`) — 25 petals, every vertex of it
// on z1^5 + z2^5 = 1. Click a root and it opens inside the point.

/// The framework bakes this once, next to its sphere and its tube, and never asks
/// what it is (see `descriptor.MeshData`).
/// The manifold, handed to the framework in TWENTY-FIVE PARTS.
///
/// Not an implementation detail: the quintic's Hanson patches are indexed by a
/// pair of fifth roots of unity, k₁ and k₂, and there are 5 × 5 of them. A zengine
/// instance carries one material, so one part per patch is what lets each root of
/// unity be lit its own hue — the iridescence you see IS the ℤ₅ × ℤ₅ symmetry of
/// z₁⁵ + z₂⁵ = 1, not decoration painted over it.
pub const extra_parts = calabi.patches;

const cy_res = 22; // grid per patch; 25 × 22² = 12 100 vertices, baked once

pub fn extraMeshes(gpa: std.mem.Allocator) ![]desc.MeshData {
    var m = try calabi.build(gpa, cy_res, std.math.pi / 4.0, 1.0);
    defer m.deinit();

    const per = cy_res * cy_res; // vertices in a patch — contiguous, by construction
    const per_idx = (cy_res - 1) * (cy_res - 1) * 6;

    const parts = try gpa.alloc(desc.MeshData, calabi.patches);
    var made: usize = 0;
    errdefer {
        for (parts[0..made]) |p| {
            gpa.free(p.verts);
            gpa.free(p.idx);
        }
        gpa.free(parts);
    }

    while (made < calabi.patches) : (made += 1) {
        const base = made * per;
        const verts = try gpa.alloc(f32, per * 8);
        errdefer gpa.free(verts);
        for (0..per) |k| {
            const p = m.pos[base + k];
            const n = m.nrm[base + k];
            const v = verts[k * 8 ..][0..8];
            v[0] = p[0];
            v[1] = p[1];
            v[2] = p[2];
            v[3] = n[0];
            v[4] = n[1];
            v[5] = n[2];
            v[6] = @as(f32, @floatFromInt(made)) / @as(f32, @floatFromInt(calabi.patches));
            v[7] = 0;
        }
        const idx = try gpa.alloc(u32, per_idx);
        errdefer gpa.free(idx);
        for (m.idx[made * per_idx ..][0..per_idx], idx) |src, *dst| dst.* = src - @as(u32, @intCast(base));
        parts[made] = .{ .verts = verts, .idx = idx };
    }
    return parts;
}

fn fateRgb(f: het.Fate) [3]f32 {
    return switch (f) {
        .e6 => .{ 0.40, 1.0, 0.62 }, // the force that survives
        .holonomy => .{ 0.55, 0.58, 0.65 }, // eaten by the manifold
        .matter => .{ 1.0, 0.78, 0.28 }, // a generation, in E6's 27
        .antimatter => .{ 0.70, 0.45, 1.0 },
    };
}

var e8_cache: ?[240]e8.Root = null;

fn e8Roots() *const [240]e8.Root {
    if (e8_cache == null) e8_cache = e8.generate();
    return &(e8_cache.?);
}

/// The fate of a root under compactification — only the 240 that are Lisi's have
/// one, because only they live in an E8 to begin with. The other 1230 roots of E10
/// are not in any gauge group the Calabi-Yau can break.
fn fateOf(p: *const Point) ?het.Fate {
    if (p.core < 0) return null;
    return het.fateOf(e8Roots()[@intCast(p.core)].v);
}

/// Open the selected point: the six curled dimensions, turning. Colored by what
/// the manifold does to THIS root — green if it survives into E6, grey if the
/// geometry eats it, gold if it becomes matter.
/// Fully saturated colour at the given hue — the sheen on a soap film, and here
/// the label of a root of unity.
fn hue(h: f32) [3]f32 {
    const x = (h - @floor(h)) * 6.0;
    const i: u32 = @intFromFloat(x);
    const f = x - @floor(x);
    return switch (i % 6) {
        0 => .{ 1, f, 0 },
        1 => .{ 1 - f, 1, 0 },
        2 => .{ 0, 1, f },
        3 => .{ 0, 1 - f, 1 },
        4 => .{ f, 0, 1 },
        else => .{ 1, 0, 1 - f },
    };
}

/// Open a root and look at the six curled-up dimensions inside it.
///
/// The manifold is drawn at the ORIGIN, large, not out at the root's own position:
/// selecting a point is a zoom INTO it, and at that magnification the root system
/// around it is the backdrop, not the subject. Each of the 25 patches gets its own
/// hue and its own instance, so what turns in front of you is the quintic's ℤ₅ × ℤ₅
/// symmetry made visible. The selected root's fate tints the whole thing — a
/// surviving E6 boson greens it, a matter root warms it — because the same manifold
/// is what decided that fate.
pub fn sceneExtra(a: *App, i: usize, part: usize) ?desc.Extra {
    const p = &a.points[i];
    const f = fateOf(p) orelse return null; // not one of Lisi's: no E8, no story

    const t = a.anim * 0.30;
    const co = @cos(t);
    const si = @sin(t);
    // The mesh has radius 2.0; the inspector's camera sits 3.8 out at a 0.8 rad
    // field of view, so it sees ±1.6. Anything above ~0.85 and the petals are cut
    // off by the frame as it turns.
    const s: f32 = 0.85;

    // Hue by patch = by root of unity, but swept through the VIOLET band rather
    // than the whole wheel: cyan-blue → violet → magenta. A full rainbow makes the
    // 25 patches read as 25 unrelated objects; a narrow sweep keeps them one
    // iridescent surface with the ℤ₅ × ℤ₅ symmetry legible across it.
    const u = @as(f32, @floatFromInt(part)) / @as(f32, @floatFromInt(calabi.patches));
    const c = hue(0.56 + 0.30 * u);
    // A cool violet floor under all of it, so even the bluest patch stays lit.
    const violet = [3]f32{ 0.42, 0.20, 0.85 };
    const tint = fateRgb(f);
    var e: [3]f32 = undefined;
    for (&e, c, violet, tint) |*x, ci, vi, ti| {
        const base = 0.45 * ci + 0.55 * vi; // the patch's hue, sitting in violet
        x.* = (0.72 * base + 0.28 * base * ti) * 1.05; // …carrying the root's fate
    }

    return .{
        .model = .{
            co * s, 0,  -si * s, 0,
            0,      s,  0,       0,
            si * s, 0,  co * s,  0,
            0,      0,  0,       1,
        },
        // Dark, glossy, metallic body: the light in it is the emissive hue and the
        // specular highlight riding over it, which is what makes a soap-film surface
        // read as a surface at all.
        .base_color = .{ 0.04, 0.04, 0.05 },
        .emissive = e,
        .roughness = 0.16,
        .metallic = 0.85,
    };
}

// --- text ---------------------------------------------------------------------------------

pub fn describe(a: *App, i: usize, buf: []u8) []const u8 {
    const p = &a.points[i];
    if (p.core >= 0) {
        return std.fmt.bufPrint(buf, "{s} · {s} — one of Lisi's 240, inside E10 · ℓ={d} ({s}) · height {d}", .{
            p.class.name(), e8.genName(p.gen), p.level, p.field.label(), p.height,
        }) catch "";
    }
    return std.fmt.bufPrint(buf, "{s} · ℓ={d} · height {d} · ⟨α,α⟩={d} · |v|²={d:.0} — not in E8", .{
        p.field.label(), p.level, p.height, e10.ip(p.w, p.w), e10.euclid2(p.v),
    }) catch "";
}

pub fn story(a: *App) void {
    if (a.selected < 0) {
        a.hud.setPanel(
            "E10 — what Lisi's E8 is a corner of",
            "Adjoin two nodes to E8's Dynkin diagram and it stops being a compact group of 248 dimensions and becomes E10: infinite-dimensional, and HYPERBOLIC. Its metric acquires a light cone, and its roots never run out.\nGrade them by level ℓ — how many times the tenth simple root appears — and something remarkable falls out. Each level is finite, and each level IS a field of eleven-dimensional supergravity: ℓ=0 gives 90 roots, the metric, gravity itself; ℓ=±1 gives 120, the 3-form an M2-brane carries; ℓ=±2 gives 210, the 6-form of the M5-brane; ℓ=±3 gives 360, the dual graviton — a field the supergravity Lagrangian does not even contain.\nThose counts are not put in by hand. They are what you get from solving Σw = 3ℓ and Σw² = 2 + ℓ². The algebra knows about branes.\nAnd Lisi's 240 are still here — press C: they are exactly the roots that use neither of the two new nodes.\n−/+ unveils one field at a time. B runs the Big Bang. Click any root.",
            "Damour, Henneaux & Nicolai, PRL 89 (2002) 221601 · CQG 20 (2003) R145 · Lisi arXiv:0711.0770.",
        );
        return;
    }
    const p = &a.points[@intCast(a.selected)];
    var tbuf: [96]u8 = undefined;
    const t = if (p.core >= 0)
        std.fmt.bufPrint(&tbuf, "{s} — Lisi's, inside E10", .{p.class.name()}) catch "root"
    else
        std.fmt.bufPrint(&tbuf, "ℓ = {d} — {s}", .{ p.level, p.field.label() }) catch "root";
    a.hud.setPanel(
        t,
        if (p.core >= 0)
            \\One of Lisi's 240 — and it is the SAME root, not an analogy. Delete two nodes from E10's Dynkin diagram and E8 is what is left; this root is one that uses neither of them. Its inner product with every other one of the 240 is exactly what it was in E8: the demo checks all 57 600 of them.
            \\Click it and the popup opens the six curled dimensions this particle lives inside — the Calabi-Yau. Its SU(3) holonomy is embedded in E8 (the standard embedding), and that decides this root's fate: it either survives as a gauge boson of E6, or the geometry eats it, or it becomes matter in E6's 27. Press C to color all 240 by that fate.
        else switch (p.field) {
            .metric =>
            \\Level 0: the roots of sl(10), all 90 of them. This is the METRIC — gravity, the graviton, the shape of ten-dimensional space. It is the level everything else is built on, and in the cosmological billiard these are the nine SYMMETRY walls: pure geometry refusing to be sheared away.
            \\Ninety roots, and not one of them knows about matter.
            ,
            .three_form =>
            \\Level ±1: 120 roots, one for each way of choosing three of the ten directions — C(10,3). That is the 3-form A_abc of eleven-dimensional supergravity, and a 3-form is what an M2-BRANE couples to: these roots are membrane charges.
            \\In the billiard this level is the ELECTRIC WALL — the one wall that is not gravity, and the one that closes the Weyl chamber. Without it there is no chaos at the Big Bang. Matter is what makes the beginning of the universe unpredictable.
            ,
            .six_form =>
            \\Level ±2: 210 roots — C(10,6), the 6-form. A 6-form is what an M5-BRANE couples to: this level is the magnetic dual of the one below it, and the algebra produced it without being asked.
            \\Nobody put branes into E10. They fell out of counting its roots.
            ,
            .dual_graviton =>
            \\Level ±3: 360 roots — the DUAL GRAVITON. And here the algebra says something eleven-dimensional supergravity does not: this field is not in its Lagrangian. It is a field E10 predicts.
            \\This is where the E10 proposal stops describing what we already knew and starts making a claim. Levels beyond this one keep coming, forever, and nobody knows what all of them mean.
            ,
        },
        "Damour, Henneaux & Nicolai, PRL 89 (2002) 221601 (the level decomposition) · CQG 20 (2003) R145 §4 · Lisi 0711.0770 Table 9.",
    );
}

pub const InspectText = struct { title_len: usize, body_len: usize };

pub fn inspect(a: *App, i: usize, tbuf: *[96]u8, bbuf: *[512]u8) InspectText {
    const p = &a.points[i];
    const t = if (fateOf(p)) |f|
        std.fmt.bufPrint(tbuf, "{s} · {s}", .{ p.class.name(), f.label() }) catch ""
    else
        std.fmt.bufPrint(tbuf, "{s}", .{p.field.label()}) catch "";
    const b = std.fmt.bufPrint(bbuf, "level {d} · height {d} · {s}\nLorentzian norm <a,a> = {d} — a real root, like every root here.\nEuclidean length on screen |v|^2 = {d:.0} — which is NOT 2. In E8 those two numbers agree everywhere; here they part company, and the gap is the light cone.\nw = ({d},{d},{d},{d},{d},{d},{d},{d},{d},{d})\nrefs: DHN PRL 89 221601 · CQG 20 (2003) R145", .{
        p.level,
        p.height,
        if (p.core >= 0) p.class.name() else "not one of Lisi's",
        e10.ip(p.w, p.w),
        e10.euclid2(p.v),
        p.w[0], p.w[1], p.w[2], p.w[3], p.w[4],
        p.w[5], p.w[6], p.w[7], p.w[8], p.w[9],
    }) catch "";
    return .{ .title_len = t.len, .body_len = b.len };
}

/// "e8" replays Lisi's Coxeter figure from the roots of the E8 sub-system — they
/// really are the same 240. "levels" plots the Coxeter angle against the level, so
/// M-theory's fields show as horizontal bands.
pub fn figure(a: *App, fig_id: []const u8, dots: []hud_mod.FigDot) usize {
    const want_levels = std.mem.eql(u8, fig_id, "levels");
    if (!want_levels and !std.mem.eql(u8, fig_id, "e8")) return 0;
    const r0 = e10.coxeterRow(0);
    const r1 = e10.coxeterRow(1);
    var k: usize = 0;
    for (a.points) |*p| {
        if (!want_levels and p.core < 0) continue;
        var x: f32 = 0;
        var y: f32 = 0;
        for (0..10) |q| {
            x += r0[q] * p.v[q];
            y += r1[q] * p.v[q];
        }
        if (want_levels) y = @as(f32, @floatFromInt(p.level)) * 0.26;
        const rgb = if (want_levels) fieldRgb(p.field) else classRgb(p.class);
        // Level-3 roots project past the figure box; clamp them to its edge.
        dots[k] = .{ .x = std.math.clamp(x * 0.40, -1.0, 1.0), .y = std.math.clamp(y * (if (want_levels) @as(f32, 1.0) else 0.40), -1.0, 1.0), .rgb = .{
            @intFromFloat(rgb[0] * 255),
            @intFromFloat(rgb[1] * 255),
            @intFromFloat(rgb[2] * 255),
        } };
        k += 1;
        if (k == dots.len) break;
    }
    return k;
}

pub fn exportCsv(a: *App) !void {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a.gpa);
    try out.appendSlice(a.gpa, "index,level,field,height,in_e8,lisi_class,w1,w2,w3,w4,w5,w6,w7,w8,w9,w10,px,py,pz\n");
    var buf: [288]u8 = undefined;
    for (a.points, 0..) |*p, i| {
        const pr = geom.project(&a.basis, p.v);
        const line = try std.fmt.bufPrint(&buf, "{d},{d},{s},{d},{},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d:.6},{d:.6},{d:.6}\n", .{
            i,      p.level, @tagName(p.field), p.height, p.in_e8,
            if (p.core >= 0) p.class.name() else "-",
            p.w[0], p.w[1],  p.w[2],            p.w[3],   p.w[4],
            p.w[5], p.w[6],  p.w[7],            p.w[8],   p.w[9],
            pr[0],  pr[1],   pr[2],
        });
        try out.appendSlice(a.gpa, line);
    }
    const csv = try out.toOwnedSlice(a.gpa);
    defer a.gpa.free(csv);
    try std.Io.Dir.cwd().writeFile(a.io, .{ .sub_path = "e10.csv", .data = csv });
    std.debug.print("exported e10.csv ({d} roots)\n", .{a.points.len});
}
