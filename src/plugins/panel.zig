//! The particle panel (P): a side panel explaining the selected root in the
//! language of Lisi's theory, with citations into arXiv:0711.0770,
//! arXiv:2407.02497, arXiv:1004.4866 and the Distler–Garibaldi critique.
//! Opening it widens the window so a glass band appears beside the frame.

const std = @import("std");
const e8 = @import("../e8.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;

pub const id = "panel";

pub const State = struct {
    on: bool = false,
};

/// Width reserved for the panel; the window widens by 2× this so the centered
/// video keeps its size and the band appears on the right.
const panel_px: u32 = 300;

pub fn init(a: *App) void {
    updateText(a);
}

/// Open or close the side panel — the window widens/narrows to make room.
/// The slides plugin drives this (P / Esc); content comes from whoever calls
/// `hud.setPanel` last (a slide, or the selected particle's story).
pub fn setOpen(a: *App, on: bool) void {
    const st = a.pluginState(@This());
    if (st.on == on) return;
    st.on = on;
    a.hud.panel_on.store(on, .monotonic);
    a.reserve_w = if (on) 2 * panel_px else 0;
    const extra: u32 = if (on) 2 * panel_px else 0;
    a.win.requestResize(app_mod.win_w + extra, app_mod.win_h);
}

pub fn post(a: *App) void {
    if (a.info_dirty and a.pluginState(@This()).on) updateText(a);
}

fn updateText(a: *App) void {
    const hud = a.hud;
    if (a.selected < 0) {
        hud.setPanel(
            "E8 — 240 roots as elementary particles",
            "Coordinates 1-4 host the graviweak so(7,1): gravity ω on 1-2, electroweak W/B1 on 3-4, and the 16 frame-Higgs eφ roots across the two pairs. Coordinate 5 is Lisi's w u(1); su(3) color acts on 6-8.\nThe 112 integer roots are the so(16) adjoint, the 128 spinors its chiral 16⁺. The 192 fermions form three 64-blocks — generations I (8s+), II (8s−), III (8v) — related by the triality rotation T.\nClick a root for its story. G hops its triality orbit, A steps the paper atlas.",
            "A.G. Lisi, \"An Exceptionally Simple Theory of Everything\", arXiv:0711.0770 (Table 9). — \"C, P, T, and Triality\", arXiv:2407.02497.",
        );
        return;
    }
    const r = &a.roots[@intCast(a.selected)];
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
            "The su(3) adjoint root hexagon on coordinates 6-8, read off the (λ3, λ8) weights. Gluons carry no w charge and all six are triality-fixed: the strong force is generation-blind, which is why the hexagon never moves in the triality-linked figures.\nPreset 4 is Lisi's G2 picture: gluons on the hexagon, quark and antiquark triangles around it, leptons at the center.",
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
            const title = std.fmt.bufPrint(&tbuf, "{s} [{s}] — generation {s}", .{
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
                title,
                body,
                "0711.0770 Table 9 & §2.4.2 (triality). 2407.02497 §6-7 (CPTt Group, 24-cells). Distler & Garibaldi, arXiv:0905.2658 (critique).",
            );
        },
    }
}
