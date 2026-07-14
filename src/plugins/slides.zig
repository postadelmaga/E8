//! The paper journey (P): a guided, multimedia tour authored as DATA — the
//! domain ships a ZON deck (embedded default + `deck.zon` on disk, F5 reloads
//! it while authoring). Each slide names a preset/color/edge/filter config,
//! narrates it in the side panel (citations included), optionally choreographs
//! the camera and shows an inline diagram. K toggles kiosk auto-advance.
//! Esc here closes the panel layer; the final Esc (app close) is the core's.

const std = @import("std");
const geom = @import("../geom.zig");
const hud_mod = @import("../hud.zig");
const deck_mod = @import("../deck.zig");
const still_mod = @import("../still.zig");
const keys = @import("../keys.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const D = app_mod.D;
const projections = @import("projections.zig");
const colors = @import("colors.zig");
const filters = @import("filters.zig");
const edges = @import("edges.zig");
const panel = @import("panel.zig");

pub const id = "slides";

pub const State = struct {
    deck: deck_mod.Deck = .{},
    /// The picture the current slide put on screen, decoded once (a slide that
    /// names the same file as the one showing does not decode it again).
    still: ?still_mod.Still = null,
    idx: usize = 0,
    auto: bool = false,
    auto_t: f32 = 0,
    tr_from: geom.Basis = undefined,
    tr_to: geom.Basis = undefined,
    tr_t: f32 = 1,
    cam_from: [3]f32 = .{ 0, 0, 0 },
    cam_to: [3]f32 = .{ 0, 0, 0 },
    cam_t: f32 = 1,
};

/// The deck this run plays. `--deck=<path>` overrides the domain's own, because a
/// demo AUTHORED by the user is precisely that: someone else's slides over a
/// domain that already exists. Without the override the path would be a fixed name
/// relative to the working directory, and the launcher — which runs from one cwd
/// for every demo — would hot-reload the wrong file.
pub fn deckPath() []const u8 {
    return if (app_mod.cli.deck.len > 0) app_mod.cli.deck else D.deck_path;
}

pub fn init(a: *App) void {
    const st = a.pluginState(@This());
    st.deck = deck_mod.load(a.gpa, a.io, deckPath(), D.deck_default);
}

pub fn deinit(a: *App) void {
    const st = a.pluginState(@This());
    a.still = null;
    if (st.still) |*s| s.deinit();
    deck_mod.deinit(a.gpa, st.deck);
}

/// Put the slide's picture on screen, or take the last one off. A path that will
/// not decode says so on the HUD and leaves the scene — a broken image is a
/// missing figure, not a broken talk.
fn applyStill(a: *App, path: []const u8) void {
    const st = a.pluginState(@This());
    if (st.still) |*s| {
        if (std.mem.eql(u8, s.path, path)) return; // already showing it
        a.still = null;
        s.deinit();
        st.still = null;
    }
    if (path.len == 0) return;
    st.still = still_mod.load(a.gpa, a.io, path) catch |e| {
        var buf: [160]u8 = undefined;
        a.hud.setLine2(std.fmt.bufPrint(&buf, "the slide's picture will not open ({s}: {s})", .{
            path, @errorName(e),
        }) catch "the slide's picture will not open");
        return;
    };
    a.still = &st.still.?;
}

/// The slide names the file its points come from: reload only when it differs
/// from what is loaded (`reloadPoints` is a full rebuild of the point system).
fn applyData(a: *App, path: []const u8) void {
    if (path.len == 0) return;
    if (comptime !@hasDecl(D, "load")) return; // this domain computes its points
    a.reloadPoints(path) catch |e| {
        var buf: [160]u8 = undefined;
        a.hud.setLine2(std.fmt.bufPrint(&buf, "the slide's data will not open ({s}: {s})", .{
            path, @errorName(e),
        }) catch "the slide's data will not open");
    };
}

pub fn key(a: *App, code: u32) bool {
    const st = a.pluginState(@This());
    switch (code) {
        keys.present => { // P: start the journey, or next slide
            if (st.deck.slides.len == 0) return true;
            if (!a.pluginState(panel).on) {
                panel.setOpen(a, true);
            } else {
                st.idx = (st.idx + 1) % st.deck.slides.len;
            }
            show(a, st.idx);
            return true;
        },
        keys.backspace => { // Backspace: one slide back — a talk is not a one-way street
            if (st.deck.slides.len == 0) return true;
            if (!a.pluginState(panel).on) {
                panel.setOpen(a, true);
            } else {
                st.idx = (st.idx + st.deck.slides.len - 1) % st.deck.slides.len;
            }
            show(a, st.idx);
            return true;
        },
        keys.kiosk => { // K: kiosk mode
            st.auto = !st.auto;
            st.auto_t = 0;
            if (st.auto and !a.pluginState(panel).on and st.deck.slides.len > 0) {
                panel.setOpen(a, true);
                show(a, st.idx);
            }
            a.status_dirty = true;
            return true;
        },
        keys.f5 => { // F5: hot-reload the deck while authoring
            deck_mod.deinit(a.gpa, st.deck);
            const loaded = deck_mod.loadEx(a.gpa, a.io, deckPath(), D.deck_default);
            st.deck = loaded.deck;
            st.idx = @min(st.idx, st.deck.slides.len -| 1);
            if (loaded.parse_err) |e| {
                // The author just edited this file: a silent revert to the
                // embedded deck reads as "my edit was ignored".
                var buf: [160]u8 = undefined;
                a.hud.setLine2(std.fmt.bufPrint(&buf, "{s} will not parse ({s}) — playing the embedded deck", .{
                    deckPath(), @errorName(e),
                }) catch "deck.zon will not parse — playing the embedded deck");
            } else if (a.pluginState(panel).on and st.deck.slides.len > 0) show(a, st.idx);
            return true;
        },
        keys.escape => { // Esc: close the panel layer. The app-level Esc lives in
            // main.zig's key loop, so it works even in a domain without `slides`.
            if (a.pluginState(panel).on) {
                panel.setOpen(a, false);
                st.auto = false;
                a.hud.setLine2("journey paused — P resumes where you left off");
                a.status_dirty = true;
                return true;
            }
            return false;
        },
        else => return false,
    }
}

fn smooth(t: f32) f32 {
    return t * t * (3.0 - 2.0 * t);
}

pub fn frame(a: *App) void {
    const st = a.pluginState(@This());
    if (st.tr_t < 1) {
        st.tr_t = @min(1.0, st.tr_t + a.dt / 1.2);
        const t = smooth(st.tr_t);
        for (0..3) |r| {
            for (0..app_mod.dim) |c| a.basis[r][c] = st.tr_from[r][c] * (1 - t) + st.tr_to[r][c] * t;
        }
    }
    if (st.cam_t < 1) {
        st.cam_t = @min(1.0, st.cam_t + a.dt / 1.2);
        const t = smooth(st.cam_t);
        app_mod.storeF32(&app_mod.cam_yaw, st.cam_from[0] * (1 - t) + st.cam_to[0] * t);
        app_mod.storeF32(&app_mod.cam_pitch, st.cam_from[1] * (1 - t) + st.cam_to[1] * t);
        app_mod.storeF32(&app_mod.cam_dist, st.cam_from[2] * (1 - t) + st.cam_to[2] * t);
    }
    if (st.auto and a.pluginState(panel).on and st.deck.slides.len > 0) {
        st.auto_t += a.dt;
        if (st.auto_t > st.deck.slides[st.idx].dwell) {
            st.idx = (st.idx + 1) % st.deck.slides.len;
            show(a, st.idx);
        }
    }
}

pub fn status(a: *App, buf: []u8) []const u8 {
    _ = buf;
    return if (a.pluginState(@This()).auto) "kiosk (K stops)" else "";
}

/// Apply a slide: projection, camera, colors, edges, filter, panel text, figure.
/// Public because the EDITOR previews with it — the preview is not a second
/// rendering path, it is this one.
pub fn show(a: *App, idx: usize) void {
    const st = a.pluginState(@This());
    const s = &st.deck.slides[idx];
    st.auto_t = 0;
    // What the slide is ABOUT, before how it is dressed: the data it looks at,
    // and whether it looks at a picture instead.
    applyData(a, s.data);
    applyStill(a, s.image);
    // Smooth basis transition into the slide's projection (animated presets
    // drive themselves, so they snap).
    st.tr_from = a.basis;
    projections.applyByName(a, s.preset);
    if (!D.presets[a.preset].animated) {
        st.tr_to = a.basis;
        st.tr_t = 0;
        a.basis = st.tr_from;
    } else st.tr_t = 1;
    if (s.cam) |c| {
        st.cam_from = .{
            app_mod.loadF32(&app_mod.cam_yaw),
            app_mod.loadF32(&app_mod.cam_pitch),
            app_mod.loadF32(&app_mod.cam_dist),
        };
        st.cam_to = c;
        st.cam_t = 0;
    }
    a.pluginState(projections).tumble = s.tumble;
    if (s.color.len > 0) colors.setByName(a, s.color);
    edges.setByName(a, if (s.edge.len > 0) s.edge else "all");
    if (s.filter.len > 0) filters.setByName(a, s.filter);
    var tbuf: [96]u8 = undefined;
    const title = std.fmt.bufPrint(&tbuf, "{d}/{d} — {s}", .{ idx + 1, st.deck.slides.len, s.title }) catch s.title;
    a.hud.setPanel(title, s.body, s.cite);
    if (s.fig.len > 0) {
        var dots: [72]hud_mod.FigDot = undefined;
        const nd = D.figure(a, s.fig, &dots);
        a.hud.setPanelFigure(dots[0..nd]);
    }
    var lbuf: [120]u8 = undefined;
    a.hud.setLine2(std.fmt.bufPrint(&lbuf, "journey {d}/{d} — P next · Backspace back · K kiosk · H shortcuts · Esc closes", .{ idx + 1, st.deck.slides.len }) catch "");
    a.status_dirty = true;
}
