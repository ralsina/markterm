# Diagnosis: markpdf's superlinear rendering on long documents

Status: **fixed** — option 1 implemented in the vendored litehtml
(submodule commit db019543: render_item::calc_subtree_bounds +
clip-based subtree pruning in draw_children). Measured on the scaling
probe: 25%/50%/100% of the book now take 0.36/0.65/1.20 s (was
0.70/2.13/6.71) — ratios ~1.8, and the huge tier dropped from 53.5 s
to 3.71 s (37k lines, 696 pages, ratio 3.09 vs the 3.5 acceptance
bar). Page counts are unchanged and sampled pages are pixel-identical
to the pre-fix build.

## The evidence

Scaling curve, Sherlock Holmes truncated to prefixes
(`compare/.bench-book.md`, single runs):

| input | lines | time |
|---|---|---|
| 25% | 3,054 | 645 ms |
| 50% | 6,109 | 2,051 ms |
| 100% | 12,218 | 6,415 ms |

Each doubling of input multiplies time by ~3.2 and the ratio worsens
with size — superlinear, tending to quadratic. At the full novel range
the bench measured 6.05 s (12k lines) vs 53.5 s (37k lines): 3× input,
8.8× time ≈ 3².

`perf record` on the book render:

```
74.92%  litehtml::render_item::draw_children(...)
```

Three quarters of all CPU is the draw traversal. The hot leaves inside
it are destructor-shaped (`render_item_inline_context::~`,
`render_text::~`) — consistent with heavy per-call temporary
allocation/teardown while walking, and with the walk being repeated per
page.

## The mechanism

`litepdf_render` (ext/litepdf.cpp) lays the document out **once**, then
splits it into page windows and draws each one separately:

```cpp
doc->render(content_width);                     // once, fine
container.collect_breaks(...);                  // once, fine
for (const auto& window : windows) {            // P pages
    ...
    doc->draw(&context, 0, 0, &clip);           // walks the WHOLE element tree
}
```

litehtml's `document::draw` → `render_item::draw_children` culls
elements whose boxes miss the clip, but culling is a per-element
*visit* — it does not exploit document order to skip whole subtrees
that lie entirely below the window. So each page costs O(total
elements) even though it draws O(one page) of them:

    total = pages × elements = O(N²)   (pages ∝ N for fixed page size)

HPDF work and layout are linear; the walk is the quadratic term.

## Fix options (best first)

1. **Prune subtrees in litehtml's draw walk** (small, upstreamable).
   During the single layout pass, annotate every `render_item` with its
   subtree's bottom edge (a `max_bottom` a few lines deep in
   `render_item`, or computed in `collect_breaks`' existing walk). In
   `render_item::draw`, return early when `subtree_top > clip.bottom`
   (and symmetrically when `subtree_bottom < clip.top`) *for in-flow
   content*. Content is in document order, so per-page cost collapses
   to ~one page of elements + O(1) skipped-root checks. Drawing logic,
   clipping, and output are untouched — the walk just stops visiting
   dead subtrees. Guard for out-of-flow boxes (absolute/fixed elements
   break document-order assumptions): prune only when the subtree
   contains no positioned escapes, or skip the optimization for those
   subtrees.
2. **Flat draw list in the shim** (bigger refactor, no litehtml patch).
   `collect_breaks`/`collect_links` already walk the tree once; a
   sibling `collect_drawables` could record elements in paint order
   with their y, and each page would draw only its slice by y range
   (binary search). More code, and it must reproduce litehtml's
   stacking/clip semantics — option 1 gets the same win for ~20 lines.
3. Not viable: batching all pages into one draw call (libharu pages are
   separate canvases; the per-page HPDF context switch is required).

## Expected impact

The quadratic term dominates from ~10 pages onward. Removing it leaves
the linear floor (layout + HPDF writes): the book should drop from
6.4 s to roughly the 25%-prefix cost × 4 ≈ 1.5–2.5 s, and Karamazov
from 53.5 s to somewhere near 5–10 s — competitive with typst at
book scale, on top of markpdf's existing small-document lead.

## How to verify the fix

The harness is ready-made:

```console
$ ./bench.sh 10          # book and huge tiers show the new curve
$ head -n 3000 .bench-book.md > .scale.md && # re-run the 3-point
  ...                      # scaling probe above; ratios should approach 1:2:4
```

Acceptance: time(37k lines) / time(12k lines) < 3.5 (i.e., ~linear),
with byte-identical page counts (227 / 696) and visually identical
output on the book sample pages.
