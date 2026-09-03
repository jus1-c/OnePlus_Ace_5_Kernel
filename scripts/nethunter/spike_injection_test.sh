#!/bin/bash
set -euo pipefail

ADB="/mnt/c/Users/Administrator/scoop/shims/adb.exe"
KO="/tmp/nh-spike/qca_cld3_kiwi_v2.ko"
RESULTS="docs/superpowers/specs/phase0-injection-spike-results.md"
STOCK_BACKUP="/data/adb/nethunter/qca_cld3_kiwi_v2_stock.ko"
PATCHED_REMOTE="/data/local/tmp/qca_cld3_kiwi_v2_patched.ko"
MODULE_PATH="/vendor_dlkm/lib/modules/qca_cld3_kiwi_v2.ko"

cleanup() {
  echo "[!] Failure detected, releasing Wi-Fi..."
  "$ADB" shell su -c "iw dev mon0 del 2>/dev/null" || true
  "$ADB" shell su -c "rmmod qca_cld3_kiwi_v2 2>/dev/null" || true
  "$ADB" shell su -c "cp $STOCK_BACKUP $MODULE_PATH 2>/dev/null" || true
  "$ADB" shell su -c "start vendor.wifi_hal_legacy 2>/dev/null" || true
  "$ADB" shell su -c "svc wifi enable 2>/dev/null" || true
  echo "[!] Release complete. Check results file for details."
}

trap cleanup ERR

if [ ! -f "$KO" ]; then
  echo "ERROR: Patched module not found at $KO"
  exit 1
fi

if ! "$ADB" devices | grep -q "device$"; then
  echo "ERROR: No ADB device connected"
  exit 1
fi

MODULE_HASH=$(sha256sum "$KO" | cut -d' ' -f1)

cat > "$RESULTS" <<EOF
# Phase 0 Injection Spike Results

Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Module hash: $MODULE_HASH
Device: $("${ADB}" shell getprop ro.product.model 2>/dev/null || echo "unknown")

## Acquire

EOF

echo "Acquiring Wi-Fi..."
"$ADB" shell su -c "svc wifi disable"
sleep 3
"$ADB" shell su -c "stop vendor.wifi_hal_legacy"
sleep 2
"$ADB" shell su -c "mkdir -p /data/adb/nethunter"
"$ADB" shell su -c "cp $MODULE_PATH $STOCK_BACKUP"
"$ADB" push "$KO" "$PATCHED_REMOTE"
"$ADB" shell su -c "cp $PATCHED_REMOTE $MODULE_PATH"
"$ADB" shell su -c "insmod $MODULE_PATH"
"$ADB" shell su -c "iw phy phy0 interface add mon0 type monitor"
echo "- Wi-Fi acquired, mon0 created" >> "$RESULTS"
echo "" >> "$RESULTS"

echo "## Mgmt Injection" >> "$RESULTS"
echo "" >> "$RESULTS"
echo "Running mdk4 deauth injection on channel 6..."
MGMT_RESULT=$("$ADB" shell su -c "mdk4 mon0 d -c 6 2>&1 | head -5" || echo "TOOL_MISSING")
echo '```' >> "$RESULTS"
echo "$MGMT_RESULT" >> "$RESULTS"
echo '```' >> "$RESULTS"
echo "" >> "$RESULTS"
echo "External sniffer confirmation: PENDING" >> "$RESULTS"
echo "" >> "$RESULTS"

echo "## Monitor RX" >> "$RESULTS"
echo "" >> "$RESULTS"
echo "Capturing 5 frames on mon0..."
RX_RESULT=$("$ADB" shell su -c "timeout 5 tshark -i mon0 -c 5 2>&1" || echo "CAPTURE_FAILED")
echo '```' >> "$RESULTS"
echo "$RX_RESULT" >> "$RESULTS"
echo '```' >> "$RESULTS"
echo "" >> "$RESULTS"

echo "Releasing Wi-Fi..."
"$ADB" shell su -c "iw dev mon0 del"
"$ADB" shell su -c "rmmod qca_cld3_kiwi_v2"
"$ADB" shell su -c "cp $STOCK_BACKUP $MODULE_PATH"
"$ADB" shell su -c "start vendor.wifi_hal_legacy"
"$ADB" shell su -c "svc wifi enable"
echo "- Wi-Fi released, stock module restored" >> "$RESULTS"
echo "" >> "$RESULTS"

cat >> "$RESULTS" <<'EOF'
## Verdict

- Mgmt injection: **PENDING** (confirm with external sniffer)
- Monitor RX: **PENDING** (verify radiotap headers and frame count)
- Data raw injection: NOT TESTED (deferred to Phase 1)

### External Sniffer Confirmation

| Check | Result | Notes |
|-------|--------|-------|
| Deauth frames observed | PENDING | |
| Source MAC matches device | PENDING | |
| Radiotap headers present | PENDING | |
| Frame count >= 5 | PENDING | |

Decision: PENDING (PROCEED if all PASS, STOP if any FAIL)
EOF

echo "Done. Results written to $RESULTS"
