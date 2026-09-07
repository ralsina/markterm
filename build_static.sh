#!/bin/bash
set -e

# Static linux binaries for amd64 and arm64.
#
# Everything compiles on real hardware and only the final link of the
# arm64 binaries runs under qemu: g++ segfaults intermittently when the
# qemu emulator compiles the C++ shim, so emulating a compiler is the
# one thing this script refuses to do.
#
#   1. amd64: one container builds the shim and the binaries natively.
#   2. cross: another run of the same amd64 container builds the arm64
#      shim with a cross-toolchain and emits the arm64 crystal objects
#      with `crystal build --cross-compile`, capturing the link command
#      crystal prints for each binary.
#   3. arm64 (emulated): the C shims and libraries the crystal link
#      command needs are alpine packages already present in the
#      container; it only runs the captured link commands.

# musl.cc's toolchain (github mirror first: musl.cc itself refuses
# datacenter connections often enough to break CI runs; the binaries
# are static and musl-linked, so they run inside the alpine builders,
# unlike glibc-hosted toolchains such as bootlin's).
CROSS_TC_DIR="aarch64-linux-musl-cross"
CROSS_TC_URL="https://github.com/OpenListTeam/musl-compilers/releases/download/2025-06-12/$CROSS_TC_DIR.tgz"
CROSS_TC_FALLBACK_URL="https://musl.cc/$CROSS_TC_DIR.tgz"
ZLIB_VERSION="1.3.1"
LIBPNG_VERSION="1.6.44"

download() {
  local destination="$1" url="$2"
  if [ ! -f "$destination" ]; then
    echo "fetching $url"
    curl -fSL --retry 3 --retry-delay 5 -o "$destination" "$url"
  fi
  test -f "$destination"
}

# The cross toolchain and the third-party sources are fetched on the
# host, into the tree: the alpine build containers carry busybox wget,
# whose TLS setup is not worth relying on, and their /tmp is not this
# one.
mkdir -p .cross-src
download ".cross-src/zlib-$ZLIB_VERSION.tar.gz" \
  "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz"
[ -d ".cross-src/zlib-$ZLIB_VERSION" ] ||
  tar -C .cross-src -xf ".cross-src/zlib-$ZLIB_VERSION.tar.gz"
download ".cross-src/libpng-$LIBPNG_VERSION.tar.gz" \
  "https://github.com/pnggroup/libpng/archive/refs/tags/v$LIBPNG_VERSION.tar.gz"
[ -d ".cross-src/libpng-$LIBPNG_VERSION" ] ||
  tar -C .cross-src -xf ".cross-src/libpng-$LIBPNG_VERSION.tar.gz"
download "/tmp/$CROSS_TC_DIR.tgz" "$CROSS_TC_URL" ||
  download "/tmp/$CROSS_TC_DIR.tgz" "$CROSS_TC_FALLBACK_URL"
[ -d "$CROSS_TC_DIR" ] || tar -C . -xf "/tmp/$CROSS_TC_DIR.tgz"

# Inside a container, and therefore subject to `docker run ...
# /bin/sh -c`, where the script-level set -e does not apply: without
# set -e a failed build (say, a missing cross compiler) sails on to a
# confusing link error.
build_binaries() {
  set -e
  make -C ext clean
  ext/build-libharu.sh
  make -C ext
  rm -rf lib shard.lock
  shards install --without-development
  shards build --without-development --release --static
}

# Native build of everything the arm64 binaries link against, except
# the alpine-provided crystal runtime: the aarch64 shim (liblitepdf.a
# with libharu, litehtml, gumbo and libtexprintf) via a cross gcc, and
# the crystal objects via `crystal build --cross-compile`. The link
# commands crystal prints land in cross-arm64/link-commands.txt.
cross_compile_arm64() {
  set -e
  # Self-contained on purpose: this function crosses into the build
  # container via `declare -f`, which serializes the body alone — no
  # script globals come along.
  cross_tc_dir="aarch64-linux-musl-cross"
  zlib_version="1.3.1"
  libpng_version="1.6.44"
  deps="$(pwd)/.cross-deps"
  tcbin="$(pwd)/$cross_tc_dir/bin"
  sysroot="$(pwd)/$cross_tc_dir/aarch64-linux-musl"

  rm -rf .cross-deps cross-arm64
  mkdir -p .cross-deps cross-arm64

  cat > cross-arm64/toolchain.cmake <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER aarch64-linux-musl-gcc)
