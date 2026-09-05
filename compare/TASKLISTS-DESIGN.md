# Design: rendering GFM task-list checkboxes in markpdf

Status: **design only, not implemented**. Grounded in the current code:
markd (with `gfm = true`, set in src/main_pdf.cr) emits the markup
below, and the vendored litehtml drops `<input>` elements entirely —
which is why task lists currently render as plain bullets
(comparison matrix row F14).

## The input we get

`lib/markd/src/markd/renderers/html_renderer.cr` (item()) emits, per
task item, an `<input>` as the first child of the `<li>` — verified
byte-for-byte with `gfm = true`:

```html
<ul>
<li><input checked="" disabled="" type="checkbox"> done thing</li>
<li><input disabled="" type="checkbox"> open thing</li>
</ul>
```

Only these two exact shapes exist (attribute order fixed by the
renderer; the trailing space is a separate text node).

## Recommended fix: rewrite the markup in Crystal before layout

A small pass in `Markd::Pdf.render` between `Markd.to_html` and
`process_images`:

```crystal
private def self.rewrite_task_lists(html : String) : String
  html
    .gsub(%r{<li><input checked="" disabled="" type="checkbox">},
      %(<li class="task-list-item"><span class="task-box">☑</span>))
    .gsub(%r{<li><input disabled="" type="checkbox">},
      %(<li class="task-list-item"><span class="task-box">☐</span>))
end
```

plus two rules appended to `DEFAULT_CSS`:

```css
li.task-list-item { list-style-type: none; }
```

Result: "☑ done thing" / "☐ open thing" with no bullet, exactly like
GitHub's rendering. Everything else falls out of existing machinery:

- the ☑/☐ glyphs (U+2611, U+2610) live in DejaVu Sans, the default
  body font — same block as ✓ U+2713 and ∑ U+2211, both of which the
  comparison already verified render through this pipeline;
- markd's literal `" "` after the input keeps the gap between box and
  text, so no margin CSS is needed;
- nested lists inside a task item keep their own bullets (the class is
  on the `<li>`, not the `<ul>`), matching GitHub;
- themes (`theme_css`) never touch `list-style`, so dark/sepia/base16
  stay compatible without changes;
- markterm and markmark are untouched — the rewrite lives in pdf.cr.

## Why not the alternatives

- **Shim-side (draw a box when hitting `<input>`)**: needs litehtml to
  hand the shim form-element geometry, which it does not do for
  `<input>` today — real C++ work in two layers to reproduce what a
  two-line string rewrite achieves.
- **CSS-only (`li::before { content: "☐" }`)**: litehtml parses
  pseudo-class *selectors* but does not implement `content` generation.
- **Patching the markd fork to emit spans**: would change the HTML that
  markmark and every other consumer of the fork sees; `<input>` is the
  semantically correct HTML and GitHub-compatible tools may rely on it.

## Verify before shipping

1. ☐/☑ actually draw with the default font stack (render the two-line
   sample; if a glyph were missing it would come out blank like the
   emoji do today — F24 is the cautionary tale). Fallback plan if
   blank: ship the boxes as `[x]`/`[ ]` text in a monospace span
   (uglier but universal), or extend the emoji-font fallback.
2. `list-style-type: none` suppresses the marker (verified present in
   the vendored litehtml: `render_inline_context.cpp` checks
   `list_style_type_none` before drawing markers; `none` parses — first
   entry of `list_style_type_strings`).
3. Nested task lists and tasks inside ordered lists (markd allows
   `1. [x]` — the same two patterns cover it since only the `<li>`
   prefix is matched).

## Test plan

* Unit specs on `rewrite_task_lists` (pure function): checked → ☑ with
  class, unchecked → ☐, plain `<li>` untouched, mixed list, nested list.
* Kitchen sink F14: screenshot should show ☑/☐ with no bullets — the
  comparison harness re-renders it on every run, so the visual gate is
  automatic (`./render.sh` then check `out/png/`).
* `crystal spec` + `ameba src/pdf.cr` as usual.

Estimated size: ~10 lines of Crystal, 1 CSS rule, 3 specs.
