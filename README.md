<div align="center">

# ✴ E8 Explorer

**An interactive research tool for the E8 root system, in the spirit of Garrett
Lisi's *An Exceptionally Simple Theory of Everything* (arXiv:0711.0770) and its
triality extension *C, P, T, and Triality* (arXiv:2407.02497) — window by
[zrame](../Zrame), GPU render by [zengine](../Zengine).**

</div>

---

## What it is

The 240 roots of E8 live in R⁸; every picture of them is a choice of projection.
This tool keeps the whole system live — exact lattice coordinates, the 6720
minimal-angle edges (inner product 1, i.e. 60°), and Lisi's physics labeling —
and lets you steer the 8D→3D projection interactively:

* **Coxeter plane** — the eigenplane of a Coxeter element with rotation angle
  2π/30, computed at startup by orthogonal iteration on C+Cᵀ (C = product of the
  8 simple reflections, Bourbaki base). The xy view is the iconic 30-fold figure.
* **Physics axes** — charge axes in the spirit of Lisi's Elementary Particle
  Explorer (weak-isospin-like × graviweak × color λ8), so particle multiplets
  cluster by quantum number.
* **Lattice axes** — plain e1e2e3, plus free rotation of the view basis through
  any 8D coordinate plane (and a slow "tumble" through three hidden planes).

### The physics labeling (exact, and where it stops being exact)

Roots are classified by the chain **so(8)⊕so(8) ⊂ so(16) ⊂ E8** that Lisi's
assignment builds on — this decomposition is exact Lie theory, checked by unit
tests; the particle *names* follow Table 9 of arXiv:0711.0770 and are Lisi's
interpretation, not derivations:

