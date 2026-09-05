# Markdown → PDF: markpdf vs. the alternatives

*Measured on 2026-09-04, Arch Linux; all data in this directory.
Feature matrix re-verified 2026-09-05 against the current build (all
cells unchanged; the F25 probe now accepts both logical-order Arabic,
as extracted by shaped routes, and visual-order Arabic, as extracted
by direct renderers). Performance numbers still from the 2026-09-04
release-build run. Reproduce with `./render.sh && python3 check.py &&
./bench.sh && python3 sizes.py`.*

markpdf is not the only way to turn markdown into a PDF, and "just use
pandoc" is the standard answer. This document compares markpdf against
seven real toolchains a user might pick, on three axes: **what each
produces** (feature completeness, verified against a kitchen-sink
document), **what it costs to install**, and **how fast it renders**.

## The contenders

| Toolchain | Architecture | Runs as |
|---|---|---|
| **markpdf** (ours) | markd → HTML → litehtml layout → libharu | single binary (Crystal + C++ shim, statically linkable) |
| **goldmark-pdf** | goldmark → own layout → gofpdf | single Go binary, but a library: needs ~15 lines of Go to get a CLI |
| **pandoc → weasyprint** | pandoc → HTML → Pango/Cairo paged renderer | two tools, Python stack underneath |
| **pandoc → tectonic** | pandoc → LaTeX → XeTeX | two tools, LaTeX bundle downloaded on first use |
| **pandoc → typst** | pandoc → typst markup → typst | two tools, modern typesetting engine |
| **md-to-pdf** | marked.js → HTML → headless Chrome | npm package, pulls a full Chromium |
| **pandoc HTML → chromium CLI** | pandoc → HTML → `chromium --print-to-pdf` | whatever browser is already installed |
| **lowdown → groff** | lowdown → roff (ms) → groff -Tpdf | two tiny C tools |

Everything was driven from one input document,
[kitchen-sink.md](kitchen-sink.md), which exercises 29 features (the F
IDs below match its sections). Each toolchain rendered the same file;
where a toolchain cannot consume some input, the preprocessing it needs
is listed — that burden is part of the comparison.

## Feature matrix

Automated extraction (`check.py`) probes the text layer of each PDF for
sentinel phrases; every cell was then confirmed or corrected by visually
inspecting the rendered pages. "✗" means the feature is missing, mangled,
or visibly wrong. Notes on the trickier cells:

