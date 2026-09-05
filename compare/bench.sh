#!/usr/bin/env bash
# Benchmark every toolchain on five documents:
#   small  ~220 lines, the kitchen sink (all features, images)
#   medium ~160 lines, the markterm README (remote images localized)
#   large  ~4,600 generated lines, flat structures (no nested lists so the
#          markpdf nested-list crash does not mask its throughput)
#   book   a real novel from the esposito library (Sherlock Holmes,
#          12k lines) — very long simple document
#   huge   a longer novel (The Brothers Karamazov, 37k lines) — scaling
#          probe; 3 runs only, books may need override paths via
#          ESPOSITO_BOOK / ESPOSITO_HUGE
#
# Each timing covers the whole pipeline (e.g. pandoc + renderer) because
# that is what a user runs. Tools whose renderer aborts on the kitchen
# sink (markpdf: nested lists; goldmark-pdf: SVG/WebP) will simply fail
# on the small document; the failure is part of the comparison.
#
# Results: out/bench.tsv (doc, tool, mean, stddev — hyperfine units).
#
# Usage: ./bench.sh [runs-per-doc]   (default: 10, large docs get runs/2)

set -u
cd "$(dirname "$0")"

RUNS="${1:-10}"
OUT="out"
MARKPDF_BIN="${MARKPDF_BIN:-./bin/markpdf-snapshot}"
M2P="$PWD/tools/m2p/node_modules/.bin/md-to-pdf"
CHROME_PROFILE="$(mktemp -d)"
mkdir -p "$OUT"

REMOTE='https://ralsina.me/images/markterm-light.png'
REMOTE_LOCAL='assets/remote-markterm-light.png'

# --- prepare documents ----------------------------------------------------
# medium: README with every remote image localized (badge + screenshots) —
# remote images are a feature difference, not a size/throughput difference,
# and the chromium CLI hangs on them entirely
sed -e 's#https://github.com/ralsina/markterm/actions/workflows/ci.yml/badge.svg#assets/remote-markterm-light.png#' \
    -e 's#https://ralsina.me/images/markterm-light.png#assets/remote-markterm-light.png#' \
    -e 's#https://ralsina.me/images/markterm-dark.png#assets/remote-markterm-dark.png#' \
    ../README.md > .bench-medium.md

python3 - <<'EOF'
lines = []
for block in range(200):
    n = block + 1
    lines.append(f"## Section {n}: stress block")
    lines.append("")
    lines.append(
        f"Paragraph {n} with **bold**, *italic* and `inline code`, plus a "
        f"link to [Example](https://example.com). The diligent dolphin "
        f"delves deeper, numbered {n}."
    )
    lines.append("")
    lines.append("| Name | Value | Flag | Note |")
    lines.append("|:-----|------:|:----:|------|")
    for row in range(4):
        lines.append(f"| item {row} | {row * n} | {'yes' if row % 2 else 'no'} | remark {row} |")
    lines.append("")
    lines.append("```crystal")
    lines.append(f"# block {n}")
    lines.append("def compute(value : Int32) : Int32")
    lines.append("  value * 2 + 1")
    lines.append("end")
    lines.append("```")
    lines.append("")
    lines.append("* list entry one")
    lines.append("* list entry two")
    lines.append("")
    lines.append("> quoted wisdom")
    lines.append("")
open(".bench-large.md", "w").write("\n".join(lines))
EOF

cp kitchen-sink.md .bench-small.md

# --- real books (very long simple documents) ------------------------------
# From the esposito e-reader's markdown library: pure prose, one cover
# image that ships separately, no tables or lists. Image references are
# stripped uniformly (the LaTeX route hard-fails on the missing file
# otherwise). Override with ESPOSITO_BOOK / ESPOSITO_HUGE.
BOOK="${ESPOSITO_BOOK:-$HOME/code/esposito/books/The Adventures of Sherlock Holmes.md}"
HUGE="${ESPOSITO_HUGE:-$HOME/code/esposito/site/assets/books/The Brothers Karamazov.md}"
if [ -f "$BOOK" ]; then
  sed -e '/!\[.*](.*\.\(jpg\|jpeg\|png\))/d' -e '/^<img /d' "$BOOK" > .bench-book.md
  echo "book: $(wc -l < .bench-book.md) lines, $(stat -c%s .bench-book.md) bytes"
else
  echo "book: no book at $BOOK — book tier skipped" >&2
fi
if [ -f "$HUGE" ]; then
  sed -e '/!\[.*](.*\.\(jpg\|jpeg\|png\))/d' -e '/^<img /d' "$HUGE" > .bench-huge.md
  echo "huge: $(wc -l < .bench-huge.md) lines, $(stat -c%s .bench-huge.md) bytes"
else
  echo "huge: no book at $HUGE — huge tier skipped" >&2
