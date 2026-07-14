//! The other half of `deck.zig`: turning a `Deck` back into ZON text.
//!
//! Reading a deck was always enough, because decks were written by hand. The
//! editor changes that — it holds a deck in memory and has to put it back on disk
//! — and a deck that has been through the editor must still be a file a person
//! wants to open. So this is not a dump: fields at their default are OMITTED (a
//! slide that does not move the camera says nothing about the camera), the slides
//! are laid out one field per line, and strings are escaped the way Zig escapes
//! them, since a body legitimately contains newlines and quotes.
//!
//! The invariant that matters is the ROUND TRIP: parse → write → parse must give
//! the same deck back. The test at the bottom asserts it on a real deck, field by
//! field, because a serializer that silently loses a citation would be worse than
//! no serializer at all.

const std = @import("std");
const deck = @import("deck.zig");

/// Zig's own string escaping — the escapes a ZON parser will read back. UTF-8 goes
/// through untouched (a Zig string literal holds raw bytes), so accented text and
/// the symbols the decks are full of survive as themselves.
fn writeEscaped(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try out.append(gpa, '"');
    try escapeBody(out, gpa, s);
    try out.append(gpa, '"');
}

/// The escaped body of a string literal, without the quotes: what a caller writing
/// its own ZON by hand needs when it interpolates text a person typed. The launcher
/// does exactly that with the demo's name, and a name containing a quote used to
/// produce a .zon file nothing could parse.
pub fn escapeAlloc(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try escapeBody(&out, gpa, s);
    return out.toOwnedSlice(gpa);
}

fn escapeBody(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(gpa, "\\\""),
        '\\' => try out.appendSlice(gpa, "\\\\"),
        '\n' => try out.appendSlice(gpa, "\\n"),
        '\r' => try out.appendSlice(gpa, "\\r"),
        '\t' => try out.appendSlice(gpa, "\\t"),
        else => {
            if (c < 0x20 or c == 0x7f) {
                var buf: [4]u8 = undefined;
                try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{c}) catch unreachable);
            } else try out.append(gpa, c);
        },
    };
}

fn field(out: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8, s: []const u8) !void {
    try out.appendSlice(gpa, "            .");
    try out.appendSlice(gpa, name);
    try out.appendSlice(gpa, " = ");
    try writeEscaped(out, gpa, s);
    try out.appendSlice(gpa, ",\n");
}

/// The deck as ZON source. Caller owns the returned bytes.
pub fn toStringAlloc(gpa: std.mem.Allocator, d: deck.Deck) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa,
        \\// Slide deck. Authored in the editor, or by hand — both end up here, and
        \\// F5 reloads it in a running demo. Names (preset, color, filter, edge, fig)
        \\// are resolved against the domain's own tables at show time.
        \\.{
        \\    .slides = .{
        \\
    );

    var buf: [96]u8 = undefined;
    for (d.slides) |s| {
        try out.appendSlice(gpa, "        .{\n");
        try field(&out, gpa, "title", s.title);
        try field(&out, gpa, "body", s.body);
        if (s.cite.len > 0) try field(&out, gpa, "cite", s.cite);
        // What the slide LOOKS AT: a picture instead of the scene, and the file
        // the points come from. Both absent = the scene, as the demo was opened.
        if (s.image.len > 0) try field(&out, gpa, "image", s.image);
        if (s.data.len > 0) try field(&out, gpa, "data", s.data);
        try field(&out, gpa, "preset", s.preset);
        if (s.color.len > 0) try field(&out, gpa, "color", s.color);
        // "all" is what an absent edge mode means, so only a slide that departs
        // from it needs to say anything.
        if (s.edge.len > 0 and !std.mem.eql(u8, s.edge, "all")) try field(&out, gpa, "edge", s.edge);
        if (s.filter.len > 0) try field(&out, gpa, "filter", s.filter);
        if (s.fig.len > 0) try field(&out, gpa, "fig", s.fig);
        if (s.tumble) try out.appendSlice(gpa, "            .tumble = true,\n");
        if (s.cam) |c| {
            try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "            .cam = .{{ {d:.4}, {d:.4}, {d:.4} }},\n", .{ c[0], c[1], c[2] }) catch unreachable);
        }
        if (s.dwell != 22) {
            try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "            .dwell = {d},\n", .{s.dwell}) catch unreachable);
        }
        try out.appendSlice(gpa, "        },\n");
    }

    try out.appendSlice(gpa,
        \\    },
        \\}
        \\
    );
    return out.toOwnedSlice(gpa);
}