- the text layer can contain codepoints whose glyphs never rendered
  (markpdf's tofu for CJK), so text probes alone lie — the visual pass
  is what decides;
- pandoc wraps images in `<figure>` and prints the alt text as a
  caption in every route, so alt-text leakage cannot detect image
  failure; images were judged visually;
- the harness configures fonts where tools accept them, so a cell
  means "missing even when configured": tectonic runs with
  `-V mainfont="DejaVu Sans" -V CJKmainfont="Noto Sans CJK SC"` (its
  dropped CJK and symbols; color emoji stay impossible in XeTeX),
  lowdown runs `groff -k` (UTF-8 text), and markpdf gets a
  converted-to-TrueType Noto Sans CJK via `--font` (emoji and symbol
  fallback fonts are discovered automatically);
- hyphenation (F29) is configured where the tool accepts it: markpdf
  runs `--hyphenate`, the WeasyPrint route gets `hyphens: auto` +
  `lang="en-US"` (print.css), groff hyphenates by default, and the
  chromium route gets the same `hyphens: auto` override injected;
- the chromium route needs `--password-store=basic` (headless startup
  otherwise pops a keyring dialog), `--generate-pdf-document-outline`
  (bookmarks), a scratch `--user-data-dir`, and
  `--virtual-time-budget`; even then the CLI hangs forever when the
  HTML references remote resources.

| Feature | markpdf | goldmark | pandoc+weasy | pandoc+tectonic | pandoc+typst | md-to-pdf | chromium | lowdown+groff |
|---|---|---|---|---|---|---|---|---|
| OUTLINE bookmarks from headings | ✓ | ✗ | ✓ | ✓ | ✓ | ✗ | ✓ | ✓ |
| F01 headings h1–h6 | ✓ | ⚠ | ✓ | ✓ | ✓ | ✓ | ✓ | ⚠ |
| F02 emphasis + strikethrough | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| F03 inline code + entities | ✓ | ⚠ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| F04 links (inline/ref/autolink/mail) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| F05–F06 local PNG/JPEG | ✓ | ⚠ | ✓ | ⚠ | ✓ | ✓ | ✓ | ✗ |
| F07 SVG | ✓ | ✗ | ✓ | ✗ | ✓ | ✓ | ✓ | ✗ |
| F08 GIF | ✓ | ⚠ | ✓ | ✗ | ✓ | ✓ | ✓ | ✗ |
| F09 WebP | ✓ | ✗ | ✓ | ✗ | ✓ | ✓ | ✓ | ✗ |
| F10 remote HTTPS image | ✓ | ✗ | ✓ | ✗ | ✗ | ✗ | ⚠ | ✗ |
| F11 data-URI image | ✓ | ✗ | ✓ | ⚠ | ✓ | ✓ | ✓ | ✗ |
| F12 blockquotes + nesting | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| F13 nested lists, ordered start≠1 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| F14 task lists | ✓ | ⚠ | ✓ | ⚠ | ✓ | ✓ | ✓ | ⚠ |
| F15 tables + alignment | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| F16 wide 10-col table | ✓ | ✓ | ⚠ | ⚠ | ✓ | ⚠ | ⚠ | ✓ |
| F17–F18 code highlighting | ✓ | ✓ | ✓ | ✓ | ✓ | ⚠ | ✓ | ✗ |
| F19 plain + indented code | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| F20 long unbreakable code line | ✓ | ✓ | ✗ | ✗ | ✓ | ✓ | ⚠ | ✗ |
| F21 footnotes | ✓ | ⚠ | ✓ | ✓ | ✓ | ✗ | ✓ | ✓ |
| F22 GFM alerts | ✓ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ |
| F23 inline HTML kbd/mark/sub/sup | ✓ | ✗ | ⚠ | ✗ | ✗ | ✓ | ✓ | ✗ |
| F24 emoji | ✓ | ✗ | ✓ | ✗ | ✓ | ✓ | ✓ | ✗ |
| F25 accents / CJK / RTL / symbols | ⚠ | ✗ | ✓ | ✓ | ✓ | ✓ | ✓ | ✗ |
| F26 math `$…$` / `$$…$$` | ✓ | ✗ | ✓ | ✓ | ✓ | ✗ | ✓ | ✗ |
| F27 rules, hard breaks | ✓ | ⚠ | ✓ | ✓ | ✓ | ⚠ | ✓ | ✓ |
| F28 page-breaking | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| F29 hyphenation at line ends | ✓ | ✗ | ✓ | ✓ | ✗ | ✗ | ✗ | ✓ |

Legend: ✓ works · ⚠ works with visible flaws · ✗ missing or broken.
The notes below carry what the icons can't say; the preprocessing each
toolchain needed is its own table further down.

Cell notes:

- **OUTLINE** the LaTeX/typst/WeasyPrint routes, markpdf and groff
  produce bookmarks from headings; chromium does too once
  `--generate-pdf-document-outline` is passed (without it, headless
  Chrome emits none); md-to-pdf has no equivalent switch.
- **F01** goldmark renders near-uniform heading sizes; lowdown
  auto-numbers headings.
- **F03** goldmark eats the space following inline code.
- **F05–F09** goldmark scales local images to page width and *aborts the
  whole render* on SVG/WebP; tectonic floats images with captions and
  needs SVG/GIF/WebP converted first; markpdf needs an optional
  rsvg-convert/ImageMagick on PATH for embedded SVG/WebP; only the first
  GIF frame renders everywhere.
- **F10** goldmark requires fully local input; tectonic and typst need
  the image downloaded ahead; md-to-pdf draws a broken-image icon; the
  chromium CLI hangs forever on remote resources.
- **F11** goldmark drops data-URI images; tectonic prints the caption
  without the image; lowdown dumps the base64 as text.
- **F14** markpdf draws ☑/☐ glyphs with no bullet; goldmark prints the
  literal markup; tectonic and lowdown lose the checkbox entirely.
- **F16** weasyprint, tectonic and chromium clip the wide table or hide
  parts behind scrollbars; markpdf scales it to the content width.
- **F17–F18** md-to-pdf's highlight.js has no crystal lexer (python
  works); lowdown highlights nothing.
