#!/usr/bin/env bash
# Render the kitchen-sink document through every markdown-to-PDF toolchain
# we are comparing, into out/<tool>.pdf. Records page count, bytes and
# wall time per tool into out/results.tsv, plus versions into
# out/versions.txt.
#
# Some toolchains need the input preprocessed (LaTeX cannot embed
# SVG/GIF/WebP or fetch remote images; typst and the chromium CLI do not
# fetch remote images; goldmark-pdf aborts on SVG/WebP). Variants are
# generated here so every tool still produces a comparable document; the
# preprocessing each tool needed is itself comparison data, and it is
# echoed to stdout as a reminder.
#
# Usage: ./render.sh [doc.md]   (default: kitchen-sink.md)

set -u
cd "$(dirname "$0")"

DOC="${1:-kitchen-sink.md}"
BASE="${DOC%.md}"
OUT="out"
MARKPDF_BIN="${MARKPDF_BIN:-./bin/markpdf-head}"
M2P="$PWD/tools/m2p/node_modules/.bin/md-to-pdf"
CHROME_PROFILE="$(mktemp -d)"
REMOTE='https://ralsina.me/images/markterm-light.png'
REMOTE_LOCAL='assets/remote-markterm-light.png'

mkdir -p "$OUT"
: > "$OUT/results.tsv"

note() { printf '  %s\n' "$*"; }
record() { # tool pages bytes seconds
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$OUT/results.tsv"
}
timed() { # timed <tool> <command...>; records page count/bytes/time
  local tool="$1"; shift
  local start end
  start=$(date +%s%3N)
  if "$@" > "$OUT/$tool.log" 2>&1; then :; else
    end=$(date +%s%3N)
    echo "$tool FAILED (see $OUT/$tool.log)"
    record "$tool" FAIL - "$((end - start))"
    return 1
  fi
  end=$(date +%s%3N)
  local pdf="$OUT/$tool.pdf"
  local pages
  pages=$(pdfinfo "$pdf" 2>/dev/null | awk '/^Pages:/ {print $2}')
  record "$tool" "${pages:-?}" "$(stat -c%s "$pdf")" "$((end - start))"
  echo "$tool OK ($((end - start)) ms, ${pages:-?} pages)"
}

versions() {
  {
    echo "markpdf:       $("$MARKPDF_BIN" --version 2>&1 | head -1)"
    echo "pandoc:        $(pandoc --version | head -1)"
    echo "weasyprint:    $(weasyprint --version 2>&1 | head -1)"
    echo "tectonic:      $(tectonic --version)"
    echo "typst:         $(typst --version)"
    echo "md-to-pdf:     $($M2P --version 2>/dev/null)"
    echo "chromium:      $(chromium --version)"
    echo "lowdown:       $(lowdown --version | head -1)"
    echo "groff:         $(groff --version | head -1)"
    echo "goldmark-pdf:  $(cd tools/gmmdpdf && go list -m -f '{{join .Require " "}}' 2>/dev/null | grep -o 'goldmark-pdf[^ ]*' | head -1) (go $(go version | awk '{print $3}'))"
  } > "$OUT/versions.txt"
}

# --- input variants -----------------------------------------------------
# LaTeX route: SVG/GIF/WebP are not embeddable and remote images are not
# fetched, so all four must be localized/converted by hand.
sed -e 's#assets/sample.svg#assets/sample-svgconv.png#' \
    -e 's#assets/sample.gif#assets/sample-gifconv.png#' \
    -e 's#assets/sample.webp#assets/sample-webpconv.png#' \
    -e "s#$REMOTE#$REMOTE_LOCAL#" "$DOC" > ".variant-latex.md"
# typst and the chromium CLI: images must be local, formats are fine as-is.
sed -e "s#$REMOTE#$REMOTE_LOCAL#" "$DOC" > ".variant-local.md"
# goldmark-pdf: aborts the whole document on SVG or WebP.
sed -e 's#assets/sample.svg#assets/sample-svgconv.png#' \
    -e 's#assets/sample.webp#assets/sample-webpconv.png#' \
    "$DOC" > ".variant-goldmark.md"
# --- pandoc HTML (shared by weasyprint and chromium) ----------------------
# lang=en-US: hyphenation (CSS hyphens: auto) needs a document language.
pandoc "$DOC" -f markdown -t html5 -s --metadata title="$BASE" --metadata lang=en-US -o ".build.html" 2>"$OUT/pandoc.log"
# the browser route renders pandoc's default styling; hyphens: auto is
# the one override, injected so it stays a one-flag comparison
sed "s#$REMOTE#$REMOTE_LOCAL#" ".build.html" | \
  sed 's#</head>#<style>:root { hyphens: auto; }</style></head>#' > ".build-local.html"

