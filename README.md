# MARKTerm

[![CI](https://github.com/ralsina/markterm/actions/workflows/ci.yml/badge.svg)](https://github.com/ralsina/markterm/actions/workflows/ci.yml)

Markterm is a library and program to render Markdown to
a terminal. It's inspired by [Glow](https://github.com/charmbracelet/glow)
and implemented using [Markd](https://github.com/icyleaf/markd)

It can also render Markdown to Markdown if you really need that :-)

## Features

* It will syntax highlight code blocks
* It will try to handle light and dark terminal themes. Since
  it uses the terminal's colors, it should match things like
  vs code themes in the vs code terminal, etc.
* In general it tries to look good and not gaudy
* It will do the right thing if output is not a tty
* Can be used as a library or as a program

![markterm on a light terminal](https://ralsina.me/images/markterm-light.png)
![markterm on a dark terminal](https://ralsina.me/images/markterm-dark.png)

## TODO

* ✅ Configurable themes
* ✅ Implement HTML-style links as supported in kitty/alacritty
* ✅ Don't break paragraphs on soft breaks
* ✅ Implement images as supported in kitty (requires timg, kinda buggy)
* ✅ Images in all terminals (requires catimg, kinda useless)
* ✅ Implement HTML block support
* ✅ Better textual image display when images are not supported
* ✅ Maybe only support timg with options
* ✅ Support being used in a pipeline
* ✅ Task lists, GFM alerts, wrapped tables
* ✅ Footnotes
* Implement internal piping to $PAGER
* Allow enabling/disabling images/html-style-links via CLI (partly done)
* Use crystal-term/color to detect color capabilities
* ✅ Wrap styled table cells at word boundaries when tables are squeezed
* markpdf: richer header/footer templating (alignment, per-page
  sections, fonts)

## Usage as a program

Either get a static binary from the [releases page](https://github.com/ralsina/markterm/releases)
or build from source:

* Install crystal
* Checkout the repo
* run `shards build`

This is the help:

```docopt
Markterm - A tool to render markdown to the terminal

Usage:
  markterm <file> [-t <theme>][--code-theme <code-theme>][-l]
  markterm -h | --help
  markterm --version

Options:
  -h --help                  Show this screen.
  -t <theme>                 Theme to use for coloring output
  --code-theme <code-theme>  Theme to use for coloring code blocks
  --version                  Show version.
  -l                         Force html-like links

If you use "-" as the file argument, markterm will read from stdin.
```

There is a similar `markmark` binary that will render markdown to markdown.

### markpdf

The `markpdf` binary renders markdown to PDF. It converts the markdown to
HTML with markd, lays it out with [litehtml](https://github.com/litehtml/litehtml),
and writes the PDF through [libharu](https://github.com/libharu/libharu),
via the C++ shim in `ext/`. Styling is CSS: `markpdf` ships a print-oriented
default stylesheet, and you can add your own rules with `--css`.

```docopt
Markpdf - A tool to render markdown to PDF

  Usage:
    markpdf [<file>] [options]
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
  --css <css>                Additional CSS file with extra styles
  --font <font>              TTF font file to embed (can be repeated). Fonts are
                             matched by their internal family name; system fonts
                             are used automatically when available.
  --emoji-font <font>        TTF font used for emoji and symbols the main fonts
                             lack (auto-detected from system fonts by default)
  --header <header>          Page header text; "%p" is the page number, "%t" the
                             total page count
  --footer <footer>          Page footer text; supports the same placeholders

If you use "-" as the file argument, markpdf will read from stdin.
Images are resolved relative to the input file's directory.
```

Text uses embedded TrueType fonts with full Unicode support: the shim
matches the CSS `font-family` names against the fonts you pass with
`--font` and against installed system fonts (`/usr/share/fonts`,
`~/.fonts`, ...), falling back to the PDF base-14 fonts for Latin text
when nothing matches.

Complete HTML documents are detected automatically and rendered
directly — no markdown conversion — so markpdf doubles as a small
HTML→PDF converter for the HTML subset litehtml supports.

Links pointing at `http(s)://` or `mailto:` URIs become clickable PDF
link annotations, and internal anchors (including footnote references
and their back-links) jump to their targets. Fenced code blocks get
tartrazine syntax highlighting (the `docopt` lexer included).

Complete HTML documents are detected automatically and rendered
directly — no markdown conversion — so markpdf doubles as a small
HTML→PDF converter for the HTML subset litehtml supports.

Example with a dark base16 theme, page numbers and a header:

```bash
markpdf notes.md -o notes.pdf -t "0x96f" --header "notes" --footer "%p / %t"
```

Building `markpdf` from source requires libharu (`pacman -S libharu`,
`apt install libharu-dev`, ...) and a C++ toolchain: run `make -C ext`
once to build the shim, then `shards build`.

## Usage as a library

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     markterm:
       github: ralsina/markterm
   ```

In your code, use it like this:

```crystal
  puts Markd.to_term(source)
  puts Markd.to_md(source)
```

## Contributing

1. Fork it (<https://github.com/ralsina/markterm/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

* [Roberto Alsina](https://github.com/ralsina) - creator and maintainer
