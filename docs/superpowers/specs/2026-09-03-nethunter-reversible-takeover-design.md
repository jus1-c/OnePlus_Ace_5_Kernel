# NetHunter Reversible Hardware Takeover Design

## 1. Context and Scope

### 1.1 Objective

Deliver a maximal Kali NetHunter deployment for OnePlus Ace 5 (A16) that prioritizes reversible takeover of built-in radios over external adapters, while preserving the existing single-Image build contract. The system must provide high-level control over Wi-Fi, Bluetooth, NFC, USB, and GNSS without permanently altering vendor partitions or requiring reflash to restore stock behavior.

### 1.2 Decisions Locked

| #   | Decision                                                                                          | Rationale                                                                                                                                                  |
| --- | ------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | Cellular/baseband excluded                                                                        | No sysmocom/Osmocom support on SM8650 modem; raw baseband takeover infeasible                                                                              |
| 2   | Wi-Fi injection is mandatory                                                                      | Core NetHunter Arsenal requirement; elevates injection from gated feature to critical path                                                                   |
| 3   | NFC raw NCI capture/send accepted; card-emulation out of scope                                    | NDA + TEE/QSEE block MIFARE/eSE emulation (reason NCIHost discontinued); raw NCI sufficient for capture/inject                                               |
| 4   | Injection tiering: mgmt-frame stable-required, data-frame best-effort                             | Mgmt covers ~95% of NetHunter Wi-Fi arsenal (deauth/beacon/probe/handshake); data raw depends on WCN7750 firmware and may fail without blocking release     |
| 5   | Single Image build preserved; takeovers delivered as per-target ReSukiSU module ZIPs              | Maintains existing CI/release contract; enables radio-level reversibility without kernel variants                                                            |
| 6   | No auto-acquire at boot; reboot restores stock                                                    | Fail-safe default; user explicitly invokes acquire/release                                                                                                 |
| 7   | Phase 0 hardware spike gates all subsequent takeover work                                         | Injection feasibility unproven on WCN7750; must validate before building full machinery                                                                    |

### 1.3 Out of Scope

- Cellular/baseband raw control
- NFC card-emulation (MIFARE Classic, HCE via eSE)
- Qualcomm vendor BT features (LE-audio offload, LHDC, bttpi)
- External adapter integration (deferred to future phase)
- Camera/sensor raw takeover

---

## 2. Verified Device State

All observations below are read-only probes against live device `3B6F4EE7NT8TM34E` (PKG110 / OP5D2BL1).

### 2.1 Kernel and Modules

- Running: `Linux 6.1.141-android14-OP-ACE5-RESUKISU`
- Shipped vendor_dlkm modules vermagic: `6.1.174-g638ecc425319 SMP preempt mod_unload modversions aarch64`, scmversion `g976cb1e13abc`
- GKI decouples Image uname from module vermagic via protected symbol set; replacement .ko must match GKI KMI, not uname
- `CONFIG_MODVERSIONS=y`, `CONFIG_RFKILL=m`, `CONFIG_BT=m`, `CONFIG_BT_HCIVHCI` not currently enabled

### 2.2 Wi-Fi (Qualcomm Kiwi-v2 / WCN7750)

- Module: `/vendor_dlkm/lib/modules/qca_cld3_kiwi_v2.ko` (22 MB)
- Depends: `cfg80211, cnss_utils, cnss_nl, ipam, cnss_prealloc, qcom_iommu_util, sched-walt, qcom_va_minidump, cnss2`
- PCI: `17cb:1107`; phy: `/sys/class/ieee80211/phy0`; iface: `wlan0`
- `con_mode` writable, currently `0`
- Runtime config has `CONFIG_FEATURE_MONITOR_MODE_SUPPORT` but monitor netdev lacks `ndo_start_xmit` → no TX today
- Both vendor revisions enable monitor-related configs

### 2.3 Bluetooth (Hamilton)

- HAL: `android.hardware.bluetooth@1.1-service-qti` (HIDL 1.1) on `/dev/hwbinder`
- Registered: `android.hardware.bluetooth@1.0::IBluetoothHci/default`, `android.hardware.bluetooth@1.1::IBluetoothHci/default`
- Devices present: `/dev/binder`, `/dev/hwbinder`, `/dev/vndbinder`, `/dev/rfkill`
- **Missing**: `/dev/vhci` (requires `CONFIG_BT_HCIVHCI=m`)
- Firmware: Hamilton (`persist.vendor.qcom.bluetooth.soc=hamilton`)

