//! Data-driven slide decks: the paper journey is authored in ZON, not code.
//! A domain ships `deck.zon` next to its sources (embedded as the default) and
//! the same file is re-read from disk on F5 for hot reload while authoring.

const std = @import("std");

pub const Slide = struct {
    title: []const u8,
    body: []const u8,
    cite: []const u8 = "",
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

/// Load `path` from the working directory, falling back to the embedded
/// default. The returned deck is owned by the caller (free with `deinit`).
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, embedded: [:0]const u8) Deck {
    if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20))) |bytes| {
        defer gpa.free(bytes);
        const z = gpa.dupeZ(u8, bytes) catch return parseOrEmpty(gpa, embedded);
        defer gpa.free(z);
        if (parse(gpa, z)) |d| {
            std.debug.print("deck: loaded {s} ({d} slides)\n", .{ path, d.slides.len });
            return d;
        } else |e| std.debug.print("deck: {s} unparsable ({s}) — using embedded\n", .{ path, @errorName(e) });
    } else |_| {}
    return parseOrEmpty(gpa, embedded);
}

fn parseOrEmpty(gpa: std.mem.Allocator, embedded: [:0]const u8) Deck {
    return parse(gpa, embedded) catch |e| blk: {
        std.debug.print("deck: embedded deck unparsable ({s})\n", .{@errorName(e)});
        break :blk .{};
    };
}