- **F20** weasyprint, tectonic and lowdown clip the long line so hard
  that its tail is *gone from the text layer*; chromium keeps the text
  but hides it behind a scrollbar. markpdf and typst wrap the line,
  keeping every character in the PDF.
- **F21** goldmark footnote references lose their markers and the
  definitions become plain paragraphs; md-to-pdf prints literal `[^1]`.
- **F22** GFM alerts: only markpdf renders them, as colored titled
  callouts — every other route leaves literal `[!NOTE]` text.
- **F23** markpdf and the browser routes handle all four elements
  (markpdf styles kbd as a keycap chip and mark with a highlight);
  pandoc+weasyprint leaves kbd unstyled.
- **F24–F25** markpdf renders accents, RTL and math symbols, and now
  emoji and CJK too: emoji come from a monochrome symbol font picked
  automatically (Symbola, Noto Emoji), and CJK renders through any
  covering TrueType — the harness hands over a converted Noto Sans CJK
  via `--font`, since the common Linux CJK packages are CFF `.ttc`
  collections libharu cannot embed. Arabic shows in isolated (unshaped)
  letterforms — no shaping engine — which keeps this a ⚠ visually; the
  probe accepts both the logical order (shaped routes) and markpdf's
  visual-order extraction. In the justified `book` style, wrapping and
  justification split the probe's CJK and Arabic runs, so its cell
  reads ✗ there — an extraction artifact, the text is present.
  lowdown's fonts cannot do CJK/RTL at all, and
  tectonic only with explicit font flags.
- **F26** markpdf renders math without LaTeX: inline `$…$` as Unicode
  (symbols, sub/superscripts, serif italics) and display math as text
  art from the linked libtexprintf (tall integral with limits, real
  superscripts). This is styled text, not math layout — the LaTeX and
  MathML routes stay ahead.
- **F29** hyphenation at line ends, probed structurally: the fixture's
  long dictionary words must appear *split across a line break by a
  hyphen* (`-layout` extraction, since plain pdftotext silently
  re-joins hyphenated lines). markpdf (`--hyphenate`: soft hyphens
  inserted at Knuth–Liang points, hyphen drawn only when the break is
  taken), groff, tectonic/LaTeX and weasyprint/pyphen hyphenate; typst,
  md-to-pdf, chromium (no dictionaries in headless Linux by default)
  and goldmark don't under this configuration.

### Preprocessing each toolchain needed

