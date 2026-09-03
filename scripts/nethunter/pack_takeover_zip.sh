#!/bin/bash
set -euo pipefail

TARGET="${1:?Usage: $0 <OP-ACE-5|OP-ACE-5-6.1.118>}"
VERSION="${2:?Version string required}"
BUILD_DIR="/tmp/nh-build/$TARGET"
OUT_DIR="dist"
mkdir -p "$OUT_DIR"

PACK_DIR="/tmp/nh-pack-$TARGET"
rm -rf "$PACK_DIR"
mkdir -p "$PACK_DIR"/{system/bin,vendor_dlkm_override,META-INF/com/google/android}

# Copy framework + radio scripts
cp -r nethunter/framework "$PACK_DIR/"
cp -r nethunter/wifi "$PACK_DIR/"
cp -r nethunter/bt "$PACK_DIR/"
cp -r nethunter/nfc "$PACK_DIR/"

# Copy built binaries (skip missing — Phase 0 spike, best-effort)
BUILT_COMPONENTS=""
if [ -f "$BUILD_DIR/qca_cld3_kiwi_v2.ko" ]; then
  cp "$BUILD_DIR/qca_cld3_kiwi_v2.ko" "$PACK_DIR/vendor_dlkm_override/"
  BUILT_COMPONENTS="${BUILT_COMPONENTS}wifi,"
fi
if [ -f "$BUILD_DIR/bt_vhci.ko" ]; then
  cp "$BUILD_DIR/bt_vhci.ko" "$PACK_DIR/vendor_dlkm_override/"
  BUILT_COMPONENTS="${BUILT_COMPONENTS}bt,"
fi
if [ -f /tmp/nh-build/bluebinder/bluebinder ]; then
  cp /tmp/nh-build/bluebinder/bluebinder "$PACK_DIR/system/bin/"
  BUILT_COMPONENTS="${BUILT_COMPONENTS}bluebinder,"
fi
if [ -f nethunter/nfc/nci_raw_tool ]; then
  cp nethunter/nfc/nci_raw_tool "$PACK_DIR/system/bin/"
  BUILT_COMPONENTS="${BUILT_COMPONENTS}nfc,"
fi

if [ -z "$BUILT_COMPONENTS" ]; then
  echo "WARNING: No components built. Creating scripts-only ZIP." >&2
fi
echo "Built components: ${BUILT_COMPONENTS:-none}"

# Generate module.prop from template (use placeholders for missing modules)
SHA_QCA="not_built"
SHA_BTVHCI="not_built"
VERMAGIC="unknown"
SCMVERSION="unknown"
if [ -f "$PACK_DIR/vendor_dlkm_override/qca_cld3_kiwi_v2.ko" ]; then
  SHA_QCA=$(sha256sum "$PACK_DIR/vendor_dlkm_override/qca_cld3_kiwi_v2.ko" | cut -d' ' -f1)
  VERMAGIC=$(modinfo "$PACK_DIR/vendor_dlkm_override/qca_cld3_kiwi_v2.ko" | grep vermagic | awk '{print $2}' || echo "unknown")
  SCMVERSION=$(modinfo "$PACK_DIR/vendor_dlkm_override/qca_cld3_kiwi_v2.ko" | grep scmversion | awk '{print $2}' || echo "unknown")
fi
if [ -f "$PACK_DIR/vendor_dlkm_override/bt_vhci.ko" ]; then
  SHA_BTVHCI=$(sha256sum "$PACK_DIR/vendor_dlkm_override/bt_vhci.ko" | cut -d' ' -f1)
fi

sed -e "s/@@TARGET@@/$TARGET/g" \
    -e "s/@@VERSION@@/$VERSION/g" \
    -e "s/@@VERSION_CODE@@/1/g" \
    -e "s/@@VERMAGIC@@/$VERMAGIC/g" \
    -e "s/@@SCMVERSION@@/$SCMVERSION/g" \
    -e "s/@@SHA_QCA@@/$SHA_QCA/g" \
    -e "s/@@SHA_BTVHCI@@/$SHA_BTVHCI/g" \
    nethunter/module/module.prop.template > "$PACK_DIR/module.prop"

# Copy ReSukiSU install scripts
cp nethunter/module/customize.sh "$PACK_DIR/"
cp nethunter/module/post-fs-data.sh "$PACK_DIR/"
cp nethunter/module/service.sh "$PACK_DIR/"

# Create ZIP
ZIP_NAME="$OUT_DIR/nethunter-takeover-${TARGET}-${VERSION}.zip"
cd "$PACK_DIR"
zip -r "$OLDPWD/$ZIP_NAME" .
cd "$OLDPWD"

echo "Created: $ZIP_NAME"
sha256sum "$ZIP_NAME"
