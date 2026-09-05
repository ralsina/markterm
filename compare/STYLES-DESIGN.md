# Design: built-in stylesheets for markpdf

Status: **implemented** (with one deviation: the vendored docopt cannot
express an optional option argument, so `--print-style` is a flag that
prints the stylesheet named by `--style` — `markpdf --print-style
--style book`). Open questions resolved as follows: dark auto-picks the
`monokai` code theme unless `--code-theme`/`-t` is given; `--print-style`
does not bake theme colors in; `--style` kept; `reset_css` resets to the
*selected* style. Original design below.

## Problem

markpdf ships exactly one stylesheet (DEFAULT_CSS in src/pdf.cr). The
comparison showed the single biggest "feel" gap for long documents is
typography mode: the default reads like a web page (sans-serif, ragged
right, spaced paragraphs), while real books — and the esposito e-reader
use case — need serif, justified, indented, tighter text. Users can
already layer fixes with `--css`, but they must write them from scratch,
and there is no way to see what the built-in style even contains.

## Goals

1. A small roster of built-in stylesheets covering the distinct
   "output personalities" markpdf has: screen/print, book, dark, sepia.
2. `--style <name>` to pick one.
3. `--print-style [<name>]` to emit a built-in stylesheet on stdout, so
   users can copy, edit, and feed it back through `--css`. This is the
   "GET the included ones" requirement.
4. `--list-styles` for discovery.
5. Library parity: everything the CLI does is available on
   `Markd::Pdf` for embedders.

Non-goals (pinned out): a user stylesheet *search path* (a file argument
to `--css` already covers it), per-element style overrides on the CLI,
CSS custom properties (litehtml does not support them).

## CLI (docopt)

```
Usage:
  markpdf [<file>] [options]
  markpdf --list-styles
  markpdf --print-style [<style>]
  markpdf -h | --help
  markpdf --version

Options:
  -h --help                  Show this screen.
  -t <theme>                 Theme to use for coloring output
  --code-theme <code-theme>  Theme to use for coloring code blocks
  --version                  Show version.
  -o <output>                Write the PDF to a file (defaults to standard output)
  --page-size <size>         Page size: a4 or letter [default: a4]
  --margin <margin>          Page margin in millimeters [default: 20]
  --style <style>            Built-in stylesheet: see --list-styles [default: default]
  --list-styles              List the built-in stylesheets and exit
  --print-style [<style>]    Print a built-in stylesheet to standard output and exit
                             (defaults to the value of --style)
  --css <css>                Extra CSS layered on top of the style; last
                             declaration wins (may be repeated)
  --font <font>              (unchanged)
  --emoji-font <font>        (unchanged)
  --header <header>          (unchanged)
  --footer <footer>          (unchanged)
```

Round-trip workflow this enables:

```console
$ markpdf --list-styles
default  clean sans-serif print style (current)
book     serif, justified, indented — for long prose / e-readers
dark     dark page, light text — for screen reading
sepia    warm paper tones — e-reader default

$ markpdf --print-style book > my-book.css
$ $EDITOR my-book.css
$ markpdf book.md --css my-book.css -o book.pdf
```

`--css` stays an *overlay*: the built-in base is always prepended, user
CSS comes last and wins on equal specificity. Because `--print-style`
dumps a full-coverage stylesheet, editing it and passing it via `--css`
behaves as "my edited copy, with the default plugging any holes" — good
enough in practice because the built-ins set the same property set.
Making `--css` repeatable (small docopt + loop change) lets people keep
their base tweak and snippets separate.

## Layering model

Rendered stylesheet = **style → theme → user CSS**, each layer appended,
last declaration wins:

```
STYLES[ --style ]  +  theme_css( -t )  +  all --css layers
```

This is exactly today's append chain (`css=` appends; theme and user CSS
flow through it); `--style` only chooses what the chain starts from.
The shim already paints the page background from the `body`
background-color rule, so dark/sepia work without C++ changes (verified:
sixteen themes do this today).

## Built-in roster

Four styles, each ~30–45 lines of the same property set (so they
interchange cleanly):

| name    | body type                             | personality / use |
|---------|---------------------------------------|--------------------|
| default | DejaVu Sans 11px, ragged right        | current print style, unchanged |
| book    | DejaVu Serif 12px / 1.6, justified    | long prose, e-readers |
| dark    | #121212 page, #e8e8e8 text            | screen reading |
| sepia   | #f4ecd8 page, #5b4636 text, serif     | e-reader default look |

