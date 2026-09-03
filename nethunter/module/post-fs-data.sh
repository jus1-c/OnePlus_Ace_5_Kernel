#!/system/bin/sh
# Verify stock state on boot. Do NOT auto-acquire.
LOG="/data/adb/nethunter/boot.log"
echo "[$(date +%H:%M:%S)] Boot check: verifying stock state" >> "$LOG"
# Check no leftover locks
for radio in wifi bt nfc; do
  if [ -f "/data/adb/nethunter/${radio}.lock" ]; then
    echo "[$(date +%H:%M:%S)] WARNING: stale lock for $radio, cleaning" >> "$LOG"
    rm -f "/data/adb/nethunter/${radio}.lock"
    echo "IDLE" > "/data/adb/nethunter/${radio}.state"
  fi
done
