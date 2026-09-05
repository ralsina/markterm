#!/usr/bin/env python3
"""Collect installation footprints for every toolchain in the comparison.

Repo packages are measured via pacman (recursive dependency closure);
binary releases and npm installs are measured on disk. Output: a TSV
block printed to stdout, also saved to out/sizes.tsv.
"""

import subprocess
import sys
from pathlib import Path

HOME = Path.home()
REPO = Path("/home/ralsina/code/markterm")


def pkg_installed_size(name: str) -> int:
    out = subprocess.run(["pacman", "-Qi", name], capture_output=True, text=True)
    for line in out.stdout.splitlines():
        if line.startswith("Installed Size"):
            raw = line.split(":")[1].strip()          # e.g. "25.55 MiB"
            value, unit = raw.split()
            factor = {"B": 1, "KiB": 1024, "MiB": 1024**2, "GiB": 1024**3}[unit]
            return float(value.replace(",", ".")) * factor
    return 0


def pkg_deps(name: str) -> list[str]:
    out = subprocess.run(["pacman", "-Qi", name], capture_output=True, text=True)
    for line in out.stdout.splitlines():
        if line.startswith("Depends On"):
            raw = line.split(":", 1)[1].strip()
            return [d for d in raw.split() if d and d != "None"]
    return []


def closure_size(name: str, seen: set | None = None) -> tuple[int, int]:
    """(total bytes incl. dependency closure, number of packages)"""
    if seen is None:
        seen = set()
    if name in seen:
        return 0, 0
    seen.add(name)
    total = pkg_installed_size(name)
    count = 1
    for dep in pkg_deps(name):
        # deps carry version constraints like "python>=3.11"
        dep = dep.split(">")[0].split("<")[0].split("=")[0]
        add, add_count = closure_size(dep, seen)
        total += add
        count += add_count
    return total, count


def du(path: str) -> int:
    out = subprocess.run(f"du -sb '{path}'", shell=True, capture_output=True, text=True)
    return int(out.stdout.split()[0]) if out.returncode == 0 else 0


def mb(n: int) -> str:
    return f"{n / 1024**2:.1f} MiB"


def main() -> int:
    rows = []

    # markpdf: binary as built here; ext libs (litehtml+libharu) are
    # linked in from ext/build, so ldd only shows base system libs.
    markpdf = REPO / "bin" / "markpdf"
    static = sorted(REPO.glob("bin/*static*amd64"))
    static_size = static[0].stat().st_size if static else 0
    rows.append(("markpdf (ours)", mb(markpdf.stat().st_size),
                 "1 file; 0 runtime deps beyond glibc; static release build "
                 f"reference: {mb(static_size)} (markterm)"))

    rows.append(("goldmark-pdf (Go)", mb((REPO / "compare/tools/gmmdpdf/gmmdpdf").stat().st_size),
                 "1 file; fully static Go binary (plus ~15 lines of Go to write it)"))

    for label, pkgs in [
        ("lowdown + groff", ["lowdown", "groff"]),
        ("pandoc (base)", ["pandoc"]),
        ("pandoc + weasyprint", ["pandoc", "python-weasyprint"]),
        ("pandoc + tectonic", ["pandoc", "tectonic"]),
        ("pandoc + typst", ["pandoc", "typst"]),
        ("chromium (browser)", ["chromium"]),
    ]:
        seen: set = set()
        total = 0
        count = 0
        for pkg in pkgs:
            add, add_count = closure_size(pkg, seen)
            total += add
            count += add_count
        rows.append((label, mb(int(total)), f"{count} packages via pacman"))

    tectonic_cache = du(str(HOME / ".cache/tectonic")) or du(str(HOME / ".cache/Tectonic"))
    rows.append(("tectonic first-run bundle", mb(tectonic_cache),
                 "downloaded on first compile into ~/.cache/Tectonic"))

    m2p = du(str(REPO / "compare/tools/m2p/node_modules"))
    chrome = du(str(HOME / ".cache/puppeteer"))
    rows.append(("md-to-pdf (npm)", mb(m2p + chrome),
                 f"node_modules {mb(m2p)} + bundled Chrome {mb(chrome)} (puppeteer cache)"))
    print("| Toolchain | Installed size | Notes |")
    print("|---|---|---|")
    for label, size, note in rows:
        print(f"| {label} | {size} | {note} |")

    Path("out").mkdir(exist_ok=True)
    with open("out/sizes.tsv", "w") as handle:
        for label, size, note in rows:
            handle.write(f"{label}\t{size}\t{note}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
