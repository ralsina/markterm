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

git clone --depth 1 --branch v2.4.6 https://github.com/libharu/libharu.git
cmake -S libharu -B libharu/build \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DBUILD_SHARED_LIBS=OFF \
  -DLIBHPDF_EXAMPLES=NO -DLIBHPDF_UTILS=NO
cmake --build libharu/build

find libharu/build -name 'libhpdf.a' -exec cp {} . \;
test -f libhpdf.a