set(CMAKE_CXX_COMPILER aarch64-linux-musl-g++)
set(CMAKE_FIND_ROOT_PATH $deps $sysroot)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
EOF

  export PATH="$tcbin:$PATH"
  export CC=aarch64-linux-musl-gcc
  export CXX=aarch64-linux-musl-g++
  export AR=aarch64-linux-musl-ar
  export RANLIB=aarch64-linux-musl-ranlib
  CMAKE_TOOLCHAIN_FILE="$(pwd)/cross-arm64/toolchain.cmake"
  export CMAKE_TOOLCHAIN_FILE
  export CMAKE_PREFIX_PATH="$deps"
  export CPATH="$deps/include${CPATH:+:$CPATH}"
  export LIBRARY_PATH="$deps/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"

  # zlib, then libpng against it, then the shim's build-libharu.sh
  # picks both up from $deps through CMAKE_PREFIX_PATH. The sources
  # are already extracted by the host preamble.
  (cd ".cross-src/zlib-$zlib_version" &&
    CHOST=aarch64-linux-musl ./configure --static --prefix="$deps" &&
    make -j2 && make install)
  cmake -S ".cross-src/libpng-$libpng_version" -B .cross-src/libpng-build \
    -DCMAKE_INSTALL_PREFIX="$deps" -DZLIB_ROOT="$deps" \
    -DBUILD_SHARED_LIBS=OFF -DPNG_SHARED=OFF -DPNG_STATIC=ON \
    -DPNG_TESTS=OFF -DPNG_TOOLS=OFF
  cmake --build .cross-src/libpng-build -j2
  cmake --build .cross-src/libpng-build --target install

  make -C ext clean
  ext/build-libharu.sh
  make -C ext

  # Crystal's build-time probes (shards postinstalls checking for
  # OpenSSL, etc.) compile snippets with ${CC:-cc}: the cross toolchain
  # must be gone from the environment by now or they compile against
  # the aarch64 sysroot and fail.
  unset CC CXX AR RANLIB CMAKE_TOOLCHAIN_FILE CMAKE_PREFIX_PATH
  unset CPATH LIBRARY_PATH

  rm -rf lib shard.lock
  shards install --without-development
  crystal --version | head -n1 > cross-arm64/crystal-version.txt
  for target in markterm:src/main.cr markmark:src/main_mark.cr markpdf:src/main_pdf.cr; do
    name="${target%%:*}"
    source="${target#*:}"
    crystal build --cross-compile --target aarch64-linux-musl \
      --release --static -o "cross-arm64/$name" "$source" \
      | tail -n1 >> cross-arm64/link-commands.txt
  done
  test -s cross-arm64/link-commands.txt
}

# Inside the emulated arm64 container: check the crystal version matches
# the cross-compile stage (the objects must agree with this container's
# libcrystal.a), then run the captured link commands from the repo root
# so their relative object paths resolve.
link_cross_arm64() {
  set -e
  [ "$(cat cross-arm64/crystal-version.txt)" = "$(crystal --version | head -n1)" ] || {
    echo "crystal version mismatch between cross-compile and link stages:" >&2
    echo "  cross-compiled with: $(cat cross-arm64/crystal-version.txt)" >&2
    echo "  linking with:        $(crystal --version | head -n1)" >&2
    exit 1
  }
  while read -r command; do
    sh -c "$command"
  done < cross-arm64/link-commands.txt
  test -x cross-arm64/markterm -a -x cross-arm64/markmark -a -x cross-arm64/markpdf
}

docker run --rm --privileged \
  multiarch/qemu-user-static \
  --reset -p yes

# Build for AMD64 (native)
docker build . -f Dockerfile.static -t markterm-builder
docker run --rm -v "$PWD":/app --user="$UID" markterm-builder /bin/sh -c "cd /app && $(declare -f build_binaries) && build_binaries"
mv bin/markterm bin/markterm-static-linux-amd64
mv bin/markmark bin/markmark-static-linux-amd64
mv bin/markpdf bin/markpdf-static-linux-amd64

# ARM64: everything compiles natively, the emulated container links
docker run --rm -v "$PWD":/app --user="$UID" markterm-builder /bin/sh -c "cd /app && $(declare -f cross_compile_arm64) && cross_compile_arm64"
docker build . -f Dockerfile.static --platform linux/arm64 -t markterm-builder-arm64
docker run --rm -v "$PWD":/app --platform linux/arm64 --user="$UID" markterm-builder-arm64 /bin/sh -c "cd /app && $(declare -f link_cross_arm64) && link_cross_arm64"
mv cross-arm64/markterm bin/markterm-static-linux-arm64
mv cross-arm64/markmark bin/markmark-static-linux-arm64
mv cross-arm64/markpdf bin/markpdf-static-linux-arm64
