#!/system/bin/sh
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/../framework/nh-state.sh"
source "$SCRIPT_DIR/../framework/nh-fingerprint.sh"

RADIO="wifi"
MODULE_PROP="$SCRIPT_DIR/../module.prop"
KO_PATH="$SCRIPT_DIR/../vendor_dlkm_override/qca_cld3_kiwi_v2.ko"
LOG="/data/adb/nethunter/wifi.log"

log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }

# Gate: fingerprint check
result=$(nh_check_fingerprint "$MODULE_PROP" "qca" "$KO_PATH")
if [ "$result" != "OK" ]; then
  log "ABORT: fingerprint $result"
  echo "ABORT: $result" >&2
  exit 1
fi

# Gate: acquire lock
if ! nh_acquire_lock "$RADIO"; then
  log "ABORT: lock failed"
  exit 1
fi

log "Acquiring Wi-Fi..."

# Quiesce Android Wi-Fi
svc wifi disable
sleep 2
stop vendor.wifi_hal_legacy || true
sleep 2

# Backup stock module
STOCK_HASH=$(sha256sum /vendor_dlkm/lib/modules/qca_cld3_kiwi_v2.ko | cut -d' ' -f1)
echo "$STOCK_HASH" > /data/adb/nethunter/wifi_stock_hash
cp /vendor_dlkm/lib/modules/qca_cld3_kiwi_v2.ko /data/adb/nethunter/qca_cld3_kiwi_v2_stock.ko

# Load patched module
cp "$KO_PATH" /vendor_dlkm/lib/modules/qca_cld3_kiwi_v2.ko
insmod /vendor_dlkm/lib/modules/qca_cld3_kiwi_v2.ko || {
  log "FAIL: insmod failed"
  cp /data/adb/nethunter/qca_cld3_kiwi_v2_stock.ko /vendor_dlkm/lib/modules/qca_cld3_kiwi_v2.ko
  nh_release_lock "$RADIO"
  exit 1
}

# Create monitor interface
iw phy phy0 interface add mon0 type monitor || {
  log "FAIL: iw add mon0 failed"
  rmmod qca_cld3_kiwi_v2
  cp /data/adb/nethunter/qca_cld3_kiwi_v2_stock.ko /vendor_dlkm/lib/modules/qca_cld3_kiwi_v2.ko
  nh_release_lock "$RADIO"
  exit 1
}

# Smoke test
if ! iw dev mon0 info >/dev/null 2>&1; then
  log "FAIL: smoke test failed"
  iw dev mon0 del 2>/dev/null || true
  rmmod qca_cld3_kiwi_v2
  cp /data/adb/nethunter/qca_cld3_kiwi_v2_stock.ko /vendor_dlkm/lib/modules/qca_cld3_kiwi_v2.ko
  nh_release_lock "$RADIO"
  exit 1
fi

nh_set_state "$RADIO" "TAKEOVER"
log "TAKEOVER active"
echo "Wi-Fi takeover active. mon0 ready."
