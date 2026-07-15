//! Pictures a browser decoded, kept by name — the tab's answer to a slide that shows
//! an image instead of the scene.
//!
//! Natively a slide's `image = "detector.png"` is a file, and `still.zig` decodes it
//! with zengine's stb_image. A tab has neither the file nor stb_image — but it has a
//! decoder of its own, the one the browser already ships. So the page decodes the
//! picture to RGBA and registers it HERE under the name the slide will ask for, and
//! `still.load` looks it up instead of reaching for a filesystem that is not there.
//!
//! A deck can name several images (one per slide), so this is a small map, not the
//! single slot the data file uses. The bytes are owned here and COPIED to each `Still`,
//! because a `Still` frees its own `rgba` when the slide leaves.

const std = @import("std");

pub const Image = struct {
    w: u32,
    h: u32,
    rgba: []u8,
};

var gpa: std.mem.Allocator = undefined;
var map: std.StringHashMapUnmanaged(Image) = .{};
var ready = false;

pub fn init(allocator: std.mem.Allocator) void {
    gpa = allocator;
    ready = true;
}

/// Register (or replace) the picture the page decoded. Name and pixels are copied, so
/// the caller keeps nothing alive on our behalf.
pub fn put(name: []const u8, w: u32, h: u32, rgba: []const u8) !void {
    if (!ready) return error.NotReady;
    if (rgba.len != @as(usize, w) * h * 4) return error.BadSize;

    const key = try gpa.dupe(u8, name);
    errdefer gpa.free(key);
    const pixels = try gpa.dupe(u8, rgba);
    errdefer gpa.free(pixels);

    if (map.fetchRemove(key)) |old| {
        gpa.free(old.key);
        gpa.free(old.value.rgba);
    }
    try map.put(gpa, key, .{ .w = w, .h = h, .rgba = pixels });
}

pub fn get(name: []const u8) ?Image {
    if (!ready) return null;
    return map.get(name);
}
