# Authoring an interactive paper

This repository is two things: a **presenter framework** for interactive
scientific papers on [zengine](../Zengine)/[zrame](../Zrame), and its reference
consumer — an interactive reading of Garrett Lisi's E8 papers. The framework
knows nothing about physics: it draws a set of points in R^dim, projects them
to 3D, lets you steer, select, filter and narrate. Everything else comes from a
**domain package**.

```
zig build run                              # the LAUNCHER: pick a demo, or author one
zig build run-demo -Ddemo=mtheory -- --gpu # one demo, straight (the dev loop)
```

`zig build` produces one executable **per demo** — `e8-lisi`, `e8-mtheory`, … —
plus `e8-menu`. It has to: a domain's `Point` type and its `dim` are comptime
(`geom.Vec = [dim]f32`), so an 8-dimensional demo and a 3-dimensional one are
different programs. The launcher carries no domain and starts whichever you pick.

A domain may build on another (`mtheory` imports `demos/lisi/e8.zig` and its 240
roots become E10's level 0), and it may carry **its own plugins**: a file in the
demo's folder listed in its `plugins` tuple is dispatched exactly like a
framework one. `demos/mtheory/cinema.zig` is the worked example — it owns the
Big Bang mode, and it drives the projection basis from a cosmological billiard
rather than from the preset table.

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
pub const filters: []const FilterDef              // S cycles these
pub const relations: []const RelationDef          // partner maps (triality, antipode…)
pub const actions: []const ActionDef              // key-bound domain verbs (G, N, M, B, J…)
pub const plugins = .{ … };                       // which framework plugins to load

pub fn descriptor(a, i) descriptor.Object         // how point i looks and behaves
pub fn describe(a, i, buf) []const u8             // HUD one-liner
pub fn story(a) void                              // side-panel page for the selection
pub fn inspect(a, i, tbuf, bbuf) InspectText      // the point card's text
pub fn figure(a, fig_id, dots) usize              // inline panel diagram
pub fn exportCsv(a) !void                         // X

pub const deck_path = "deck.zon";                 // hot-reloaded from cwd (F5)
pub const deck_default = @embedFile("deck.zon");  // fallback, compiled in
```

Then add it to the switch in `src/domain.zig` and to the `demos` list in
`build.zig` (which is what gives it its own executable and a place in the
launcher). That is the whole contract — `src/demos/lisi/domain.zig` is the
worked reference, `molecule` the smallest one.

### Domains that read a file

A domain does not have to *generate* its points. Instead of `n` + `generate()`
it may export:

```zig
pub fn load(gpa, io) ![]Point     // read the file named on the command line
pub fn unload(gpa) void           // release whatever it kept alongside the points
```

The point count is then a **runtime** value: nothing in the framework is sized at
comptime off `n`, and `a.count()` is the truth everywhere. What the user typed
reaches the domain through `app.cli` (`file`, `coords`, `class`, `label`, `knn`),
filled from argv before the domain loads.

The menus can be runtime too: `presets`, `color_modes`, `filters` and `relations`
are read as slices, so a loading domain declares them `pub var` and fills them
once it has seen the data — one color mode per numeric column, one filter per
class. The plugins never notice the difference.

`src/demos/data/` is the reference: it reads ANY delimited table (`table.zig`
sniffs the delimiter and infers each column's type), turns the numeric columns
into standardized coordinates in R^k, the categorical one into classes, builds
the k-nearest-neighbor graph and the principal axes, and ships a deck that
explains what it just did to the reader.

```
zig build run-demo -Ddemo=data -- iris.csv
zig build run-demo -Ddemo=data -- vecs.tsv --coords=x,y,z,w --class=label --knn=8
```

### Field profiles — the domains a working scientist opens

A *profile* is a loading domain that knows one field: its file formats, the
projections that field argues about, the colors it reads without a legend, and
the one tool it cannot work without. Each is one directory; the framework is
untouched.

| profile | opens | projections | colors | its tool |
|---|---|---|---|---|
| `data` | any CSV/TSV | principal axes, raw axes | class, a ramp per numeric column | k-NN graph, nearest neighbor (N) |
| `embed` | `.npy`, CSV | **PCA ⇄ t-SNE, in the same point** | labels, k-means clusters, neighbor agreement | cosine k-NN, 5 nearest listed (N) |
| `chem` | PDB, XYZ | as deposited, inertia axes | CPK elements, chains, residue chemistry, B-factor | **the ruler: M marks an atom, distances in Å** |
| `graph` | GraphML, edge list | **the Laplacian spectrum** | communities (label propagation), degree, components | clustering coefficient, hub climb (J) |
| `astro` | catalog CSV (Gaia/HYG/SIMBAD) | equatorial, galactic plane | blackbody stellar color, distance, luminosity | **the HR diagram**, nearest star (N) |

Two of them make the framework's central trick mean something field-specific.
The **embeddings** profile puts the principal components in coordinates 0..12 and
the t-SNE embedding in 13..15 of the *same* R^16 point, so switching view is a
change of basis, not a reload — the selection, the neighbors and the colors
follow you across, and the k-NN graph (computed in the original space, by cosine)
shows you exactly where each projection lies. The **network** profile lays the
graph out on its own Laplacian eigenvectors, so "rotate the hidden dimensions
into view" *is* walking up the spectrum.

```
zig build run-demo -Ddemo=embed -- vectors.npy --label=names.txt --knn=8
zig build run-demo -Ddemo=chem  -- 1ubq.pdb
zig build run-demo -Ddemo=graph -- karate.txt
zig build run-demo -Ddemo=astro -- gaia.csv
```

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
breathing"` and `"purine core → warm tint, breathing"` are written the same way.

`render_gpu.zig` owns one zengine **device** (Vulkan + the baked sphere/tube
meshes) and hands out **views** — a raster plus export images. The main window
takes one with `--gpu`; a resize rebuilds only that view.

#### A mesh of the domain's own

The framework bakes two meshes and knows what they are for: a sphere per point, a
tube per edge. Beyond that it has no opinions, so a domain may hand over meshes of
its own; they are placed in THE scene, around the selected point (`--gpu` only):

```zig
pub const extra_parts = 25;                                  // how many, so instances can be sized
pub fn extraMeshes(gpa) ![]desc.MeshData { … }               // baked once, at startup
pub fn sceneExtra(a: *App, i: usize, part: usize) ?desc.Extra // placed per selected point
```

`MeshData` is interleaved `pos3 / nrm3 / uv2`; `Extra` is a model matrix plus a
material. Several **parts** rather than one because a zengine instance carries a
single material — parts are how a domain gets more than one color into its object.
The M-theory demo uses it to open a root and show the Calabi–Yau curled up inside
it, one part per patch of the quintic. Nothing in the framework knows that is what
they are.

### The keys — one table, three consumers

`src/keys.zig` holds every code the framework binds, and the rows the user reads.
It exists because the alternative had already failed: shortcuts spelled as raw
evdev numbers at the point of use (`if (code != 18) return false; // E`) let two
plugins claim `E`, which made the editor unreachable, while the banner printed at
startup went on promising it. A key binds three things at once — the plugin that
handles it, the help the user opens, and the guide drawn over the scene — so it is
declared once and read three times.

The layout: presenting gets the keys you can find in the dark (`P` next, `Backspace`
back, `K` kiosk, `F` fullscreen, `H` help); everything that changes what you see is
the letter that names it (`C` colors, `S` subset, `E` edges, `T` tumble, `R` reset,
`O` editor, `X` export); the domains get what is left (`G`, `N`, `M`, `B`, `J`, `±`)
and declare theirs in `actions`, whose `help` line lands in the card automatically.

`src/plugins/guide.zig` builds that card from `keys.help_rows` and `D.actions`, so a
demo that adds a key documents it by adding it. Esc is layered: the card first, then
the panel, then the app.

### The editor — authoring the deck from inside the demo

`src/plugins/editor.zig` is a plugin like any other (`O`, or `--editor` from the
launcher), and it edits the deck the demo is playing. Two things make it cheap:

- **The dropdowns are the domain's own tables.** `preset`, `color`, `filter` and
  `edge` are names resolved against `D.presets`, `D.color_modes`, `D.filters` and
  `D.relations` — the same lookup `slides.show()` does. A new domain therefore gets
  a working editor with no editor code of its own.
- **The preview is not a second path.** The editor never hands a `Slide` across the
  thread boundary; it serializes its model to ZON and publishes the string, and the
  render thread parses it and calls `slides.show()` — which is precisely what `F5`
  does. Save writes those same bytes. What you previewed is what the file says.

`--deck=<path>` points a demo at someone else's slides, which is what a demo
authored in the launcher is: an existing domain, a file of your own, and a deck.

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
tabulates it once, offers it as an edge mode, and flares it around the
selection (the lighthouse). An action binds a key to a domain verb:

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
5. `zig build run-demo -Ddemo=mine`. Press `P`. Edit `deck.zon`, press `F5`.

The molecule domain is ~300 lines including all its prose — that is the real
cost of a new interactive paper.
