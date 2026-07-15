# The samples the profile demos open with

Five of the nine demos are *profiles*: they exist to open a file you bring — a
structure, a catalog, an edge list, a table, a matrix of vectors. That is their whole
point, and it used to be their whole problem, in two places:

* **In a browser** there is no file to bring. Those demos simply were not on the web.
* **Natively**, a demo launched without an argument died with `NoInputFile` /
  `NoSkyCoordinates` — an error message that tells you what went wrong and nothing
  about what to do, and which the launcher happily produced by handing a demo the
  wrong file.

So each profile now **ships one real dataset** and opens it when nothing else is given
(`sample_name` / `sample` in its `domain.zig`, `@embedFile`d into the binary). The demo
always has something to show; the file you bring replaces it.

Real data, not fabrications: a plot that looks plausible and means nothing is worse for
a scientific tool than an empty window.

| Demo | File | What it is | Source & licence |
|---|---|---|---|
| `chem` | `chem/sample.pdb` | **Crambin** (PDB `1CRN`), 46 residues — the classic high-resolution small protein. | [RCSB PDB](https://www.rcsb.org/structure/1CRN). PDB data are in the public domain (CC0). |
| `astro` | `astro/sample.csv` | **3,081 stars**: the solar neighbourhood — everything within 25 parsecs. Columns: name, ra, dec, dist (pc), mag, ci, spect. | [HYG database](https://github.com/astronexus/HYG-Database) v4.1, trimmed. CC BY-SA 4.0 (David Nash) — compiled from Hipparcos, Yale BSC and Gliese. |
| `graph` | `graph/sample.csv` | **Zachary's karate club**: 34 members, 78 ties. The club split in two, and the split is exactly what the community detection finds — which is why this graph has been the standard test since 1977. | W. W. Zachary, *An Information Flow Model for Conflict and Fission in Small Groups*, J. Anthropological Research **33** (1977). Edge list transcribed from NetworkX's copy of the published matrix. |
| `data` | `data/sample.csv` | **Iris**, 150 flowers, 4 measurements, 3 species. | R. A. Fisher (1936) / UCI ML Repository. Public domain. |
| `embed` | `embed/sample.csv` | **Handwritten digits**: 1,797 vectors of 64 pixels (8×8), plus the digit each one is. PCA and t-SNE separate them by digit — which is the thing that demo exists to show. | scikit-learn's `digits` (a copy of UCI *Optical Recognition of Handwritten Digits*). Public domain / BSD. |

One transcription note, because it cost an hour: the karate matrix as published (and as
carried in NetworkX's source) has a few asymmetric cells — transcription zeros. Reading
only the upper triangle gives **77** edges; the canonical count is **78**. An edge is
therefore taken when *either* half of the matrix declares it. The degrees then come out
right: node 0 (Mr. Hi) has 16, node 33 (the instructor) has 17.

## Two things that cost an evening, and would cost it again

**Right ascension is in HOURS.** HYG's `ra` column runs 0–24, not 0–360, and the domain
multiplies by π/180 because that is what every other catalog means by "ra". Fed the raw
column, all 3,081 stars land inside a 24° wedge, and the solar neighbourhood — which,
seen from inside it, must be a *sphere* — comes out a cigar. The sample stores degrees
(`ra × 15`). If a figure's SHAPE is impossible, suspect the units before the renderer.

**Density is a choice, not a detail.** The first cut of this sample was every naked-eye
star (mag ≤ 5.5), out to hundreds of parsecs: 5,646 points that, in a unit ball with
sizes set by apparent magnitude, overlap into one white mass. 25 pc is the radius at
which the stars are still separate objects you can orbit and click — and at which the
colours tell the truth about our neighbourhood: mostly orange K and red M dwarfs, with
a handful of bright white A stars (Sirius, Vega, Altair) among them.
