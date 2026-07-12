//! The paper journey (P): a guided, multimedia tour of Lisi's papers. The
//! first P opens the side panel on the current slide; every further P advances
//! — each slide sets the projection, colors, edges and filter to reproduce a
//! specific figure AND narrates it in the panel, citations included. Clicking
//! a root mid-journey swaps in that particle's own story (the panel plugin);
//! P resumes the tour. Esc closes the topmost layer first (panel → app).

const std = @import("std");
const e8 = @import("../e8.zig");
const hud_mod = @import("../hud.zig");
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
    /// Kiosk mode (K): auto-advance after each slide's dwell time.
    auto: bool = false,
    auto_t: f32 = 0,
    /// Smooth basis transition between slides (1 = settled).
    tr_from: e8.Basis = undefined,
    tr_to: e8.Basis = undefined,
    tr_t: f32 = 1,
    /// Camera choreography (1 = settled).
    cam_from: [3]f32 = .{ 0, 0, 0 },
    cam_to: [3]f32 = .{ 0, 0, 0 },
    cam_t: f32 = 1,
};

/// Inline panel diagram computed live from the root system.
const Fig = enum { none, g2, f4, spin13 };

const Slide = struct {
    title: []const u8,
    body: []const u8,
    cite: []const u8,
    preset: u32,
    color: u32,
    edge: u32,
    filter: u32,
    tumble: bool = false,
    /// Camera target (yaw, pitch, dist) eased in over ~1.2 s.
    cam: ?[3]f32 = null,
    /// Kiosk dwell time, seconds.
    dwell: f32 = 22,
    fig: Fig = .none,
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
        .cam = .{ 0.65, 0.35, 4.2 },
    },
    .{
        .title = "Strong charges: the G2 picture",
        .body = "Projected on the gluon axes (g³, g⁸), su(3) color becomes geometry: the six gluons draw the root hexagon, quarks and antiquarks sit on the two triangles — their color IS their position — and the color-blind leptons stack on the central axis.\nDepth is Lisi's w charge, separating the three xΦ generations.\nInteractions are root addition: quark + gluon lands on another quark of the same triangle.",
        .cite = "0711.0770 §2.1, Table 2.",
        .preset = 4,
        .color = 0,
        .edge = 0,
        .filter = 0,
        .cam = .{ 0.10, 0.95, 5.0 },
        .fig = .g2,
    },
    .{
        .title = "The graviweak F4",
        .body = "Coordinates 1-4 hold so(7,1): the gravitational spin connection ω, the electroweak W/B1, and the frame-Higgs eφ — one connection carrying general relativity and the Higgs together.\nOn the F4 Petrie plane the 48 graviweak weights make the 12-fold figure of Tables 5-6; the triality links shown here rotate the three generations into each other, colored by generation.",
        .cite = "0711.0770 §2.2, Tables 5-6. Lisi, Smolin, Speziale, arXiv:1004.4866.",
        .preset = 5,
        .color = 1,
        .edge = 3,
        .filter = 0,
        .cam = .{ 0.40, 0.25, 4.6 },
        .fig = .f4,
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
        .cam = .{ 0.65, 0.20, 4.4 },
        .dwell = 30,
    },
    .{
        .title = "New particles: xΦ and w",
        .body = "After every Standard Model field is placed, E8 has 18 roots left over: xΦ ∈ 3×(3+3̄) — a w-charged x joined to a colored Higgs Φ, built exactly like the frame-Higgs eφ.\nIt couples leptons to quarks: proton decay, the falsifiable prediction of the theory. The w charge splits it into x1, x2, x3, one per generation — watch the pulse run through them in sequence.\nThe flat hexagon behind them: the generation-blind gluons.",
        .cite = "0711.0770 §2.4.1, Table 9.",
        .preset = 4,
        .color = 0,
        .edge = 0,
        .filter = 9,
        .cam = .{ 0.20, 0.75, 5.2 },
        .fig = .g2,
    },
    .{
        .title = "Gravitational weights (2024)",
        .body = "The 2024 paper rebuilds the story from quantum Dirac spinors: the lattice axes e1, e2 ARE the boost/spin weights (ωT, ωS) of spin(1,3).\nRoots at (±1,±1) are the gravitational spin connection ω, (±1,0) the frame e, and the (±½,±½) spinors the fermion states — Table 1 of the paper, live in 3D. C, P and T act on this square as reflections; the CPT Group is the split-biquaternion group.",
        .cite = "2407.02497 §2-5, Tables 1-2.",
        .preset = 3,
        .color = 2,
        .edge = 0,
        .filter = 0,
        .cam = .{ 1.20, 0.30, 5.0 },
        .fig = .spin13,
    },
    .{
        .title = "Three generations, eight 24-cells",
        .body = "Extending C, P, T by triality t yields the CPTt Group — order 96, the central product 2T∘D4. It acts on 24 weights per fermion type: 3 generations × 8 CPT states, a 24-cell.\nThe 192 fermion roots split into 8 disjoint 24-cells: ν, e, three colors of up, three of down. The links you see are t itself — select a root and press G to ride its orbit.\nLisi's own caveat: generation II/III weights are physical only through t. The Distler-Garibaldi objection lives exactly here.",
        .cite = "2407.02497 §6-7, Fig 2. Distler & Garibaldi, arXiv:0905.2658.",
        .preset = 2,
        .color = 1,
        .edge = 3,
        .filter = 2,
        .cam = .{ 0.65, 0.35, 4.0 },
        .dwell = 28,
    },
};

