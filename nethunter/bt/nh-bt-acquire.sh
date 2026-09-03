#!/system/bin/sh
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/../framework/nh-state.sh"
source "$SCRIPT_DIR/../framework/nh-fingerprint.sh"

RADIO="bt"
MODULE_PROP="$SCRIPT_DIR/../module.prop"
VHCI_KO="$SCRIPT_DIR/../vendor_dlkm_override/bt_vhci.ko"
BLUEBINDER="$SCRIPT_DIR/../system/bin/bluebinder"
LOG="/data/adb/nethunter/bt.log"

log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }

# Gate: fingerprint check
result=$(nh_check_fingerprint "$MODULE_PROP" "btvhci" "$VHCI_KO")
if [ "$result" != "OK" ]; then
  log "ABORT: fingerprint $result"
  echo "ABORT: $result" >&2
  exit 1
fi

# Gate: patched KO must exist before we touch anything
if [ ! -f "$VHCI_KO" ]; then
  log "ABORT: patched KO not found at $VHCI_KO"
  echo "ABORT: patched KO not found at $VHCI_KO" >&2
  exit 1
fi

# Gate: acquire lock
if ! nh_acquire_lock "$RADIO"; then
  log "ABORT: lock failed"
  exit 1
fi

log "Acquiring Bluetooth..."

# Quiesce Android Bluetooth
svc bluetooth disable
sleep 3
rfkill block bluetooth || true
sleep 1

# Load VHCI module
insmod "$VHCI_KO" || {
  log "FAIL: insmod bt_vhci"
  nh_release_lock "$RADIO"
  exit 1
}

# Start bluebinder daemon
"$BLUEBINDER" --hci 0 &
echo $! > /data/adb/nethunter/bluebinder.pid
sleep 3

# Wait for hci0 (10s timeout)
for i in $(seq 1 10); do
  if hciconfig hci0 >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! hciconfig hci0 >/dev/null 2>&1; then
  log "FAIL: hci0 not appearing"
  kill "$(cat /data/adb/nethunter/bluebinder.pid)" 2>/dev/null || true
  rm -f /data/adb/nethunter/bluebinder.pid
  rmmod bt_vhci
  nh_release_lock "$RADIO"
  exit 1
fi

hciconfig hci0 up
nh_set_state "$RADIO" "TAKEOVER"
log "TAKEOVER active"
echo "Bluetooth takeover active. hci0 ready."
