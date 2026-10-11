# Building MARKTerm

The repo builds three binaries:

| binary   | what it does                              | needs the C shim? |
|----------|-------------------------------------------|-------------------|
| markterm | Markdown → terminal (themes, images)      | no                |
| markmark | Markdown → Markdown (round-trip filter)   | no                |
| markpdf  | Markdown → PDF (litehtml layout + libharu)| **yes**           |

Only `markpdf` compiles the C++ shim in `ext/`, so only its build
depends on libharu and the submodules.

## Prerequisites

* [Crystal](https://crystal-lang.org) (see `shard.yml` for the minimum
  version)
* A C and C++ toolchain (`gcc` or `clang`, plus `make`; the MicroTeX
  math engine needs C++17)
* git (the sources use submodules)
* libharu development files for `markpdf` (`pacman -S libharu`,
  `apt install libharu-dev`, ...)
* Optional, for `markpdf` image formats: `rsvg-convert` or
  `ImageMagick` (embedded SVG/WebP)
* Optional, for `markterm` images: `timg` (kitty/iterm terminals) or
  `catimg`

## Submodules

```bash
git submodule update --init
```

This fetches:

* `ext/litehtml` — HTML parsing and layout (required for `markpdf`)
* `ext/microtex` — MIT-licensed LaTeX typesetting engine used by
  `markpdf` to draw math as vector graphics (required for the default
  math build)
* `ext/libtexprintf` — LaTeX-to-Unicode-art renderer for the terminal
  and the non-vector math fallback (required only for the GPL math
  build; see below)

## Standard build

```bash
make -C ext
shards build
```

That produces `bin/markterm`, `bin/markmark` and `bin/markpdf`.

`markpdf` typesets math with MicroTeX and needs its resource tree
(Computer Modern fonts + TeX metrics, ~2 MB) at runtime. The tree is
looked up in this order: `$MARKPDF_MATH_RES`, a `math-res` directory
installed next to the binary (`<prefix>/share/markterm/math-res`),
`/usr/{,local/}/share/{markterm/math-res,clatexmath}` — and, failing
all of those, a copy embedded into the binary is extracted to a temp
directory, so the stock build needs no external files. Fonts embedded
that way carry their own licenses (`ext/microtex/res/fonts/licences`).

**License note:** the standard build additionally links the GPL-3
libtexprintf for the terminal's ASCII math art (and the non-vector
fallback), which makes the resulting binaries effectively GPL-3 (the
project source itself stays MIT).

## Build without the GPL math (MIT binary)

Pass `WITH_TEXMATH=0` to **both** build steps — the flag is read by
the C build and, at compile time, by the Crystal sources:

```bash
make -C ext clean
make -C ext WITH_TEXMATH=0
WITH_TEXMATH=0 shards build
```

The differences: display math (`$$…$$`) in the terminal renders
through a Unicode styling pass instead of libtexprintf's text art,
and `markpdf` loses that art as its non-MicroTeX fallback. Everything
else (including the MicroTeX vector math in `markpdf`) is identical.
When switching the flag, rebuild the shim (`make -C ext clean` is the
safe way) so the objects and the license agree.

`WITH_MICROTEX=0` (again in both steps) disables the vector engine
too, if you want a binary with no math resources embedded at all.

## Tests

```bash
crystal spec            # Crystal test suite (all binaries)
ameba                   # linter
make -C ext test        # small C++ driver for the shim (build/litepdf_test)
```

## Static binaries

`./build_static.sh` builds fully static binaries for linux amd64 and
arm64 via Docker (musl + qemu). It builds libharu from source inside
the container; expect the first run to take a while. The static
binaries include the GPL math build by default — pass
`WITH_TEXMATH=0` inside `build_binaries()` if you need MIT-licensed
releases.

## Quick troubleshooting

* **`undefined constant Litepdf` / link errors about `litepdf`** — the
  shim isn't built: run `make -C ext`.
* **Link error about `texstring`** — the libtexprintf objects are
  missing although the Crystal side expects them: you disabled
  `WITH_TEXMATH` in one step and not the other. Rerun both steps with
  the same value.
* **`markpdf: math resources not found`** — the binary was built
  without the embedded resources (`WITH_MICROTEX=0`) and no resource
  directory was found; point `$MARKPDF_MATH_RES` at a copy of
  `ext/microtex/res`.
* **`Invalid memory access` while rendering math** — you are running a
  binary older than the writable-copy fix in `litepdf_render_math`;
  rebuild.
