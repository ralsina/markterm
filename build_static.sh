#!/bin/bash
set -e

# Inside the container: build libharu statically, the litepdf shim, then
# all binaries. The clean is required: the repo may carry shim objects
# built by the host toolchain, which cannot link into a static musl build.
build_binaries() {
  make -C ext clean
  ext/build-libharu.sh
  make -C ext
  rm -rf lib shard.lock
  shards build --without-development --release --static
}

docker run --rm --privileged \
  multiarch/qemu-user-static \
  --reset -p yes

# Build for AMD64
docker build . -f Dockerfile.static -t markterm-builder
docker run --rm -v "$PWD":/app --user="$UID" markterm-builder /bin/sh -c "cd /app && $(declare -f build_binaries) && build_binaries"
mv bin/markterm bin/markterm-static-linux-amd64
mv bin/markmark bin/markmark-static-linux-amd64
mv bin/markpdf bin/markpdf-static-linux-amd64

# Build for ARM64
docker build . -f Dockerfile.static --platform linux/arm64 -t markterm-builder
docker run --rm -v "$PWD":/app --platform linux/arm64 --user="$UID" markterm-builder /bin/sh -c "cd /app && $(declare -f build_binaries) && build_binaries"
mv bin/markterm bin/markterm-static-linux-arm64
mv bin/markmark bin/markmark-static-linux-arm64
mv bin/markpdf bin/markpdf-static-linux-arm64
