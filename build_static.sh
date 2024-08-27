#!/bin/bash
set -e

docker run --rm --privileged \
  multiarch/qemu-user-static \
  --reset -p yes

# Build for AMD64
docker build . -f Dockerfile.static -t markterm-builder
docker run -ti --rm -v "$PWD":/app --user="$UID" markterm-builder /bin/sh -c "cd /app && rm -rf lib shard.lock && shards build --without-development --release --static"
mv bin/markterm bin/markterm-static-linux-amd64

# Build for ARM64
docker build . -f Dockerfile.static --platform linux/arm64 -t markterm-builder
docker run -ti --rm -v "$PWD":/app --platform linux/arm64 --user="$UID" markterm-builder /bin/sh -c "cd /app && rm -rf lib shard.lock && shards build --without-development --release --static"
mv bin/markterm bin/markterm-static-linux-arm64
