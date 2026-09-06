# Changelog

All notable changes to this project will be documented in this file.

## [0.11.0] - 2026-09-06

### 🚀 Features

- *(markpdf)* Pad emoji segments and link the ext test driver
- *(markpdf)* Borderless admonitions, quote bars aligned with them
- Add the markpdf-web playground
- Harden markpdf-web against abusive input
- Make remote image fetching optional, off on the demo
- Stream the rendered PDF from memory, write no temp file

### 🐛 Bug Fixes

- Resolve emoji advance through the alternate-CID map

### ⚙️ Miscellaneous Tasks

- Pin markd at footnotes-v3 for the byte-offset label fix
- Publish markpdf-web images to ghcr for amd64 and arm64
- Check out the litehtml submodule for image builds
- Sanitize the artifact name (no slashes allowed)

### Markpdf-web

- Rate-limit renders per client and throttle auto-render

### Web

- Cut the feature cards down to three
- Drop the external-link arrows
- Mention embedded HTML in the GFM feature card

## [0.10.0] - 2026-09-06

### 🚀 Features

- *(markpdf)* Render markdown to PDF via litehtml + libharu
- *(markpdf)* Internal anchor links as PDF GoTo annotations
- *(markpdf)* Page headers and footers with page numbers
- *(markpdf)* Base16 themes via -t
- *(markpdf)* Fetch remote images and convert other formats
- *(markpdf)* Document new flags and features in README
- *(markpdf)* Drop hardcoded background for code inside pre
- *(markpdf)* Syntax highlighting for fenced code blocks
- *(markpdf)* Align CLI help with markterm
- *(markpdf)* Remove viewer-drawn borders from link annotations
- *(markpdf)* Fix list indentation and per-line code block alignment
- *(markpdf)* Clip literal blocks and narrow the usage line
- *(markpdf)* Fix remote image fetching, scale images to fit
- *(markpdf)* Fix gmode poisoning on circle markers, add useful libharu errors
- *(markpdf)* Scale wide tables to fit, restore outline after revert
- *(markpdf)* Wrap long lines in literal blocks (pre-wrap)
- *(markpdf)* Render SVG images via external rasterizer
- *(markpdf)* Render WebP images via ImageMagick fallback
- *(markpdf)* Accept a single --font occurrence
- *(markpdf)* Render complete HTML documents directly
- *(markpdf)* Embed fonts, fix CID font handling
- *(markpdf)* Raise super/subscripts, complete table outer borders
- *(markpdf)* Fix table borders, drop body margin, render task lists
- *(markpdf)* Built-in stylesheets (--style, --list-styles, --print-style)
- *(markpdf)* Paginate wide tables in flow space
- *(markpdf)* Draw borders collapse-style so table grids connect
- *(markpdf)* Book style justifies list items
- *(markpdf)* Split tables across pages at row boundaries
- *(markpdf)* --pageless single-page output mode
- *(markpdf)* Style kbd, mark, u/ins, q and abbr inline elements
- *(markpdf)* Scale pageless output to fit the PDF page-dimension limit
- *(markmark)* Fix crash on code blocks without a fence language
- *(markmark)* Keep blank lines between paragraphs
- *(markpdf)* Map outline destinations through flow space
- *(markpdf)* Scope texmath includes and pass libtexprintf a writable string
- *(markpdf)* Add litehtml CI-parity guard and per-page drawing specs
- *(markterm)* Exactly one blank line between blocks, line-drawing table borders
- *(markpdf)* Hyphenated fully-justified paragraphs (--hyphenate)
- *(markpdf)* Never split table rows across pages
- *(markpdf)* Coverage-driven font fallback for glyphs the primary lacks
- *(markpdf)* Draw non-BMP codepoints (emoji!) through alternate CIDs
- *(markpdf)* Continuation table rows keep their top border
- *(markpdf)* Clean border rules at table page cuts
- *(markpdf)* Surface image failures, correct alpha on themed pages, guard the C boundary
- *(markpdf)* Spec coverage for emoji CIDs, table page cuts, and crash paths
- *(markterm)* Measure display width, tolerate parser data gaps
- *(markterm)* Readability pass on math, links, images, headings, code
- *(markterm)* Color GFM alert gutters per type
- *(markterm)* Formatting fixes from ameba
- *(markterm)* Optional hyphenation when wrapping
- *(markpdf)* Work as a library via Markd::Pdf::Renderer
- *(compare)* Track the comparison harness
- *(markpdf)* Keep-with-next survives the first line-box candidate
- *(markpdf)* Format the pagination spec

### 🔖 Releases

- Release v0.10.0

### 📚 Documentation

- Add BUILDING.md covering build modes and licensing
- Add upstreaming section to the TODO
- State the threading contract for the pdf renderer

### ⚙️ Miscellaneous Tasks

- Build the C shim for markpdf
- Build libharu from source (Ubuntu ships no libharu package)
- Replace mdl with markdownlint-cli2
- Precommit
- Parse component prefixes in the changelog, ship markpdf release assets
- The AUR update runs manually after the release
- Defer the markpdf-web target until its sources land

