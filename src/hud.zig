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

/// One dot of the panel's inline figure (a 2D weight/root diagram), in
/// normalized coordinates: x, y ∈ [-1, 1], y up.
pub const FigDot = struct { x: f32, y: f32, rgb: [3]u8 };

pub const Hud = struct {
    /// Wired AFTER `Window.init` returns (init dispatches an initial redraw).
    win: ?*zrame.Window = null,
    /// Live content size, learned from every redraw (window thread writes,
    /// render thread reads) — the hook the adaptive CPU render sizes off.
    content_w: std.atomic.Value(u32) = .init(0),
    content_h: std.atomic.Value(u32) = .init(0),
    /// Size of the presented video frame (render thread writes) — lets the
    /// panel find the glass band to the right of the centered frame.
    frame_w: std.atomic.Value(u32) = .init(0),
    frame_h: std.atomic.Value(u32) = .init(0),
    /// Side panel visibility (render thread writes, window thread reads).
    panel_on: std.atomic.Value(bool) = .init(false),
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
    p_title: [96]u8 = undefined,
    p_title_len: usize = 0,
    p_body: [720]u8 = undefined,
    p_body_len: usize = 0,
    p_cite: [256]u8 = undefined,
    p_cite_len: usize = 0,
    p_fig: [72]FigDot = undefined,
    p_fig_len: usize = 0,

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

    /// Side-panel content: title, body (paragraphs split on '\n', word-wrapped
    /// at draw time), and the paper citations drawn dimmer underneath.
    pub fn setPanel(self: *Hud, title: []const u8, body: []const u8, cite: []const u8) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.p_title_len = @min(title.len, self.p_title.len);
        @memcpy(self.p_title[0..self.p_title_len], title[0..self.p_title_len]);
        self.p_body_len = @min(body.len, self.p_body.len);
        @memcpy(self.p_body[0..self.p_body_len], body[0..self.p_body_len]);
        self.p_cite_len = @min(cite.len, self.p_cite.len);
        @memcpy(self.p_cite[0..self.p_cite_len], cite[0..self.p_cite_len]);
        self.p_fig_len = 0; // a new panel page clears the figure
    }

    /// Inline 2D diagram drawn under the panel citation (weight diagrams,
    /// root projections). Call after `setPanel`.
    pub fn setPanelFigure(self: *Hud, dots: []const FigDot) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.p_fig_len = @min(dots.len, self.p_fig.len);
        @memcpy(self.p_fig[0..self.p_fig_len], dots[0..self.p_fig_len]);
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

    /// Draw `txt` word-wrapped in a column `w` px wide starting at baseline
    /// `y0`; paragraphs split on '\n'. Returns the baseline after the last line.
    pub fn drawWrapped(
        canvas: *zrame.Canvas,
        font: anytype,
        x: i32,
        y0: i32,
        w: i32,
        comptime size: comptime_int,
        comptime style: @TypeOf(.enum_literal),
        color: zrame.Color,
        txt: []const u8,
        line_h: i32,
    ) i32 {
        var y = y0;
        var paras = std.mem.splitScalar(u8, txt, '\n');
        while (paras.next()) |para| {
            if (para.len == 0) {
                y += @divTrunc(line_h, 2);
                continue;
            }
            var words = std.mem.tokenizeScalar(u8, para, ' ');
            var line_start: ?usize = null;
            var line_end: usize = 0;
            while (words.next()) |word| {
                const ws = @intFromPtr(word.ptr) - @intFromPtr(para.ptr);
                const we = ws + word.len;
                if (line_start == null) {
                    line_start = ws;
                    line_end = we;
                    continue;
                }
                if (font.measure(size, style, para[line_start.?..we]) <= w) {
                    line_end = we;
                } else {
                    canvas.drawText(font, x, y, para[line_start.?..line_end], .{
                        .size = size,
                        .style = style,
                        .color = color,
                    });
                    y += line_h;
                    line_start = ws;
                    line_end = we;
                }
            }
            if (line_start) |ls| {
                canvas.drawText(font, x, y, para[ls..line_end], .{
                    .size = size,
                    .style = style,
                    .color = color,
                });
                y += line_h;
            }
        }
        return y;
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
        var pt: [96]u8 = undefined;
        var pb: [720]u8 = undefined;
        var pc: [256]u8 = undefined;
        var pf: [72]FigDot = undefined;
        var n1: usize = 0;
        var n2: usize = 0;
        var nl: usize = 0;
        var npt: usize = 0;
        var npb: usize = 0;
        var npc: usize = 0;
        var npf: usize = 0;
        if (self.lock.tryLock()) {
            n1 = self.len1;
            n2 = self.len2;
            nl = self.n_legend;
            npt = self.p_title_len;
            npb = self.p_body_len;
            npc = self.p_cite_len;
            npf = self.p_fig_len;
            @memcpy(l1[0..n1], self.line1[0..n1]);
            @memcpy(l2[0..n2], self.line2[0..n2]);
            @memcpy(leg[0..nl], self.legend[0..nl]);
            @memcpy(pt[0..npt], self.p_title[0..npt]);
            @memcpy(pb[0..npb], self.p_body[0..npb]);
            @memcpy(pc[0..npc], self.p_cite[0..npc]);
            @memcpy(pf[0..npf], self.p_fig[0..npf]);
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

        // Side panel: the glass band to the right of the centered video frame
        // (same centering math as chrome.frameOrigin).
        if (self.panel_on.load(.monotonic) and npt > 0) {
            const fw = @min(self.frame_w.load(.monotonic), content.w);
            const ox = content.x + (content.w - fw) / 2;
            const px: i32 = @intCast(ox + fw + 16);
            const pw: i32 = @as(i32, @intCast(content.x + content.w)) -| px - 14;
            if (pw >= 140) {
                const top: i32 = @intCast(content.y + 78);
                canvas.fillRoundedRect(
                    @floatFromInt(px - 10),
                    @floatFromInt(top - 16),
                    2,
                    @floatFromInt(@max(@as(i32, @intCast(content.h)) - 140, 40)),
                    1,
                    zrame.Color.rgba(120, 140, 180, 0.35),
                );
                var y = drawWrapped(canvas, font, px, top, pw, 15, .bold, zrame.Color.rgba(235, 220, 160, 0.95), pt[0..npt], 20);
                y += 8;
                y = drawWrapped(canvas, font, px, y, pw, 13, .regular, zrame.Color.rgba(202, 208, 216, 0.92), pb[0..npb], 18);
                y += 10;
                y = drawWrapped(canvas, font, px, y, pw, 12, .regular, zrame.Color.rgba(150, 180, 230, 0.88), pc[0..npc], 16);
                // Inline figure: a boxed 2D diagram (weights, root projections).
                if (npf > 0) {
                    y += 12;
                    const fig_w: f32 = @floatFromInt(@min(pw - 8, 220));
                    const fig_h: f32 = fig_w * 0.72;
                    const fx: f32 = @floatFromInt(px);
                    const fy: f32 = @floatFromInt(y);
                    canvas.fillRoundedRect(fx, fy, fig_w, fig_h, 8, zrame.Color.rgba(16, 20, 34, 0.55));
                    for (pf[0..npf]) |d| {
                        const dx = fx + (d.x * 0.44 + 0.5) * fig_w - 3;
                        const dy = fy + (0.5 - d.y * 0.44) * fig_h - 3;
                        canvas.fillRoundedRect(dx, dy, 6, 6, 3, zrame.Color.rgba(d.rgb[0], d.rgb[1], d.rgb[2], 0.95));
                    }
                }
            }
        }

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
