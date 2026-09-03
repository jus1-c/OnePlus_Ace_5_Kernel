#!/system/bin/sh
set -euo pipefail

MODDIR="/data/adb/modules/nethunter_takeover_OP-ACE-5"
PASS=0
FAIL=0

run_test() {
  local name="$1"
  shift
  echo -n "TEST: $name ... "
  if "$@" >/dev/null 2>&1; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL"
    FAIL=$((FAIL + 1))
  fi
}

# Wi-Fi tests
run_test "wifi-acquire" "$MODDIR/wifi/nh-wifi-acquire.sh"
run_test "wifi-mon0-exists" iw dev mon0 info
run_test "wifi-release" "$MODDIR/wifi/nh-wifi-release.sh"
run_test "wifi-stock-restored" dumpsys wifi

# BT tests
run_test "bt-acquire" "$MODDIR/bt/nh-bt-acquire.sh"
run_test "bt-hci0-exists" hciconfig hci0
run_test "bt-release" "$MODDIR/bt/nh-bt-release.sh"

# NFC tests
run_test "nfc-acquire" "$MODDIR/nfc/nh-nfc-acquire.sh"
run_test "nfc-nci-init" "$MODDIR/system/bin/nci_raw_tool" init
run_test "nfc-release" "$MODDIR/nfc/nh-nfc-release.sh"
run_test "nfc-stock-restored" dumpsys nfc

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