### 2.4 NFC (NXP SN1xx/NQ330)

- Driver: `/vendor_dlkm/lib/modules/nxp-nci.ko` (79 KB), name `nxp_nci`, description "NXP NFC I2C driver"
- OF compatible: `qcom,sn-nci`
- Depends: `qcom_ipc_logging, pinctrl-msm`
- Device: `/dev/nq-nci` (nfc:nfc, major 482)
- HAL: `vendor.nfc_hal_service` (PID 1179) → `android.hardware.nfc-service.nxp`
- Framework: `com.android.nfc` (PID 5281) + `com.android.nfcservices` apex
- Android 16 uses AIDL `android.hardware.nfc.INfc/default` — incompatible with NCIHost's HIDL ptrace hooks
- `cmd nfc` supports: enable/disable, observe-mode, reader-mode, controller-always-on, discovery-tech, DTA, offhost-se, routing-table

### 2.5 USB/GNSS

- DWC3 dual-role at `/sys/class/udc/a600000.dwc3`; role switches functional
- ConfigFS gadgets: `/config/usb_gadget/g1`, `/config/usb_gadget/g2`
- Functions available: HID, mass-storage, ACM, NCM, ECM, EEM, RNDIS, FunctionFS
- GNSS: `android.hardware.gnss.IGnss/default` (AIDL); NetHunter wardriving bridges via UDP 10110

### 2.6 Build System

- Production builds only `Image`; `modules_install` runs only when `debug=true`
- Module overlay mechanism: `kernel/module/module_overlay/modules/*.ko` with priority suffix matching
- Vendor module blacklist has `RISKY_MODULES` guard protecting `cnss2`, `rfkill`, etc.
- Two targets pinned:
  - `OP-ACE-5`: common `086936b3`, modules/devicetree `21a5694f`
  - `OP-ACE-5-6.1.118`: common `7499247f`, modules/devicetree `d5323ede`

---

## 3. Architecture

### 3.1 Artifact Layout

```
AnyKernel3 ZIP ─── Image only (single build, unchanged)

ReSukiSU ZIP #1: nethunter-takeover-OP-ACE-5.zip
├── module.prop          (target fingerprint, kernel vermagic, scmversion, sha256 per .ko)
├── customize.sh         (fail-closed fingerprint check, directory setup, NO auto-insmod)
├── post-fs-data.sh      (verify stock state only, exit 0)
├── service.sh           (verify stock state only, exit 0)
├── system/bin/
│   ├── nh-wifi-acquire
│   ├── nh-wifi-release
│   ├── nh-bt-acquire
│   ├── nh-bt-release
│   ├── nh-nfc-acquire
│   ├── nh-nfc-release
│   └── nci_raw_tool
├── vendor_dlkm_override/
│   ├── qca_cld3_kiwi_v2.ko    (patched, signed with build key)
│   └── bt_vhci.ko             (new, CONFIG_BT_HCIVHCI=m)
└── data/adb/nethunter/        (runtime state dir, created by customize.sh)

ReSukiSU ZIP #2: nethunter-takeover-OP-ACE-5-6.1.118.zip
    Same layout, rebuilt against d5323ede/7499247f vermagic/KMI
```

### 3.2 Per-Radio State Machine

```
IDLE ──acquire──▶ QUIESCE_ANDROID ──load_module──▶ TAKEOVER ──release──▶ RESTORE
  ▲                      │                              │                     │
  └──── reboot ──────────┘                              │                     │
                                                        ├── crash/timeout ──▶ RESTORE
                                                        └── watchdog ──────▶ RESTORE
```

- **Lock**: `/data/adb/nethunter/<radio>.lock` (flock) + `<radio>.state` file
- **Acquire sequence**: verify fingerprint == ZIP metadata → stop relevant HAL/service → rfkill/dumpsys gate → insmod/modprobe takeover → smoke test → mark TAKEOVER
- **Release sequence**: rmmod (if loaded) → start HAL/service → verify dumpsys/hciconfig/nfc state → delete lock
- **Reboot**: no `post-fs-data.sh` auto-load; `boot-completed.sh` verifies stock restoration only
- **Timeout**: 15s quiesce timeout; if HAL doesn't stop, auto-release and log failure

### 3.3 Fail-Closed Gates

