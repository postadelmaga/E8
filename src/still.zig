//! A picture, as a slide.
//!
//! A talk is not only its live figure. A photograph of the detector, a scan of
//! the page the theory was written on, a plot someone else made — a deck that
//! cannot hold those makes the author leave the program to show them, and the
//! program has then lost the talk. So a slide may name an image, and when it
//! does, the picture IS the scene: it takes the frame the 3D would have had, the
//! side panel keeps narrating beside it, and the next slide gives the figure back.
//!
//! Decoding is zengine's (stb_image / libwebp: PNG, JPG, TGA, WebP), which the
//! framework already links. The picture is composed into the software frame and
//! presented like any other — a still needs no GPU, and going through the same
//! `presentRgba` path is what keeps it working on the machines that have no
//! Vulkan at all.

const std = @import("std");
const platform = @import("platform.zig");
/// The decoder is zengine's. The WEB build is handed a stub module under the same
/// name (see build.zig): a browser has a decoder of its own, and dragging Vulkan
/// into a tab to reach stb_image would be an odd way to open a PNG.
const ze = @import("zengine");

pub const Still = struct {
    gpa: std.mem.Allocator,
    /// The path this was decoded from — so a slide that names the same picture
    /// as the one on screen does not decode it again.
    path: []u8,
    w: u32,
    h: u32,
    rgba: []u8,

    pub fn deinit(s: *Still) void {
        s.gpa.free(s.path);
        s.gpa.free(s.rgba);
    }
};

pub const max_bytes: usize = 64 << 20;

/// Decode `path` (relative to the working directory, like the deck itself).
pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Still {
    // The `else` keeps the filesystem out of the wasm build's ANALYSIS, not just
    // out of its execution (see deck.zig).
    if (comptime platform.web) {
        return error.NoPicturesInATabYet;
    } else {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_bytes));
        defer gpa.free(bytes);
        var img = try ze.image.decode(gpa, bytes);
        errdefer img.deinit();
        const owned_path = try gpa.dupe(u8, path);
        return .{
            .gpa = gpa,
            .path = owned_path,
            .w = img.width,
            .h = img.height,
            .rgba = img.rgba, // ownership moves to the Still
        };
    }
}

/// Compose the picture into an RGBA framebuffer of `dst_w` × `dst_h`: fitted
/// (aspect preserved), centred, the rest black. Nearest-neighbour on purpose —
/// the alternative is a sampler, and this runs once per frame on a still.
pub fn compose(s: *const Still, dst: []u8, dst_w: u32, dst_h: u32) void {
    @memset(std.mem.bytesAsSlice(u32, dst), 0xFF00_0000);
    if (s.w == 0 or s.h == 0 or dst_w == 0 or dst_h == 0) return;

    // The largest rect with the picture's aspect that fits the frame.
    const sw: u64 = s.w;
    const sh: u64 = s.h;
    var out_w: u32 = dst_w;
    var out_h: u32 = @intCast(@max(1, sh * dst_w / sw));
    if (out_h > dst_h) {
        out_h = dst_h;
        out_w = @intCast(@max(1, sw * dst_h / sh));
    }
    const ox = (dst_w - out_w) / 2;
    const oy = (dst_h - out_h) / 2;

    for (0..out_h) |y| {
        const sy = @min(s.h - 1, @as(u32, @intCast(y * sh / out_h)));
        const src_row = s.rgba[@as(usize, sy) * s.w * 4 ..][0 .. s.w * 4];
        const dst_row = dst[((oy + y) * dst_w + ox) * 4 ..][0 .. out_w * 4];
        for (0..out_w) |x| {
            const sx = @min(s.w - 1, @as(u32, @intCast(x * sw / out_w)));
            const p = src_row[sx * 4 ..][0..4];
            const q = dst_row[x * 4 ..][0..4];
            // The frame is opaque: a transparent picture sits on black, which is
            // what the scene it replaces would have been behind it anyway.
            const a: u32 = p[3];
            q[0] = @intCast(@as(u32, p[0]) * a / 255);
            q[1] = @intCast(@as(u32, p[1]) * a / 255);
            q[2] = @intCast(@as(u32, p[2]) * a / 255);
            q[3] = 255;
        }
    }
}
