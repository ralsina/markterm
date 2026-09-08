# Printing with KDP: a markpdf guide

Amazon KDP accepts paperback interiors as PDF, and it enforces its rules
mechanically — a manuscript that misses one gets bounced at upload, or
worse, prints badly. markpdf's `--kdp` mode automates the mechanical
part. This page explains what it does, what it warns about, and the
choices that are still yours to make.

## A complete example

A typical trade paperback, 6"×9", chapters opening on right-hand pages,
mirrored running feet with page numbers:

```console
$ markpdf book.md \
    --kdp \
    --page-size 6x9 \
    --style book \
    --font TypewriterSerif.ttf --font TypewriterBold.ttf --font TypewriterItalic.ttf \
    --emoji-font NotoEmoji.ttf \
    --mirror-headers \
    --footer '|%t|%p' \
    --hyphenate \
    -o book.pdf
```

Order of business after that: check the warnings (below), flip through
the PDF, then upload `book.pdf` as the manuscript to KDP. The cover is
a separate upload with its own template — never include it in the
manuscript.

## What `--kdp` does

| KDP rule (or print convention)        | What markpdf does                                      |
| ------------------------------------- | ------------------------------------------------------ |
| Fonts must be embedded                 | Embeds every font, including emoji and fallbacks; base-14 stand-ins get promoted to an embedded TrueType |
| Bookmarks serve no purpose in print    | Drops the PDF outline (the bookmarks panel)            |
| — (cleanliness)                        | Scrubs the document info dictionary — your metadata does not travel with the file |
| Inside margin must grow with page count | Sizes the gutter from Amazon's table (see below), re-rendering until the count and the gutter agree |
| Chapters open on right-hand pages      | Starts every `h1` on a recto page, inserting blank filler pages when needed |
| Even page count                        | Pads an odd final count with a trailing blank          |

Blank pages — chapter fillers and the parity pad — carry no header or
footer and no content, the way a real book's blanks look. They do count
toward the page number and the `%t` total, because in print they count,
period.

A `--toc` table of contents plays by those same rules: its pages are
ordinary pages — they count toward the page number, the recto fillers
and the even-page pad — and the entry numbers are settled by
re-rendering until the TOC matches the real layout, blanks included.
So `# Chapter 1` after a one-page TOC lands on page 3, and the TOC
says 3.

If you pass your own gutter in `--margin` (the five-value form below),
markpdf respects it and skips the table lookup.

## The warnings, and what to do about them

`--kdp` never blocks a render: it prints warnings on stderr and produces
the PDF, so a draft stays renderable. Each warning names the rule it
would trip at upload.

- **`no --font given`** — kdp mode will embed whatever system fonts
  cover the text, which makes the output depend on the machine that
  rendered it. Pass `--font` (repeatable) for each typeface you want:
  regular, bold, italic. Fonts are matched by their internal family
  name, so bold/italic variants of a registered family are found
  automatically. Pin `--emoji-font` too if you use emoji, for
  reproducible output.
- **`renders at about N DPI (below the 300 DPI print recommendation)`** —
  an image would print soft. Export a higher-resolution version; a
  300 DPI image needs ~1200×1800 px for a full 4"×6" figure.
- **`a font renders at Npt (KDP recommends at least 7pt)`** — something
  in your CSS is too small to read in print (7pt at print size, not
  screen size). Superscript markers legitimately trigger this; use your
  judgment. Bump the CSS size or accept the warning.
- **`KDP paperbacks need 24 to 828 pages (got N)`** — outside that range
  KDP will not print the book. For a draft, ignore it; for a real
  submission, grow the manuscript or check you picked the right trim.
- **`need at least 6.35mm margins on every side`** — KDP requires
  ≥ 0.25" (6.35 mm) of outside margin on a no-bleed interior. Widen
  `--margin`.

## The choices you make

### Trim size (`--page-size`)

KDP prints fixed trims; the PDF must match exactly. Values under 12
read as inches, so the common paperbacks are spelled naturally:

```console
--page-size 5x8      # small mass-market
--page-size 5.5x8.5  # popular for fiction
--page-size 6x9      # the classic trade size
```