Every acquire checks ALL of the following before proceeding:
1. Target model matches `module.prop` target field exactly
2. Running kernel vermagic matches `module.prop` kernel_vermagic
3. Running kernel scmversion matches `module.prop` scmversion
4. SHA-256 of each `.ko` in ZIP matches `module.prop` checksums
5. No other radio currently in TAKEOVER state (mutual exclusion per-radio, concurrent across radios allowed)

Any check failure → abort acquire, log reason, exit non-zero. Never load mismatched modules.

---

## 4. Radio-Specific Designs

### 4.1 Wi-Fi (Kiwi-v2 / WCN7750)

#### 4.1.1 Patch Set

Two upstream patch sets applied to pinned source `21a5694f` (OP-ACE-5) / `d5323ede` (6.1.118):

1. **Loukious/vendor_qcom_opensource_wlan@25875eb** — adds `FEATURE_FRAME_INJECTION_SUPPORT`:
   - `cdp_refresh_monitor_mode()` op + datapath registration
   - `DP_TX_INJECTION_DESC_PREFIX` marker for injection nbufs
   - `FILTER_MGMT_ALL` for WCN7750 in `dp_mon_filter_set_reset_mon_dest`
   - `wma_injection_dp_complete()` callback on TX completion
   - Kbuild: `CONFIG_FEATURE_FRAME_INJECTION_SUPPORT=y` implies `CONFIG_FEATURE_MONITOR_MODE_SUPPORT=y`

2. **brokestar233/android_kernel_modules_and_devicetree_oneplus_sm8750@be87f12** — enables TX path:
   - `wlan_mon_drv_ops.ndo_start_xmit = hdd_hard_start_xmit`
   - Skip `dp_intf_is_tx_allowed()` peer check for `QDF_MONITOR_MODE`
   - Copy source MAC from frame header for monitor TX
   - Register `tx_comp` callback on monitor vdev

#### 4.1.2 Injection Tiering

| Tier            | Requirement       | Verification Method                                                | Firmware Dependency                          |
| --------------- | ----------------- | ------------------------------------------------------------------ | -------------------------------------------- |
| Mgmt-frame      | **Stable-required** | `mdk4 mon0 d` + `aireplay-ng --deauth` confirmed by external sniffer | High — matches patch intent                  |
| Data-frame raw  | Best-effort       | `aireplay-ng` data injection test; record PASS/FAIL per-target     | Unknown — WCN7750 may silently drop          |
| Monitor RX      | Required          | `tshark -i mon0` shows radiotap headers                            | High — already working                       |

#### 4.1.3 Acquire/Release

**Acquire:**
1. Verify fingerprint gates
2. `svc wifi disable` + wait `wpa_supplicant` exit (timeout 10s)
3. `stop vendor.wifi_hal_legacy` + verify stopped
4. Backup stock module hash: `sha256sum /vendor_dlkm/lib/modules/qca_cld3_kiwi_v2.ko > /data/adb/nethunter/wifi_stock_hash`
5. `cp /data/adb/modules/nethunter_takeover/vendor_dlkm_override/qca_cld3_kiwi_v2.ko /vendor_dlkm/lib/modules/qca_cld3_kiwi_v2.ko`
6. `insmod /vendor_dlkm/lib/modules/qca_cld3_kiwi_v2.ko` (or modprobe if deps need reload)
7. `iw phy phy0 interface add mon0 type monitor`
8. Smoke: `iw dev mon0 info` shows monitor mode; `tshark -i mon0 -c 5` captures frames
9. Mark TAKEOVER in state file

**Release:**
1. `iw dev mon0 del`
2. `rmmod qca_cld3_kiwi_v2`
3. Restore stock: `cp` from backup hash-verified location OR `modprobe qca_cld3_kiwi_v2` from vendor_dlkm original
4. `start vendor.wifi_hal_legacy`
5. `svc wifi enable`
6. Verify: `dumpsys wifi` shows normal state, `wlan0` associated if previously connected
7. Delete lock + state

### 4.2 Bluetooth (Hamilton)

#### 4.2.1 Kernel Module

Build `CONFIG_BT_HCIVHCI=m` against target KMI → produces `bt_vhci.ko`. This creates `/dev/vhci` which bluebinder proxies to the Android BT HAL.

Dependencies already satisfied: `CONFIG_BT=m`, `CONFIG_RFKILL=m`, `/dev/rfkill` present.

#### 4.2.2 Bluebinder Bridge

