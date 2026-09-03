#!/system/bin/sh
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/../framework/nh-state.sh"

RADIO="wifi"
LOG="/data/adb/nethunter/wifi.log"

log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }

state=$(nh_get_state "$RADIO")
if [ "$state" = "IDLE" ]; then
  echo "Wi-Fi already in stock state."
  exit 0
fi

log "Releasing Wi-Fi..."

# Remove monitor interface
iw dev mon0 del 2>/dev/null || true

# Unload patched module
rmmod qca_cld3_kiwi_v2 || true

# Restore stock module
if [ -f /data/adb/nethunter/qca_cld3_kiwi_v2_stock.ko ]; then
  cp /data/adb/nethunter/qca_cld3_kiwi_v2_stock.ko /vendor_dlkm/lib/modules/qca_cld3_kiwi_v2.ko
fi

# Restart Android Wi-Fi
start vendor.wifi_hal_legacy || true
sleep 2
svc wifi enable || true

nh_release_lock "$RADIO"
log "RESTORED to stock"
echo "Wi-Fi restored to stock."
