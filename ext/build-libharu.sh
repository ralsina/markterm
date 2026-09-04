#!/bin/sh
# Build a static libhpdf into ext/build/libhpdf.a, for the fully static
# markpdf build (Alpine's libharu-dev ships no static archive).
# Requires git and cmake. Skipped when the archive already exists.
set -e

cd "$(dirname "$0")"
mkdir -p build
cd build

if [ -f libhpdf.a ]; then
  echo "libhpdf.a already present"
  exit 0
fi

# Clone once; keep an existing checkout so local patches (e.g. the CID
# font fixes) survive.
[ -d libharu ] || git clone --depth 1 --branch v2.4.6 https://github.com/libharu/libharu.git

# Font embedding fixes (see libharu-cid-fixes.patch): the Identity-H
# encoder wrote a nonstandard CIDSystemInfo ordering ("Adobe-Identity-H")
# that readers reject, and the ToUnicode CMap generator emitted an
# invalid empty range block when the range count was a multiple of 100.
# The patch is applied on top of a fresh clone; an already-patched
# checkout skips it.
if [ -d libharu/.git ]; then
  if git -C libharu apply --check ../libharu-cid-fixes.patch 2>/dev/null; then
    git -C libharu apply ../libharu-cid-fixes.patch
  else
    echo "libharu-cid-fixes.patch already applied"
  fi
fi
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