/// Write the deck to `path`. This is what the editor's "save" does, and the file it
/// leaves behind is the demo — there is nothing else to persist.
pub fn save(gpa: std.mem.Allocator, io: std.Io, path: []const u8, d: deck.Deck) !void {
    const src = try toStringAlloc(gpa, d);
    defer gpa.free(src);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = src });
}

// --- tests ------------------------------------------------------------------------------

const testing = std.testing;

test "a deck survives the round trip: parse -> write -> parse" {
    const gpa = testing.allocator;

    // A deck that exercises every field, including the ones that are omitted at
    // their default and the ones that need escaping.
    const src =
        \\.{
        \\    .slides = .{
        \\        .{
        \\            .title = "The metric breaks: a \"light cone\" opens",
        \\            .body = "One line.\nAnd another — with an em dash, ℓ = Σwₐ/3, and a backslash \\ in it.",
        \\            .cite = "DHN, PRL 89 (2002) 221601.",
        \\            .preset = "light cone",
        \\            .color = "Lorentzian vs Euclidean",
        \\            .filter = "+ the dual graviton — all 1470",
        \\            .edge = "off",
        \\            .tumble = true,
        \\            .cam = .{ 0.4, 0.5, 7.0 },
        \\            .dwell = 30,
        \\            .fig = "levels",
        \\        },
        \\        .{
        \\            .title = "A picture, and a different molecule",
        \\            .body = "The slide that looks at something else.",
        \\            .image = "figures/detector.png",
        \\            .data = "molecules/caffeine.pdb",
        \\            .preset = "E8 core",
        \\        },
        \\        .{
        \\            .title = "A slide that leans on every default",
        \\            .body = "No cite, no color, no filter, no fig, no cam, edge stays all, dwell stays 22.",
        \\            .preset = "E8 core",
        \\        },
        \\    },
        \\}
    ;

    const a = try deck.parse(gpa, src);
    defer deck.deinit(gpa, a);

    const written = try toStringAlloc(gpa, a);
    defer gpa.free(written);
    const z = try gpa.dupeZ(u8, written);
    defer gpa.free(z);

    const b = try deck.parse(gpa, z);
    defer deck.deinit(gpa, b);

    try testing.expectEqual(a.slides.len, b.slides.len);
    for (a.slides, b.slides) |x, y| {
        try testing.expectEqualStrings(x.title, y.title);
        try testing.expectEqualStrings(x.body, y.body);
        try testing.expectEqualStrings(x.cite, y.cite);
        try testing.expectEqualStrings(x.image, y.image);
        try testing.expectEqualStrings(x.data, y.data);
        try testing.expectEqualStrings(x.preset, y.preset);
        try testing.expectEqualStrings(x.color, y.color);
        try testing.expectEqualStrings(x.filter, y.filter);
        try testing.expectEqualStrings(x.fig, y.fig);
        try testing.expectEqual(x.tumble, y.tumble);
        try testing.expectEqual(x.dwell, y.dwell);
        try testing.expectEqual(x.cam == null, y.cam == null);
        if (x.cam) |c| for (c, y.cam.?) |u, v| try testing.expectApproxEqAbs(u, v, 1e-3);
    }

    // The defaults really are omitted — the file stays one a person would write.
    try testing.expect(std.mem.indexOf(u8, written, ".dwell = 30") != null);
    try testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, written, ".dwell = 22"));
    try testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, written, ".edge = \"all\""));
    try testing.expect(std.mem.indexOf(u8, written, ".edge = \"off\"") != null);
}

test "the M-theory deck, the real one, round-trips" {
    const gpa = testing.allocator;
    const src = @embedFile("demos/mtheory/deck.zon");

    const a = try deck.parse(gpa, src);
    defer deck.deinit(gpa, a);
    try testing.expect(a.slides.len >= 7);

    const written = try toStringAlloc(gpa, a);
    defer gpa.free(written);
    const z = try gpa.dupeZ(u8, written);
    defer gpa.free(z);

    const b = try deck.parse(gpa, z);
    defer deck.deinit(gpa, b);

    try testing.expectEqual(a.slides.len, b.slides.len);
    for (a.slides, b.slides) |x, y| {
        try testing.expectEqualStrings(x.title, y.title);
        try testing.expectEqualStrings(x.body, y.body); // the long ones, with their newlines
        try testing.expectEqualStrings(x.cite, y.cite);
        try testing.expectEqualStrings(x.preset, y.preset);
        try testing.expectEqualStrings(x.filter, y.filter);
    }
}
