//! The side panel service: opening/closing (the window widens to make room)
//! and keeping the panel on the selection's story (domain-provided) whenever
//! the selection changes. Content otherwise comes from whoever wrote it last
//! (a deck slide, or the domain story).

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const D = app_mod.D;

pub const id = "panel";

pub const State = struct {
    on: bool = false,
};

const panel_px: u32 = 300;

pub fn init(a: *App) void {
    D.story(a);
}

/// Open or close the side panel — the window widens/narrows to make room. The
/// window keeps the panel's width as a gutter on the right, so the figure stays
/// centered in what is left instead of leaving a dead band of glass on the left.
pub fn setOpen(a: *App, on: bool) void {
    const st = a.pluginState(@This());
    if (st.on == on) return;
    st.on = on;
    a.hud.panel_on.store(on, .monotonic);
    const extra: u32 = if (on) panel_px else 0;
    a.reserve_w = extra;
    a.hud.gutter.store(extra, .monotonic);
    a.win.reserveGutter(extra);
    a.win.requestResize(app_mod.win_w + extra, app_mod.win_h);
}

pub fn post(a: *App) void {
    if (a.info_dirty and a.pluginState(@This()).on) D.story(a);
}
