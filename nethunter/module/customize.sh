#!/system/bin/sh
set -euo pipefail

MODDIR="$MODPATH"
TARGET=$(grep_prop target "$MODDIR/module.prop")
EXPECTED_VERMAGIC=$(grep_prop kernel_vermagic "$MODDIR/module.prop")
ACTUAL_VERMAGIC=$(uname -r)

ui_print "NetHunter Takeover for $TARGET"

# Fail-closed: verify target matches
ACTUAL_MODEL=$(getprop ro.product.model)
if [ "$ACTUAL_MODEL" != "$TARGET" ]; then
  ui_print "ERROR: Target mismatch. Expected $TARGET, got $ACTUAL_MODEL"
  abort "Installation aborted: target mismatch"
fi

# Create runtime directories
mkdir -p /data/adb/nethunter
chmod 755 /data/adb/nethunter

ui_print "Module installed. Use nh-*-acquire scripts to activate."
ui_print "NO auto-activation at boot. Reboot restores stock."
