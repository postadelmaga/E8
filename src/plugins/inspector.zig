//! The point card (click a point): the domain's supplementary reading on the
//! selection, drawn IN the main window, on the glass to the left of the scene.
//!
//! It used to be a second toplevel window — a frameless popup with its own
//! zengine view, its own thread and its own software fallback, opening and
//! closing on every click. That is a window transition in exchange for a
//! question about a dot, and three hundred lines of surface to keep alive. The
//! card replaces all of it: `D.inspect` writes the text, `D.figure` optionally
//! sketches the neighbourhood, and the HUD draws both over the scene. Nothing
//! is created, nothing takes focus, and the picture behind it never moves.
//!
//! The selection is still lit in the scene itself (see plugins/selection.zig and
//! plugins/effects.zig: the white ring, the halo, the relation orbit's
//! lighthouse) — which is where the old popup's mini-scene was duplicating the
//! main view anyway. A domain with a mesh of its own (`sceneExtra`) now has it
//! placed in THE scene, next to the roots it belongs to (see main.zig).
//!
//! Esc closes the card — it is the layer above the panel and below the shortcut
//! card, so the domains register `inspector` between `guide` and `slides`.

const std = @import("std");
const hud_mod = @import("../hud.zig");
const keys = @import("../keys.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const D = app_mod.D;

pub const id = "inspector";

pub const State = struct {
    /// The selection the card is currently showing (−1 = no card).
    shown: i32 = -1,
};

/// The neighbourhood map: the point you clicked, at the centre, and the points
/// it is joined to, where they are ON SCREEN relative to it — a zoom of the
/// patch of scene under your cursor. Taken as a snapshot at the click, not
/// tracked live: the HUD is glass, and repainting it at frame rate to spin a
/// thumbnail would cost the whole window a repaint per frame for a decoration.
fn neighbourhood(a: *App, sel: usize, out: []hud_mod.CardDot) usize {
    if (!a.vis[sel]) return 0;
    const c = a.scr[sel];
    var span: f32 = 1e-4;
    for (a.neighbors(sel)) |nb| {
        if (!a.vis[nb]) continue;
        span = @max(span, @abs(a.scr[nb][0] - c[0]));
        span = @max(span, @abs(a.scr[nb][1] - c[1]));
    }
    // dots[0] is the selection: the HUD draws every other dot joined to it.
    out[0] = .{ .x = 0, .y = 0, .r = 4.5, .rgb = .{ 255, 255, 255 } };
    var n: usize = 1;
    for (a.neighbors(sel)) |nb| {
        if (n == out.len) break;
        if (!a.vis[nb]) continue;
        const v = a.visuals[nb].color;
        out[n] = .{
            .x = (a.scr[nb][0] - c[0]) / span,
            .y = -(a.scr[nb][1] - c[1]) / span, // screen y is down, the card's is up
            .r = 3,
            .rgb = .{
                @intFromFloat(std.math.clamp(v[0], 0, 1) * 255),
                @intFromFloat(std.math.clamp(v[1], 0, 1) * 255),
                @intFromFloat(std.math.clamp(v[2], 0, 1) * 255),
            },
            .a = 0.95,
        };
        n += 1;
    }
    return if (n > 1) n else 0; // a lone dot is not a map
}

pub fn key(a: *App, code: u32) bool {
    if (code != keys.escape) return false;
    const st = a.pluginState(@This());
    if (st.shown < 0) return false; // no card up: Esc belongs to the layer below
    a.selected = -1;
    a.info_dirty = true;
    return true;
}

pub fn post(a: *App) void {
    const st = a.pluginState(@This());
    if (a.selected == st.shown) return;
    st.shown = a.selected;

    if (a.selected < 0) {
        a.hud.setCardOn(false);
        return;
    }

    var title: [96]u8 = undefined;
    var body: [512]u8 = undefined;
    const txt = D.inspect(a, @intCast(a.selected), &title, &body);

    var dots: [72]hud_mod.CardDot = undefined;
    const nd = neighbourhood(a, @intCast(a.selected), &dots);

    a.hud.setCard(title[0..txt.title_len], body[0..txt.body_len], dots[0..nd]);
    a.hud.setCardOn(true);
}

pub fn deinit(a: *App) void {
    a.hud.setCardOn(false);
}
