//! Data export (X): delegates to the domain (CSV of the whole system under
//! the current projection, or whatever the domain deems useful).

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const D = app_mod.D;

pub const id = "exporter";

pub fn key(a: *App, code: u32) bool {
    if (code != 45) return false; // X
    D.exportCsv(a) catch |e| {
        std.debug.print("export failed: {s}\n", .{@errorName(e)});
    };
    return true;
}
