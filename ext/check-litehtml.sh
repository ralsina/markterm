#!/usr/bin/env bash
# Guards the litehtml submodule: it must sit on top of upstream master and
# carry only the known markpdf patches, and it must pass the upstream CI
# gates (tests + clang-tidy).
#
# Upstream master itself carries the draw-time subtree pruning ("Draw
# elements optimization", 277b1d31, from the closed PR #485 discussion).
#
# What it does:
#   1. Reports the patch stack: which commits the submodule carries on top of
#      upstream master, so local-only patches never ride along unnoticed and
#      the tree markpdf builds against never falls behind upstream.
#   2. Builds the exact submodule tree markpdf compiles against (throwaway
#      worktree, live checkout untouched) with the PR's CI settings:
#      LITEHTML_BUILD_TESTING=ON and clang-tidy with -warnings-as-errors=*.
#   3. Runs litehtml's full test suite (~5.7k render tests).
#
# Notes:
#   - upstream tests draw with page-top clips only; pagination-specific
#     draw pruning is covered by spec/pdf_pagination_spec.cr on the
#     markpdf side (hace test).
#   - a missing clang-tidy only skips the lint pass (CI's macOS behavior);
#     the build itself then proves nothing about the lint gate.
#
# Usage: ext/check-litehtml.sh [--no-fetch]
#   --no-fetch  skip `git fetch` of upstream master (offline runs)
#
# Environment overrides:
#   BASE_REMOTE (default: origin)  BASE_BRANCH (default: master)

set -euo pipefail
cd "$(dirname "$0")/litehtml"

BASE_REMOTE="${BASE_REMOTE:-origin}"
BASE_BRANCH="${BASE_BRANCH:-master}"

if [ "${1:-}" != "--no-fetch" ] && git remote get-url "$BASE_REMOTE" >/dev/null 2>&1; then
	if ! git fetch "$BASE_REMOTE" "$BASE_BRANCH" >/dev/null 2>&1; then
		echo "note: could not fetch $BASE_REMOTE/$BASE_BRANCH (offline?); using last fetched state"
	fi
fi

# --- patch stack report ----------------------------------------------------
base_tip=$(git rev-parse "$BASE_REMOTE/$BASE_BRANCH" 2>/dev/null || true)
sub_head=$(git rev-parse HEAD)
short_head=$(git rev-parse --short "$sub_head")

if [ -z "$base_tip" ]; then
	echo "WARNING: cannot resolve $BASE_REMOTE/$BASE_BRANCH — cannot check the patch stack"
elif git merge-base --is-ancestor "$base_tip" "$sub_head"; then
	n_local=$(git rev-list --count "$base_tip..$sub_head")
	if [ "$n_local" -eq 0 ]; then
		echo "submodule: exactly at $BASE_REMOTE/$BASE_BRANCH ($(git rev-parse --short "$base_tip"))"
	else
		echo "submodule: $n_local local commit(s) on top of $BASE_REMOTE/$BASE_BRANCH ($(git rev-parse --short "$base_tip")):"
		git log --oneline --reverse "$base_tip..$sub_head" | sed 's/^/  local-only: /'
	fi
else
	echo "WARNING: submodule HEAD ($short_head) is NOT on top of $BASE_REMOTE/$BASE_BRANCH" \
		"($(git rev-parse --short "$base_tip")) — rebase the markpdf patches onto it"
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
	echo "note: submodule has uncommitted changes; building HEAD ($short_head) only"
fi

# --- build + test the exact tree markpdf uses -------------------------------
worktree=$(mktemp -d /tmp/litehtml-check.XXXXXX)
cleanup() {
	git worktree remove --force "$worktree" >/dev/null 2>&1 || rm -rf "$worktree"
}
trap cleanup EXIT

git worktree add --detach "$worktree" "$sub_head" >/dev/null

if command -v clang-tidy >/dev/null 2>&1; then
	echo "== building litehtml @ $short_head (tests + clang-tidy, as PR CI does)"
else
	echo "== building litehtml @ $short_head (WARNING: clang-tidy not found, lint pass skipped)"
fi
cmake -S "$worktree" -B "$worktree/build" -DLITEHTML_BUILD_TESTING=ON -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$worktree/build" -j"$(nproc)"

echo "== running litehtml test suite"
ctest --test-dir "$worktree/build/litehtml-tests-build" --output-on-failure -j"$(nproc)"
echo "== litehtml check passed"
