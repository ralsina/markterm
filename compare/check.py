#!/usr/bin/env python3
"""Feature-gap checker: extract text from every PDF in out/ and probe for
the sentinel strings each kitchen-sink feature must contribute to the
output. Produces a markdown matrix on stdout and out/features.tsv.

Text presence proves the content survived; visual-only aspects (colors,
borders, alignment, actual image pixels) are reviewed separately. An image
row here checks for a renderer's failure text (alt text printed instead of
pixels), which is why a ✓ means "no failure text", not "image looks right".
"""

import re
import subprocess
import sys
import unicodedata
from pathlib import Path

# feature id -> (human label, [required sentinels], mode)
# mode "any": cell passes if ANY sentinel is found (presence proof)
# mode "all": cell passes only if EVERY sentinel is found (used when each
# sentinel covers a different sub-capability, e.g. one script per writing
# system)
# mode "hyphenated": sentinels are whole words; the cell passes if ANY
# word shows up split across a line break by a hyphenation hyphen
# ("counterrevolutionar-" / "ies"), which whole-word wrapping can never
# produce. Probed on -layout extraction: default pdftotext silently
# re-joins hyphenated line ends.
FEATURES = {
    "F01": ("Headings h3-h6", ["Level three heading", "level six heading"], "any"),
    "F02": ("Emphasis + strikethrough", ["boldly bold", "struck through"], "any"),
    "F03": ("Inline code + entities", ["if a < b && c > d", "café & crème"], "any"),
    "F04": ("Links + autolink + mailto", ["inline link to Example", "https://crystal-lang.org", "hello@example.com"], "any"),
    "F12": ("Blockquote + nesting", ["quirkly quokka quips", "baffled badger bounces"], "any"),
    "F13": ("Nested list + ordered start", ["Inner alpha", "Fifth ordered item"], "any"),
    "F14": ("Task list items", ["well-earned nap", "Ship the markpdf renderer"], "any"),
    "F15": ("Table with alignment", ["brown", "jumps"], "any"),
    "F16": ("Wide table (10 cols)", ["chinchilla", "hedgehog", "jaguar"], "any"),
    "F17": ("Code fence: crystal", ["zesty zebra zooms", 'Greeter.new("World")'], "any"),
    "F18": ("Code fence: python", ["mellow mongoose meanders"], "any"),
    "F19": ("Plain + indented code", ["cautious cougar crouches", "timid tapir tiptoes"], "any"),
    "F20": ("Long unbreakable code line", ["TRAILING=done"], "any"),
    "F21": ("Footnote definitions", ["Knuth, The Art of Computer Programming", "richer footnote with"], "any"),
    "F22": ("GFM alerts (5 kinds)", ["sunny sidekick salutes", "cranky crab clacks"], "any"),
    "F23": ("Inline HTML (kbd/mark/sub/sup)", ["marked text", "Ctrl"], "any"),
    "F24": ("Emoji", ["👍", "🎉", "🚀"], "any"),
    # a sentinel may itself be a list: alternative spellings, of which one
    # must be present (Arabic comes out of pdftotext in either visual or
    # logical order depending on the tool)
    "F25": ("Accents+CJK+RTL+symbols", ["Señor Cárdenas", "中文排版测试", ["بالعالم", "ملاعلاب"], "∑"], "all"),
    "F26": ("Math not literal", ["E = mc2", "E=mc2", "mc2", "mc 2"], "any"),
    "F28": ("Multi-page code block", ["patient penguin perches", "endearing emu emigrates"], "any"),
    "F29": ("Hyphenation at line ends", ["internationalization", "electroencephalography", "incomprehensibilities", "counterrevolutionaries"], "hyphenated"),
}


def normalize_math_italics(text: str) -> str:
    """Map the Mathematical Alphanumeric Symbols block (U+1D400..) used by
    LaTeX math fonts back to ASCII so pdftotext output matches."""
    out = []
    for char in text:
        code = ord(char)
        if 0x1D400 <= code <= 0x1D7FF:
            name = unicodedata.name(char, "")
            # e.g. "MATHEMATICAL ITALIC SMALL M" -> "m"
            words = name.split()
            if words and words[-1].isalpha() and len(words[-1]) == 1:
                out.append(words[-1].upper() if "CAPITAL" in name else words[-1].lower())
                continue
        out.append(char)
    return "".join(out)


