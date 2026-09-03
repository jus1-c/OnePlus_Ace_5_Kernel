#!/bin/bash
# Build patched qca_cld3_kiwi_v2.ko for NetHunter Phase 0 spike testing.
# Usage: build_patched_wifi.sh <OP-ACE-5|OP-ACE-5-6.1.118>
set -euo pipefail

TARGET="${1:?Usage: $0 <OP-ACE-5|OP-ACE-5-6.1.118>}"
OUT="/tmp/nh-spike"
mkdir -p "$OUT"

case "$TARGET" in
  OP-ACE-5)       MOD_REV="21a5694f721d3826ac9e101e5d65919f2a8e739e"; COMMON_REV="086936b3387b4018805500fa4069d09637fdb89b" ;;
  OP-ACE-5-6.1.118) MOD_REV="d5323ede4f2059880c54818abfc1ac22d7e8bd5f"; COMMON_REV="7499247fd6e0669a062ec44cce948ec1e9d4c75e" ;;
  *) echo "Unknown target: $TARGET" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
KERNEL_SRC="${KERNEL_SRC:-$SCRIPT_DIR}"
PATCH_DIR="$SCRIPT_DIR/patches/wifi"
CLANG_DIR="kernel_platform/prebuilts/clang/host/linux-x86/clang-r487747c/bin"

echo "=== NetHunter Wi-Fi Injection Spike Build ==="
echo "Target:     $TARGET"
echo "Module rev: $MOD_REV"
echo "Common rev: $COMMON_REV"
echo "Output:     $OUT/qca_cld3_kiwi_v2.ko"
echo ""

# Step 1: Checkout pinned source revisions
echo "[1/5] Checking out source at $MOD_REV..."
if [ -d "vendor/qcom/opensource/wlan/qcacld-3.0/.git" ]; then
  git -C vendor/qcom/opensource/wlan/qcacld-3.0 checkout "$MOD_REV"
else
  echo "WARNING: qcacld-3.0 not a git repo, assuming already at correct revision"
fi

if [ -d "vendor/qcom/opensource/wlan/qca-wifi-host-cmn/.git" ]; then
  git -C vendor/qcom/opensource/wlan/qca-wifi-host-cmn checkout "$COMMON_REV"
else
  echo "WARNING: qca-wifi-host-cmn not a git repo, assuming already at correct revision"
fi

# Step 2: Apply patches
echo "[2/5] Applying injection patches..."
for patch in "$PATCH_DIR"/*.patch; do
  echo "  Applying $(basename "$patch")..."
  if ! git apply --check "$patch" 2>/dev/null; then
    echo "  WARNING: patch may not apply cleanly, attempting anyway..."
  fi
  git apply "$patch" || { echo "ERROR: Failed to apply $patch" >&2; exit 1; }
done

# Step 3: Enable frame injection in defconfig
echo "[3/5] Enabling CONFIG_FEATURE_FRAME_INJECTION_SUPPORT..."
DEFCONFIG="vendor/qcom/opensource/wlan/qcacld-3.0/configs/default_defconfig"
if grep -q "CONFIG_FEATURE_FRAME_INJECTION_SUPPORT" "$DEFCONFIG"; then
  echo "  Already enabled in defconfig"
else
  echo "CONFIG_FEATURE_FRAME_INJECTION_SUPPORT := y" >> "$DEFCONFIG"
  echo "  Added to defconfig"
fi

# Step 4: Build module
echo "[4/5] Building qca_cld3_kiwi_v2.ko..."
export PATH="$CLANG_DIR:$PATH"
export CC=clang
export LD=ld.lld

MAKE_ARGS=(
  ARCH=arm64
  CROSS_COMPILE=aarch64-linux-gnu-
  CLANG_TRIPLE=aarch64-linux-gnu-
  CONFIG_FEATURE_FRAME_INJECTION_SUPPORT=y
  CONFIG_FEATURE_MONITOR_MODE_SUPPORT=y
  M=vendor/qcom/opensource/wlan/qcacld-3.0
  modules
)

make -C "$KERNEL_SRC" "${MAKE_ARGS[@]}" O="$OUT/build" || {
  echo "ERROR: Build failed" >&2
  exit 1
}

# Find the built module
KO_PATH=$(find "$OUT/build" -name "qca_cld3_kiwi_v2.ko" -type f | head -1)
if [ -z "$KO_PATH" ]; then
  echo "ERROR: Built module not found" >&2
  exit 1
fi

cp "$KO_PATH" "$OUT/qca_cld3_kiwi_v2.ko"

# Step 5: Verify output
echo "[5/5] Verifying output..."
echo ""
echo "Build complete: $OUT/qca_cld3_kiwi_v2.ko"
modinfo "$OUT/qca_cld3_kiwi_v2.ko" | grep -E 'vermagic|scmversion|depends' || true
sha256sum "$OUT/qca_cld3_kiwi_v2.ko"

# Verify vermagic matches expected
VERMAGIC=$(modinfo "$OUT/qca_cld3_kiwi_v2.ko" | grep vermagic | awk '{print $2}')
EXPECTED="6.1.174-g638ecc425319"
if echo "$VERMAGIC" | grep -q "$EXPECTED"; then
  echo ""
  echo "SUCCESS: vermagic matches expected ($EXPECTED)"
else
  echo ""
  echo "WARNING: vermagic mismatch!"
  echo "  Expected substring: $EXPECTED"
  echo "  Got: $VERMAGIC"
  echo "  Module may need signing or kernel config alignment."
fi
