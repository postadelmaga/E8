//! What the presenter says to the terminal.
//!
//! A browser tab has no terminal — and reaching for one is not merely useless
//! there, it is fatal: `std.debug.print` locks stderr, which instantiates
//! `std.Io.Threaded`, which pulls in posix, which wasm32-freestanding does not
//! have. One print in a file the web build happens to reach and the whole target
//! stops compiling, with an error message about `IOV_MAX` that names nothing the
//! author wrote.
//!
//! So the framework prints through here. Natively it is `std.debug.print`; in a
//! tab it is nothing at all, and the browser console stays the JS harness's.
//! (main.zig and the launcher are native-only programs and print as they please.)

const std = @import("std");
const platform = @import("platform.zig");

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (comptime platform.web) return;
    std.debug.print(fmt, args);
}
