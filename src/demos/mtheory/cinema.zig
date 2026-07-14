//! The Big Bang mode (B) — a demo-local plugin, and the payoff of the whole
//! M-theory domain.
//!
//! Wind time backwards toward t = 0 and watch what Damour, Henneaux and Nicolai
//! say happens: the ten scale factors of eleven-dimensional supergravity start
//! bouncing off the walls of E10's Weyl chamber, faster and faster, and space
//! stops being a smooth background. Two things happen on screen at once, and
//! they are the same thing:
//!
//!   • THE PICTURE IS SHEARED BY THE KASNER EXPONENTS. The projection basis is
//!     stretched along the expanding axes and crushed along the collapsing ones,
//!     using the billiard's live exponents pᵃ. The root system is not being
//!     "animated" — the geometry of space is being applied to it directly.
//!   • THE CLASSICAL SECTOR SWITCHES OFF. Lisi's 240 particles — ordinary matter
//!     in ordinary space — fade toward black as t → 0, while the string tower and
//!     the hyperbolic M-theory sector brighten. At the singularity nothing is
//!     left of the picture but the pure, pulsing structure of E10.
//!
//! Every wall the ball hits lights its own sector: gravity's nine symmetry walls
//! flare the E8 core and its string tower; the tenth — the ELECTRIC wall of the
//! M-theory 3-form, the one the membrane sector carries — flares gold.
//!
//! The message the mode is built to land: space and time are not the canvas the
//! picture is painted on. They come out of the geometry.

const std = @import("std");
const geom = @import("../../geom.zig");
const e10 = @import("e10.zig");
const app_mod = @import("../../app.zig");
const projections = @import("../../plugins/projections.zig");
const App = app_mod.App;
const D = app_mod.D;

pub const id = "cinema";

pub const State = struct {
    on: bool = false,
    /// Cosmological time: 1 = today, 0 = the singularity. B starts the countdown.
    t: f32 = 1,
    /// The billiard itself — allocated on first use (it carries an RNG).
    bil: ?e10.Billiard = null,
    /// Decaying flash from the last wall bounce, and which wall it was.
    flash: f32 = 0,
    wall: i32 = -1,
};

/// Seconds of cosmological countdown from today to the singularity.
const countdown: f32 = 24.0;

/// Bound to B by the domain's action table (so it shows up in the help).
pub fn toggle(a: *App) void {
    const st = a.pluginState(@This());
    st.on = !st.on;
    if (st.on) {
        st.t = 1;
        st.flash = 0;
        st.wall = -1;
        // hep-th/0212256 → Class. Quantum Grav. 20 (2003) R145.
        st.bil = e10.Billiard.init(20_031_145);
    }
    // The Kasner shear IS a non-unit basis: the core's per-frame
    // orthonormalization would renormalize every row and cancel the
    // stretch/crush this mode exists to show.
    a.renorm_basis = !st.on;
    a.status_dirty = true;
    a.info_dirty = true;
}

pub fn frame(a: *App) void {
    const st = a.pluginState(@This());
    if (!st.on) return;
    const b = &(st.bil orelse return);

    st.t = @max(st.t - a.dt / countdown, 0);
    const near = 1.0 - st.t; // 0 today → 1 at the singularity

    // The closer to t = 0, the faster the billiard runs: in BKL the oscillations
    // pile up without bound, and there is no last epoch. Sub-stepped so a wall is
    // never overshot.
    const speed = 0.5 + 7.0 * near * near;
    for (0..8) |_| {
        b.step(a.dt * speed / 8.0);
        if (b.just_bounced) {
            st.flash = 1;
            st.wall = b.last_wall;
        }
    }
    st.flash = @max(st.flash - a.dt * 2.4, 0);
    a.status_dirty = true;

    // The Kasner exponents, applied to the PROJECTION. Rebuilt from the preset
    // each frame (so the shear is applied to a clean basis, never compounded) —
    // which does mean the manual ←/→ rotation is parked while the mode runs.
    a.basis = D.presets[a.preset].basis(a.pluginState(projections).theta);
    const p = b.kasner();
    const kappa = near * 1.15;
    for (&a.basis) |*row| {
        for (row, 0..) |*x, k| x.* *= @exp(kappa * (p[k] - 0.1));
    }
}

pub fn visual(a: *App, i: usize, v: *app_mod.Visual) void {
    const st = a.pluginState(@This());
    if (!st.on) return;
    const near = 1.0 - st.t;
    const r = &a.points[i];

    // Ordinary space, switching off. Lisi's particles — matter in a smooth
    // background — go dark as the background stops existing.
    if (r.core >= 0) {
        const k = 1.0 - 0.93 * near;
        for (&v.color) |*c| c.* *= k;
        v.glow *= k;
        v.bright *= k;
    } else {
        // What the singularity leaves standing: the branes, and the algebra.
        v.glow *= 1.0 + 2.4 * near;
        v.bright *= 1.0 + 0.9 * near;
        v.radius *= 1.0 + 0.25 * near;
    }

    if (st.flash <= 0) return;
    // Which roots the wall we just hit actually IS. The nine symmetry walls are
    // gravity — level 0, the metric. The tenth is the electric wall of the 3-form,
    // and that is literally level ±1: the M2-brane's own roots light up when the
    // universe bounces off the membrane. Same algebra, both sides.
    const electric = st.wall == 9;
    const lit = if (electric) @abs(r.level) == 1 else r.level == 0;
    if (!lit) return;
    const rgb: [3]f32 = if (electric) .{ 1.0, 0.76, 0.26 } else .{ 0.48, 0.82, 1.0 };
    v.glow += 2.6 * st.flash;
    v.bright += 0.8 * st.flash;
    v.halo = .{ .rgb = rgb, .radius_mul = 3.6, .k = 30.0 * st.flash };
}

pub fn status(a: *App, buf: []u8) []const u8 {
    const st = a.pluginState(@This());
    if (!st.on) return "";
    const b = st.bil orelse return "";
    const kind: []const u8 = if (st.wall < 0)
        "free Kasner flight"
    else switch (e10.wallKind(@intCast(st.wall))) {
        .symmetry => "gravity wall (ℓ=0)",
        .electric => "3-form wall — the M2-brane (ℓ=±1)",
    };
    return std.fmt.bufPrint(buf, "BIG BANG t={d:.2} · {d} epochs · {s} · anisotropy {d:.2}", .{
        st.t, b.bounces, kind, b.anisotropy(),
    }) catch "BIG BANG";
}