- Source: `mer-hybris/bluebinder@c3e1b155e308f6df9c9a02dbd909a44e7319ab7d`
- Dependencies: `libgbinder`, `glib-2.0` (cross-compiled for aarch64 Android)
- Auto-detects HIDL vs AIDL: tries `android.hardware.bluetooth.IBluetoothHci` (AIDL) first, falls back to `android.hardware.bluetooth@1.0::IBluetoothHci` (HIDL)
- On this device: HIDL 1.1 registered → bluebinder will use HIDL path
- Handles rfkill power recovery (commit `c3e1b155` fix)
- Runs as daemon: `bluebinder --hci 0`

#### 4.2.3 Acquire/Release

**Acquire:**
1. Verify fingerprint gates
2. `svc bluetooth disable` + wait `bluetooth_manager` off (timeout 10s)
3. `rfkill block bluetooth` (retry up to 3x)
4. `insmod bt_vhci.ko` → verify `/dev/vhci` exists
5. Start `bluebinder` daemon (foreground or background with PID tracking)
6. Wait for `hciconfig hci0` to appear (timeout 10s)
7. Smoke: `hciconfig hci0 up` + `hcitool lescan` returns results (or at least doesn't error)
8. Mark TAKEOVER

**Release:**
1. Kill bluebinder daemon
2. `hciconfig hci0 down` (best-effort)
3. `rmmod bt_vhci`
4. `rfkill unblock bluetooth`
5. `svc bluetooth enable`
6. Verify: `dumpsys bluetooth_manager` shows adapter on, profiles functional
7. Delete lock + state

### 4.3 NFC (NXP SN1xx/NQ330)

#### 4.3.1 Approach

Exclusive `/dev/nq-nci` takeover with conditional fallback. NCIHost (`cinit/NCIHost@b293fb19`) is NOT reused: discontinued 2022, targets SDK 31, relies on ptrace/HAL hooking incompatible with Android 16 AIDL `INfc`.

Instead: minimal `nci_raw_tool` binary providing open/read/write/ioctl on `/dev/nq-nci` with NCI framing.

#### 4.3.2 nci_raw_tool Specification

Minimal C binary (~500 LOC):
- `nci_raw_tool init` — open `/dev/nq-nci`, send CORE_RESET + CORE_INIT, print NFCC info
- `nci_raw_tool capture [duration]` — read loop, hexdump NCI packets to stdout/file
- `nci_raw_tool send <hex>` — write raw NCI command, print response
- `nci_raw_tool close` — clean shutdown

No dependencies beyond libc. No Xposed, no ptrace, no HAL hooking.

#### 4.3.3 Acquire/Release

**Acquire:**
1. Verify fingerprint gates
2. `cmd nfc disable-nfc persist` + `svc nfc disable`
3. `stop vendor.nfc_hal_service` + verify stopped (timeout 10s)
4. `stop com.android.nfc` (framework) + verify
5. `flock /dev/nq-nci` (exclusive lock held for duration)
6. Smoke: `nci_raw_tool init` succeeds, prints NFCC version
7. Mark TAKEOVER

**Release:**
1. Close nci_raw_tool (releases flock)
2. `start vendor.nfc_hal_service`
3. `svc nfc enable` + `cmd nfc enable-nfc`
4. Verify: `dumpsys nfc` shows `mState=on`
5. Delete lock + state

#### 4.3.4 Fallback Path

If exclusive takeover fails on exact target (HAL won't quiesce, SE conflict, etc.):
- Fall back to `NfcAdapter.sendVendorNciMessage()` via root shell (Android 16 API, GID 0xF)
- Document limitation: shared ownership, no exclusive capture
- Record in spec as known ceiling

### 4.4 USB/GNSS

No takeover needed. Stock capabilities already sufficient:
- USB: ConfigFS gadgets at `/config/usb_gadget/g1|g2`, HID/mass-storage/NCM/RNDIS/FunctionFS all functional
- GNSS: `IGnss` AIDL HAL + NetHunter wardriving UDP 10110 bridge

These are documented in the spec but require no ZIP artifacts or acquire/release scripts.

---

## 5. Phase 0: Injection Proof Spike

### 5.1 Purpose

Validate Wi-Fi injection feasibility on exact target hardware BEFORE building full reversible machinery. This is the critical-path gate established by decision #2 (injection mandatory) and #4 (mgmt stable-required).

### 5.2 Procedure

1. Build single `qca_cld3_kiwi_v2.ko` patched per §4.1.1 for `OP-ACE-5` target (`21a5694f` + `086936b3`), matching current vermagic `6.1.174-g638ecc425319`
2. Install `iw`, `aircrack-ng`, `mdk4` into NetHunter rootfs (`/data/local/nhsystem`)
3. Manual acquire: stop `vendor.wifi_hal_legacy` + `wpa_supplicant` → `insmod` patched .ko → `iw wlan0 interface add mon0 type monitor`
4. Test mgmt injection: `mdk4 mon0 d -c <channel>` + `aireplay-ng --deauth 10 -a <AP_MAC> mon0` → **confirm with external sniffer that frames are actually transmitted**
5. Test data raw injection: `aireplay-ng` data injection test → record PASS/FAIL
6. Test monitor RX: `tshark -i mon0 -c 20` → confirm radiotap capture
7. Manual release: `rmmod` → stock modprobe → verify Wi-Fi恢复正常
8. Record results in `docs/superpowers/specs/phase0-injection-spike-results.md`

### 5.3 Gate Criteria

- **Mgmt PASS** → proceed to Phase 1 (full Wi-Fi takeover build)
- **Mgmt FAIL** → STOP. Redesign required. Do not proceed.
- **Data raw PASS** → include in release as supported feature
- **Data raw FAIL** → document as known limitation, do not block release

### 5.4 Non-Read-Only Notice

This spike modifies live device state (insmod/rmmod/service control). It is planned here but executed only after explicit user authorization to leave plan mode.

---

## 6. CI/Release Contract

### 6.1 Build Pipeline Changes

Extend `.github/actions/build-kernel/action.yml`:
1. After existing `Image` build step, add conditional `modules` build when `nethunter_takeover=true` input is set
2. Build `bt_vhci.ko` (enable `CONFIG_BT_HCIVHCI=m` via `scripts/config`)
3. Build patched `qca_cld3_kiwi_v2.ko` from pinned source with injection patches applied
4. Sign both with kernel build key via `modules_install`
5. Compare vermagic against stock `modules.dep` entry; fail build if mismatch
6. Pack into target-specific ReSukiSU ZIP with `module.prop` containing exact fingerprints + SHA-256 checksums

### 6.2 Release Artifacts

Per workflow run, produce exactly 3 artifacts:
1. `AnyKernel3-OP-ACE5-RESUKISU-*.zip` — Image only (existing)
2. `nethunter-takeover-OP-ACE-5-*.zip` — takeover module ZIP for primary target
3. `nethunter-takeover-OP-ACE-5-6.1.118-*.zip` — takeover module ZIP for secondary target

Plus `provenance.json` listing:
- Wi-Fi patch commits (Loukious `25875eb`, brokestar233 `be87f12`)
- Bluebinder commit (`c3e1b155`)
- NCI tool source hash
- Per-.ko SHA-256 + vermagic + scmversion
- Phase 0 spike result reference

### 6.3 Drift Audit Integration

Existing `audit_wild_release.sh` gate remains unchanged. Takeover ZIPs are additive artifacts; they do not alter the WildKernel stability contract. New audit step verifies takeover ZIP checksums match provenance.json before release publication.

---

## 7. Testing Matrix

### 7.1 Static Tests (CI)

- `modinfo` vermagic/scmversion/depends match target
- `depmod` dependency resolution succeeds
- `verify_kernel_config.sh` extended to check `CONFIG_BT_HCIVHCI=m`, `CONFIG_RFKILL=m`, `CONFIG_FEATURE_FRAME_INJECTION_SUPPORT=y`
- SHA-256 of each .ko matches module.prop
- Fingerprint fields in module.prop match target config JSON

### 7.2 Runtime Tests (Exact Target Hardware)

Per radio, execute acquire → smoke → release → verify-stock cycle:

| Radio   | Smoke Test                                                         | Restore Verification                    |
| ------- | ------------------------------------------------------------------ | --------------------------------------- |
| Wi-Fi   | `mon0` created, mgmt injection confirmed by external sniffer       | `dumpsys wifi` normal, wlan0 functional |
| BT      | `hci0` appears, `hcitool lescan` returns                           | `dumpsys bluetooth_manager` adapter on  |
| NFC     | `nci_raw_tool init` prints NFCC info                               | `dumpsys nfc mState=on`                 |
| USB     | (no takeover)                                                      | (N/A)                                   |
| GNSS    | (no takeover)                                                      | (N/A)                                   |

### 7.3 Failure Handling Tests

- Kill bluebinder mid-TAKEOVER → watchdog detects, auto-release, stock restored
- Force-reboot during TAKEOVER → next boot stock, no tainted state
- Fingerprint mismatch on acquire → abort, log, no module loaded
- HAL quiesce timeout → auto-release, log failure reason

---

## 8. Risk Register

| Risk                                          | Likelihood | Impact | Mitigation                                                                                     |
| --------------------------------------------- | ---------- | ------ | ---------------------------------------------------------------------------------------------- |
| WCN7750 firmware blocks mgmt injection        | Medium     | Critical | Phase 0 spike gates entire project; if fail, redesign before any build                         |
| WCN7750 firmware blocks data raw injection    | High       | Medium | Accepted as best-effort per decision #4; document limitation                                   |
| Bluebinder incompatible with HIDL 1.1 on A16  | Low        | High   | Bluebinder c3e1b155 supports HIDL 1.0/1.1 + AIDL; test in Phase 1                             |
| NFC HAL won't quiesce for exclusive takeover  | Medium     | Medium | Fallback to sendVendorNciMessage API (§4.3.4); document as degraded mode                       |
| GKI KMI mismatch prevents module load         | Low        | Critical | CI vermagic comparison gate; build from exact pinned source revision                           |
| Reboot during TAKEOVER leaves tainted state   | Low        | High   | No auto-acquire at boot; boot-completed.sh verifies stock; manual cleanup script provided      |
| SE/eSE conflict during NFC exclusive access   | Medium     | Medium | Test qseecom/quiesce in Phase 1; fallback to API path if conflict confirmed                    |

---

## 9. Success Criteria

### 9.1 Mandatory (Release Blockers)

- [ ] Phase 0 spike: mgmt-frame injection PASS on exact target
- [ ] Wi-Fi monitor RX functional with radiotap headers
- [ ] Bluetooth `hci0` raw HCI access via bluebinder
- [ ] NFC raw NCI capture/send via exclusive takeover OR documented API fallback
- [ ] USB Arsenal (HID/mass-storage/NCM) functional via stock ConfigFS
- [ ] All acquire/release cycles complete without permanent state change
- [ ] Reboot from any state restores stock behavior
- [ ] Fail-closed gates reject mismatched fingerprints/modules

### 9.2 Best-Effort (Documented, Non-Blocking)

- [ ] Data-frame raw injection (PASS/FAIL recorded per-target)
- [ ] NFC exclusive takeover (fallback to API if blocked)
- [ ] Wide-channel (80/160 MHz) monitor capture

### 9.3 Out of Scope (Explicitly Excluded)

- Cellular/baseband raw control
- NFC card-emulation (MIFARE/HCE-eSE)
- Qualcomm vendor BT features (LE-audio/LHDC/bttpi)
- Camera/sensor raw access

---

## 10. Open Questions

None. All decisions locked per §1.2. Spec is ready for self-review and user approval.

---

## Appendix A: Upstream References

| Component         | Repository                                                                                   | Commit                                       | Purpose                              |
| ----------------- | -------------------------------------------------------------------------------------------- | -------------------------------------------- | ------------------------------------ |
| Wi-Fi injection   | Loukious/vendor_qcom_opensource_wlan                                                         | 25875eb1a65e94fae404c6e9188c7a1fe679e0f5     | FRAME_INJECTION_SUPPORT + WCN7750 filter |
| Wi-Fi TX path     | brokestar233/android_kernel_modules_and_devicetree_oneplus_sm8750                            | be87f121e5c53b1693662248da8a28a37f6b19db     | ndo_start_xmit + monitor TX bypass   |
| Bluetooth bridge  | mer-hybris/bluebinder                                                                        | c3e1b155e308f6df9c9a02dbd909a44e7319ab7d     | Binder↔VHCI proxy + rfkill recovery  |
| NFC reference     | cinit/NCIHost                                                                                | b293fb190799b143041d74f00ced87cc5b7e6d19     | Reference only; NOT reused           |

## Appendix B: Pinned Source Revisions

| Target              | Common Kernel  | Modules/Devicetree | Manifest                   |
| ------------------- | -------------- | ------------------ | -------------------------- |
| OP-ACE-5            | 086936b3       | 21a5694f           | oneplus_ace5_w.xml         |
| OP-ACE-5-6.1.118    | 7499247f       | d5323ede           | oneplus_ace5_6.1.118_w.xml |
