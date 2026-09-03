#!/bin/bash
set -euo pipefail

source nethunter/framework/nh-state.sh

TMPDIR=$(mktemp -d)
export NH_STATE_DIR="$TMPDIR"
export NH_LOCK_DIR="$TMPDIR"

# Test: initial state is IDLE
state=$(nh_get_state wifi)
[ "$state" = "IDLE" ] || { echo "FAIL: expected IDLE, got $state"; exit 1; }

# Test: set_state changes state
nh_set_state wifi TAKEOVER
state=$(nh_get_state wifi)
[ "$state" = "TAKEOVER" ] || { echo "FAIL: expected TAKEOVER, got $state"; exit 1; }

# Test: acquire_lock creates lockfile
nh_acquire_lock wifi || { echo "FAIL: acquire_lock failed"; exit 1; }
[ -f "$NH_LOCK_DIR/wifi.lock" ] || { echo "FAIL: lockfile not created"; exit 1; }

# Test: release_lock removes lockfile and resets state
nh_release_lock wifi
[ ! -f "$NH_LOCK_DIR/wifi.lock" ] || { echo "FAIL: lockfile not removed"; exit 1; }
state=$(nh_get_state wifi)
[ "$state" = "IDLE" ] || { echo "FAIL: expected IDLE after release, got $state"; exit 1; }

echo "ALL TESTS PASSED"

# --- Fingerprint tests ---

source nethunter/framework/nh-fingerprint.sh

TMP_PROP="$TMPDIR/module.prop"
cat > "$TMP_PROP" <<EOF
target=OP-ACE-5
kernel_vermagic=6.1.174-g638ecc425319
scmversion=g976cb1e13abc
sha256_wifi=abc123
sha256_btvhci=def456
EOF

FAKE_KO="$TMPDIR/fake.ko"
echo -n "fakeko" > "$FAKE_KO"
FAKE_SHA=$(sha256sum "$FAKE_KO" | cut -d' ' -f1)

sed -i "s/^sha256_wifi=.*/sha256_wifi=$FAKE_SHA/" "$TMP_PROP"

nh_get_target_model() { echo "OP-ACE-5"; }
nh_get_running_vermagic() { echo "6.1.174-g638ecc425319"; }
nh_get_running_scmversion() { echo "g976cb1e13abc"; }

result=$(nh_check_fingerprint "$TMP_PROP" "wifi" "$FAKE_KO")
[ "$result" = "OK" ] || { echo "FAIL: expected OK, got $result"; exit 1; }

# Test: mismatch target
nh_get_target_model() { echo "WRONG-MODEL"; }
result=$(nh_check_fingerprint "$TMP_PROP" "wifi" "$FAKE_KO" || true)
[ "$result" = "MISMATCH_TARGET" ] || { echo "FAIL: expected MISMATCH_TARGET, got $result"; exit 1; }

# Test: mismatch vermagic
nh_get_target_model() { echo "OP-ACE-5"; }
nh_get_running_vermagic() { echo "wrong-vermagic"; }
result=$(nh_check_fingerprint "$TMP_PROP" "wifi" "$FAKE_KO" || true)
[ "$result" = "MISMATCH_VERMAGIC" ] || { echo "FAIL: expected MISMATCH_VERMAGIC, got $result"; exit 1; }

rm -rf "$TMPDIR"
echo "FINGERPRINT TESTS PASSED"
