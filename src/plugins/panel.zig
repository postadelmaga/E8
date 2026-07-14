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

/// Wide enough for the prose to be read at the size it is now set in (19/17/15 px,
/// see `hud.zig`): a narrower column would wrap the body two words at a time.
const panel_px: u32 = 380;

pub fn init(a: *App) void {
    D.story(a);
}

/// Open or close the side panel. The window does NOT change size: it keeps the
/// panel's width as a gutter on the right and the scene re-centers in what is
/// left. Widening the window on P — which is what this did — meant that starting
/// the talk jumped the window under the presenter, undid a maximize, and on a
/// small screen pushed the figure off the edge. The panel is a layer, not a
/// second window: it costs the scene some width, and nothing else.
pub fn setOpen(a: *App, on: bool) void {
    const st = a.pluginState(@This());
    if (st.on == on) return;
    st.on = on;
    a.hud.panel_on.store(on, .monotonic);
    const extra: u32 = if (on) panel_px else 0;
    a.reserve_w = extra;
    a.hud.gutter.store(extra, .monotonic);
    a.win.reserveGutter(extra);
}

pub fn post(a: *App) void {
    if (a.info_dirty and a.pluginState(@This()).on) D.story(a);
}
