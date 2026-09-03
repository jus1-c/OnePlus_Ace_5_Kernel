# NetHunter Takeover — Troubleshooting

## Fingerprint Mismatch

**Symptom:** Acquire script exits with `FINGERPRINT_MISMATCH` or error code 2.

**Cause:** Running kernel vermagic or SCM version differs from values baked into the module at build time. Kernel was updated without rebuilding the module.

**Recovery:**
```bash
# Check current kernel fingerprint
uname -r
cat /proc/version

# Compare against module expected values
grep vermagic /data/adb/modules/nethunter_takeover_OP-ACE-5/module.prop
grep scmversion /data/adb/modules/nethunter_takeover_OP-ACE-5/module.prop

# Fix: rebuild module against current kernel, reinstall, reboot
```

## Stale Lock Files

**Symptom:** Acquire fails with `LOCK_HELD` even though no other process is using the radio. Previous session crashed without releasing.

**Recovery:**
```bash
# Remove stale locks
rm -f /dev/shm/nh_lock_wifi /dev/shm/nh_lock_bt /dev/shm/nh_lock_nfc

# Reset state to released
/data/adb/modules/nethunter_takeover_OP-ACE-5/framework/nh-state.sh set wifi released
/data/adb/modules/nethunter_takeover_OP-ACE-5/framework/nh-state.sh set bt released
/data/adb/modules/nethunter_takeover_OP-ACE-5/framework/nh-state.sh set nfc released

# Verify clean state
/data/adb/modules/nethunter_takeover_OP-ACE-5/framework/nh-state.sh get wifi
```

Locks are advisory (flock-based). A reboot also clears them since `/dev/shm` is tmpfs.

## HAL Quiesce Timeout

**Symptom:** Acquire hangs or fails during HAL stop phase. Log shows `HAL_QUIESCE_TIMEOUT`.

**Cause:** Vendor HAL process did not respond to stop signal within timeout window. Common after system update or when vendor HAL is in a bad state.

**Recovery:**
```bash
# Force-kill stuck HAL processes
pkill -9 vendor.qti.wifi || true
pkill -9 android.hardware.bluetooth || true
pkill -9 vendor.nxp.nfc || true

# Wait for init to restart them
sleep 2

# Retry acquire
/data/adb/modules/nethunter_takeover_OP-ACE-5/wifi/nh-wifi-acquire.sh
```

If persistent, reboot. The HAL may have corrupted internal state that only a cold start fixes.

## Module Load Failure

**Symptom:** Module does not appear in Magisk Manager after install. Or scripts missing from `/data/adb/modules/nethunter_takeover_OP-ACE-5/`.

**Diagnosis:**
```bash
# Check if module directory exists
ls -la /data/adb/modules/nethunter_takeover_OP-ACE-5/

# Check module.prop validity
cat /data/adb/modules/nethunter_takeover_OP-ACE-5/module.prop

# Check Magisk log
cat /cache/magisk.log | grep -i nethunter
```

**Common causes:**
- Zip structure wrong (files must be at root of zip, not in subdirectory)
- `module.prop` missing required fields (`id`, `name`, `version`)
- SELinux blocking file access

**Recovery:** Rebuild zip with correct structure, reinstall via Magisk Manager, reboot.

## Bluebinder Crash Recovery

**Symptom:** Bluetooth stops working entirely after BT acquire/release cycle. `hciconfig` shows no devices. System log shows bluebinder or bt_snoop crashes.

**Diagnosis:**
```bash
logcat -d | grep -E "bluebinder|bt_snoop|android.hardware.bluetooth"
```

**Recovery:**
```bash
# Restart Bluetooth service
setprop ctl.restart bluetooth
sleep 3

# If still broken, release and re-acquire cleanly
/data/adb/modules/nethunter_takeover_OP-ACE-5/bt/nh-bt-release.sh
sleep 1
/data/adb/modules/nethunter_takeover_OP-ACE-5/bt/nh-bt-acquire.sh
```

If BT remains dead after clean release, reboot. The vendor BT stack may need full reinitialization.

## NFC Not Responding After Release

**Symptom:** NFC tap-to-pay or reader mode stops working after NCI takeover release.

**Recovery:**
```bash
# Toggle NFC off/on in settings, or:
svc nfc disable
sleep 1
svc nfc enable
sleep 2

# Verify
dumpsys nfc | head -20
```

The stock NFC HAL sometimes fails to re-bind after raw NCI access. A toggle forces re-initialization.

## General Debugging

```bash
# Enable verbose logging in acquire/release scripts
export NH_DEBUG=1

# Check state files directly
cat /dev/shm/nh_state_wifi
cat /dev/shm/nh_state_bt
cat /dev/shm/nh_state_nfc

# Monitor kernel messages
dmesg | grep -i nethunter

# Run runtime test suite
/data/adb/modules/nethunter_takeover_OP-ACE-5/tests/test_all_radios.sh
```