| roots | count | label (Lisi Table 9) |
|---|---|---|
| ±eᵢ±eⱼ, i,j ∈ 1..2 | 4 | gravity ω (so(3,1) spin connection) |
| ±eᵢ±eⱼ, i,j ∈ 3..4 | 4 | electroweak W±, B1± |
| ±eᵢ±eⱼ, one of 1..2 × one of 3..4 | 16 | frame-Higgs eφ ∈ 4×(2+2̄) |
| ±(eᵢ−eⱼ), i,j ∈ 6..8 | 6 | gluons (su(3) root hexagon, adjoint weights) |
| rest of ±eᵢ±eⱼ, i,j ∈ 5..8 | 18 | colored xΦ "X" bosons ∈ 3×(3+3̄) |
| ±eᵢ±eⱼ mixed (1..4 × 5..8) | 64 | **generation III** (ντ τ t b) — the (8v,8v') block |
| spinor (±½)⁸, even # of − in 1..4 | 64 | **generation I** (νe e u d) — (8s+,8s+') |
| spinor (±½)⁸, odd # of − in 1..4 | 64 | **generation II** (νμ μ c s) — (8s−,8s−') |

Within each 64-fermion generation the su(3) weight decides lepton (singlet, 16)
vs quark (3/3̄, 48 — tinted by their actual color state). su(3) color acts on
coordinates 6,7,8 (λ3 = x6−x7 halved, λ8 = (x6+x7−2x8)/2√3); coordinate 5 is
Lisi's generation-related **w** u(1), and B−L = ⅔(x6+x7+x8).

The three generations are related by Lisi's **triality rotation T**
(arXiv:0711.0770 §2.4.2), implemented here in lattice coordinates: orthogonal,
order 3, maps roots to roots, cycles gen I → II → III, leaves W³ and color
invariant (W±, four eφ, and the six gluons are its 12 fixed roots) — the same t
that extends CPT to the order-96 **CPTt Group** of Lisi's "C, P, T, and
Triality" (arXiv:2407.02497), whose 192 fermion weights in 8 disjoint 24-cells
are exactly the three 64-blocks here. Press `G` on a selected root to hop its
triality orbit. Caveat honestly inherited from the theory: generation II/III
quantum numbers are physical only *via* T (Lisi's own caveat, and the heart of
the Distler–Garibaldi critique); the labels are bookkeeping, not predictions.

Click any root to read its coordinates, class, generation, (λ3, λ8), w and B−L
in the HUD; its 56 nearest neighbors light up, and its two triality partners
flare in generation colors, peaking in I → II → III order. The theory's special
particles are animated all the time: the 18 xΦ bosons — Lisi's new-particle
prediction, the proton-decay mediators — pulse as a wave phased by their w
charge (x1 → x2 → x3), and the 12 triality-fixed roots (W±, four eφ, the gluon
hexagon) breathe slowly. On the GPU path the HDR bloom amplifies the pulses;
the software path draws equivalent additive halos.

### The paper journey (`P`)

`P` turns the explorer into a guided, interactive reading of the papers. The
first press opens the side panel; each further press advances one slide. Every
slide sets the projection, colors, edges and filter to reproduce a specific
figure, and narrates it in the panel with precise citations:

| slide | figure | what you see |
|---|---|---|
| 1 | 0711.0770 Fig 2 | E8 Petrie plane, every root a particle, triality links |
| 2 | 0711.0770 Table 2 | G2 strong charges: gluon hexagon, quark/antiquark triangles |
| 3 | 0711.0770 Tables 5–6 | F4 graviweak plane (12-fold Petrie figure) with triality links |
| 4 | 0711.0770 Figs 3–4 | animated F4↔G2 rotation (Lisi's e8rotation.mov); E6 at the G2 end |
| 5 | 0711.0770 §2.4.1 | the new xΦ bosons alone, split in depth by their w charge |
| 6 | 2407.02497 Tables 1–2 | spin(1,3) boost/spin weights: lattice e1e2 *is* the (ωT, ωS) plane |
| 7 | 2407.02497 Fig 2 | the 192 fermion states, 8 disjoint 24-cells of the CPTt Group |

Clicking a root opens its **card**, on the glass beside the scene: the
particle's supplementary reading, in the window you are already looking at —
no popup, no new surface, no focus change. The root itself is lit in the scene
(white ring and halo) and its triality partners flare around it in turn, which
is what the card would otherwise be showing you a second, smaller copy of. The
side panel simultaneously swaps to **that particle's story** — which block it
belongs to, what Lisi identifies it as, what is exact and what is
interpretation, with citations into 0711.0770, 2407.02497, 1004.4866 and the
Distler–Garibaldi critique 0905.2658 where it applies. `P` resumes the tour;
`Esc` closes the card, then the panel, then the app — layered.

## Controls

```
H           the shortcut card: every key this build binds, this demo's included
P           the paper journey: opens the side panel on a guided slide, then
            advances — each slide reproduces a figure of the papers AND
            narrates it (citations included), with camera choreography and an
            inline diagram; click a root mid-journey for that particle's own
            story (and its card), P resumes the tour
Backspace   one slide back
K           kiosk mode: the journey auto-advances (per-slide dwell)
F           fullscreen (F11 too)
Esc         layered: the shortcut card, then the point card, then the panel,
            then the app

drag        orbit · scroll zoom · click pick a root (click empty space to clear)
1 / 2 / 3   projection: Coxeter plane · physics axes · lattice e1e2e3 (= Lisi's ωT,ωS spin-boost plane)
4 / 5 / 6   paper views: G2 plane (g³,g⁸) · F4 graviweak plane · F4↔G2 rotation
            (in preset 6, ←/→ sweep the F4↔G2 angle and T animates the sweep)
← / →       rotate the view basis through the current 8D plane · Tab next plane
T           8D tumble · Space 3D auto-spin · R reset view
C           colors: physics classes → generations (triality) → so(16) 120⊕128 → hidden depth
S           subset filter: all → bosons → fermions → gen I/II/III → leptons → quarks → d4 blocks
E           edges: all → triality partners → selection-only → none
G           jump the selected root to its triality partner (gen I → II → III → I)
O           open the slide editor · F5 hot-reload deck.zon while authoring
X           export e8_roots.csv (coordinates, labels, weights, charges, triality)
```

`X` writes the full system under the *current* projection — ready for
numpy/pandas/Mathematica. The e8.zig module is dependency-free and usable on its
own for scripted analysis (now at `src/demos/lisi/e8.zig`).

## Architecture: a framework for interactive papers

This repo is two things: a **domain-agnostic presenter framework** for
interactive scientific papers on zengine/zrame, and its reference consumer —
this reading of Lisi's E8 papers. The core (`src/main.zig`) owns only the
window, camera, projection and rasterizers; features are plugins
(`src/plugins/`), and the science lives in a domain package
(`src/demos/<name>/`). Three more domains ship as proof:

```sh
zig build run-demo -Ddemo=mtheory    # E10: where Lisi's E8 goes next (see below)
zig build run-demo -Ddemo=molecule   # caffeine: ball-and-stick, purine-core tour
zig build run-demo -Ddemo=polytope   # the 24-cell: three 16-cells, isoclinic rotation
```

### The M-theory demo

`-Ddemo=mtheory` is the framework's answer to "what comes after E8?", and the
first domain built ON another: Lisi's 240 roots are found *inside* E10 — the same
roots, with every inner product between every pair preserved (the tests check all
57 600 of them).

Adjoin two nodes to E8's Dynkin diagram and you get **E10** — infinite-
dimensional and hyperbolic, with a Lorentzian metric that has a light cone. The
roots are the norm-2 vectors of the lattice `{ w ∈ ℤ¹⁰ : Σwₐ ≡ 0 mod 3 }`, and
they are graded by **level** `ℓ = Σwₐ/3`. That grading is the whole point:

| level | roots | | |
|---|---|---|---|
| ℓ = 0 | 90 | `sl(10)` | the **metric** — gravity |
| ℓ = ±1 | 120 | `C(10,3)` = a 3-form | what an **M2-brane** carries |
| ℓ = ±2 | 210 | `C(10,6)` = a 6-form | what an **M5-brane** carries |
| ℓ = ±3 | 360 | | the **dual graviton** — not in the supergravity Lagrangian |

Those counts are not hard-coded. They come out of solving `Σw = 3ℓ` and
`Σw² = 2 + ℓ²`, and the unit tests assert them. *Nobody put branes into E10; they
fall out of counting its roots.*

| key | |
|---|---|
| `−` / `+` | the level. The slider does not zoom — it unveils M-theory's field content one field at a time. |
| `G` | the **3-form ladder**. The tenth simple root is the only one that changes the level, so climbing it walks metric → M2 → M5 → dual graviton. |
| `B` | **the Big Bang.** The ten scale factors of eleven-dimensional supergravity bounce off the walls of E10's Weyl chamber (Damour–Henneaux–Nicolai) — and the walls *are* these same ten simple roots, in these same coordinates. The projection is sheared by the *live* Kasner exponents, so the figure is stretched and crushed by the actual geometry of space. Each bounce lights the roots the wall is: blue for gravity's nine symmetry walls (level 0), gold for the electric wall (level ±1 — the M2-brane's own roots). Lisi's particles fade to black as the classical sector switches off. |

The same billiard drives the Big Bang prologue of zengine's `big_bang` and
`genesis` animations (`zsim.cosmo`).

See **[FRAMEWORK.md](FRAMEWORK.md)** for the hook contract, the object-descriptor
API, the ZON deck format, and a tutorial for authoring your own interactive
paper.

## Build & run

```sh
zig build         # builds one executable PER DEMO (e8-lisi, e8-mtheory, …) plus e8-menu
zig build run     # opens the LAUNCHER: pick a demo, or author a new one
zig build test    # root-system invariants: 240/56/6720, Table 9 class census,
                  # 3×64 generations, triality order 3 + I→II→III cycle,
                  # Coxeter element order 30, Petrie plane rotation = 12°;
                  # plus the deck serializer's round trip and the SDF→XYZ converter

# one demo, straight, while developing it:
zig build run-demo -Ddemo=mtheory -- --gpu
```

There is one executable per demo because there has to be. A demo's point type and
its dimension are **comptime** — `geom.Vec = [dim]f32` — so `lisi` in 8D and
`chem` in 3D are genuinely different programs. The launcher has no domain at all:
it is a window, a list, and `std.process.Child`.

## The launcher and the editor

`zig build run` opens a **wall of posters** — one card per demo, and a click on
a poster plays it. The posters are drawn, not loaded: each domain gets a few
lines of canvas — roots on their rings, atoms and bonds, a star field, two
t-SNE blobs — deterministic from the card's own index, so the same demo always
wears the same face and nothing ever goes stale. Hover a card and it lifts; the
pencil in its corner opens the same demo **in the editor**, which is how you
read how a deck is made: the slides you are looking at are the ones in the
list. The wall hangs in three shelves:

**Your demos** — what you have authored, scanned from `demos-user/`. It comes
first, because it is the reason you opened the launcher.

**Ready to watch** — the built-in demos whose points are computed, so they need
no file: Lisi's E8, M-theory's E10, the 24-cell, the toy molecule.

**Bring your own data** — one poster per field, closed by a **New demo** card.
Clicking any of them opens the wizard: pick a category, give it data, name it.
A **GPU rendering** toggle (off by default) decides whether the demos the
launcher starts get `--gpu` — software rendering stays the default, for the
reasons at the end of this page. A demo you make is nothing but a directory:

```
demos-user/my-protein/
  manifest.zon    .{ .name = "…", .domain = "chem", .asset = "1ubq.pdb" }
  1ubq.pdb        the data
  deck.zon        the slides
```

Authoring is therefore not inventing a demo — it is choosing which of the domains
that already exist should look at your data, and then writing the slides.

| category | domain | asset | its specialized tool |
|---|---|---|---|
| Chemistry & structural biology | `chem` | PDB, XYZ | **the online vocabulary**: a molecule by name from **PubChem** (3D conformer → XYZ), a structure by ID from **RCSB** |
| Astronomy | `astro` | catalog CSV | the H–R diagram, blackbody color |
| Networks & graphs | `graph` | GraphML, edge list | the Laplacian spectrum, communities |
| Tables | `data` | CSV, TSV | principal axes, k-NN |
| Embeddings / ML | `embed` | `.npy`, CSV | PCA ⇄ t-SNE |
| Mathematics & physics | `lisi`, `mtheory`, … | none (points are computed) | the deck alone |

The network is only ever touched by `src/menu/fetch.zig`, only when you press the
button. No other executable in the project opens a socket.

**The editor** (`O` in any demo, or `--editor`) is its own glass window beside the
running scene — so the scene *is* the preview, and the letters you type into a
title field never reach the demo's single-key shortcuts. The dropdowns for
projection / color / filter / edges are the domain's own declarative tables, so a
new domain gets a working editor for free. "Capture the camera" takes the shot you
are looking at.

It does not hand slide structs across the thread boundary: it serializes the deck
to ZON and publishes the string. The render thread parses it — the same two calls
`F5` makes. So the preview cannot drift from the demo, and *save* writes the very
bytes you already previewed.

```sh
zig build run-demo -Ddemo=lisi -- --gpu   # zengine mesh raster: emissive spheres + edge
                                          # tubes, HDR bloom, dmabuf zero-copy
```

Requirements: Zig 0.16, Linux + Wayland with `../Zrame`, `../Zicro`,
`../Zengine` checked out alongside (path deps). The GPU path additionally needs
Vulkan with dmabuf export.

> **Why is software the default?** It is fast enough, adapts to the window, and
> zrame's dmabuf video plane currently ignores fractional display scaling
> (README: "Scale 1 for now"), so on a 110% KDE display the GPU frame is drawn
> slightly oversized and off-center. On a scale-1 display `--gpu` is the pretty
> path. The GPU scene is ~7000 instances (240 spheres + 6720 tubes); on small
> GPUs prefer `E` → selection-only edges.