def pdf_text(pdf: Path) -> str:
    out = subprocess.run(
        ["pdftotext", "-enc", "UTF-8", str(pdf), "-"],
        capture_output=True, text=True,
    )
    text = out.stdout
    # join hyphenated line breaks (groff hyphenates) and collapse newlines
    # so sentinels split across lines still match
    flat = text.replace("-\n", "").replace("\n", " ")
    text = text + "\n" + flat
    return normalize_math_italics(text)


def pdf_text_layout(pdf: Path) -> str:
    """Line-preserving extraction (-layout keeps hyphenated line ends,
    which default mode re-joins silently)."""
    out = subprocess.run(
        ["pdftotext", "-layout", "-enc", "UTF-8", str(pdf), "-"],
        capture_output=True, text=True,
    )
    return normalize_math_italics(out.stdout)


def word_hyphen_split(word: str, layout_text: str) -> bool:
    """True when `word` appears broken across a line break by a
    hyphenation hyphen: prefix, hyphen at line end, suffix on the next
    line (possibly indented)."""
    for cut in range(2, len(word) - 2):
        pattern = re.escape(word[:cut]) + r"-\n\s*" + re.escape(word[cut:])
        if re.search(pattern, layout_text):
            return True
    return False


def pdf_outline_titles(pdf: Path) -> str:
    """Flatten the PDF outline (bookmarks) into one string, empty if none."""
    try:
        from pypdf import PdfReader

        reader = PdfReader(str(pdf))

        def walk(nodes) -> str:
            out = []
            for node in nodes:
                if isinstance(node, list):
                    out.append(walk(node))
                else:
                    out.append(" " + str(node.title))
            return "".join(out)

        return walk(reader.outline)
    except Exception:
        return ""


def main() -> int:
    out_dir = Path("out")
    tools = sorted(pdf.stem for pdf in out_dir.glob("*.pdf"))
    if not tools:
        print("no PDFs in out/", file=sys.stderr)
        return 1

    texts = {tool: pdf_text(out_dir / f"{tool}.pdf") for tool in tools}
    layouts = {tool: pdf_text_layout(out_dir / f"{tool}.pdf") for tool in tools}
    outlines = {tool: pdf_outline_titles(out_dir / f"{tool}.pdf") for tool in tools}

    rows = ["| Feature | " + " | ".join(tools) + " |",
            "|---|" + "---|" * len(tools)]
    tsv = ["feature\t" + "\t".join(tools)]
    # PDF outline (bookmarks) built from headings: needs the outline to
    # exist and contain section headings (the F-ids make a precise probe)
    outline_row = []
    for tool in tools:
        outline = outlines[tool]
        outline_row.append("✓" if ("F01" in outline and "F22" in outline) else "✗")
    rows.append("| OUTLINE bookmarks from headings | " + " | ".join(outline_row) + " |")
    tsv.append("OUTLINE\t" + "\t".join(outline_row))

    for fid, spec in FEATURES.items():
        label, sentinels, mode = spec
        cells = []
        for tool in tools:
            text = texts[tool]

            def hit(sentinel) -> bool:
                if isinstance(sentinel, list):
                    return any(hit(s) for s in sentinel)
                if mode == "hyphenated":
                    return word_hyphen_split(sentinel, layouts[tool])
                return sentinel in text

            if mode == "all":
                ok = all(hit(s) for s in sentinels)
            elif mode == "hyphenated":
                ok = any(hit(s) for s in sentinels)
            else:
                ok = any(hit(s) for s in sentinels)
            cells.append("✓" if ok else "✗")
        rows.append(f"| {fid} {label} | " + " | ".join(cells) + " |")
        tsv.append(f"{fid}\t" + "\t".join(cells))

    print("\n".join(rows))
    (out_dir / "features.tsv").write_text("\n".join(tsv) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
