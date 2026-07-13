//! The geometric filter: what the Calabi–Yau DOES to E8.
//!
//! Rolling up six dimensions is not a passive act. A Calabi–Yau threefold has
//! SU(3) holonomy — parallel-transport a vector around a loop in it and it comes
//! back rotated by an element of SU(3), never anything more. To make the
//! compactification consistent the heterotic string must cancel that twisting
//! against the gauge field, and the simplest way to do it — the STANDARD
//! EMBEDDING of Candelas, Horowitz, Strominger and Witten — is to set the gauge
//! connection equal to the spin connection: to embed the manifold's SU(3) holonomy
//! directly INTO E8.
//!
//! An SU(3) sitting inside E8 breaks it. What survives is the commutant — the
//! part of E8 that commutes with the whole SU(3) — and the commutant of SU(3) in
//! E8 is E6. This is not an approximation or a choice of convention; it is a fact
//! about the root system, and it can be computed on Lisi's own 240 roots:
//!
//!     248  =  (78, 1)  ⊕  (1, 8)  ⊕  (27, 3)  ⊕  (27̄, 3̄)
//!             E6         holonomy    matter      antimatter
//!
//! and in roots (the eight Cartan generators split 6 + 2):
//!
//!     240  =   72     +     6      +    81     +    81
//!
//! Those four numbers are what this file computes, from nothing but inner
//! products, and what the tests assert. E6 is a real grand-unified group — it
//! contains SU(3)×SU(2)×U(1) — and the 27 is where a generation of quarks and
//! leptons comes from. So the shape of the curled-up dimensions is what decides
//! which of Lisi's 240 particles are gauge bosons of the surviving force, which
//! are eaten by the geometry, and which become matter.
//!
//! HOW MANY GENERATIONS.  The standard embedding gives |χ|/2 net generations,
//! with χ the Euler characteristic of the manifold. For the quintic χ = −200, so
//! it predicts ONE HUNDRED generations of matter. We observe three. That is not a
//! detail we are hiding: it is the honest state of the subject. The quintic is the
//! wrong Calabi–Yau, there are hundreds of millions of candidates, and choosing
//! among them is the unsolved problem sitting under this entire construction.
//!
//!   P. Candelas, G. Horowitz, A. Strominger, E. Witten, "Vacuum configurations
//!     for superstrings", Nucl. Phys. B258 (1985) 46.
//!   P. Hořava, E. Witten, Nucl. Phys. B460 (1996) 506 — M-theory on an interval
//!     IS the E₈×E₈ heterotic string, which is why an E8 is here at all.
//!   M. Green, J. Schwarz, E. Witten, Superstring Theory, vol. 2, ch. 15.

const std = @import("std");
const e8 = @import("../lisi/e8.zig");

/// Where a root of E8 ends up once the Calabi–Yau has had its say.
pub const Fate = enum(u8) {
    /// One of E6's 72 roots: a gauge boson of the force that SURVIVES the
    /// compactification. E6 ⊃ SO(10) ⊃ SU(5) ⊃ the Standard Model.
    e6,
    /// One of the 6 roots of the SU(3) the manifold's own holonomy is embedded
    /// in. These are EATEN: they are the gauge symmetry the geometry uses up.
    holonomy,
    /// One of the 81 roots of (27, 3): MATTER. A generation of quarks and leptons
    /// lives in E6's 27.
    matter,
    /// One of the 81 roots of (27̄, 3̄): the conjugate — antimatter.
    antimatter,

    pub fn label(f: Fate) []const u8 {
        return switch (f) {
            .e6 => "E6 — the surviving force",
            .holonomy => "SU(3) holonomy — eaten by the manifold",
            .matter => "(27, 3) — matter",
            .antimatter => "(27̄, 3̄) — antimatter",
        };
    }
};

