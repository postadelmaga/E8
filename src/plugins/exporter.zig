//! CSV export (X): the full root system under the current projection —
//! coordinates, labels, weights, charges, triality partners.

const std = @import("std");
const e8 = @import("../e8.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;

pub const id = "exporter";

pub fn key(a: *App, code: u32) bool {
    if (code != 45) return false; // X
    const csv = e8.buildCsv(a.gpa, &a.roots, &a.basis) catch |e| {
        std.debug.print("export failed: {s}\n", .{@errorName(e)});
        return true;
    };
    defer a.gpa.free(csv);
    std.Io.Dir.cwd().writeFile(a.io, .{ .sub_path = "e8_roots.csv", .data = csv }) catch |e| {
        std.debug.print("export failed: {s}\n", .{@errorName(e)});
        return true;
    };
    std.debug.print("exported e8_roots.csv ({d} roots, current projection)\n", .{e8.n_roots});
    return true;
}
