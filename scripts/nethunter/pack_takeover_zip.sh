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

# Copy built binaries
cp "$BUILD_DIR/qca_cld3_kiwi_v2.ko" "$PACK_DIR/vendor_dlkm_override/"
cp "$BUILD_DIR/bt_vhci.ko" "$PACK_DIR/vendor_dlkm_override/"
cp /tmp/nh-build/bluebinder/bluebinder "$PACK_DIR/system/bin/"
cp nethunter/nfc/nci_raw_tool "$PACK_DIR/system/bin/"

# Generate module.prop from template
SHA_QCA=$(sha256sum "$PACK_DIR/vendor_dlkm_override/qca_cld3_kiwi_v2.ko" | cut -d' ' -f1)
SHA_BTVHCI=$(sha256sum "$PACK_DIR/vendor_dlkm_override/bt_vhci.ko" | cut -d' ' -f1)
VERMAGIC=$(modinfo "$PACK_DIR/vendor_dlkm_override/qca_cld3_kiwi_v2.ko" | grep vermagic | awk '{print $2}')
SCMVERSION=$(modinfo "$PACK_DIR/vendor_dlkm_override/qca_cld3_kiwi_v2.ko" | grep scmversion | awk '{print $2}')

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