`book` sketch (all verified litehtml features — see the feature notes):

```css
body  { font-family: "DejaVu Serif", Georgia, serif; font-size: 12px;
        line-height: 1.6; color: #1a1a1a; }
h1, h2, h3 { text-align: center; }        /* chapter headings */
h1 { font-size: 24px; margin: 26px 0 18px 0; }
p    { margin: 0; text-indent: 1.5em; text-align: justify; }
/* keep code and tables modest: same rules as default but tighter */
pre  { background-color: #f6f6f6; border: none; font-size: 10px; }
blockquote { margin-left: 0; font-size: 11.5px; }
```

`dark`/`sepia` sketches: same skeleton as `default` plus
`body { background-color: ...; color: ... }` and dimmed borders, code
fills, table header fills, and alert colors so nothing is white-on-white
or black-on-black. (sepia uses serif body to match e-reader
conventions.)

## Library API

```crystal
Markd::Pdf.style_names            # => ["default", "book", "dark", "sepia"]
Markd::Pdf.style                  # => "default"
Markd::Pdf.style = "book"         # resets the base layer; raises Pdf::Error on unknown name
Markd::Pdf.style_css("book")      # raw stylesheet text (for --print-style); raises on unknown
Markd::Pdf.render(source, out, style: "book")   # optional named arg, applied before theme/css
```

`reset_css` becomes "reset to the *selected* style" (or drops the style
argument and resets to `default`; either is fine — pick one and
document). Existing behavior of `css=` (append) is preserved so the
`-t` theme path in main_pdf.cr needs no change.

## Implementation sketch (when unpinned)

* New file `src/pdf_styles.cr`: `STYLES = { "default" => …, … }` and the
  small API above; `require`d from `src/pdf.cr`. Keeping the literal CSS
  out of pdf.cr keeps that hot file small for the other work in flight.
* `src/main_pdf.cr`: three new options in the docopt text; after option
  parsing: validate `--style` (unknown name → abort listing valid
  names), `--list-styles` prints `"name  first line of description"`,
  `--print-style` prints `style_css(name)` and exits before any render.
* README: new "Styles" subsection under the markpdf heading with the
  round-trip workflow above.

Estimated size: ~150 lines of CSS, ~40 lines of Crystal, ~10 lines of
CLI. No C++ changes; the shim needs nothing new.

## Feature notes the styles rely on (verified in ext/litehtml)

* `text-align: justify` — implemented (line_box.cpp distributes leftover
  width across items, skips the last line of a paragraph); verified
  visually on a 227-page book render via `--css`.
* `text-indent` — parsed and applied in render_inline_context.cpp
  (verify it applies to the block's first line only, per spec).
* Pseudo-class machinery (`:first-child`, `:nth-child`) exists in
  css_selector.cpp — useful for the classic "no indent on the first
  paragraph after a heading"; verify before relying on it.
* No `page-break-*` support anywhere in litehtml/the shim — chapter
  breaks are out of scope for styles (a shim feature for another day).
* No CSS variables, no grid — keep styles to plain properties.

## Open questions

1. Should `--style dark` (or any dark-page style) auto-pick a dark
   tartrazine code theme when `--code-theme` is not given? Today the
   code theme follows `-t` when tartrazine knows it, else `friendly`
   (light) — which would glow on a dark page.
2. Should `--print-style` accept `-t` and bake the theme colors in?
   Lean no (themes are runtime layers, and the printed file would stop
   matching the built-in); document instead.
3. Naming: `--style` vs `--stylesheet`? `--style` collides conceptually
   with `-t` themes; the doc should say styles set *layout/typography*,
   themes set *colors*.
4. Do we want a `list` subcommand style (`markpdf styles list`) for
   future growth, or are the two flags enough? Lean: flags are enough.

## Test plan (for when it is implemented)

* Unit specs: `style_names` includes the four; `style_css` raises on
  unknown; `style=` raises on unknown; `css` starts with the selected
  style's body rule; layering order (style < theme < user).
* Golden renders in the comparison harness: `render.sh` grows a loop
  over styles for the kitchen sink so every style has a visual sample
  next to the alternatives (keeps the comparison honest about default
  look).
* Manual check on the Sherlock book: `--style book` output against the
  `--css`-only justification test already done.
