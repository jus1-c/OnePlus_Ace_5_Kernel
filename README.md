# OnePlus Ace 5 (giuliac) kernel — manual build

Custom kernel for the OnePlus Ace 5 (`giuliac`, model `PKG110`, device `OP5D2BL1`) on
Android 16, built from the **Lunaris** (aosp-for-giulia) source tree with the
**GKI** feature set.

The device keeps its **stock vendor modules**; the flashable ZIP replaces only the
kernel `Image`.

## Sources

- Kernel, kernel modules and kernel devicetrees: `aosp-for-giulia/android_kernel_oneplus_sm8650*`,
  branch selected by the Lunaris `local_manifest@lunaris` (currently `lineage-23.2`, kernel `6.1.176`).
- Device/config reference: `aosp-for-giulia/android_device_oneplus_giuliac@lunaris`
  (via `android_device_oneplus_sm8650-common@lunaris`).
- Feature integration method and versions: `WildKernels/GKI_KernelSU_SUSFS@main`
  plus its patch sources, resolved to a commit for each run.

The kernel version is **derived from the checked-out kernel `Makefile`**, never hardcoded.

## Included

- BakaSU (own integration, `main` resolved to a full commit per run).
- SUSFS matching `gki-android14-6.1`.
- NoMount compiled into the kernel; official stable NoMount release shipped as a module.
- VPNHide built-in backend (latest stable release, full filesystem hiding).
- From the GKI flow: BBG, BBRv1/BBRv3, CAKE, WireGuard, IP Set, IPv6 NAT, TTL/HL,
  ThinLTO, Unicode fix, Droidspaces, NTSync, TMPFS XATTR/ACL.
- PIE/FQ_PIE are kept from the local config.

`/proc/config.gz` reports a **stock GKI config** (spoof) so the custom options are
not exposed. The real build `.config` and `Module.symvers` are kept as artifacts.

## Run

Use **Actions → Build OnePlus Ace 5 A16 → Run workflow**.

- `publish_release=false` only uploads run artifacts.
- `publish_release=true` creates a prerelease after the kernel, the NoMount module
  package and the VPNHide integration all succeed.
- The workflow runs only on `workflow_dispatch` — never on push, PR, schedule, tag
  or upstream update.

Each run writes `resolved-sources.json` with the checked-out kernel/modules/devicetrees
SHAs, the GKI reference commit, the NoMount release tag and asset digest, the VPNHide
release tag and asset digests, and the single-target matrix.

## Verify locally

```sh
bash tests/test_resolve_sources.sh
bash tests/test_vpnhide_contract.sh
```

## Artifacts

One flashable AnyKernel3 ZIP (Image only), the raw `Image`, the final `.config`,
`Module.symvers`, a summary and SHA256 values. Releases also carry the official
`vpnhide-builtin.zip` and `vpnhide.apk`, verified against upstream SHA256 digests.

## Flashing

Flash manually, checking firmware/KMI compatibility first. Keep a known-good boot
image for rollback. Install the VPNHide companion ZIP and APK after boot, enable the
LSPosed `System Framework` scope, and do not install another VPNHide native backend.

CI validates compilation and static feature gates only; it cannot prove boot, radio,
camera, biometric or sleep health. On-device testing remains a separate gate.