/// E8's highest root θ: the unique root that is non-negative against every simple
/// root. In Bourbaki coordinates it is e₇ + e₈, but we find it rather than assume
/// it, so nothing depends on the labelling convention.
pub fn highestRoot() [8]f32 {
    const roots = e8.generate();
    outer: for (roots) |r| {
        for (e8.simple_roots) |s| {
            if (e8.dot8(r.v, s) < -1e-4) continue :outer;
        }
        return r.v;
    }
    unreachable;
}

/// The two roots that generate the SU(3) we embed the holonomy in.
///
/// Which SU(3)? Not any: it has to be the one whose commutant is E6, and there is
/// a standard way to find it. Extend E8's Dynkin diagram by the lowest root −θ;
/// the extended diagram has one more node, and the affine node together with the
/// last simple root α₈ forms an A₂ — an SU(3). Delete those two nodes and what is
/// left is six nodes with a branch: E6.
pub fn holonomySu3() [2][8]f32 {
    const theta = highestRoot();
    var lowest: [8]f32 = undefined;
    for (&lowest, theta) |*x, t| x.* = -t;
    return .{ lowest, e8.simple_roots[7] };
}

/// The fate of a root under the standard embedding, from inner products alone.
///
/// A root commutes with the whole SU(3) exactly when it is orthogonal to both of
/// its generators — those are E6's. A root that lies in the SU(3)'s own plane is
/// holonomy. Everything else carries a non-trivial SU(3) charge, and its sign
/// under the SU(3) hypercharge decides matter from antimatter.
pub fn fateOf(v: [8]f32) Fate {
    const su3 = holonomySu3();
    const a = e8.dot8(v, su3[0]);
    const b = e8.dot8(v, su3[1]);
    if (@abs(a) < 1e-4 and @abs(b) < 1e-4) return .e6;

    // In the SU(3) plane? Then it is one of its six roots.
    // (Project onto the plane and compare lengths — the root has norm 2, so it is
    // in the plane exactly when its projection still has norm 2.)
    // Gram matrix of the two generators: ⟨a,a⟩=⟨b,b⟩=2, ⟨a,b⟩=−1, det = 3.
    const ca = (2.0 * a + b) / 3.0;
    const cb = (a + 2.0 * b) / 3.0;
    const proj2 = 2.0 * ca * ca + 2.0 * cb * cb - 2.0 * ca * cb;
    if (@abs(proj2 - 2.0) < 1e-3) return .holonomy;

    // Charged under SU(3). The 3 and the 3̄ are told apart by the sign of the
    // weight along the SU(3) hypercharge direction; a + 2b is one such direction,
    // and it never vanishes on these 162 roots (the tests check that).
    return if (a + 2.0 * b > 0) .matter else .antimatter;
}

/// The census: how E8's 240 roots are divided by the Calabi–Yau.
pub const Census = struct {
    e6: usize = 0,
    holonomy: usize = 0,
    matter: usize = 0,
    antimatter: usize = 0,
};

pub fn census() Census {
    var c = Census{};
    for (e8.generate()) |r| {
        switch (fateOf(r.v)) {
            .e6 => c.e6 += 1,
            .holonomy => c.holonomy += 1,
            .matter => c.matter += 1,
            .antimatter => c.antimatter += 1,
        }
    }
    return c;
}

/// Net generations from the standard embedding: |χ| / 2. For the quintic,
/// χ = −200, so a hundred. We see three. Nobody knows which manifold gives three.
pub const quintic_euler: i32 = -200;

pub fn generations(euler: i32) u32 {
    return @intCast(@divTrunc(@abs(euler), 2));
}

// --- tests ------------------------------------------------------------------------------

const testing = std.testing;

test "the Calabi-Yau's SU(3) really is an SU(3): two roots at 120 degrees" {
    const su3 = holonomySu3();
    try testing.expectApproxEqAbs(@as(f32, 2.0), e8.dot8(su3[0], su3[0]), 1e-4);
    try testing.expectApproxEqAbs(@as(f32, 2.0), e8.dot8(su3[1], su3[1]), 1e-4);
    // ⟨α,β⟩ = −1 is the Cartan matrix of A₂ = su(3). Nothing else it could be.
    try testing.expectApproxEqAbs(@as(f32, -1.0), e8.dot8(su3[0], su3[1]), 1e-4);
}

