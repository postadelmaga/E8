//! Domain selection seam: the presenter framework is domain-agnostic; the
//! build option `-Ddemo=<name>` picks which domain package supplies the
//! points, classifications, presets, deck and stories. Everything the
//! framework needs from a domain is documented in `demos/lisi/domain.zig`,
//! the reference implementation.

const std = @import("std");
const opts = @import("build_options");

pub const D = blk: {
    if (std.mem.eql(u8, opts.demo, "lisi")) break :blk @import("demos/lisi/domain.zig");
    if (std.mem.eql(u8, opts.demo, "molecule")) break :blk @import("demos/molecule/domain.zig");
    if (std.mem.eql(u8, opts.demo, "polytope")) break :blk @import("demos/polytope/domain.zig");
    if (std.mem.eql(u8, opts.demo, "mtheory")) break :blk @import("demos/mtheory/domain.zig");
    if (std.mem.eql(u8, opts.demo, "data")) break :blk @import("demos/data/domain.zig");
    if (std.mem.eql(u8, opts.demo, "embed")) break :blk @import("demos/embed/domain.zig");
    if (std.mem.eql(u8, opts.demo, "chem")) break :blk @import("demos/chem/domain.zig");
    if (std.mem.eql(u8, opts.demo, "graph")) break :blk @import("demos/graph/domain.zig");
    if (std.mem.eql(u8, opts.demo, "astro")) break :blk @import("demos/astro/domain.zig");
    @compileError("unknown -Ddemo=" ++ opts.demo ++ " (expected: lisi, mtheory, molecule, polytope, data, embed, chem, graph, astro)");
};

pub const dim = D.dim;
pub const Point = D.Point;
