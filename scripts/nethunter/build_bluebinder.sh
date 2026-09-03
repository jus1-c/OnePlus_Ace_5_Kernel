#!/bin/bash
# Cross-compile bluebinder for NetHunter Bluetooth VHCI proxy.
# Usage: build_bluebinder.sh
set -euo pipefail

BLUEBINDER_COMMIT="c3e1b155e308f6df9c9a02dbd909a44e7319ab7d"
OUT="/tmp/nh-build/bluebinder"
mkdir -p "$OUT"

echo "=== NetHunter Bluebinder Build ==="
echo "Commit: $BLUEBINDER_COMMIT"
echo "Output: $OUT/bluebinder"
echo ""

# Step 1: Clone at pinned commit
echo "[1/3] Cloning mer-hybris/bluebinder at $BLUEBINDER_COMMIT..."
if [ ! -d "$OUT/src/.git" ]; then
  git clone https://github.com/mer-hybris/bluebinder.git "$OUT/src"
fi
git -C "$OUT/src" checkout "$BLUEBINDER_COMMIT"

# Step 2: Cross-compile for aarch64-android
echo "[2/3] Cross-compiling bluebinder..."
NDK_ROOT="${ANDROID_NDK_HOME:-${NDK_HOME:-}}"
if [ -z "$NDK_ROOT" ]; then
  echo "ERROR: Set ANDROID_NDK_HOME or NDK_HOME to Android NDK path" >&2
  exit 1
fi

TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64"
CC="$TOOLCHAIN/bin/aarch64-linux-android34-clang"

if [ ! -x "$CC" ]; then
  echo "ERROR: NDK clang not found at $CC" >&2
  exit 1
fi

# Dependencies: libgbinder, glib-2.0 must be prebuilt for aarch64-android
PREBUILT_LIBS="${NH_PREBUILT_LIBS:-$OUT/prebuilt}"
if [ ! -d "$PREBUILT_LIBS" ]; then
  echo "WARNING: Prebuilt libs dir not found at $PREBUILT_LIBS"
  echo "Set NH_PREBUILT_LIBS to directory containing libgbinder and glib-2.0"
fi

export CC
export PKG_CONFIG_PATH="$PREBUILT_LIBS/lib/pkgconfig"
export CFLAGS="--sysroot=$TOOLCHAIN/sysroot -I$PREBUILT_LIBS/include"
export LDFLAGS="-L$PREBUILT_LIBS/lib"

make -C "$OUT/src" clean || true
make -C "$OUT/src" || {
  echo "ERROR: Build failed" >&2
  exit 1
}

cp "$OUT/src/bluebinder" "$OUT/bluebinder"

# Step 3: Verify output
echo "[3/3] Verifying output..."
echo ""
echo "Build complete: $OUT/bluebinder"
file "$OUT/bluebinder"
sha256sum "$OUT/bluebinder"
