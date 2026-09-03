#!/system/bin/sh
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/../framework/nh-state.sh"

RADIO="nfc"
LOG="/data/adb/nethunter/nfc.log"

log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }

state=$(nh_get_state "$RADIO")
if [ "$state" = "IDLE" ]; then
  echo "NFC already in stock state."
  exit 0
fi

log "Releasing NFC..."

start vendor.nfc_hal_service || true
sleep 2
svc nfc enable || true
cmd nfc enable-nfc || true

nh_release_lock "$RADIO"
log "RESTORED to stock"
echo "NFC restored to stock."
