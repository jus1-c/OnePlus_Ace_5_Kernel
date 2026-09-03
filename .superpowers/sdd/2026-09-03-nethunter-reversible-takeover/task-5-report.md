# Task 5 Report: Bluetooth VHCI Module Build and Bluebinder Integration

## Status: COMPLETE

## Files Created

1. `scripts/nethunter/build_btvhci.sh` — Builds `bt_vhci.ko` with `CONFIG_BT_HCIVHCI=m`, follows same pattern as `build_patched_wifi.sh` (target selection, clang toolchain, vermagic verification)
2. `scripts/nethunter/build_bluebinder.sh` — Cross-compiles bluebinder at pinned commit `c3e1b155`, requires NDK + prebuilt libgbinder/glib-2.0
3. `nethunter/bt/nh-bt-acquire.sh` — Fingerprint gate → lock → disable stock BT → insmod bt_vhci → start bluebinder daemon → wait hci0 (10s) → hciconfig up → TAKEOVER state
4. `nethunter/bt/nh-bt-release.sh` — Kill bluebinder via PID file → hciconfig down → rmmod → rfkill unblock → svc bluetooth enable → release lock → IDLE

## Consistency with Task 4

- Same shebang (`#!/system/bin/sh`), same `set -euo pipefail`
- Same SCRIPT_DIR/source pattern for framework
- Same log function format
- Same fingerprint check → lock → action → state flow in acquire
- Same state check → teardown → restore → unlock flow in release
- Build scripts follow same structure as `build_patched_wifi.sh`

## Key Differences from Wi-Fi

- No stock module backup needed (VHCI is additive, not replacement)
- Uses bluebinder daemon (PID tracked in `/data/adb/nethunter/bluebinder.pid`)
- hci0 appearance poll loop with 10s timeout
- Rollback on hci0 failure kills daemon + unloads module + releases lock

## Fix Round 1 (2026-09-04)

### Important #1: KO existence pre-check in acquire
Added `[ ! -f "$VHCI_KO" ]` gate BEFORE `nh_acquire_lock` in `nethunter/bt/nh-bt-acquire.sh`, matching the pattern from `nethunter/wifi/nh-wifi-acquire.sh`. Prevents acquiring a lock when the patched KO is missing.

### Important #2: Orphan prevention in release
After SIGTERM, added `sleep 1` + `kill -0` liveness check in `nethunter/bt/nh-bt-release.sh`. If bluebinder survives SIGTERM, sends SIGKILL with logged warning. Prevents orphaned bluebinder processes after release.

### Verification
- `bash -n nh-bt-acquire.sh` → OK
- `bash -n nh-bt-release.sh` → OK
