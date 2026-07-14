//! zengine, as a browser tab knows it — which is to say, its shape and nothing
//! else. The web build imports this under the name `zengine` (see build.zig), so
//! the files that mention the engine compile there without it.
//!
//! The engine is Vulkan: a hand-rolled FFI, a cluster raster, bloom, a virtual
//! texture cache. None of that reaches a tab, and the framework does not need it
//! to — the figure is rasterized by `render_cpu.zig`, which is pure Zig. What is
//! left is the image decoder, which `still.zig` calls for picture slides; a
//! browser already has one of those, so when the web build wants pictures the
//! decode belongs on the JS side. Until then it says so, in the only way it can.

const std = @import("std");

pub const image = struct {
    pub const DecodeError = error{ UnsupportedImage, ImageTooLarge } || std.mem.Allocator.Error;

    pub const Image = struct {
        gpa: std.mem.Allocator,
        width: u32,
        height: u32,
        rgba: []u8,

        pub fn deinit(self: *Image) void {
            self.gpa.free(self.rgba);
        }
    };

    pub fn decode(_: std.mem.Allocator, _: []const u8) DecodeError!Image {
        return error.UnsupportedImage;
    }
};
