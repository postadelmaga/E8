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

/// How much slide/story prose the side panel can hold. A longer body is cut at
/// a UTF-8 boundary and marked with an ellipsis (see `setPanel`); deck loading
/// warns about it, so an author finds out at F5 time, not mid-talk.
pub const panel_body_max: usize = 2048;

/// One dot of the point card's little diagram — same normalized coordinates as
/// `FigDot`, with a size and an alpha, so a domain can sketch a neighbourhood.
pub const CardDot = struct { x: f32, y: f32, r: f32, rgb: [3]u8, a: f32 = 1.0 };

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
    /// Width the window keeps for the panel on the right of the content (the
    /// same gutter it was handed via `reserveGutter`): the frame centers in the
    /// content MINUS this, so the panel band starts where the frame ends.
    gutter: std.atomic.Value(u32) = .init(0),
    ms_bits: std.atomic.Value(u32) = .init(0),
    last_ns: i128 = 0,
    ema_ms: f32 = 0,

    lock: Spin = .{},
    line1: [256]u8 = undefined,
    len1: usize = 0,
    line2: [200]u8 = undefined,
    len2: usize = 0,
    /// A transient message ("exported…", "journey paused"), drawn as its own
    /// centered pill and cleared by `tick` when its time is up. It used to be
    /// pushed through `line2`, where it clobbered the selection detail and then
    /// sat on screen forever.
    toast_txt: [200]u8 = undefined,
    toast_len: usize = 0,
    /// Deadline in render-thread time; written by `toast`, read by `tick` —
    /// both on the render thread, so it needs no lock.
    toast_until: i128 = 0,
    legend: [10]LegendItem = undefined,
    n_legend: usize = 0,
    p_title: [96]u8 = undefined,
    p_title_len: usize = 0,
    p_body: [panel_body_max]u8 = undefined,
    p_body_len: usize = 0,
    p_cite: [256]u8 = undefined,
    p_cite_len: usize = 0,
    p_fig: [72]FigDot = undefined,
    p_fig_len: usize = 0,

    /// The point card: what you get when you click a point. It used to be a second
    /// TOPLEVEL WINDOW — a popup opening and closing on every click, which is a
    /// window transition where the user asked a question about a dot. Now it is a
    /// card drawn on this window's own glass, over the scene: no new surface, no
    /// second render path, no focus change. Written by the inspector plugin when
    /// the selection changes; the HUD only draws it.
    card_on: std.atomic.Value(bool) = .init(false),
    card_title: [96]u8 = undefined,
    card_title_len: usize = 0,
    card_body: [512]u8 = undefined,
    card_body_len: usize = 0,
    card_dots: [72]CardDot = undefined,
    card_dots_len: usize = 0,

    /// The shortcut card (H). Its text is built once, at startup, from `keys.zig`
    /// and the domain's own actions — the HUD only draws it.
    /// One row per line, key and description split by a tab.
    help_on: std.atomic.Value(bool) = .init(false),
    help_txt: [2400]u8 = undefined,
    help_len: usize = 0,
    /// The strip drawn over the scene at all times: the keys someone who has never
    /// seen this program needs in order to get anywhere.
    guide: [160]u8 = undefined,
    guide_len: usize = 0,

    pub fn tick(self: *Hud, now_ns: i128) void {
        defer self.last_ns = now_ns;
        if (self.toast_until != 0 and now_ns >= self.toast_until) {
            self.toast_until = 0;
            self.lock.lock();
            self.toast_len = 0;
            self.lock.unlock();
            self.dirty();
        }
        if (self.last_ns == 0) return;
        const dt_ms: f32 = @as(f32, @floatFromInt(now_ns - self.last_ns)) / 1.0e6;
        self.ema_ms = if (self.ema_ms == 0) dt_ms else self.ema_ms * 0.8 + dt_ms * 0.2;
        self.ms_bits.store(@bitCast(self.ema_ms), .monotonic);
    }

    /// Show `s` for `secs` seconds, then clear it. Render thread only (it
    /// reads the clock `tick` keeps).
    pub fn toast(self: *Hud, s: []const u8, secs: f32) void {
        defer self.dirty();
        self.toast_until = self.last_ns + @as(i128, @intFromFloat(secs * 1.0e9));
        self.lock.lock();
        defer self.lock.unlock();
        const n = @min(s.len, self.toast_txt.len);
        @memcpy(self.toast_txt[0..n], s[0..n]);
        self.toast_len = n;
    }

    /// Every HUD write lands OUTSIDE the presented frame (status lines above it,
    /// the panel beside it, the legend below): a staged frame only damages the
    /// frame's own rect, so the window has to be told the overlay changed or the
    /// text freezes on its last full paint while the figure keeps moving.
    fn dirty(self: *Hud) void {
        if (self.win) |w| w.invalidate();
    }

    pub fn setLine1(self: *Hud, s: []const u8) void {
        defer self.dirty();
        self.lock.lock();
        defer self.lock.unlock();
        const n = @min(s.len, self.line1.len);
        @memcpy(self.line1[0..n], s[0..n]);
        self.len1 = n;
    }

    pub fn setLine2(self: *Hud, s: []const u8) void {
        defer self.dirty();
        self.lock.lock();
        defer self.lock.unlock();
        const n = @min(s.len, self.line2.len);
        @memcpy(self.line2[0..n], s[0..n]);
        self.len2 = n;
    }

    /// Side-panel content: title, body (paragraphs split on '\n', word-wrapped
    /// at draw time), and the paper citations drawn dimmer underneath.
    pub fn setPanel(self: *Hud, title: []const u8, body: []const u8, cite: []const u8) void {
        defer self.dirty();
        self.lock.lock();
        defer self.lock.unlock();
        self.p_title_len = @min(title.len, self.p_title.len);
        @memcpy(self.p_title[0..self.p_title_len], title[0..self.p_title_len]);
        if (body.len <= self.p_body.len) {
            self.p_body_len = body.len;
            @memcpy(self.p_body[0..body.len], body);
        } else {
            // Cut at a UTF-8 boundary and say so — silent truncation once ate
            // half a slide mid-sentence.
            const mark = " […]";
            var n = self.p_body.len - mark.len;
            while (n > 0 and (body[n] & 0xC0) == 0x80) n -= 1;
            @memcpy(self.p_body[0..n], body[0..n]);
            @memcpy(self.p_body[n..][0..mark.len], mark);
            self.p_body_len = n + mark.len;
        }
        self.p_cite_len = @min(cite.len, self.p_cite.len);
        @memcpy(self.p_cite[0..self.p_cite_len], cite[0..self.p_cite_len]);
        self.p_fig_len = 0; // a new panel page clears the figure
    }

    /// Inline 2D diagram drawn under the panel citation (weight diagrams,
    /// root projections). Call after `setPanel`.
    pub fn setPanelFigure(self: *Hud, dots: []const FigDot) void {
        defer self.dirty();
        self.lock.lock();
        defer self.lock.unlock();
        self.p_fig_len = @min(dots.len, self.p_fig.len);
        @memcpy(self.p_fig[0..self.p_fig_len], dots[0..self.p_fig_len]);
    }

    /// The point card's content. `dots` is optional (a domain diagram of the
    /// selection's neighbourhood); pass an empty slice for text only.
    pub fn setCard(self: *Hud, title: []const u8, body: []const u8, dots: []const CardDot) void {
        defer self.dirty();
        self.lock.lock();
        defer self.lock.unlock();
        self.card_title_len = @min(title.len, self.card_title.len);
        @memcpy(self.card_title[0..self.card_title_len], title[0..self.card_title_len]);
        self.card_body_len = @min(body.len, self.card_body.len);
        @memcpy(self.card_body[0..self.card_body_len], body[0..self.card_body_len]);
        self.card_dots_len = @min(dots.len, self.card_dots.len);
        @memcpy(self.card_dots[0..self.card_dots_len], dots[0..self.card_dots_len]);
    }

    pub fn setCardOn(self: *Hud, on: bool) void {
        if (self.card_on.swap(on, .monotonic) == on) return;
        self.dirty();
    }

    pub fn cardOn(self: *const Hud) bool {
        return self.card_on.load(.monotonic);
    }

    /// The shortcut card's text (rows of "keys\tdescription") and the always-on
    /// guide strip. Written once at startup by the `guide` plugin.
    pub fn setHelp(self: *Hud, rows: []const u8, strip: []const u8) void {
        defer self.dirty();
        self.lock.lock();
        defer self.lock.unlock();
        self.help_len = @min(rows.len, self.help_txt.len);
        @memcpy(self.help_txt[0..self.help_len], rows[0..self.help_len]);
        self.guide_len = @min(strip.len, self.guide.len);
        @memcpy(self.guide[0..self.guide_len], strip[0..self.guide_len]);
    }

    pub fn helpOn(self: *const Hud) bool {
        return self.help_on.load(.monotonic);
    }

    pub fn setHelpOn(self: *Hud, on: bool) void {
        self.help_on.store(on, .monotonic);
        self.dirty();
    }

    pub const LegendIn = struct { rgb: [3]u8, label: []const u8 };

    pub fn setLegend(self: *Hud, items: []const LegendIn) void {
        defer self.dirty();
        self.lock.lock();
        defer self.lock.unlock();
        self.n_legend = @min(items.len, self.legend.len);
        for (items[0..self.n_legend], self.legend[0..self.n_legend]) |src, *dst| {
            dst.rgb = src.rgb;
            dst.len = @min(src.label.len, dst.label.len);
            @memcpy(dst.label[0..dst.len], src.label[0..dst.len]);
        }
    }

    /// Height the wrapped `txt` would take — the same walk as `drawWrapped`
    /// with nothing painted, so a caller can lay a block out before drawing it.
    pub fn wrappedHeight(
        font: anytype,
        w: i32,
        comptime size: comptime_int,
        comptime style: @TypeOf(.enum_literal),
        txt: []const u8,
        line_h: i32,
    ) i32 {
        return drawWrapped(null, font, 0, 0, w, size, style, zrame.Color.rgba(0, 0, 0, 0), txt, line_h);
    }

    /// Draw `txt` word-wrapped in a column `w` px wide starting at baseline
    /// `y0`; paragraphs split on '\n'. Returns the baseline after the last line.
    /// A null canvas measures without painting (see `wrappedHeight`).
    pub fn drawWrapped(
        canvas: ?*zrame.Canvas,
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
                    if (canvas) |c| c.drawText(font, x, y, para[line_start.?..line_end], .{
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
                if (canvas) |c| c.drawText(font, x, y, para[ls..line_end], .{
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
        var l1: [256]u8 = undefined;
        var l2: [200]u8 = undefined;
        var tt: [200]u8 = undefined;
        var leg: [10]LegendItem = undefined;
        var pt: [96]u8 = undefined;
        var pb: [panel_body_max]u8 = undefined;
        var pc: [256]u8 = undefined;
        var pf: [72]FigDot = undefined;
        var n1: usize = 0;
        var n2: usize = 0;
        var ntt: usize = 0;
        var nl: usize = 0;
        var npt: usize = 0;
        var npb: usize = 0;
        var npc: usize = 0;
        var npf: usize = 0;
        if (self.lock.tryLock()) {
            n1 = self.len1;
            n2 = self.len2;
            ntt = self.toast_len;
            nl = self.n_legend;
            npt = self.p_title_len;
            npb = self.p_body_len;
            npc = self.p_cite_len;
            npf = self.p_fig_len;
            @memcpy(l1[0..n1], self.line1[0..n1]);
            @memcpy(l2[0..n2], self.line2[0..n2]);
            @memcpy(tt[0..ntt], self.toast_txt[0..ntt]);
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

        // No clock has ticked yet → "0 FPS" would be a lie; show nothing instead.
        var l1_x = x0;
        if (ms > 0.001) {
            canvas.drawText(font, x0, base1, fps_str, .{
                .size = 16,
                .style = .bold,
                .color = zrame.Color.rgba(120, 230, 160, 1.0),
            });
            l1_x += font.measure(16, .bold, fps_str) + 14;
        }
        if (n1 > 0) canvas.drawText(font, l1_x, base1, l1[0..n1], .{
            .size = 15,
            .style = .regular,
            .color = zrame.Color.rgba(200, 206, 214, 0.92),
        });
        if (n2 > 0) canvas.drawText(font, x0, base2, l2[0..n2], .{
            .size = 15,
            .style = .regular,
            .color = zrame.Color.rgba(235, 220, 160, 0.95),
        });

        // The toast: its own centered pill, so it neither fights the selection
        // detail for `line2` nor outstays its welcome (`tick` clears it).
        if (ntt > 0) {
            const t = tt[0..ntt];
            const tw = font.measure(15, .regular, t);
            const tx = @as(i32, @intCast(content.x)) + @divTrunc(@as(i32, @intCast(content.w)) - tw, 2);
            const ty: i32 = @intCast(content.y + 76);
            canvas.fillRoundedRect(
                @floatFromInt(tx - 16),
                @floatFromInt(ty - 20),
                @floatFromInt(tw + 32),
                30,
                15,
                zrame.Color.rgba(10, 12, 20, 0.82),
            );
            canvas.strokeRoundedRect(
                @floatFromInt(tx - 16),
                @floatFromInt(ty - 20),
                @floatFromInt(tw + 32),
                30,
                15,
                1,
                zrame.Color.rgba(120, 140, 180, 0.35),
            );
            canvas.drawText(font, tx, ty, t, .{
                .size = 15,
                .style = .regular,
                .color = zrame.Color.rgba(240, 226, 170, 0.97),
            });
        }

        // Side panel: the glass band to the right of the centered video frame
        // (same centering math as chrome.frameOrigin).
        if (self.panel_on.load(.monotonic) and npt > 0) {
            const gut = @min(self.gutter.load(.monotonic), content.w);
            const area_w = content.w - gut;
            const fw = @min(self.frame_w.load(.monotonic), area_w);
            const ox = content.x + (area_w - fw) / 2;
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
                // Reading sizes, not label sizes: this panel is the paper's prose, and
                // it is read from a seat, not from the keyboard.
                var y = drawWrapped(canvas, font, px, top, pw, 19, .bold, zrame.Color.rgba(240, 226, 170, 0.97), pt[0..npt], 26);
                y += 10;
                y = drawWrapped(canvas, font, px, y, pw, 17, .regular, zrame.Color.rgba(216, 222, 232, 0.95), pb[0..npb], 24);
                y += 12;
                y = drawWrapped(canvas, font, px, y, pw, 15, .regular, zrame.Color.rgba(160, 190, 240, 0.9), pc[0..npc], 20);
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
                    .size = 15,
                    .style = .regular,
                    .color = zrame.Color.rgba(205, 212, 222, 0.95),
                });
                lx += 14 + font.measure(15, .regular, label) + 18;
            }
        }

        // The guide strip: the way in. A person handed this program with no
        // instructions has to be able to find the presentation, and it is one key.
        var gbuf: [160]u8 = undefined;
        var ng: usize = 0;
        var hbuf: [2400]u8 = undefined;
        var nh: usize = 0;
        if (self.lock.tryLock()) {
            ng = self.guide_len;
            nh = self.help_len;
            @memcpy(gbuf[0..ng], self.guide[0..ng]);
            @memcpy(hbuf[0..nh], self.help_txt[0..nh]);
            self.lock.unlock();
        }
        if (ng > 0) {
            const g = gbuf[0..ng];
            const gw = font.measure(15, .regular, g);
            const gx = @as(i32, @intCast(content.x)) + @divTrunc(@as(i32, @intCast(content.w)) - gw, 2);
            const gy = @as(i32, @intCast(content.y + content.h)) - 54;
            canvas.fillRoundedRect(
                @floatFromInt(gx - 16),
                @floatFromInt(gy - 20),
                @floatFromInt(gw + 32),
                30,
                15,
                zrame.Color.rgba(10, 12, 20, 0.55),
            );
            canvas.drawText(font, gx, gy, g, .{
                .size = 15,
                .style = .regular,
                .color = zrame.Color.rgba(198, 208, 224, 0.9),
            });
        }

        // The point card, on the left of the scene: the click's answer, in this
        // window. (Drawn before the help card, which is the layer above it.)
        if (self.card_on.load(.monotonic)) {
            var ct: [96]u8 = undefined;
            var cb: [512]u8 = undefined;
            var cd: [72]CardDot = undefined;
            var nct: usize = 0;
            var ncb: usize = 0;
            var ncd: usize = 0;
            if (self.lock.tryLock()) {
                nct = self.card_title_len;
                ncb = self.card_body_len;
                ncd = self.card_dots_len;
                @memcpy(ct[0..nct], self.card_title[0..nct]);
                @memcpy(cb[0..ncb], self.card_body[0..ncb]);
                @memcpy(cd[0..ncd], self.card_dots[0..ncd]);
                self.lock.unlock();
            }
            if (nct > 0) drawCard(canvas, font, content, ct[0..nct], cb[0..ncb], cd[0..ncd]);
        }

        // The shortcut card (H): every key this build binds, the domain's own
        // actions included — built from `keys.zig`, so it cannot drift from what the
        // plugins actually do.
        if (nh > 0 and self.help_on.load(.monotonic)) drawHelp(canvas, font, content, hbuf[0..nh]);
    }

    /// The point card: a glass panel on the left of the content, sized to its own
    /// text. It sits OVER the scene rather than beside it — the scene keeps its
    /// width, nothing reflows, and closing the card puts the picture back exactly
    /// as it was.
    fn drawCard(
        canvas: *zrame.Canvas,
        font: anytype,
        content: zrame.Rect,
        title: []const u8,
        body: []const u8,
        dots: []const CardDot,
    ) void {
        const pad: i32 = 18;
        const w: i32 = @min(@as(i32, @intCast(content.w)) - 32, 340);
        if (w < 200) return; // a card this narrow would be a smear, not a card
        const tw = w - 2 * pad;

        const th = wrappedHeight(font, tw, 18, .bold, title, 24);
        const bh = wrappedHeight(font, tw, 15, .regular, body, 21);
        const fig: i32 = if (dots.len > 0) @divTrunc(tw, 2) + 12 else 0;
        const h = pad + th + 10 + fig + bh + pad + 18;

        const x: i32 = @as(i32, @intCast(content.x)) + 16;
        const y: i32 = @as(i32, @intCast(content.y)) +
            @max(78, @divTrunc(@as(i32, @intCast(content.h)) - h, 2));

        canvas.fillRoundedRect(
            @floatFromInt(x),
            @floatFromInt(y),
            @floatFromInt(w),
            @floatFromInt(h),
            14,
            zrame.Color.rgba(15, 16, 26, 0.93),
        );
        canvas.strokeRoundedRect(
            @floatFromInt(x),
            @floatFromInt(y),
            @floatFromInt(w),
            @floatFromInt(h),
            14,
            1,
            zrame.Color.rgba(120, 140, 180, 0.35),
        );

        const tx = x + pad;
        var ty = y + pad + 18;
        ty = drawWrapped(canvas, font, tx, ty, tw, 18, .bold, zrame.Color.rgba(240, 226, 170, 0.97), title, 24);
        ty += 10;
        if (dots.len > 0) {
            // The neighbourhood map. By the card's contract `dots[0]` is the point
            // itself and every other dot is joined to it, so the links are drawn
            // from the first — no second array to keep in step with this one.
            const fx: f32 = @floatFromInt(tx);
            const fy: f32 = @floatFromInt(ty);
            const fw: f32 = @floatFromInt(tw);
            const fh: f32 = @floatFromInt(fig - 12);
            canvas.fillRoundedRect(fx, fy, fw, fh, 8, zrame.Color.rgba(8, 10, 18, 0.75));
            const place = struct {
                fn atX(d: CardDot, ox: f32, box_w: f32) f32 {
                    return ox + (d.x * 0.44 + 0.5) * box_w;
                }
                fn atY(d: CardDot, oy: f32, box_h: f32) f32 {
                    return oy + (0.5 - d.y * 0.44) * box_h;
                }
            };
            const c0x = place.atX(dots[0], fx, fw);
            const c0y = place.atY(dots[0], fy, fh);
            for (dots[1..]) |d| {
                canvas.strokeSegment(c0x, c0y, place.atX(d, fx, fw), place.atY(d, fy, fh), 1, zrame.Color.rgba(150, 170, 210, 0.30));
            }
            for (dots) |d| {
                const dx = place.atX(d, fx, fw);
                const dy = place.atY(d, fy, fh);
                const rr = @max(d.r, 1.5);
                canvas.fillRoundedRect(
                    dx - rr,
                    dy - rr,
                    2 * rr,
                    2 * rr,
                    rr,
                    zrame.Color.rgba(d.rgb[0], d.rgb[1], d.rgb[2], d.a),
                );
            }
            ty += fig;
        }
        ty = drawWrapped(canvas, font, tx, ty, tw, 15, .regular, zrame.Color.rgba(216, 223, 233, 0.96), body, 21);
        canvas.drawText(font, tx, y + h - 12, "Esc closes · click the point again to clear", .{
            .size = 12,
            .style = .regular,
            .color = zrame.Color.rgba(150, 160, 178, 0.8),
        });
    }

    fn drawHelp(canvas: *zrame.Canvas, font: anytype, content: zrame.Rect, txt: []const u8) void {
        const line_h: i32 = 26;
        var rows: usize = 0;
        var it = std.mem.splitScalar(u8, txt, '\n');
        while (it.next()) |_| rows += 1;

        const w: i32 = @min(@as(i32, @intCast(content.w)) - 80, 760);
        const h: i32 = @as(i32, @intCast(rows)) * line_h + 76;
        const x: i32 = @as(i32, @intCast(content.x)) + @divTrunc(@as(i32, @intCast(content.w)) - w, 2);
        const y: i32 = @as(i32, @intCast(content.y)) + @max(24, @divTrunc(@as(i32, @intCast(content.h)) - h, 2));

        canvas.fillRoundedRect(
            @floatFromInt(content.x),
            @floatFromInt(content.y),
            @floatFromInt(content.w),
            @floatFromInt(content.h),
            0,
            zrame.Color.rgba(0, 0, 0, 0.62),
        );
        canvas.fillRoundedRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(h), 16, zrame.Color.rgba(17, 19, 28, 0.97));
        canvas.strokeRoundedRect(@floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(h), 16, 1, zrame.Color.rgba(120, 140, 180, 0.35));

        canvas.drawText(font, x + 28, y + 38, "Shortcuts", .{
            .size = 20,
            .style = .bold,
            .color = zrame.Color.rgba(240, 226, 170, 0.97),
        });
        canvas.drawText(font, x + w - 28 - font.measure(14, .regular, "H or Esc closes"), y + 38, "H or Esc closes", .{
            .size = 14,
            .style = .regular,
            .color = zrame.Color.rgba(150, 160, 178, 0.85),
        });

        var ly: i32 = y + 70;
        it = std.mem.splitScalar(u8, txt, '\n');
        while (it.next()) |row| {
            defer ly += line_h;
            // A row with no tab is a section heading — the domain's own actions get one.
            const tab = std.mem.indexOfScalar(u8, row, '\t') orelse {
                if (row.len == 0) continue;
                canvas.drawText(font, x + 28, ly, row, .{
                    .size = 15,
                    .style = .bold,
                    .color = zrame.Color.rgba(160, 190, 240, 0.9),
                });
                continue;
            };
            canvas.drawText(font, x + 28, ly, row[0..tab], .{
                .size = 16,
                .style = .bold,
                .color = zrame.Color.rgba(235, 238, 245, 0.97),
            });
            canvas.drawText(font, x + 190, ly, row[tab + 1 ..], .{
                .size = 16,
                .style = .regular,
                .color = zrame.Color.rgba(200, 208, 220, 0.92),
            });
        }
    }
};