A4 is the default and is *not* a KDP trim — always pass `--page-size`.

### Margins and the gutter (`--margin`)

Margins are CSS-style, in millimeters: one value (all sides), two
(top/bottom, left/right), four (top, right, bottom, left), or five
(plus gutter). In kdp mode the gutter is the inside margin and it gets
book parity — left on recto pages, right on verso ones — so both page
faces keep the same text measure.

The gutter comes from Amazon's table by page count:

| Pages     | Gutter           |
| --------- | ---------------- |
| 24–150    | 9.525 mm (0.375") |
| 151–300   | 12.7 mm (0.5")    |
| 301–500   | 15.875 mm (0.625") |
| 501–700   | 19.05 mm (0.75")  |
| 701–828   | 22.225 mm (0.875") |

`--margin 18` is enough for most books; the outside sides just need to
clear 6.35 mm. To control the gutter yourself: `--margin
18,18,20,18,12.7` (top, right, bottom, left, gutter).

### Running heads and page numbers (`--header`, `--footer`, `--mirror-headers`)

Both take text with `%p` (page number) and `%t` (total). Split with `|`
into left|center|right sections; a single section is centered, two are
left and right. `--mirror-headers` swaps the section sides on verso
pages so whatever you put on the outer edge stays on the outer edge of
every page — the book convention, and the reason it pairs with a
gutter margin. The template names its sections for the recto view:
inner|center|outer.

```console
--mirror-headers --footer '|%t|%p'
```

gives you the total centered on every page and the page number on the
outer edge — right-hand pages 1, 3, 5 … on the right, verso pages on
the left. The leading section is empty on purpose: recto footers carry
no inner text.

### Typography (`--style`, `--hyphenate`)

`--style book` is the one aimed at long prose: serif, justified,
indented paragraphs. Dark and sepia styles exist for screen reading and
have no business in a print file. `--hyphenate` (with
`--language en` or `es`) lets justified text break long words cleanly.

### Chapters (`--css`)

The recto-chapter rule is `h1 { page-break-before: right }`, added by
kdp mode under your own CSS. A book that structures itself differently
retargets it in one line:

```css
h1 { page-break-before: auto }   /* the title page, not a chapter */
h2 { page-break-before: right }  /* chapters live at ## */
```

`left`/`verso` mirror it, `recto`/`verso` are accepted spellings, and
blank fillers appear automatically whenever a cut lands on the wrong
parity. The same file can force breaks anywhere with
`page-break-before: always` on a marker div or selector.

Layering, for the record: style → theme → kdp additions → your `--css`
files, later layers winning on equal specificity. One caveat: complete
HTML documents (`.html` input) keep their own stylesheets, so the kdp
additions do not apply there — add the rules yourself.

## What markpdf cannot do for you

- **The cover.** Uploaded separately, built from KDP's cover template,
  with its own spine-width math. Never in the manuscript.
- **Front matter.** Title page, copyright page, dedication — that is
  content. (A `# Title` heading opens on page 1, which is recto by
  definition, so the recto rule does not push it anywhere.)
- **Bleed.** Text-and-figures interiors do not need it; if you want
  edge-to-edge images, markpdf is the wrong tool for that page. Keep
  images inside the margins and the no-bleed rules cover you.
- **The final word.** Run KDP's Print Previewer after upload. It is the
  authoritative check, and it is free.

## Checking your PDF before upload

```console
$ pdfinfo book.pdf | grep Pages        # even, and 24..828
$ pdffonts book.pdf                    # every row "emb: yes"
$ pdftotext book.pdf - | head          # text made it through
```

## Config files and environment variables

Anything you set per-invocation can be made permanent in
`~/.config/markpdf/config.yml` (keys are the long option names):

```yaml
kdp: true
page-size: 6x9
style: book
footer: "|%t|%p"
font: [TypewriterSerif.ttf, TypewriterBold.ttf, TypewriterItalic.ttf]
```

or through `MARKPDF_*` environment variables (`MARKPDF_PAGE_SIZE`).
Command line wins over environment, environment over the config file —
handy for keeping kdp defaults and overriding per project.
