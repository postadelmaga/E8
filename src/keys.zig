//! Every key the framework binds, in one place.
//!
//! Shortcuts used to be spelled as raw evdev codes at the point of use — `if (code
//! != 18) return false; // E` — and the consequence was predictable: two plugins
//! claimed E, the editor could never be opened, and the banner printed at startup
//! promised keys that no longer did what it said. A key is not a number, it is a
//! CONTRACT between three things: the plugin that handles it, the help the user
//! reads, and the on-screen guide. Here they are one declaration.
//!
//! THE LAYOUT, and why it is what it is:
//!
//!   • Presenting is the primary job, so it gets the keys a presenter can find in
//!     the dark: P (next), Backspace (back), K (kiosk), F (fullscreen), H (help).
//!   • Everything that CHANGES WHAT YOU SEE is a single letter naming it: C colors,
//!     S subset (the filter), E edges, T tumble, R reset, X export, O open editor.
//!   • Everything a DOMAIN adds lives on the letters the framework leaves free —
//!     G, N, M, B, J and +/− (see each domain's `actions`).
//!
//! Adding a key means adding a row here, then handling `keys.<name>` in a plugin.
//! Nothing else has to be told: the help popup and the on-screen guide are built
//! from this table.

const std = @import("std");

// --- the codes (Linux evdev; Win32 translates its VKs to the same set) -------------

pub const escape: u32 = 1;
pub const backspace: u32 = 14;
pub const tab: u32 = 15;
pub const space: u32 = 57;
pub const left: u32 = 105;
pub const right: u32 = 106;
pub const f5: u32 = 63;
pub const f11: u32 = 87;

/// KEY_1 … KEY_9 are contiguous: preset i is `preset_1 + i`.
pub const preset_1: u32 = 2;
pub const preset_9: u32 = 10;

pub const colors: u32 = 46; // C
pub const subset: u32 = 31; // S — the filter (F went to fullscreen)
pub const edges: u32 = 18; // E
pub const tumble: u32 = 20; // T
pub const reset: u32 = 19; // R
pub const export_csv: u32 = 45; // X
pub const present: u32 = 25; // P
pub const kiosk: u32 = 37; // K
pub const editor: u32 = 24; // O
pub const fullscreen: u32 = 33; // F
pub const help: u32 = 35; // H

// Left free for the domains, and spoken for in exactly one domain each:
pub const domain_g: u32 = 34; // G
pub const domain_h: u32 = 36; // J — the hub climb (H is the help now)
pub const domain_n: u32 = 49; // N
pub const domain_m: u32 = 50; // M
pub const domain_b: u32 = 48; // B
pub const domain_plus: u32 = 13; // +
pub const domain_minus: u32 = 12; // −

// --- what the user is told ----------------------------------------------------------

pub const Row = struct {
    keys: []const u8,
    what: []const u8,
};

/// The help popup (H), in reading order. Domain actions are appended to this at
/// runtime, from `D.actions`.
pub const help_rows = [_]Row{
    .{ .keys = "P", .what = "next slide — starts the guided journey" },
    .{ .keys = "Backspace", .what = "previous slide" },
    .{ .keys = "K", .what = "kiosk: the slides advance on their own" },
    .{ .keys = "F", .what = "fullscreen (F11 too)" },
    .{ .keys = "H", .what = "this list" },
    .{ .keys = "Esc", .what = "close the top layer: popup, then panel, then the app" },
    .{ .keys = "drag / scroll", .what = "orbit the camera / zoom" },
    .{ .keys = "click", .what = "pick a point — opens the inspector" },
    .{ .keys = "1 … 9", .what = "projection presets" },
    .{ .keys = "←  →", .what = "rotate the hidden plane (or sweep an animated preset)" },
    .{ .keys = "Tab", .what = "which hidden plane the arrows turn" },
    .{ .keys = "T", .what = "tumble (slow drift through the hidden dimensions)" },
    .{ .keys = "Space", .what = "spin" },
    .{ .keys = "R", .what = "reset the view" },
    .{ .keys = "C", .what = "color mode" },
    .{ .keys = "S", .what = "subset filter" },
    .{ .keys = "E", .what = "edge mode" },
    .{ .keys = "O", .what = "open the slide editor" },
    .{ .keys = "X", .what = "export the system as CSV" },
    .{ .keys = "F5", .what = "reload the deck from disk" },
};

/// The strip drawn over the scene, always: the five keys someone who has never seen
/// this program needs in order to get anywhere.
pub const guide = "P next slide  ·  Backspace back  ·  H shortcuts  ·  F fullscreen  ·  Esc close";
