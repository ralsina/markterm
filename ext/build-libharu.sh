#!/bin/sh
# Build a static libhpdf into ext/build/libhpdf.a, for the fully static
# markpdf build (Alpine's libharu-dev ships no static archive).
# Skipped when the archive already exists and is newer than the patch.
set -e

cd "$(dirname "$0")"
mkdir -p build
cd build

# the patch lives one directory up (ext/), next to this script; the
# absolute path keeps both the staleness test and `git -C libharu
# apply` working regardless of the current directory
PATCH="$(cd .. && pwd)/libharu-cid-fixes.patch"

if [ -f libhpdf.a ] && [ ! "$PATCH" -nt libhpdf.a ]; then
  echo "libhpdf.a already present"
  exit 0
fi

# Clone once; keep an existing checkout so rebuilds work offline.
[ -d libharu ] || git clone --depth 1 --branch v2.4.6 https://github.com/libharu/libharu.git

# A stale checkout may carry an older version of the patch: reset to
# pristine v2.4.6 so the current patch applies cleanly.
if [ -d libharu/.git ]; then
  git -C libharu reset --hard >/dev/null
  git -C libharu clean -dff src >/dev/null
fi

if [ ! -f "$PATCH" ]; then
  echo "libharu-cid-fixes.patch not found next to $0" >&2
  exit 1
fi

# A pristine v2.4.6 tree must take the patch; any failure is fatal.
# (An earlier version of this script ran `git apply --check` with a
# relative path that never resolved, silently skipped the patch, and
# reported it as already applied.)
git -C libharu apply "$PATCH"
cmake -S libharu -B libharu/build \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DLIBHPDF_EXAMPLES=NO -DLIBHPDF_UTILS=NO
cmake --build libharu/build

find libharu/build -name 'libhpdf.a' -exec cp {} . \;
test -f libhpdf.a

# Export the headers too (libharu/build carries the generated
# hpdf_config.h): the shim compiles against these so a build works on
# machines without a system libharu.
mkdir -p include
cp -f libharu/include/*.h include/
cp -f libharu/build/include/*.h include/