pub fn key(a: *App, code: u32) bool {
    const st = a.pluginState(@This());
    switch (code) {
        25 => { // P: start the journey, or next slide
            if (!a.pluginState(panel).on) {
                panel.setOpen(a, true);
            } else {
                st.idx = (st.idx + 1) % slides.len;
            }
            show(a, st.idx);
            return true;
        },
        37 => { // K: kiosk mode — auto-advance through the deck
            st.auto = !st.auto;
            st.auto_t = 0;
            if (st.auto and !a.pluginState(panel).on) {
                panel.setOpen(a, true);
                show(a, st.idx);
            }
            a.status_dirty = true;
            return true;
        },
        1 => { // Esc: close the topmost layer first, then the app
            if (a.pluginState(panel).on) {
                panel.setOpen(a, false);
                st.auto = false;
                a.hud.setLine2("journey paused — P resumes where you left off");
                a.status_dirty = true;
                return true;
            }
            a.win.close();
            return true;
        },
        else => return false,
    }
}

fn smooth(t: f32) f32 {
    return t * t * (3.0 - 2.0 * t);
}

pub fn frame(a: *App) void {
    const st = a.pluginState(@This());
    // Slide-to-slide basis transition (skipped for the self-animating preset 6):
    // linear blend, re-orthonormalized by the core every frame.
    if (st.tr_t < 1) {
        st.tr_t = @min(1.0, st.tr_t + a.dt / 1.2);
        const t = smooth(st.tr_t);
        for (0..3) |r| {
            for (0..8) |c| a.basis[r][c] = st.tr_from[r][c] * (1 - t) + st.tr_to[r][c] * t;
        }
    }
    // Camera choreography.
    if (st.cam_t < 1) {
        st.cam_t = @min(1.0, st.cam_t + a.dt / 1.2);
        const t = smooth(st.cam_t);
        app_mod.storeF32(&app_mod.cam_yaw, st.cam_from[0] * (1 - t) + st.cam_to[0] * t);
        app_mod.storeF32(&app_mod.cam_pitch, st.cam_from[1] * (1 - t) + st.cam_to[1] * t);
        app_mod.storeF32(&app_mod.cam_dist, st.cam_from[2] * (1 - t) + st.cam_to[2] * t);
    }
    // Kiosk auto-advance.
    if (st.auto and a.pluginState(panel).on) {
        st.auto_t += a.dt;
        if (st.auto_t > slides[st.idx].dwell) {
            st.idx = (st.idx + 1) % slides.len;
            show(a, st.idx);
        }
    }
}

