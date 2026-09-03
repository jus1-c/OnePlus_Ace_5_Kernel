# Task 1 Report: Phase 0 — Build Patched Wi-Fi Module for Spike

## Status: DONE_WITH_CONCERNS

## Commits Made
- `19b0744` feat(nethunter): add Wi-Fi injection patches and spike build script

## Files Created
- `patches/wifi/0001-FEATURE_FRAME_INJECTION_SUPPORT.patch` (293 lines added, 12 removed across 11 files)
- `patches/wifi/0002-monitor-tx-path-enable.patch` (75 lines added, 1 removed across 3 files)
- `scripts/nethunter/build_patched_wifi.sh` (executable, 88 lines)

## Test Summary
Patches parse correctly (`git apply --numstat` succeeds); `git apply --check` fails only because target source tree (`vendor/qcom/opensource/wlan/`) is not checked out in this modules-devicetree repo. Build script passes `bash -n` syntax check. No cross-compile environment available for actual build verification.

## Concerns

1. **Source tree not present**: This is a modules/devicetree repository, not the common kernel repo where `vendor/qcom/opensource/wlan/qcacld-3.0/` lives. Patches cannot be verified with `git apply --check` against actual source. They will need validation when the full kernel source is synced via manifest at revision `21a5694f`.

2. **Adapted from upstream, not extracted verbatim**: The original Loukious commit (`65c6a05e`) targets `drivers/staging/qcacld-3.0/` paths (in-tree kernel layout). These patches use `vendor/qcom/opensource/wlan/qcacld-3.0/` paths (out-of-tree Qualcomm vendor layout). Path adaptation was done manually; line numbers are approximate and may need adjustment against the actual pinned source.

3. **Placeholder implementations**: `wma_frame_inject.c` functions (`wma_vdev_create_hidden_sta`, `wma_mgmt_tx_with_vdev_override`) contain stub returns. The real implementation requires WMI command construction specific to Kiwi-v2 firmware API. The medium article describes the approach but doesn't provide complete WMI-level code.

4. **Hunk headers auto-corrected**: Original hand-written patch had mismatched hunk line counts in 5 locations. Fixed programmatically by counting actual context/add/remove lines per hunk. This means the patches are structurally valid unified diffs but the content line numbers are estimates.

5. **No module signing step**: Build script references signing via `modules_install` with kernel build key but doesn't implement it. Signing procedure depends on the specific kernel build infrastructure.

## What Was Skipped
- Actual cross-compile build (no toolchain/target available)
- Module signing integration
- Full WMI command implementation in wma_frame_inject.c
- Radiotap TX rate/channel override parsing
- Unit test files from upstream (stripped per ponytail)

## Add When
- Full kernel source synced → verify patches with `git apply --check`
- Cross-compile environment ready → run `build_patched_wifi.sh OP-ACE-5`
- Kiwi-v2 WMI API documented → implement real hidden STA vdev creation
- Device available → test injection with `aireplay-ng --test`

## Fix Round 1

### Findings Fixed

**#4 — Removed CONFIG_WLAN_DEBUG_CRASH_INJECT from defconfig patch**
- Deleted `CONFIG_WLAN_DEBUG_CRASH_INJECT := y` line from `patches/wifi/0001-FEATURE_FRAME_INJECTION_SUPPORT.patch` defconfig hunk
- Merged two defconfig hunks into one (only `CONFIG_FEATURE_FRAME_INJECTION_SUPPORT := y` remains)
- Updated hunk header line counts accordingly

**#5 — Removed orphan Kbuild object entries**
- Removed `wlan_hdd_frame_validate.o`, `wlan_hdd_inject_security.o`, `wlan_hdd_frame_inject_debug.o`, and `wlan_hdd_frame_validate_test.o` from Kbuild hunk
- Only `wlan_hdd_frame_inject.o` remains (has corresponding `.c` source in patch)
- Updated hunk header from `+208,16` to `+208,10`

**#6 — Added KERNEL_SRC to build script**
- Added `KERNEL_SRC="${KERNEL_SRC:-$SCRIPT_DIR}"` variable after `SCRIPT_DIR` definition
- Changed `make "${MAKE_ARGS[@]}"` to `make -C "$KERNEL_SRC" "${MAKE_ARGS[@]}"`

### Verification

```
$ bash -n scripts/nethunter/build_patched_wifi.sh
SYNTAX OK

$ git apply --numstat patches/wifi/0001-FEATURE_FRAME_INJECTION_SUPPORT.patch
21	1	vendor/qcom/opensource/wlan/qcacld-3.0/Kbuild
1	0	vendor/qcom/opensource/wlan/qcacld-3.0/configs/default_defconfig
10	2	vendor/qcom/opensource/wlan/qcacld-3.0/core/dp/txrx/ol_tx.c
25	4	vendor/qcom/opensource/wlan/qcacld-3.0/core/dp/txrx/ol_tx_desc.c
6	0	vendor/qcom/opensource/wlan/qcacld-3.0/core/dp/txrx/ol_txrx.c
23	4	vendor/qcom/opensource/wlan/qcacld-3.0/core/dp/txrx/ol_txrx_flow_control.c
51	0	vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/inc/wlan_hdd_frame_inject.h
60	0	vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_frame_inject.c
12	0	vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_main.c
42	0	vendor/qcom/opensource/wlan/qcacld-3.0/core/wma/src/wma_frame_inject.c
34	1	vendor/qcom/opensource/wlan/qca-wifi-host-cmn/os_if/linux/qca_vendor.h
EXIT: 0
```