| Toolchain | Had to preprocess the input because |
|---|---|
| markpdf | CJK font handed over via `--font` (converted TrueType; embedded CFF `.ttc` packages are not embeddable). Optional: rsvg-convert/ImageMagick for embedded SVG or WebP |
| goldmark-pdf | SVG and WebP removed — the library aborts the whole document on unsupported image types |
| pandoc+weasyprint | `lang` metadata + `hyphens: auto` in print.css for F29 |
| pandoc+tectonic | SVG, GIF, WebP converted to PNG; remote image downloaded; CJK/emoji need explicit font setup |
| pandoc+typst | remote image downloaded (typst does no network) |
| md-to-pdf | nothing (remote image silently fails instead) |
| chromium CLI | remote image localized — the CLI *hangs forever* on remote resources ([chromium bug](https://issues.chromium.org/issues/362301064)); plus `--password-store=basic`, `--generate-pdf-document-outline`, `hyphens: auto` injected |
| lowdown+groff | nothing (`groff -k` handles UTF-8 text; images are not a feature at all, and CJK/RTL exceed its fonts) |

## Installation and deployment

Measured on-disk footprints (`sizes.py`); pacman numbers are the full
dependency closure as pacman would install it on a fresh system, so they
overstate what a desktop that already has python/fonts/browser shares.

| Toolchain | Installed size | Deployment story |
|---|---|---|
| **markpdf** | **10.0 MiB binary** (release build; markterm ships at 9.4 MiB static) | copy one file, done. Fonts probed on the system, or embedded via flags. Optional: rsvg-convert/ImageMagick if your documents embed SVG or WebP |
| goldmark-pdf | 16.8 MiB binary | copy one file — after writing a small Go main yourself |
| lowdown + groff | 238.0 MiB (22 packages) | two well-packaged tools |
| pandoc alone | 804.7 MiB (261 packages) | the "obvious" answer is the heaviest single piece |
| pandoc + typst | 879.5 MiB | + typst is one extra package |
| pandoc + tectonic | 1051.6 MiB + 44.8 MiB LaTeX bundle on first run | bundle downloads on demand, needs network once |
| pandoc + weasyprint | 1372.1 MiB | + Python, Pango stack |
| md-to-pdf (npm) | 426.4 MiB (37 MiB node_modules + 389 MiB bundled Chrome) | `npm install` pulls a private browser |
| chromium | 1713.8 MiB | most desktops already pay this cost |

The single-binary claim holds up: markpdf and goldmark-pdf are the only
options that ship as one artifact with zero runtime dependencies, and
they are two orders of magnitude smaller than the HTML-browser and
LaTeX stacks. markpdf is the only one of the two that is also a
finished CLI.

## Performance

`bench.sh` × hyperfine, whole pipeline (including the pandoc step for
pandoc routes), warm caches, 10 runs (fewer for the long docs), warmup 2.
markpdf measured as the release build. **Bold marks the fastest raw
time per column**; the full-featured reading is in the notes below —
goldmark's book/huge wins come from skipping images, raw HTML and most
features (it cannot render the kitchen sink at all), and lowdown's
small-doc win from not rendering images either. Documents, all real files in
the repo or from the esposito book library:

| tier | content | lines | output |
|---|---|---|---|
| small | kitchen sink (7 images, 29 features) | 238 | 3–9 pp |
| medium | markterm README (images localized) | 161 | 4–8 pp |
| large | generated stress file (200 sections) | 4,599 | 71–115 pp |
| book | *The Adventures of Sherlock Holmes* | 12,218 | 135–221 pp |
| huge | *The Brothers Karamazov* | 37,274 | 409–676 pp |

| Toolchain | small | medium | large | book | huge |
|---|---|---|---|---|---|
| markpdf | 506 ms ± 70 (8 pp) | **141 ms** ± 1 (8 pp) | 464 ms ± 2 (112 pp) | 1.08 s ± 0.02 (221 pp) | 3.36 s ± 0.02 (676 pp) |
| goldmark-pdf | FAIL (aborts on SVG) | 403 ms ± 240 | **447 ms** ± 75 (115 pp) | **0.36 s** ± 0.01 (195 pp) | **0.93 s** ± 0.14 (568 pp) |
| lowdown + groff | **106 ms** ± 1 (4 pp) | 108 ms ± 2 (4 pp) | 481 ms ± 7 (71 pp) | 1.81 s ± 0.01 (135 pp) | 6.10 s ± 0.30 (409 pp) |
| pandoc + typst | 688 ms ± 5 (5 pp) | 673 ms ± 8 | 1.46 s | 1.98 s | 5.33 s |
| md-to-pdf | 1.92 s ± 0.31 (3 pp) | 1.76 s | 2.39 s | 2.23 s | 4.63 s |
| chromium CLI | 935 ms ± 9 (7 pp) | 1.13 s | 2.56 s | 2.53 s | 6.89 s |
| pandoc + tectonic | 1.93 s (7 pp) | 2.12 s | 3.10 s | 3.73 s | 9.09 s |
| weasyprint | 1.66 s (5 pp) | 1.70 s | 11.9 s | 8.44 s | 26.1 s |

Readings:

- **markpdf is the fastest full-featured renderer at every size that
  matters**: 506 ms on the kitchen sink (edging out typst), 141 ms on
  the README (5× the fastest pandoc route), 464 ms for the 112-page
  stress file (goldmark's 447 ms ± 75 is within that run's noise and
  skips images), and 1.1 s / 3.4 s for the two novels — at book and
  huge scale only goldmark-pdf is faster, and it drops raw HTML, skips
  images, and aborts on SVG/WebP. Render time scales linearly with
  document size.
- goldmark-pdf's timings wobble (σ up to ±0.35 s) because it pulls
  fonts from Google unless cached — a network dependency the other
  direct renderers don't have.
- **weasyprint is erratic at scale** — slower than everything on the
  generated file (11.9 s) yet mid-pack on the novels.
- **tectonic pays a ~2 s floor** on every run (XeTeX startup); the
  first compile ever also downloads a ~45 MiB LaTeX bundle.
- Output *file size* on the large doc varies ~20×: lowdown 155 KiB,
  weasyprint 232 KiB, goldmark-pdf 540 KiB, markpdf 706 KiB, typst
  1.8 MiB, chromium 2.99 MiB.

## What markpdf should learn from this

Genuine feature gaps, roughly in order of user impact:

1. **Arabic and complex scripts render unshaped** — letterforms come
   out isolated instead of contextually joined (no shaping engine in
   the shim), so extraction reads visual rather than logical order.
   Real RTL needs HarfBuzz or equivalent.
2. **Math is styled, not laid out** — inline `$…$` renders as italic
   serif with Unicode symbols and sub/superscripts, and `$$…$$` gets
   text art via the libtexprintf the shim links by default
   (`WITH_TEXMATH=0` opts out for GPL-averse packagers). True
   math layout would still need LaTeX/MathML — every non-LaTeX route
   in this comparison is in the same boat, but markpdf matches their
   text-layer behavior.
3. **Color (bitmap) emoji don't embed** — emoji render as monochrome
   outlines from Symbola/Noto Emoji; the popular color CBDT fonts
   cannot be embedded as PDF text and would need rasterizing.
4. ~~Minor: silent image failure still hides problems~~ **Fixed
   2026-09-05**: when no fetcher or rasterizer handles an image,
   markpdf now warns on stderr by default; `LITEPDF_DEBUG` still adds
   per-image detail.

What markpdf already does better than most:

- **GFM alerts render properly** — colored, titled callouts. Every
  pandoc route and every browser route in this comparison leaves them
  as literal `[!NOTE]` text.
- **Hyphenated justified prose** — groff-grade line breaking with a
  flag (`--hyphenate`, `--language en|es`): soft hyphens go in at
  Knuth–Liang points, the hyphen is drawn only when the break is taken,
  and justification never stretches inside a hyphenated word. typst,
  the browser routes and goldmark don't hyphenate in this
  configuration at all.
- **Font fallback built in** — uncovered scripts (CJK, emoji, symbols)
  are drawn through any installed or `--font`-provided TrueType that
  covers them, without configuration; only goldmark does less here and
  it does nothing.
- **Math without LaTeX** — inline math as Unicode with real
  sub/superscripts, display math as text art; no other non-LaTeX
  non-MathML route here does both.
- **Built-in stylesheets** — `--style` switches the whole personality
  (print, book with serif/justified/indented prose, dark, sepia),
  `--print-style` dumps one for editing; themes stay a separate axis.
- **Color themes, headers/footers, page size, margins, fonts** as plain
  flags — no CSS or LaTeX knowledge required.
- **One artifact, no runtime deps** — smaller install than everything
  except goldmark-pdf, with far more features.
- **Header/footer templates with sections** — `--header`/`--footer`
  accept `left|center|right` sections, expand `%p`/`%t`, draw through
  the embedded fonts (base-14 fallback when none), and work on every
  document.
- Data-URI and remote images just work; several "mature" tools can't
  say the same.

## Verdict

The space splits into three families. **Typesetting engines** (tectonic,
typst) produce the most beautiful output and the only real math, at the
cost of a heavy toolchain and input preprocessing. **Browser engines**
(md-to-pdf, chromium) are the most CSS-compatible and handle every
image format, at the cost of a Chrome install, literal footnotes/alerts,
and brittle automation. **Direct renderers** (markpdf, goldmark-pdf,
lowdown) are the lightest and the fastest to start, and this comparison
shows exactly where markpdf's direct approach must catch up (complex-
script shaping, math layout, color emoji) — and where it is already
ahead (alerts, hyphenated justification, emoji/CJK font fallback, math
styling, theming, task-list awareness, footnotes) of everything except
the big engines.

For a single static binary that "just renders my README to PDF",
nothing else in this comparison ships both the fidelity and the
deployment story of markpdf: complete pagination with keep-with-next
headings, wrapped code and scaled wide tables, connected table borders,
task-list checkboxes, PDF outline, SVG/WebP/data-URI/remote images,
hyphenated justification, emoji and CJK through automatic font
fallback, and styles and theming as plain flags — at every size that
matters, the fastest full-featured tool in the set. The remaining gaps
are complex-script shaping (Arabic), math layout, and color emoji.
