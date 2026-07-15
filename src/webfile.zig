//! What a browser tab has instead of a filesystem: one file, in memory.
//!
//! Five of the nine demos are PROFILES — they exist to open something you bring: a
//! PDB, a star catalog, an edge list, a CSV of vectors. Natively they take a path and
//! read it. A tab has no path to take, and for a while that was the end of it: those
//! demos simply were not on the web.
//!
//! But a tab is not short of files — it is short of a *filesystem*. The browser has a
//! file picker (on a phone too), a drop target, and `fetch`, and all three hand you the
//! same thing: bytes. So the loaders stop asking the OS for a path and start asking
//! HERE for bytes, and the three ways in become one:
//!
//!   · the SAMPLE the demo ships with, so it opens full for someone who just clicked a
//!     link and has no catalog of stars in their pocket;
//!   · the file the visitor drops or picks (`zicroOpenFile` in web.zig);
//!   · and, natively, nothing at all — this module is dead code there, because the
//!     comptime guard in each loader never reaches it.
//!
//! `bytes` is borrowed, never owned: it is either a slice of the wasm module's own
//! embedded sample (static) or a buffer JavaScript wrote into and the app keeps. The
//! loaders COPY what they keep.

const std = @import("std");

/// The bytes the next `load` will parse. Empty means the demo has nothing to show yet.
pub var bytes: []const u8 = &.{};

/// What to call it — the loaders that must tell a PDB from an XYZ read the extension,
/// and the HUD prints it as the source. Not a path: nothing will ever open it.
pub var name: []const u8 = "";

pub fn have() bool {
    return bytes.len > 0;
}

/// Hand the module a file. The caller keeps the bytes alive for as long as the demo
/// holds them, which in practice means: until the next one replaces it.
pub fn set(file_name: []const u8, data: []const u8) void {
    name = file_name;
    bytes = data;
}
