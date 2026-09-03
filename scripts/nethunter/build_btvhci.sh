#!/bin/bash
# Build bt_vhci.ko for NetHunter Bluetooth VHCI takeover.
# Usage: build_btvhci.sh <OP-ACE-5|OP-ACE-5-6.1.118>
set -euo pipefail

TARGET="${1:?Usage: $0 <OP-ACE-5|OP-ACE-5-6.1.118>}"
OUT="/tmp/nh-build/$TARGET"
mkdir -p "$OUT"

case "$TARGET" in
  OP-ACE-5|OP-ACE-5-6.1.118) ;;
  *) echo "Unknown target: $TARGET" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KERNEL_SRC="${KERNEL_SRC:-$SCRIPT_DIR}"
CLANG_DIR="kernel_platform/prebuilts/clang/host/linux-x86/clang-r487747c/bin"

echo "=== NetHunter BT VHCI Module Build ==="
echo "Target: $TARGET"
echo "Output: $OUT/bt_vhci.ko"
echo ""

# Step 1: Enable CONFIG_BT_HCIVHCI=m
echo "[1/3] Enabling CONFIG_BT_HCIVHCI=m..."
scripts/config --file "$KERNEL_SRC/.config" --enable CONFIG_BT_HCIVHCI || {
  echo "ERROR: Failed to enable CONFIG_BT_HCIVHCI" >&2
  exit 1
}

# Step 2: Build module
echo "[2/3] Building bt_vhci.ko..."
export PATH="$CLANG_DIR:$PATH"
export CC=clang
export LD=ld.lld

MAKE_ARGS=(
  ARCH=arm64
  CROSS_COMPILE=aarch64-linux-gnu-
  CLANG_TRIPLE=aarch64-linux-gnu-
  M=drivers/bluetooth
  modules
)

make -C "$KERNEL_SRC" "${MAKE_ARGS[@]}" O="$OUT/build" || {
  echo "ERROR: Build failed" >&2
  exit 1
}

KO_PATH=$(find "$OUT/build" -name "bt_vhci.ko" -type f | head -1)
if [ -z "$KO_PATH" ]; then
  echo "ERROR: Built module not found" >&2
  exit 1
fi

cp "$KO_PATH" "$OUT/bt_vhci.ko"

# Step 3: Verify output
echo "[3/3] Verifying output..."
echo ""
echo "Build complete: $OUT/bt_vhci.ko"
modinfo "$OUT/bt_vhci.ko" | grep -E 'vermagic|depends'
sha256sum "$OUT/bt_vhci.ko"
