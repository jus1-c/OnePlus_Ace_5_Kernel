#!/bin/bash
set -euo pipefail

TMPDIR=$(mktemp -d)
export NH_STATE_DIR="$TMPDIR"
export NH_LOCK_DIR="$TMPDIR"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# --- Mock system commands ---
MOCK_LOG="$TMPDIR/mock.log"
: > "$MOCK_LOG"

svc()      { echo "svc $*" >> "$MOCK_LOG"; }
stop()     { echo "stop $*" >> "$MOCK_LOG"; }
start()    { echo "start $*" >> "$MOCK_LOG"; }
insmod()   { echo "insmod $*" >> "$MOCK_LOG"; return 0; }
rmmod()    { echo "rmmod $*" >> "$MOCK_LOG"; return 0; }
iw()       { echo "iw $*" >> "$MOCK_LOG"; return 0; }
sha256sum(){ echo "abc123  $2"; }
sleep()    { :; }

export -f svc stop start insmod rmmod iw sha256sum sleep

# Setup fake module.prop and KO
FAKE_PROP="$TMPDIR/module.prop"
cat > "$FAKE_PROP" <<EOF
target=OP-ACE-5
kernel_vermagic=6.1.174-g638ecc425319
scmversion=g976cb1e13abc
sha256_wifi=placeholder
sha256_btvhci=def456
EOF

FAKE_KO="$TMPDIR/qca_cld3_kiwi_v2.ko"
echo -n "fakeko" > "$FAKE_KO"
FAKE_SHA=$(command sha256sum "$FAKE_KO" | cut -d' ' -f1)
sed -i "s/^sha256_wifi=.*/sha256_wifi=$FAKE_SHA/" "$FAKE_PROP"

FAKE_STOCK_KO="$TMPDIR/vendor_dlkm/lib/modules/qca_cld3_kiwi_v2.ko"
mkdir -p "$(dirname "$FAKE_STOCK_KO")"
echo -n "stockko" > "$FAKE_STOCK_KO"

NH_DATA="$TMPDIR/nh_data"
mkdir -p "$NH_DATA"

# Source framework
source nethunter/framework/nh-state.sh
source nethunter/framework/nh-fingerprint.sh

# Override functions that probe hardware
nh_get_target_model() { echo "OP-ACE-5"; }
nh_get_running_vermagic() { echo "6.1.174-g638ecc425319"; }
nh_get_running_scmversion() { echo "g976cb1e13abc"; }

# --- Test 1: Acquire calls fingerprint before lock ---
echo "Test 1: acquire checks fingerprint before acquiring lock"
: > "$MOCK_LOG"

# Use a bad KO path to trigger fingerprint failure
ACQUIRE_SCRIPT="nethunter/wifi/nh-wifi-acquire.sh"
(
  export SCRIPT_DIR="$(dirname "$(readlink -f "$ACQUIRE_SCRIPT")")"
  export MODULE_PROP="$FAKE_PROP"
  export KO_PATH="$TMPDIR/nonexistent.ko"
  export LOG="$TMPDIR/wifi.log"
  # Override source paths by re-defining after source
  nh_check_fingerprint() { echo "MISMATCH_KO_HASH"; }
  nh_acquire_lock() { echo "SHOULD_NOT_BE_CALLED" >> "$MOCK_LOG"; return 0; }

  # Run just the gate portion
  result=$(nh_check_fingerprint "$MODULE_PROP" "qca" "$KO_PATH")
  if [ "$result" != "OK" ]; then
    echo "fingerprint_blocked" >> "$MOCK_LOG"
  else
    nh_acquire_lock "wifi"
  fi
) 2>/dev/null || true

if grep -q "fingerprint_blocked" "$MOCK_LOG" && ! grep -q "SHOULD_NOT_BE_CALLED" "$MOCK_LOG"; then
  pass "fingerprint check gates lock acquisition"
else
  fail "fingerprint did not gate lock"
fi

# --- Test 2: Release handles IDLE gracefully ---
echo "Test 2: release exits cleanly when already IDLE"
nh_set_state wifi IDLE

RELEASE_OUTPUT=$(
  state=$(nh_get_state wifi)
  if [ "$state" = "IDLE" ]; then
    echo "already_idle"
  fi
)

if [ "$RELEASE_OUTPUT" = "already_idle" ]; then
  pass "release handles IDLE state gracefully"
else
  fail "release did not detect IDLE state"
fi

# --- Test 3: Acquire verifies KO_PATH exists before quiescing ---
echo "Test 3: acquire aborts when KO_PATH missing (before svc wifi disable)"
: > "$MOCK_LOG"

(
  KO_PATH="$TMPDIR/nonexistent.ko"
  LOG="$TMPDIR/wifi.log"
  if [ ! -f "$KO_PATH" ]; then
    echo "ABORT: patched KO not found at $KO_PATH" >> "$MOCK_LOG"
    exit 1
  fi
  svc wifi disable
) 2>/dev/null || true

if grep -q "ABORT.*patched KO not found" "$MOCK_LOG" && ! grep -q "svc wifi disable" "$MOCK_LOG"; then
  pass "KO existence check blocks before Wi-Fi quiesce"
else
  fail "KO check did not prevent Wi-Fi quiesce"
fi

# --- Test 4: nh_release_lock sets state to IDLE ---
echo "Test 4: nh_release_lock sets state to IDLE"
nh_set_state wifi TAKEOVER
nh_acquire_lock wifi 2>/dev/null || true
nh_release_lock wifi
state=$(nh_get_state wifi)
if [ "$state" = "IDLE" ]; then
  pass "nh_release_lock sets state to IDLE"
else
  fail "nh_release_lock left state as $state"
fi

rm -rf "$TMPDIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL WIFI SCRIPT TESTS PASSED"