fi

# variant inputs for the small document, mirroring render.sh: LaTeX needs
# SVG/GIF/WebP converted plus the remote image localized; typst and the
# chromium CLI need the remote image localized
sed -e 's#assets/sample.svg#assets/sample-svgconv.png#' \
    -e 's#assets/sample.gif#assets/sample-gifconv.png#' \
    -e 's#assets/sample.webp#assets/sample-webpconv.png#' \
    -e "s#$REMOTE#$REMOTE_LOCAL#" kitchen-sink.md > .bench-small-latex.md
sed -e "s#$REMOTE#$REMOTE_LOCAL#" kitchen-sink.md > .bench-small-typst.md

file_for() { # file_for <tool> <doc> -> input file for that tool/doc
  local tool="$1" doc="$2"
  if [ "$doc" != small ]; then
    echo ".bench-$doc.md"
  elif [ "$tool" = tectonic ]; then
    echo ".bench-small-latex.md"
  elif [ "$tool" = typst ] || [ "$tool" = chromium ]; then
    echo ".bench-small-typst.md"
  else
    echo ".bench-small.md"
  fi
}

bench_one() { # doc runs warmup label command...
  local doc="$1" runs="$2" warmup="$3" label="$4"; shift 4
  local line
  line=$(hyperfine --warmup "$warmup" --runs "$runs" --style basic --command-name "$label" "$@" 2>&1 | \
    awk -F': *' '/Time \(mean/ {split($2, a, " "); printf "%s %s\t%s %s", a[1], a[2], a[3], a[4]}')
  if [ -n "$line" ]; then
    echo -e "$doc\t$label\t$line" | tee -a "$OUT/bench.tsv"
  else
    echo -e "$doc\t$label\tFAIL\t-" | tee -a "$OUT/bench.tsv"
  fi
}

: > "$OUT/bench.tsv"
for doc in small medium large book huge; do
  [ -f ".bench-$doc.md" ] || { echo "== $doc skipped (no input)"; continue; }
  case "$doc" in
    small|medium) runs=$RUNS; warmup=2 ;;
    large|book)   runs=$((RUNS / 2)); warmup=2 ;;
    huge)         runs=3; warmup=1 ;;
  esac
  echo "== $doc ($runs runs)"

  f=$(file_for markpdf "$doc")
  bench_one "$doc" "$runs" "$warmup" markpdf \
    "$MARKPDF_BIN $f -o $OUT/b.pdf"

  f=$(file_for tectonic "$doc")
  bench_one "$doc" "$runs" "$warmup" tectonic \
    "pandoc $f -f markdown -t latex -s -V papersize=a4 -o .bench.tex && tectonic -X compile .bench.tex"

  f=$(file_for weasyprint "$doc")
  bench_one "$doc" "$runs" "$warmup" weasyprint \
    "pandoc $f -f markdown -t html5 -s -o .bench.html && weasyprint .bench.html $OUT/b.pdf"

  f=$(file_for typst "$doc")
  bench_one "$doc" "$runs" "$warmup" typst \
    "pandoc $f -f markdown -t typst -o .bench.typ && typst compile --root . .bench.typ $OUT/b.pdf"

  f=$(file_for md-to-pdf "$doc")
  bench_one "$doc" "$runs" "$warmup" md-to-pdf \
    "PATH=$PWD/tools/m2p/node_modules/.bin:\$PATH $M2P $f --pdf-options '{\"format\":\"A4\"}'"

  f=$(file_for chromium "$doc")
  bench_one "$doc" "$runs" "$warmup" chromium \
    "pandoc $f -f markdown -t html5 -s -o .bench.html && chromium --headless --no-sandbox --disable-gpu --disable-dev-shm-usage --password-store=basic --user-data-dir=$CHROME_PROFILE --virtual-time-budget=15000 --no-pdf-header-footer --print-to-pdf=$PWD/$OUT/b.pdf file://$PWD/.bench.html"

  f=$(file_for lowdown-groff "$doc")
  bench_one "$doc" "$runs" "$warmup" lowdown-groff \
    "lowdown -t ms $f | groff -t -ms -Tpdf > $OUT/b.pdf"

  f=$(file_for goldmark-pdf "$doc")
  bench_one "$doc" "$runs" "$warmup" goldmark-pdf \
    "tools/gmmdpdf/gmmdpdf $f $OUT/b.pdf"
done

echo -e "\n# input scale" >> "$OUT/bench.tsv"
for doc in small medium large book huge; do
  [ -f ".bench-$doc.md" ] && \
    echo -e "# $doc: $(wc -l < .bench-$doc.md) lines, $(stat -c%s .bench-$doc.md) bytes" >> "$OUT/bench.tsv"
done
rm -rf "$CHROME_PROFILE"
echo "done — see $OUT/bench.tsv"
