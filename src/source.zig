//! Where a demo's data comes from — the one place that knows there are two answers.
//!
//! A loader wants bytes. Natively they are in a file, and `std.Io.Dir` fetches them.
//! In a tab there is no file: there is whatever the page put in memory (the sample the
//! demo shipped with, or what the visitor dropped on it — see webfile.zig).
//!
//! Both loaders would rather not know. So they ask HERE, and the difference collapses
//! into one comptime `if` — whose untaken branch is not merely skipped but never
//! ANALYZED, which is the only reason `std.Io.Dir` (and posix under it, and PATH_MAX
//! under that) stays out of a wasm32-freestanding build at all.

const std = @import("std");
const platform = @import("platform.zig");
const webfile = @import("webfile.zig");

/// Read the whole of `path` (native) or of the file the page handed us (web).
/// The caller owns the returned bytes.
pub fn readAll(gpa: std.mem.Allocator, io: std.Io, path: []const u8, limit: usize) ![]u8 {
    // The bytes may already BE here, on either target: the sample the demo ships with
    // (embedded), or the file the page handed us. Neither has a path to open — `path`
    // is only their name, which the loaders read to tell a PDB from an XYZ. The bytes
    // are borrowed (static, or owned by the page), so they are copied: the domain frees
    // what it is given, and neither of those is the domain's to free.
    if (webfile.have() and std.mem.eql(u8, path, webfile.name)) return gpa.dupe(u8, webfile.bytes);

    if (comptime platform.web) {
        return error.NoInputFile;
    } else {
        return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit));
    }
}
