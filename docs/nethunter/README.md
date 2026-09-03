# NetHunter Reversible Hardware Takeover — OnePlus Ace 5

Reversible hardware takeover module for Kali NetHunter on the OnePlus Ace 5 (SM8635). Gives NetHunter direct control of Wi-Fi, Bluetooth, and NFC radios while preserving stock Android functionality when released.

## Installation

### Prerequisites

- Rooted OnePlus Ace 5 with Magisk/KernelSU
- Kernel built with `CONFIG_NETHUNTER_TAKEOVER=y`
- Matching kernel vermagic and SCM version (module enforces fingerprint check)

### Install Module

```bash
adb push nethunter_takeover_OP-ACE-5.zip /sdcard/
# In Magisk Manager: Modules → Install from storage → select zip
# Or via CLI:
magisk --install-module /sdcard/nethunter_takeover_OP-ACE-5.zip
reboot
```

### Verify Installation

```bash
ls /data/adb/modules/nethunter_takeover_OP-ACE-5/module.prop
getprop ro.nethunter.takeover.target
```

## Usage

All commands require root shell (`su -`).

### Wi-Fi

```bash
# Acquire monitor mode (creates mon0)
/data/adb/modules/nethunter_takeover_OP-ACE-5/wifi/nh-wifi-acquire.sh

# Verify
iw dev mon0 info

# Inject frames (monitor mode)
iw dev mon0 inject mgmt <frame.hex>    # stable
iw dev mon0 inject data <frame.hex>    # best-effort, may drop

# Release back to stock
/data/adb/modules/nethunter_takeover_OP-ACE-5/wifi/nh-wifi-release.sh
```

### Bluetooth

```bash
# Acquire HCI socket
/data/adb/modules/nethunter_takeover_OP-ACE-5/bt/nh-bt-acquire.sh

# Verify
hciconfig hci0

# Use standard bt tools
hcitool scan
btmon

# Release back to stock
/data/adb/modules/nethunter_takeover_OP-ACE-5/bt/nh-bt-release.sh
```

### NFC

```bash
# Acquire NCI raw access
/data/adb/modules/nethunter_takeover_OP-ACE-5/nfc/nh-nfc-acquire.sh

# Send raw NCI commands
/data/adb/modules/nethunter_takeover_OP-ACE-5/system/bin/nci_raw_tool init
/data/adb/modules/nethunter_takeover_OP-ACE-5/system/bin/nci_raw_tool send <hex_payload>

# Release back to stock
/data/adb/modules/nethunter_takeover_OP-ACE-5/nfc/nh-nfc-release.sh
```

### State Management

```bash
# Check current state per radio
/data/adb/modules/nethunter_takeover_OP-ACE-5/framework/nh-state.sh get wifi
/data/adb/modules/nethunter_takeover_OP-ACE-5/framework/nh-state.sh get bt
/data/adb/modules/nethunter_takeover_OP-ACE-5/framework/nh-state.sh get nfc
```

## Runtime Tests

Run after installation to verify all radios:

```bash
/data/adb/modules/nethunter_takeover_OP-ACE-5/tests/test_all_radios.sh
```

Tests acquire/smoke/release cycle for each radio and reports PASS/FAIL counts.

## Known Limitations

| Feature | Status | Notes |
|---------|--------|-------|
| Wi-Fi mgmt injection | Stable | Full monitor mode, frame injection works |
| Wi-Fi data raw injection | Best-effort | May drop under load; firmware-dependent |
| BT HCI raw access | Stable | Full HCI socket control |
| NFC NCI raw access | Stable | Reader/writer mode only |
| NFC card-emulation | Not supported | Requires secure element access |
| Cellular/baseband | Not supported | No modem takeover planned |
| USB gadget | Stock | Uses existing NetHunter USB gadget support |
| GNSS | Stock | No GPS spoofing in this module |

## Architecture

```
Acquire flow:  nh-state → fingerprint check → HAL quiesce → resource claim → state update
Release flow:  nh-state → resource release → HAL restart → state update → lock cleanup
```

State files stored at `/dev/shm/nh_state_{wifi,bt,nfc}`. Lock files at `/dev/shm/nh_lock_{wifi,bt,nfc}`.
