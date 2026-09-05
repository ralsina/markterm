# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when
working with code in this repository.

## Build and Development Commands

```bash
# Build all three binaries (markterm, markmark, markpdf)
shards build

# Run tests
crystal spec -v --error-trace

# Run a single test file
crystal spec spec/markterm_spec.cr -v --error-trace

# Run specific test by line number
crystal spec spec/markterm_spec.cr:42 -v --error-trace

# Lint and auto-fix
crystal tool format src/*.cr spec/*.cr
ameba --fix
```

If you have [hace](https://github.com/ralsina/hace) installed, you can use:

- `hace build` - build the project
- `hace test` - run tests
- `hace lint` - format and lint

## Architecture

MARKTerm is a Crystal library and CLI tool for rendering Markdown to
terminal output with syntax highlighting and theme support.

### Three Binaries

- **markterm** (`src/main.cr`) - Renders Markdown to terminal output
- **markmark** (`src/main_mark.cr`) - Renders Markdown back to Markdown
  format
- **markpdf** (`src/main_pdf.cr`) - Renders Markdown or HTML to PDF

### Core Components

- `src/markterm.cr` - `Markd::TermRenderer`: Custom Markd renderer that
  outputs styled terminal text. Handles all markdown elements (headings,
  code blocks, links, images) with theme support.

- `src/markmark.cr` - Renderer that converts Markdown back to Markdown
  format, useful for reformatting.

- `src/terminal.cr` - Terminal utilities: capability detection (links,
  images), automatic light/dark theme detection, image rendering via
  `timg`, terminal color querying.

- `src/styles.cr` - Styling system: `Terminal::Style` class for text
  attributes, `Terminal::StyleStack` for managing nested styles, theme
  management with built-in light/dark themes and base16 support.

### Library Usage

```crystal
puts Markd.to_term(source)  # Terminal rendering
puts Markd.to_md(source)    # Markdown-to-markdown
```

### Key Dependencies

- `markd` - Markdown parser
- `tartrazine` - Syntax highlighting for code blocks
- `sixteen` - Base16 color themes
- `docopt` - CLI argument parsing (use the ralsina/docopt.cr fork)

## Notes

- Code in `lib/` cannot be modified - it contains external dependencies
- Do not use `not_nil!` - handle nilable values properly
- Pre-commit hooks enforce conventional commits and code quality

## litehtml submodule (markpdf)

- `ext/litehtml` tracks the `prune-clipped-subtrees` branch of the ralsina
  fork. litehtml/litehtml#485 holds the upstream part (subtree pruning);
  markpdf-specific patches sit on top as local-only commits.
- After changing anything under `ext/` (the submodule, `litepdf.cpp`, the
  Makefile), run `hace litehtml-test`. It builds the exact submodule tree
  in a throwaway worktree with the PR's CI settings (clang-tidy with
  warnings-as-errors + full ~5.7k test suite) and reports which commits
  are local-only versus already in the PR, so patches neither ride along
  unnoticed nor silently diverge.
- The upstream suite only draws with clips that start at the document
  top, and pruning bugs never change page counts (layout is unaffected,
  only drawing). `spec/pdf_pagination_spec.cr` covers the gap: it
  renders multi-page documents and checks per-page text with pdftotext
  (pending-skipped when pdftotext is not installed).
