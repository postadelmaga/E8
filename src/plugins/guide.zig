//! The way in: the shortcut card (H), fullscreen (F), and the strip that tells a
//! first-time viewer which key starts the talk.
//!
//! The card is not written by hand. It is built at startup from `keys.zig` — the
//! table the plugins actually switch on — and then from the DOMAIN's own `actions`,
//! each of which already carries the help line it wants ("G: ride the triality
//! orbit"). So a demo that adds a key gets it into the card for free, and a key that
//! moves cannot leave a lie behind on screen.
//!
//! Registered BEFORE `slides`, because Esc is layered and the card is the topmost
//! layer: Esc closes it, and only when it is closed does Esc mean the panel.

const std = @import("std");
const keys = @import("../keys.zig");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const D = app_mod.D;

pub const id = "guide";

/// The card's text, one row per line, key and description split by a tab. Built once
/// — the HUD only ever draws it.
var text: [2400]u8 = undefined;

pub fn init(a: *App) void {
    var w: usize = 0;
    const put = struct {
        fn s(buf: []u8, at: *usize, bytes: []const u8) void {
            const n = @min(bytes.len, buf.len - at.*);
            @memcpy(buf[at.*..][0..n], bytes[0..n]);
            at.* += n;
        }
    };

    for (keys.help_rows) |r| {
        put.s(&text, &w, r.keys);
        put.s(&text, &w, "\t");
        put.s(&text, &w, r.what);
        put.s(&text, &w, "\n");
    }
    if (D.actions.len > 0) {
        put.s(&text, &w, "\n");
        put.s(&text, &w, D.name);
        put.s(&text, &w, "\n");
        // A domain's help line is "K: what it does" — the same split the card wants.
        for (D.actions) |act| {
            const colon = std.mem.indexOfScalar(u8, act.help, ':') orelse {
                put.s(&text, &w, "\t");
                put.s(&text, &w, act.help);
                put.s(&text, &w, "\n");
                continue;
            };
            put.s(&text, &w, act.help[0..colon]);
            put.s(&text, &w, "\t");
            put.s(&text, &w, std.mem.trimStart(u8, act.help[colon + 1 ..], " "));
            put.s(&text, &w, "\n");
        }
    }
    // The trailing newline would draw as an empty row.
    if (w > 0 and text[w - 1] == '\n') w -= 1;

    a.hud.setHelp(text[0..w], keys.guide);
}

pub fn key(a: *App, code: u32) bool {
    switch (code) {
        keys.help => {
            a.hud.setHelpOn(!a.hud.helpOn());
            return true;
        },
        keys.fullscreen, keys.f11 => {
            a.win.toggleFullscreen();
            return true;
        },
        keys.escape => {
            // Only when the card is up: otherwise Esc belongs to the layer below.
            if (!a.hud.helpOn()) return false;
            a.hud.setHelpOn(false);
            return true;
        },
        else => return false,
    }
}
