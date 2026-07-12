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

Clicking a root mid-journey swaps the panel to **that particle's story** —
which block it belongs to, what Lisi identifies it as, what is exact and what
is interpretation, with citations into 0711.0770, 2407.02497, 1004.4866 and
the Distler–Garibaldi critique 0905.2658 where it applies. `P` resumes the
tour; `Esc` closes the panel (and only then the app — layered).

## Controls

```
drag        orbit · scroll zoom · click pick a root (click empty space to clear)
1 / 2 / 3   projection: Coxeter plane · physics axes · lattice e1e2e3 (= Lisi's ωT,ωS spin-boost plane)
4 / 5 / 6   paper views: G2 plane (g³,g⁸) · F4 graviweak plane · F4↔G2 rotation
            (in preset 6, ←/→ sweep the F4↔G2 angle and T animates the sweep)
P           the paper journey: opens the side panel on a guided slide, then
            advances — each slide reproduces a figure of the papers AND
            narrates it (citations included); click a root mid-journey for
            that particle's own story, P resumes the tour
← / →       rotate the view basis through the current 8D plane · Tab next plane
T           8D tumble · Space 3D auto-spin · R reset view
E           edges: all → triality partners → selection-only → none
C           colors: physics classes → generations (triality) → so(16) 120⊕128 → hidden depth
F           filter: all → bosons → fermions → gen I/II/III → leptons → quarks → d4 blocks
G           jump the selected root to its triality partner (gen I → II → III → I)
X           export e8_roots.csv (coordinates, labels, weights, charges, triality)
Esc         layered: closes the panel first, then the app
```

`X` writes the full system under the *current* projection — ready for
numpy/pandas/Mathematica. The e8.zig module is dependency-free and usable on its
own for scripted analysis.

## Architecture: plugin-first

The core (`src/main.zig`) owns only the window, the orbit camera, the 8D→3D
projection and the two rasterizers. Every feature is a self-contained plugin
in `src/plugins/`, registered once in `src/app.zig` and reached through
optional hooks dispatched at compile time (`inline for` + `@hasDecl` — zero
indirection, no vtables):

| hook | when |
|---|---|
| `init` | once, after the root system is built |
| `key(code) bool` | evdev keycode, render thread; first plugin to claim it wins |
| `frame` | every frame, before the 8D→3D projection |
| `post` | every frame, after screen positions are valid (picking, HUD) |
| `visual(i, *Visual)` | per root, chained in registry order — later overrides earlier |
| `edgePairs` / `edgeVisual` | which lines to draw and how |
| `status(buf)` | contribution to the HUD status line |

Current plugins: `projections` (presets 1-6, tumble, spin, reset), `colors`
(C + legends), `filters` (F), `edges` (E: lattice/triality/selection),
`selection` (picking, G, detail line), `effects` (xΦ wave, triality-fixed
breathing, orbit lighthouse), `atlas` (A), `panel` (P), `exporter` (X).
Adding a feature = one file in `src/plugins/` + one line in
`app_mod.plugin_list`. Plugin state is plain data (`P.State`) — all hooks run
on the render thread; cross-thread traffic stays in the core.

## Build & run

```sh
zig build test    # root-system invariants: 240/56/6720, Table 9 class census,
                  # 3×64 generations, triality order 3 + I→II→III cycle,
                  # Coxeter element order 30, Petrie plane rotation = 12°
zig build run     # software renderer (default): multithreaded additive raster,
                  # follows the live window size
zig build run -- --gpu   # zengine mesh raster: emissive spheres + edge tubes,
                         # HDR bloom, dmabuf zero-copy (writes e8-scene.gpak)
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
