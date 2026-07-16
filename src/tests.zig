//! Test root. The domains' mathematics is exact Lie theory, and it is checked as
//! such: E8's 240 roots and Lisi's Table-9 assignment, then E10 — the Lorentzian
//! lattice, its Dynkin diagram recovered from the simple roots, and the BKL
//! cosmological billiard. Rooted at `src/` so a demo package can reach a sibling
//! (the M-theory domain is built on Lisi's E8).

test {
    _ = @import("deck_write.zig");
    _ = @import("menu/fetch.zig");
    _ = @import("demos/lisi/e8.zig");
    _ = @import("demos/mtheory/e10.zig");
    _ = @import("demos/mtheory/calabi.zig");
    _ = @import("demos/mtheory/heterotic.zig");
    _ = @import("demos/chem/read.zig");
}