# --- markpdf (ours) -----------------------------------------------------
# --hyphenate: soft-hyphen hyphenation is opt-in; --font hands over a
# converted TrueType Noto Sans CJK for the CJK cells (see the notes on
# F24-F25 in COMPARISON.md). The font is 20 MB and gitignored: when it
# is missing, render without it (CJK cells degrade to tofu) instead of
# failing the whole run.
CJK_FONT="assets/fonts/NotoSansCJKsc-Regular.ttf.ttf"
if [ -f "$CJK_FONT" ]; then
  FONT_FLAG=(--font "$CJK_FONT")
  echo "== markpdf (--hyphenate, CJK font)"
else
  FONT_FLAG=()
  echo "== markpdf (--hyphenate; CJK font missing, CJK cells degrade)"
fi
markpdf_render() { "$MARKPDF_BIN" "$DOC" --hyphenate \
  "${FONT_FLAG[@]}" -o "$OUT/markpdf.pdf"; }
timed markpdf markpdf_render

# --- markpdf built-in styles ----------------------------------------------
# Every non-default style renders the kitchen sink too, so each has a
# visual sample next to the other toolchains.
for style in book dark sepia; do
  style_render() { "$MARKPDF_BIN" "$DOC" --style "$style" --hyphenate \
    "${FONT_FLAG[@]}" -o "$OUT/markpdf-$style.pdf"; }
  timed "markpdf-$style" style_render
done

# --- pandoc -> LaTeX (tectonic) -----------------------------------------
echo "== pandoc+tectonic (input preprocessed: SVG/GIF/WebP converted, remote image localized)"
# Font config a real user would set: DejaVu Sans covers the symbols
# Latin Modern lacks; Noto Sans CJK SC fixes dropped CJK glyphs.
pandoc ".variant-latex.md" -f markdown -t latex -s -V papersize=a4 \
  -V mainfont="DejaVu Sans" -V CJKmainfont="Noto Sans CJK SC" -o ".build.tex"
tectonic_render() { tectonic -X compile .build.tex && mv .build.pdf "$OUT/tectonic.pdf"; }
timed tectonic tectonic_render

# --- pandoc -> weasyprint -----------------------------------------------
echo "== pandoc+weasyprint (lang set, hyphens: auto in print.css)"
pandoc "$DOC" -f markdown -t html5 -s --metadata title="$BASE" --metadata lang=en-US -c print.css -o ".build-weasy.html"
timed weasyprint weasyprint ".build-weasy.html" "$OUT/weasyprint.pdf"

# --- pandoc HTML -> typst -----------------------------------------------
echo "== pandoc+typst (remote image localized)"
pandoc ".variant-local.md" -f markdown -t typst -o ".build.typ"
timed typst typst compile --root . ".build.typ" "$OUT/typst.pdf"

# --- md-to-pdf (npm, puppeteer + bundled Chrome) --------------------------
echo "== md-to-pdf"
m2p_render() { (cd "$PWD" && PATH="$PWD/tools/m2p/node_modules/.bin:$PATH" \
  "$M2P" "$DOC" --pdf-options '{"format":"A4","margin":{"top":"20mm","bottom":"20mm","left":"20mm","right":"20mm"}}' >/dev/null && mv "${BASE}.pdf" "$OUT/md-to-pdf.pdf"); }
timed md-to-pdf m2p_render

# --- pandoc HTML -> chromium CLI -----------------------------------------
echo "== pandoc+chromium (remote image localized; CLI hangs on remote resources)"
chromium_render() {
  chromium --headless --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --password-store=basic \
    --user-data-dir="$CHROME_PROFILE" --virtual-time-budget=15000 \
    --no-pdf-header-footer --generate-pdf-document-outline \
    --print-to-pdf="$PWD/$OUT/chromium.pdf" "file://$PWD/.build-local.html"
}
timed chromium chromium_render

# --- lowdown -> groff ------------------------------------------------------
echo "== lowdown+groff"
lowdown_render() { lowdown -t ms "$DOC" | groff -k -t -ms -Tpdf > "$OUT/lowdown-groff.pdf"; }
timed lowdown-groff lowdown_render

# --- goldmark-pdf (Go) ------------------------------------------------------
echo "== goldmark-pdf (SVG/WebP pre-converted: it aborts on them)"
timed goldmark-pdf tools/gmmdpdf/gmmdpdf ".variant-goldmark.md" "$OUT/goldmark-pdf.pdf"

rm -rf "$CHROME_PROFILE"
versions
echo
column -t -s $'\t' "$OUT/results.tsv"
