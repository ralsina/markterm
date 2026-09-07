#!/bin/bash
set -euo pipefail

VERSION=$(git cliff --bumped-version |cut -dv -f2)
rm -rf aur-markterm

sed "s/^version:.*$/version: $VERSION/g" -i shard.yml
git add shard.yml
hace lint test
git cliff --bump -o
git commit -a -m "bump: Release v$VERSION"
git tag "v$VERSION"
git push
git push --tags

# Binaries for every OS/architecture are built and attached to the
# release by .github/workflows/release.yml when the tag lands; here we
# only create the release with the changelog notes.
gh release create "v$VERSION" \
  --title "Release v$VERSION" --notes "$(git cliff -l -s all)"
