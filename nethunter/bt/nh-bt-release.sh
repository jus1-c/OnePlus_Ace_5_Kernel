#!/system/bin/sh
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/../framework/nh-state.sh"

RADIO="bt"
LOG="/data/adb/nethunter/bt.log"

log() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }

state=$(nh_get_state "$RADIO")
if [ "$state" = "IDLE" ]; then
  echo "Bluetooth already in stock state."
  exit 0
fi

log "Releasing Bluetooth..."

# Kill bluebinder
if [ -f /data/adb/nethunter/bluebinder.pid ]; then
  BPID="$(cat /data/adb/nethunter/bluebinder.pid)"
  kill "$BPID" 2>/dev/null || true
  sleep 1
  if kill -0 "$BPID" 2>/dev/null; then
    log "WARN: bluebinder ($BPID) still alive, sending SIGKILL"
    kill -9 "$BPID" 2>/dev/null || true
    sleep 1
  fi
  rm -f /data/adb/nethunter/bluebinder.pid
fi

hciconfig hci0 down 2>/dev/null || true
rmmod bt_vhci || true
rfkill unblock bluetooth || true
svc bluetooth enable || true

nh_release_lock "$RADIO"
log "RESTORED to stock"
echo "Bluetooth restored to stock."