### README

- Drop done TODO — all base16 themes already highlight

### Build

- Export libharu headers for the shim (no system libharu needed)
- Bump markd pin for footnote review fixes
- Bump markd pin for the footnote processor refactor
- Pin markd via the footnotes-v2 tag

### Ext

- Make the patched libharu build real, teach it cmap format 12

### Markpdf/markterm

- Math rendering with optional libtexprintf
- Math rendering with optional libtexprintf

## [0.9.0] - 2026-09-01

### 🚀 Features

- Wrap wide tables to max_width
- Support footnotes

### 🐛 Bug Fixes

- Add missing strikethrough style to themes
- Preserve soft breaks inside wrapped paragraphs
- Degrade gracefully when image rendering fails
- Handle images with empty alt text in markdown output
- Friendly CLI errors and correct markmark identity
- Time out terminal color queries instead of hanging
- Round-trip strikethrough in markdown output
- Make do_release.sh fail fast and upload all release assets
- Drop unused PKGNAME variable from do_release.sh
- Round-trip task lists, alerts and block quotes
- Parse OSC color reply channels in the right order
- Keep heading levels in unwrapped output and bullets on task lists
- Restore tracked shard.lock after the static build
- Make the static build work without a TTY
- Add readline to the static build dependencies
- Add ncurses static library to the static build

### 🔖 Releases

- Release v0.9.0

### 🚜 Refactor

- Extract shared TextRenderer base and CLI helpers

### ⚙️ Miscellaneous Tasks

- Fix ameba lint issues and scope linting to project sources
- Pin markd to a commit and track shard.lock
- Add GitHub Actions workflow
- Install readline and libxml2 dev packages before building
- Run ameba from its installed source instead of a binary
- Only lint with the latest Crystal version

## [0.8.1] - 2026-02-20

### 🐛 Bug Fixes

- Move theme initialization from class-level to instance initializer

### 🔖 Releases

- Release v0.8.1

## [0.8.0] - 2026-02-14

### 🚀 Features

- Add maximum width feature for text wrapping

### 🐛 Bug Fixes

- Remove double spaces in word wrap output
- Update terminal width test to be environment-agnostic

### 🔖 Releases

- Release v0.8.0

### 🚜 Refactor

- Use term-screen library for terminal width detection

## [0.7.0] - 2026-02-13

### 🚀 Features

- Add GFM table support to both renderers
- Restore styling in table cells with placeholder replacement

### 🐛 Bug Fixes

- Update tests and link rendering for compatibility
- Enable GFM by default and fix inline content in table cells
- Properly size table columns and strip ANSI codes from cells

### 🔖 Releases

- Release v0.6.3
- Release v0.7.0

### ⚙️ Miscellaneous Tasks

- Use my docopt fork

## [0.6.2] - 2025-09-04

### 🔖 Releases

- Release v0.6.2

### Build

- Minor fixes

## [0.6.1] - 2025-09-04

### 🔖 Releases

- Release v0.6.1

### Build

- Include markmark in releases and packages

## [0.6.0] - 2025-09-04

### 🚀 Features

- Add markmark for markdown->markdown rendering
- Added strikethrough support
- Added strikethrough support for markmark

### 🐛 Bug Fixes

- Respect soft breaks
- Issue #4: COLORFGBG was handled backwards

### 🔖 Releases

- Release v0.6.0
- Release v0.6.0

### 🧪 Testing

- Fix broken test

### Build

- Updated dependencies

## [0.5.1] - 2024-09-09

### 🐛 Bug Fixes

- Support - as filename to read stdin

### 🔖 Releases

- Release v0.5.1

### ⚙️ Miscellaneous Tasks

- Todo management

## [0.5.0] - 2024-08-31

### 🚀 Features

- Added -l option to force use of html-like links

### 🔖 Releases

- Release v0.5.0

### ⚙️ Miscellaneous Tasks

- Ameba path
- Fix install target

## [0.4.0] - 2024-08-29

### 🚀 Features

- Highlight HTML blocks and inline HTML

### 🐛 Bug Fixes

- Show image targets as links when images are not supported
- Simplify and make reliable image support

### 🔖 Releases

- Release v0.4.0

### ⚙️ Miscellaneous Tasks

- Adjusted markdown check

## [0.3.3] - 2024-08-28

### 🐛 Bug Fixes

- Always colorize even when piped, so you can use a pager

### 📚 Documentation

- Add TODO
- Update building instructions

## [0.3.2] - 2024-08-27

### 🐛 Bug Fixes

- Handle unknown languages in fenced block

### 🔖 Releases

- Release v0.3.2
- Release v0.3.2

### ⚙️ Miscellaneous Tasks

- Added cliff
- Updated hooks
- Ignore generated files

### Build

- Script to do releases
- Use local ameba
- Change from Makefile to Hacefile

## [0.1.0] - 2024-07-31

<!-- generated by git-cliff -->
