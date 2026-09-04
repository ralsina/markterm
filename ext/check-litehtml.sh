#!/usr/bin/env bash
# Guards the litehtml submodule against breaking litehtml PR #485 (draw-time
# subtree pruning) and the upstream CI that gates it.
#
# What it does:
#   1. Reports the patch stack: which commits the submodule carries on top of
#      the PR branch, so local-only patches never ride along unnoticed and the
#      PR tip is never missing from the tree markpdf builds against.
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
#   --no-fetch  skip `git fetch` of the PR branch (offline runs)
#
# Environment overrides:
#   PR_REMOTE (default: fork)  PR_BRANCH (default: prune-clipped-subtrees)

set -euo pipefail
cd "$(dirname "$0")/litehtml"

PR_REMOTE="${PR_REMOTE:-fork}"
PR_BRANCH="${PR_BRANCH:-prune-clipped-subtrees}"

if [ "${1:-}" != "--no-fetch" ] && git remote get-url "$PR_REMOTE" >/dev/null 2>&1; then
	if ! git fetch "$PR_REMOTE" "$PR_BRANCH" >/dev/null 2>&1; then
		echo "note: could not fetch $PR_REMOTE/$PR_BRANCH (offline?); using last fetched state"
	fi
fi

# --- patch stack report ----------------------------------------------------
pr_tip=$(git rev-parse "$PR_REMOTE/$PR_BRANCH" 2>/dev/null || true)
sub_head=$(git rev-parse HEAD)
short_head=$(git rev-parse --short "$sub_head")

if [ -z "$pr_tip" ]; then
	echo "WARNING: cannot resolve $PR_REMOTE/$PR_BRANCH — cannot check the patch stack"
elif git merge-base --is-ancestor "$pr_tip" "$sub_head"; then
	n_local=$(git rev-list --count "$pr_tip..$sub_head")
	if [ "$n_local" -eq 0 ]; then
		echo "submodule: exactly at the PR tip ($(git rev-parse --short "$pr_tip"))"
	else
		echo "submodule: $n_local local commit(s) on top of the PR tip ($(git rev-parse --short "$pr_tip")) — not in litehtml/litehtml#485:"
		git log --oneline --reverse "$pr_tip..$sub_head" | sed 's/^/  local-only: /'
	fi
else
	echo "WARNING: submodule HEAD ($short_head) does NOT contain the PR tip" \
		"($(git rev-parse --short "$pr_tip")) — markpdf is building against a tree missing PR fixes"
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