pub fn status(a: *App, buf: []u8) []const u8 {
    _ = buf;
    return if (a.pluginState(@This()).auto) "kiosk (K stops)" else "";
}

/// Build the slide's inline diagram from the live root system.
fn figure(a: *App, fig: Fig) void {
    if (fig == .none) return;
    var dots: [72]hud_mod.FigDot = undefined;
    var n: usize = 0;
    for (&a.roots) |*r| {
        var x: f32 = 0;
        var y: f32 = 0;
        var rgb: [3]f32 = undefined;
        switch (fig) {
            .g2 => { // su(3) weight diagram: hexagon + triangles + center
                x = r.t3;
                y = r.t8 * @sqrt(3.0) * 0.85;
                rgb = e8.rootRgb(r, .physics, 0);
            },
            .f4 => { // graviweak F4 Petrie projection (coords 1-4)
                const p = e8.f4Petrie();
                x = e8.dot8(p[0], .{ r.v[0], r.v[1], r.v[2], r.v[3], 0, 0, 0, 0 }) / 1.5;
                y = e8.dot8(p[1], .{ r.v[0], r.v[1], r.v[2], r.v[3], 0, 0, 0, 0 }) / 1.5;
                rgb = e8.rootRgb(r, .generation, 0);
            },
            .spin13 => { // 2024 Table 1: boost/spin weights (ωT, ωS)
                x = r.v[0] * 0.9;
                y = r.v[1] * 0.9;
                rgb = e8.rootRgb(r, .physics, 0);
            },
            .none => unreachable,
        }
        // Dedup on a coarse grid; many roots share the same 2D weight.
        var dup = false;
        for (dots[0..n]) |d| {
            if (@abs(d.x - x) < 0.03 and @abs(d.y - y) < 0.03) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        dots[n] = .{
            .x = std.math.clamp(x, -1, 1),
            .y = std.math.clamp(y, -1, 1),
            .rgb = .{
                @intFromFloat(std.math.clamp(rgb[0], 0, 1) * 255),
                @intFromFloat(std.math.clamp(rgb[1], 0, 1) * 255),
                @intFromFloat(std.math.clamp(rgb[2], 0, 1) * 255),
            },
        };
        n += 1;
        if (n == dots.len) break;
    }
    a.hud.setPanelFigure(dots[0..n]);
}

fn show(a: *App, idx: usize) void {
    const s = &slides[idx];
    const st = a.pluginState(@This());
    st.auto_t = 0;
    // Set up the smooth basis transition: from wherever we are to the slide's
    // projection. Preset 6 animates itself, so it snaps instead.
    st.tr_from = a.basis;
    projections.apply(a, s.preset);
    if (s.preset != 6) {
        st.tr_to = a.basis;
        st.tr_t = 0;
        a.basis = st.tr_from;
    } else st.tr_t = 1;
    if (s.cam) |c| {
        st.cam_from = .{
            app_mod.loadF32(&app_mod.cam_yaw),
            app_mod.loadF32(&app_mod.cam_pitch),
            app_mod.loadF32(&app_mod.cam_dist),
        };
        st.cam_to = c;
        st.cam_t = 0;
    }
    a.pluginState(projections).tumble = s.tumble;
    a.pluginState(colors).mode = s.color;
    a.pluginState(colors).pushed = 99; // force a legend refresh
    a.pluginState(edges).mode = s.edge;
    a.pluginState(filters).filter = s.filter;
    var tbuf: [96]u8 = undefined;
    const title = std.fmt.bufPrint(&tbuf, "{d}/{d} — {s}", .{ idx + 1, slides.len, s.title }) catch s.title;
    a.hud.setPanel(title, s.body, s.cite);
    figure(a, s.fig);
    var lbuf: [120]u8 = undefined;
    a.hud.setLine2(std.fmt.bufPrint(&lbuf, "paper journey {d}/{d} — P next slide · click a root for its story · Esc closes", .{ idx + 1, slides.len }) catch "");
    a.status_dirty = true;
}
