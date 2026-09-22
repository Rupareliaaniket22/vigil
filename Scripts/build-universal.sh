#!/usr/bin/env bash
# Build a universal (arm64 + x86_64) release binary.
#
# `swift build --arch arm64 --arch x86_64` needs XCBuild, which ships only with
# full Xcode. Two single-arch builds plus lipo produce the same result using
# nothing but the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."

PRODUCT="${1:-Vigil}"
DEPLOY_TARGET="14.0"
OUT=".build/universal"

echo "==> arm64"
swift build -c release --scratch-path .build-arm64 \
  -Xswiftc -target -Xswiftc "arm64-apple-macos${DEPLOY_TARGET}"

echo "==> x86_64"
swift build -c release --scratch-path .build-x86_64 \
  -Xswiftc -target -Xswiftc "x86_64-apple-macos${DEPLOY_TARGET}" \
  -Xcc -target -Xcc "x86_64-apple-macos${DEPLOY_TARGET}" \
  -Xlinker -arch -Xlinker x86_64

mkdir -p "$OUT"
lipo -create -output "$OUT/$PRODUCT" \
  ".build-arm64/release/$PRODUCT" \
  ".build-x86_64/release/$PRODUCT"

echo "==> $OUT/$PRODUCT"
lipo -info "$OUT/$PRODUCT"
