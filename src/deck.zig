//! Data-driven slide decks: the paper journey is authored in ZON, not code.
//! A domain ships `deck.zon` next to its sources (embedded as the default) and
//! the same file is re-read from disk on F5 for hot reload while authoring.

const std = @import("std");
const log = @import("log.zig");
const hud_mod = @import("hud.zig");
const platform = @import("platform.zig");

pub const Slide = struct {
    title: []const u8,
    body: []const u8,
    cite: []const u8 = "",
    /// A picture, instead of the figure: the image takes the scene's frame and
    /// the panel keeps narrating beside it (see src/still.zig). Empty = the
    /// scene, as always.
    image: []const u8 = "",
    /// The FILE this slide's points come from — a different molecule, a different
    /// catalog — for a domain that reads one. Empty = whatever the demo was
    /// opened with, unchanged. Switching costs a reload of the point system, so
    /// it happens only when the name actually differs from what is loaded.
    data: []const u8 = "",
    /// Names resolved against the domain's tables at show time.
    preset: []const u8,
    color: []const u8 = "",
    /// Empty means "all" — the default is the empty string, NOT the word, because
    /// `std.zon.parse.free` frees every string field it can see and a non-empty
    /// default is a static literal it must not touch. An omitted `.edge` used to
    /// crash the deinit; now it simply means "show every edge" (see slides.show).
    edge: []const u8 = "",
    filter: []const u8 = "",
    tumble: bool = false,
    /// Camera target (yaw, pitch, dist), eased in.
    cam: ?[3]f32 = null,
    /// Kiosk dwell, seconds.
    dwell: f32 = 22,
    /// Domain figure id ("" = none) for the inline panel diagram.
    fig: []const u8 = "",
};

pub const Deck = struct {
    slides: []const Slide = &.{},
};

/// Parse a deck from ZON source (embedded or freshly read from disk). The Deck
/// holds slices, so the allocating variant is the right one.
pub fn parse(gpa: std.mem.Allocator, src: [:0]const u8) !Deck {
    return std.zon.parse.fromSliceAlloc(Deck, gpa, src, null, .{ .ignore_unknown_fields = true });
}

pub fn deinit(gpa: std.mem.Allocator, d: Deck) void {
    std.zon.parse.free(gpa, d);
}

/// What `loadEx` has to say about where the deck came from — the caller (F5,
/// startup) surfaces it on the HUD, because a hand-edited deck that silently
/// reverts to the embedded slides looks like the edit was ignored.
pub const Loaded = struct {
    deck: Deck,
    /// Set when `path` existed but would not parse (the embedded deck plays).
    parse_err: ?anyerror = null,
};

/// Load `path` from the working directory, falling back to the embedded
/// default. The returned deck is owned by the caller (free with `deinit`).
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, embedded: [:0]const u8) Deck {
    return loadEx(gpa, io, path, embedded).deck;
}

pub fn loadEx(gpa: std.mem.Allocator, io: std.Io, path: []const u8, embedded: [:0]const u8) Loaded {
    // A browser tab has no working directory: the deck it plays is the one
    // compiled into it, which is also the one the author shipped. The `else` is
    // not decoration — a comptime-known condition means the branch not taken is
    // never ANALYZED, and that is what keeps std.Io.Dir (and posix under it) out
    // of a wasm build entirely.
    if (comptime platform.web) {
        return .{ .deck = parseOrEmpty(gpa, embedded) };
    } else {
        if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20))) |bytes| {
            defer gpa.free(bytes);
            const z = gpa.dupeZ(u8, bytes) catch return .{ .deck = parseOrEmpty(gpa, embedded) };
            defer gpa.free(z);
            if (parse(gpa, z)) |d| {
                log.print("deck: loaded {s} ({d} slides)\n", .{ path, d.slides.len });
                warnLongBodies(path, d);
                return .{ .deck = d };
            } else |e| {
                log.print("deck: {s} unparsable ({s}) — using embedded\n", .{ path, @errorName(e) });
                return .{ .deck = parseOrEmpty(gpa, embedded), .parse_err = e };
            }
        } else |_| {}
        return .{ .deck = parseOrEmpty(gpa, embedded) };
    }
}

/// The panel cuts a body at `hud.panel_body_max` (with a visible mark) — tell
/// the author at load time, when it can still be fixed before the talk.
fn warnLongBodies(path: []const u8, d: Deck) void {
    for (d.slides, 0..) |s, i| {
        if (s.body.len > hud_mod.panel_body_max) log.print(
            "deck: {s} slide {d} (\"{s}\") body is {d} bytes — the panel shows the first {d}\n",
            .{ path, i + 1, s.title, s.body.len, hud_mod.panel_body_max },
        );
    }
}

fn parseOrEmpty(gpa: std.mem.Allocator, embedded: [:0]const u8) Deck {
    return parse(gpa, embedded) catch |e| blk: {
        log.print("deck: embedded deck unparsable ({s})\n", .{@errorName(e)});
        break :blk .{};
    };
}
