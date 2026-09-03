#!/system/bin/sh
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/../framework/nh-state.sh"

RADIO="nfc"
NCI_TOOL="$SCRIPT_DIR/../system/bin/nci_raw_tool"
LOG="/data/adb/nethunter/nfc.log"

log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }

if ! nh_acquire_lock "$RADIO"; then
  log "ABORT: lock failed"
  exit 1
fi

log "Acquiring NFC..."

cmd nfc disable-nfc persist || true
svc nfc disable || true
sleep 2
stop vendor.nfc_hal_service || true
sleep 2

# Smoke test
if ! "$NCI_TOOL" init; then
  log "FAIL: nci_raw_tool init failed"
  start vendor.nfc_hal_service || true
  svc nfc enable || true
  nh_release_lock "$RADIO"
  exit 1
fi

nh_set_state "$RADIO" "TAKEOVER"
log "TAKEOVER active"
echo "NFC takeover active. /dev/nq-nci exclusive."
