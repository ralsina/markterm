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
* A C and C++ toolchain (`gcc` or `clang`, plus `make`)
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
* `ext/libtexprintf` — LaTeX-to-Unicode-art renderer (required only
  for the GPL math build; see below)

## Standard build

```bash
make -C ext
shards build
```

That produces `bin/markterm`, `bin/markmark` and `bin/markpdf`.

**License note:** the standard build links the GPL-3 libtexprintf for
LaTeX math, which makes the resulting binaries effectively GPL-3 (the
project source itself stays MIT).

## Build without the GPL math (MIT binary)

Pass `WITH_TEXMATH=0` to **both** build steps — the flag is read by
the C build and, at compile time, by the Crystal sources:

```bash
make -C ext clean
make -C ext WITH_TEXMATH=0
WITH_TEXMATH=0 shards build
```

The only difference: display math (`$$…$$`) renders through a Unicode
styling pass instead of libtexprintf's text art. Everything else is
identical. When switching the flag, rebuild the shim (`make -C ext
clean` is the safe way) so the objects and the license agree.

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
* **`Invalid memory access` while rendering math** — you are running a
  binary older than the writable-copy fix in `litepdf_render_math`;
  rebuild.
