# Task 4 Report: Wi-Fi Takeover Scripts

**Status:** COMPLETE
**Commit:** 52ae186

## Files Created

- `nethunter/wifi/nh-wifi-acquire.sh` — Acquires Wi-Fi takeover
- `nethunter/wifi/nh-wifi-release.sh` — Releases Wi-Fi takeover

## Implementation Notes

Both scripts follow the exact specification from task-4-brief.md:

### Acquire Script
1. Sources framework (nh-state.sh, nh-fingerprint.sh)
2. Fingerprint gate check
3. Lock acquisition
4. Quiesces Android Wi-Fi (svc disable + stop HAL)
5. Backs up stock module with hash
6. Copies patched KO and insmod
7. Creates mon0 via iw phy
8. Smoke test (iw dev mon0 info)
9. Auto-rollback on ANY failure (rmmod, restore stock, release lock)
10. Sets state to TAKEOVER

### Release Script
1. Early exit if already IDLE
2. Removes mon0
3. rmmod patched module
4. Restores stock module from backup
5. Starts HAL + svc wifi enable
6. Releases lock
7. Logs RESTORED

Both scripts are executable (`chmod +x`).

## Fix Round 1

**Findings addressed:** 3 (1 critical, 2 important)

### Critical: Release script state tracking
- **Verified:** `nh_release_lock()` in `nh-state.sh:41` already calls `nh_set_state "$radio" "IDLE"` before releasing the flock. No redundant explicit call needed in release script.
- **Action:** No code change. Confirmed correct behavior via test #4.

### Important #1: Missing test file
- **Created:** `tests/nethunter/test_wifi_scripts.sh` with 4 tests:
  1. Fingerprint check gates lock acquisition (acquire won't lock if fingerprint fails)
  2. Release handles IDLE state gracefully (early exit)
  3. KO existence check blocks before Wi-Fi quiesce
  4. `nh_release_lock` sets state to IDLE
- All mocks local (svc, stop, start, insmod, rmmod, iw, sha256sum, sleep). Runs without device.
- **Result:** 4/4 PASS

### Important #2: Acquire missing KO_PATH existence check
- **Added:** `[ ! -f "$KO_PATH" ]` guard with logged ABORT message at `nh-wifi-acquire.sh:23-27`
- Placed BEFORE `nh_acquire_lock` and BEFORE `svc wifi disable` — fails fast without touching Wi-Fi state or acquiring locks.

### Verification
- `bash -n` syntax check: all 3 files OK
- Test suite: 4/4 passed
