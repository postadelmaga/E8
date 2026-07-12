# Authoring an interactive paper

This repository is two things: a **presenter framework** for interactive
scientific papers on [zengine](../Zengine)/[zrame](../Zrame), and its reference
consumer — an interactive reading of Garrett Lisi's E8 papers. The framework
knows nothing about physics: it draws a set of points in R^dim, projects them
to 3D, lets you steer, select, filter and narrate. Everything else comes from a
**domain package**.

```
zig build run                      # the Lisi E8 interactive paper (default)
zig build run -- --gpu             # zengine mesh raster + HDR bloom
zig build -Ddemo=molecule run      # caffeine, ball-and-stick
zig build -Ddemo=polytope run      # the 24-cell, guided tour
```

## Architecture

| layer | files | knows about |
|---|---|---|
| core | `src/main.zig` | window, camera, projection, the two rasterizers |
| seam | `src/app.zig`, `src/geom.zig`, `src/descriptor.zig`, `src/deck.zig` | the `App` state, hooks, visual contracts, decks |
| plugins | `src/plugins/*.zig` | features, all domain-agnostic |
| domain | `src/demos/<name>/` | the science: points, classes, stories, deck |

Plugins are dispatched at **compile time** (`inline for` + `@hasDecl`): no
vtables, no indirection, and a plugin that doesn't implement a hook costs
nothing. The domain lists which plugins it wants in its `plugins` tuple.

### Hooks

| hook | when |
|---|---|
| `init(a)` / `deinit(a)` | once, around the app's life |
| `key(a, code) bool` | evdev keycode, render thread; first plugin to claim it wins |
| `frame(a)` | every frame, before the projection |
| `post(a)` | every frame, after screen positions are valid (picking, HUD) |
| `visual(a, i, *Visual)` | per point, chained in registry order — later overrides earlier |
| `edgePairs(a)` / `edgeVisual(a, i, j)` | which lines to draw and how |
| `status(a, buf)` | contribution to the HUD status line |

Plugin state is plain data in `P.State` (all hooks run on the render thread);
cross-thread traffic — the camera atomics, the key queue — stays in `app.zig`.

## Writing a domain

A domain package is one `domain.zig` plus a `deck.zon`. It exports:

```zig
pub const name  = "Caffeine";           // shown in the console banner
pub const title = "…";                   // window title
pub const app_id = "dev.presenter.molecule";

pub const dim = 3;                       // the space the points live in
pub const n = 14;                        // how many points
pub const radius2: f32 = 9.0;            // max |v|² (hidden-depth normalization)
pub const Point = struct { v: [3]f32, … };   // .v is required; the rest is yours

pub fn generate() [n]Point                        // the point set
pub fn buildEdges(gpa, points) ![]const [2]u16    // the lines (bonds, roots, …)

pub const presets: []const PresetDef              // projections (keys 1..9)
pub const color_modes: []const ColorModeDef       // C cycles these, legends included
pub const filters: []const FilterDef              // F cycles these
pub const relations: []const RelationDef          // partner maps (triality, antipode…)
pub const actions: []const ActionDef              // key-bound domain verbs (G, …)
pub const plugins = .{ … };                       // which framework plugins to load

pub fn descriptor(a, i) descriptor.Object         // how point i looks and behaves
pub fn describe(a, i, buf) []const u8             // HUD one-liner
pub fn story(a) void                              // side-panel page for the selection
pub fn inspect(a, i, tbuf, bbuf) InspectText      // popup text
pub fn figure(a, fig_id, dots) usize              // inline panel diagram
pub fn exportCsv(a) !void                         // X

pub const deck_path = "deck.zon";                 // hot-reloaded from cwd (F5)
pub const deck_default = @embedFile("deck.zon");  // fallback, compiled in
```

Then add it to the switch in `src/domain.zig` and to the `-Ddemo` option in
`build.zig`. That is the whole contract — `src/demos/lisi/domain.zig` is the
worked reference, `molecule` the smallest one.

### Object descriptors — how things look

Instead of writing render code, a domain *declares* per-point appearance and
behavior:

```zig
pub fn descriptor(a: *App, i: usize) desc.Object {
    const p = &a.points[i];
    return .{
        .radius = 1.5,                                   // × base point radius
        .glow = 1.0,                                     // × resting emissive
        .pulse = if (p.core) .{ .kind = .breathe, .rate = 0.9, .amp = 0.22 } else null,
        .orbit_rgb = .{ 1.0, 0.75, 0.2 },                // flare color in a relation orbit
        .orbit_phase = …,                                // lighthouse phase
    };
}
```

The GPU path maps this to emissive materials (HDR bloom amplifies the pulses);
the software path draws equivalent additive halos. `"gluon → orange emissive,
breathing"` and `"purine core → warm tint, breathing"` are written the same
way.

### Decks — the guided journey

`P` opens the side panel and advances through the deck; `K` runs it as a kiosk;
`F5` hot-reloads `deck.zon` from the working directory while you author.

```zig
.{
    .slides = .{
        .{
            .title = "The pharmacophore",
            .body = "…paragraphs separated by \n…",
            .cite = "Fredholm et al., Pharmacol. Rev. 51 (1999) 83.",
            .preset = "turntable",             // names from the domain's tables
            .color = "purine core",
            .edge = "all",                     // or "off" / "selection" / a relation name
            .filter = "nitrogen",
            .tumble = true,
            .cam = .{ 0.55, 0.35, 4.4 },       // yaw, pitch, distance — eased in
            .dwell = 26,                        // kiosk seconds
            .fig = "skeleton",                  // inline diagram id (domain's `figure`)
        },
        …
    },
}
```

Slide transitions interpolate the projection basis and the camera; nothing in
the framework is Lisi-specific.

### Relations and actions

A relation is a partner map over the points — Lisi's triality (a 3-cycle), the
24-cell's antipode (an involution), a molecule's backbone walk. The framework
tabulates it once, offers it as an edge mode, lights it in the inspector's
mini-scene, and flares it around the selection. An action binds a key to a
domain verb:

```zig
pub const relations = &[_]app_mod.RelationDef{
    .{ .name = "triality", .partner = trialityPartner },
};
pub const actions = &[_]app_mod.ActionDef{
    .{ .key = 34, .help = "G: ride the triality orbit", .run = actTriality },
};
```

## Tutorial: a minimal interactive paper

1. `mkdir src/demos/mine` and write `domain.zig` with `dim`, `n`, `Point`,
   `generate`, `buildEdges`, one preset, one color mode, one filter, and the
   text functions (`describe`, `story`, `inspect` may be one-liners; `figure`
   may return 0).
2. Copy the `plugins` tuple from `src/demos/molecule/domain.zig` — drop
   `inspector` or `slides` if you don't want them.
3. Write `deck.zon` with two or three slides referencing your preset/color
   names.
4. Add your name to the switch in `src/domain.zig` and to the `-Ddemo` help
   text in `build.zig`.
5. `zig build -Ddemo=mine run`. Press `P`. Edit `deck.zon`, press `F5`.

The molecule domain is ~300 lines including all its prose — that is the real
cost of a new interactive paper.
