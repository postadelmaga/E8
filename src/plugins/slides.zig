//! The paper journey (P): a guided, multimedia tour of Lisi's papers. The
//! first P opens the side panel on the current slide; every further P advances
//! — each slide sets the projection, colors, edges and filter to reproduce a
//! specific figure AND narrates it in the panel, citations included. Clicking
//! a root mid-journey swaps in that particle's own story (the panel plugin);
//! P resumes the tour. Esc closes the topmost layer first (panel → app).

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const projections = @import("projections.zig");
const colors = @import("colors.zig");
const filters = @import("filters.zig");
const edges = @import("edges.zig");
const panel = @import("panel.zig");

pub const id = "slides";

pub const State = struct {
    idx: usize = 0,
};

const Slide = struct {
    title: []const u8,
    body: []const u8,
    cite: []const u8,
    preset: u32,
    color: u32,
    edge: u32,
    filter: u32,
    tumble: bool = false,
};

const slides = [_]Slide{
    .{
        .title = "The E8 root system as a periodic table",
        .body = "240 roots of the largest exceptional Lie group, projected on the Coxeter plane — the iconic 30-fold figure, first plotted by hand in 1964. Lisi's move: assign EVERY root to one elementary particle of gravity plus the Standard Model.\nThe thin links join triality partners — the thread the three fermion generations hang on.\nDrag to orbit. The figure lives in R⁸: ←/→ rotates hidden dimensions into view (Tab picks the plane).",
        .cite = "0711.0770 Fig 2 & Table 9.",
        .preset = 1,
        .color = 0,
        .edge = 3,
        .filter = 0,
    },
    .{
        .title = "Strong charges: the G2 picture",
        .body = "Projected on the gluon axes (g³, g⁸), su(3) color becomes geometry: the six gluons draw the root hexagon, quarks and antiquarks sit on the two triangles — their color IS their position — and the color-blind leptons stack on the central axis.\nDepth is Lisi's w charge, separating the three xΦ generations.\nInteractions are root addition: quark + gluon lands on another quark of the same triangle.",
        .cite = "0711.0770 §2.1, Table 2.",
        .preset = 4,
        .color = 0,
        .edge = 0,
        .filter = 0,
    },
    .{
        .title = "The graviweak F4",
        .body = "Coordinates 1-4 hold so(7,1): the gravitational spin connection ω, the electroweak W/B1, and the frame-Higgs eφ — one connection carrying general relativity and the Higgs together.\nOn the F4 Petrie plane the 48 graviweak weights make the 12-fold figure of Tables 5-6; the triality links shown here rotate the three generations into each other, colored by generation.",
        .cite = "0711.0770 §2.2, Tables 5-6. Lisi, Smolin, Speziale, arXiv:1004.4866.",
        .preset = 5,
        .color = 1,
        .edge = 3,
        .filter = 0,
    },
    .{
        .title = "Rotating F4 into G2",
        .body = "Lisi's celebrated animation: the projection sweeps from the graviweak F4 plane to the strong G2 plane — the two are each other's centralizers inside E8, so e8 = f4 + g2 + 26×7 with the exceptional Jordan algebra in between.\nNear the G2 end, the central 72 roots are the E6 subsystem acting on the three colored 27s.\n←/→ sweeps by hand; T pauses or resumes the animation.",
        .cite = "0711.0770 §2.3, Figs 3-4 (the e8rotation.mov).",
        .preset = 6,
        .color = 0,
        .edge = 0,
        .filter = 0,
        .tumble = true,
    },
    .{
        .title = "New particles: xΦ and w",
        .body = "After every Standard Model field is placed, E8 has 18 roots left over: xΦ ∈ 3×(3+3̄) — a w-charged x joined to a colored Higgs Φ, built exactly like the frame-Higgs eφ.\nIt couples leptons to quarks: proton decay, the falsifiable prediction of the theory. The w charge splits it into x1, x2, x3, one per generation — watch the pulse run through them in sequence.\nThe flat hexagon behind them: the generation-blind gluons.",
        .cite = "0711.0770 §2.4.1, Table 9.",
        .preset = 4,
        .color = 0,
        .edge = 0,
        .filter = 9,
    },
    .{
        .title = "Gravitational weights (2024)",
        .body = "The 2024 paper rebuilds the story from quantum Dirac spinors: the lattice axes e1, e2 ARE the boost/spin weights (ωT, ωS) of spin(1,3).\nRoots at (±1,±1) are the gravitational spin connection ω, (±1,0) the frame e, and the (±½,±½) spinors the fermion states — Table 1 of the paper, live in 3D. C, P and T act on this square as reflections; the CPT Group is the split-biquaternion group.",
        .cite = "2407.02497 §2-5, Tables 1-2.",
        .preset = 3,
        .color = 2,
        .edge = 0,
        .filter = 0,
    },
    .{
        .title = "Three generations, eight 24-cells",
        .body = "Extending C, P, T by triality t yields the CPTt Group — order 96, the central product 2T∘D4. It acts on 24 weights per fermion type: 3 generations × 8 CPT states, a 24-cell.\nThe 192 fermion roots split into 8 disjoint 24-cells: ν, e, three colors of up, three of down. The links you see are t itself — select a root and press G to ride its orbit.\nLisi's own caveat: generation II/III weights are physical only through t. The Distler-Garibaldi objection lives exactly here.",
        .cite = "2407.02497 §6-7, Fig 2. Distler & Garibaldi, arXiv:0905.2658.",
        .preset = 2,
        .color = 1,
        .edge = 3,
        .filter = 2,
    },
};

pub fn key(a: *App, code: u32) bool {
    switch (code) {
        25 => { // P: start the journey, or next slide
            const st = a.pluginState(@This());
            if (!a.pluginState(panel).on) {
                panel.setOpen(a, true);
            } else {
                st.idx = (st.idx + 1) % slides.len;
            }
            show(a, st.idx);
            return true;
        },
        1 => { // Esc: close the topmost layer first, then the app
            if (a.pluginState(panel).on) {
                panel.setOpen(a, false);
                a.hud.setLine2("journey paused — P resumes where you left off");
                return true;
            }
            a.win.close();
            return true;
        },
        else => return false,
    }
}

fn show(a: *App, idx: usize) void {
    const s = &slides[idx];
    projections.apply(a, s.preset);
    a.pluginState(projections).tumble = s.tumble;
    a.pluginState(colors).mode = s.color;
    a.pluginState(colors).pushed = 99; // force a legend refresh
    a.pluginState(edges).mode = s.edge;
    a.pluginState(filters).filter = s.filter;
    var tbuf: [96]u8 = undefined;
    const title = std.fmt.bufPrint(&tbuf, "{d}/{d} — {s}", .{ idx + 1, slides.len, s.title }) catch s.title;
    a.hud.setPanel(title, s.body, s.cite);
    var lbuf: [120]u8 = undefined;
    a.hud.setLine2(std.fmt.bufPrint(&lbuf, "paper journey {d}/{d} — P next slide · click a root for its story · Esc closes", .{ idx + 1, slides.len }) catch "");
    a.status_dirty = true;
}
