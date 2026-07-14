//! What the target can do — the one place the code asks.
//!
//! The presenter runs in two places now: a Wayland window on a workstation, and
//! a browser tab. They are not the same machine. The browser has no Vulkan (so no
//! zengine), no threads to spawn, no working directory to read a file from, and
//! no second window to open a tool in. What it does have is the thing the whole
//! figure was already drawn with: `render_cpu`, which is pure Zig and pure
//! arithmetic, and zicro's canvas underneath it.
//!
//! So the web build is not a port of the demo — it is the SAME demo with the
//! native-only limbs left out at comptime. A plugin that needs one of them says
//! `pub const native_only = true` and is simply not in the registry there.

const builtin = @import("builtin");

/// wasm32 in a browser tab: no zengine, no threads, no filesystem.
pub const web = builtin.target.cpu.arch.isWasm();

/// The other one, spelled out where it reads better.
pub const native = !web;