test "the commutant of SU(3) in E8 is E6: 248 = 78 + 8 + (27,3) + (27bar,3bar)" {
    const c = census();

    // These four numbers are the compactification. They are computed from inner
    // products on Lisi's own 240 roots, not put in by hand.
    try testing.expectEqual(@as(usize, 72), c.e6); // E6: 78 = 72 roots + 6 Cartan
    try testing.expectEqual(@as(usize, 6), c.holonomy); // SU(3): 8 = 6 roots + 2 Cartan
    try testing.expectEqual(@as(usize, 81), c.matter); // (27, 3) = 27 × 3
    try testing.expectEqual(@as(usize, 81), c.antimatter); // (27̄, 3̄)
    try testing.expectEqual(@as(usize, 240), c.e6 + c.holonomy + c.matter + c.antimatter);

    // …and adding the Cartan back gives E8 whole: 72+6 + 6+2 + 81+81 = 248.
    try testing.expectEqual(@as(usize, 248), 240 + 8);
}

test "the survivors form E6: rank 6, and closed under addition" {
    const roots = e8.generate();
    var e6: [72][8]f32 = undefined;
    var n: usize = 0;
    for (roots) |r| {
        if (fateOf(r.v) == .e6) {
            e6[n] = r.v;
            n += 1;
        }
    }
    try testing.expectEqual(@as(usize, 72), n);

    // A root system, not a bag of vectors: every one has norm 2, the set is closed
    // under negation, and it is CLOSED — if the sum of two of them is a root of E8
    // at all, that root is in E6 too. (A subsystem that were not closed would not
    // be a subalgebra, and the whole story would be false.)
    for (e6[0..n]) |a| {
        try testing.expectApproxEqAbs(@as(f32, 2.0), e8.dot8(a, a), 1e-4);
        var found_neg = false;
        for (e6[0..n]) |b| {
            var d: f32 = 0;
            for (a, b) |x, y| d += (x + y) * (x + y);
            if (d < 1e-6) found_neg = true;

            var sum: [8]f32 = undefined;
            for (&sum, a, b) |*s, x, y| s.* = x + y;
            if (@abs(e8.dot8(sum, sum) - 2.0) > 1e-3) continue; // not a root of E8
            try testing.expectEqual(Fate.e6, fateOf(sum)); // …then it is in E6
        }
        try testing.expect(found_neg);
    }

    // Rank 6: the six simple roots that survive span the space the 72 live in.
    // (Lisi's α₁…α₆ are all orthogonal to both SU(3) generators; α₇ and α₈ are not.)
    for (0..6) |i| try testing.expectEqual(Fate.e6, fateOf(e8.simple_roots[i]));
    try testing.expect(fateOf(e8.simple_roots[7]) == .holonomy);
}

test "matter and antimatter are exact conjugates" {
    const roots = e8.generate();
    for (roots) |r| {
        const f = fateOf(r.v);
        if (f != .matter and f != .antimatter) continue;
        var neg: [8]f32 = undefined;
        for (&neg, r.v) |*x, y| x.* = -y;
        // Negating a root of (27,3) lands in (27̄,3̄) and vice versa — which is what
        // it MEANS for the two to be conjugate representations.
        const g = fateOf(neg);
        try testing.expect((f == .matter and g == .antimatter) or (f == .antimatter and g == .matter));
    }
}

test "the quintic predicts a hundred generations, and we observe three" {
    // Kept as a test because it is the most important number in the file, and the
    // one a demo is most tempted to leave out.
    try testing.expectEqual(@as(u32, 100), generations(quintic_euler));
    try testing.expect(generations(quintic_euler) != 3);
    // The manifold that gives three exists (χ = ±6 after a free quotient); which
    // one nature chose is unknown.
    try testing.expectEqual(@as(u32, 3), generations(-6));
}
