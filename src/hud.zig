//! On-window overlay for the E8 explorer, drawn with zrame's text engine —
//! adapted from zengine's examples/hud.zig (same threading contract).
//!
//! The presented frame is a subsurface stacked above the glass, so the window is
//! opened taller than the frame and the video sits centered: a glass band stays
//! free at the top (two text rows: FPS+status, selection detail) and one at the
//! bottom (the class legend). The render thread pushes strings through a short
//! spinlock; the window thread reads them in `onDraw`.

const std = @import("std");
const zrame = @import("zrame");

const Spin = struct {
    held: std.atomic.Value(bool) = .init(false),
    fn lock(self: *Spin) void {
        while (self.held.swap(true, .acquire)) std.atomic.spinLoopHint();
    }
    fn tryLock(self: *Spin) bool {
        return !self.held.swap(true, .acquire);
    }
    fn unlock(self: *Spin) void {
        self.held.store(false, .release);
    }
};

pub const LegendItem = struct {
    rgb: [3]u8 = .{ 255, 255, 255 },
    label: [24]u8 = undefined,
    len: usize = 0,
};

pub const Hud = struct {
    /// Wired AFTER `Window.init` returns (init dispatches an initial redraw).
    win: ?*zrame.Window = null,
    /// Live content size, learned from every redraw (window thread writes,
    /// render thread reads) — the hook the adaptive CPU render sizes off.
    content_w: std.atomic.Value(u32) = .init(0),
    content_h: std.atomic.Value(u32) = .init(0),
    ms_bits: std.atomic.Value(u32) = .init(0),
    last_ns: i128 = 0,
    ema_ms: f32 = 0,

    lock: Spin = .{},
    line1: [160]u8 = undefined,
    len1: usize = 0,
    line2: [200]u8 = undefined,
    len2: usize = 0,
    legend: [10]LegendItem = undefined,
    n_legend: usize = 0,

    pub fn tick(self: *Hud, now_ns: i128) void {
        defer self.last_ns = now_ns;
        if (self.last_ns == 0) return;
        const dt_ms: f32 = @as(f32, @floatFromInt(now_ns - self.last_ns)) / 1.0e6;
        self.ema_ms = if (self.ema_ms == 0) dt_ms else self.ema_ms * 0.8 + dt_ms * 0.2;
        self.ms_bits.store(@bitCast(self.ema_ms), .monotonic);
    }

    pub fn setLine1(self: *Hud, s: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        const n = @min(s.len, self.line1.len);
        @memcpy(self.line1[0..n], s[0..n]);
        self.len1 = n;
    }

    pub fn setLine2(self: *Hud, s: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        const n = @min(s.len, self.line2.len);
        @memcpy(self.line2[0..n], s[0..n]);
        self.len2 = n;
    }

    pub const LegendIn = struct { rgb: [3]u8, label: []const u8 };

    pub fn setLegend(self: *Hud, items: []const LegendIn) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.n_legend = @min(items.len, self.legend.len);
        for (items[0..self.n_legend], self.legend[0..self.n_legend]) |src, *dst| {
            dst.rgb = src.rgb;
            dst.len = @min(src.label.len, dst.label.len);
            @memcpy(dst.label[0..dst.len], src.label[0..dst.len]);
        }
    }

    pub fn onDraw(canvas: *zrame.Canvas, content: zrame.Rect, user: ?*anyopaque) void {
        const self: *Hud = @ptrCast(@alignCast(user.?));
        self.content_w.store(content.w, .monotonic);
        self.content_h.store(content.h, .monotonic);
        const win = self.win orelse return;
        const ms: f32 = @bitCast(self.ms_bits.load(.monotonic));
        const font = win.textFont() catch return;

        var fbuf: [48]u8 = undefined;
        const fps: f32 = if (ms > 0.001) 1000.0 / ms else 0;
        const fps_str = std.fmt.bufPrint(&fbuf, "{d:.0} FPS", .{fps}) catch return;

        // Snapshot under the spinlock; skip a frame of detail rather than block.
        var l1: [160]u8 = undefined;
        var l2: [200]u8 = undefined;
        var leg: [10]LegendItem = undefined;
        var n1: usize = 0;
        var n2: usize = 0;
        var nl: usize = 0;
        if (self.lock.tryLock()) {
            n1 = self.len1;
            n2 = self.len2;
            nl = self.n_legend;
            @memcpy(l1[0..n1], self.line1[0..n1]);
            @memcpy(l2[0..n2], self.line2[0..n2]);
            @memcpy(leg[0..nl], self.legend[0..nl]);
            self.lock.unlock();
        }

        const x0: i32 = @intCast(content.x + 16);
        const base1: i32 = @intCast(content.y + 22);
        const base2: i32 = @intCast(content.y + 44);
        const w_fps = font.measure(16, .bold, fps_str);

        canvas.drawText(font, x0, base1, fps_str, .{
            .size = 16,
            .style = .bold,
            .color = zrame.Color.rgba(120, 230, 160, 1.0),
        });
        if (n1 > 0) canvas.drawText(font, x0 + w_fps + 14, base1, l1[0..n1], .{
            .size = 15,
            .style = .regular,
            .color = zrame.Color.rgba(200, 206, 214, 0.92),
        });
        if (n2 > 0) canvas.drawText(font, x0, base2, l2[0..n2], .{
            .size = 15,
            .style = .regular,
            .color = zrame.Color.rgba(235, 220, 160, 0.95),
        });

        // Legend row along the bottom band: colored dot + label per class.
        if (nl > 0) {
            var lx: i32 = x0;
            const ly: i32 = @as(i32, @intCast(content.y)) + @as(i32, @intCast(content.h)) - 20;
            for (leg[0..nl]) |*item| {
                canvas.fillRoundedRect(
                    @floatFromInt(lx),
                    @floatFromInt(ly - 9),
                    9,
                    9,
                    4.5,
                    zrame.Color.rgba(item.rgb[0], item.rgb[1], item.rgb[2], 1.0),
                );
                const label = item.label[0..item.len];
                canvas.drawText(font, lx + 14, ly, label, .{
                    .size = 13,
                    .style = .regular,
                    .color = zrame.Color.rgba(190, 196, 206, 0.9),
                });
                lx += 14 + font.measure(13, .regular, label) + 18;
            }
        }
    }
};
