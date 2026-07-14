//! Data export (X): delegates to the domain (CSV of the whole system under
//! the current projection, or whatever the domain deems useful).

const std = @import("std");
const keys = @import("../keys.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const D = app_mod.D;

pub const id = "exporter";

/// Needs a file to write the CSV into — none of which a browser tab has (see platform.zig).
pub const native_only = true;

pub fn key(a: *App, code: u32) bool {
    if (code != keys.export_csv) return false; // X
    D.exportCsv(a) catch |e| {
        std.debug.print("export failed: {s}\n", .{@errorName(e)});
        var buf: [96]u8 = undefined;
        a.hud.setLine2(std.fmt.bufPrint(&buf, "export failed: {s}", .{@errorName(e)}) catch "export failed");
        return true;
    };
    // Launched from the launcher there is no terminal: say IN THE WINDOW that
    // something happened, and where (the console prints the exact file name).
    a.hud.setLine2("exported — CSV written in the working directory (console shows the file name)");
    return true;
}
