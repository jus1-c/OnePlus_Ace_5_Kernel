# OnePlus Ace 5 Kernel

Manual build fork for OnePlus Ace 5 `PKG110` on Android 16. It builds every
Ace 5 A16 target published by the latest stable WildKernel release, currently
`android14-6.1.118` and `android14-6.1.141`.

## Included

- ReSukiSU from current `main`, resolved to a full commit before each run.
- SUSFS from the matching `android14-6.1` commit recorded in that WildKernel release.
- NoMount built into the kernel from the newest `dev` commit whose completed check runs all pass.
- WildKernel BBG, BBRv1/BBRv3, CAKE/PIE, WireGuard, IP Set, IPv6 NAT, TTL,
  ThinLTO, TMPFS XATTR/ACL, Unicode fix, Droidspaces, and NTSync features.

## Run

Use **Actions > Build OnePlus Ace 5 A16 > Run workflow**.

- `publish_release=false` only uploads run artifacts.
- `publish_release=true` creates a prerelease after both kernel targets and the
  NoMount module package complete successfully.
- No workflow runs on push, pull request, schedule, tag, or upstream update.

Each run writes `resolved-sources.json` containing every full source commit,
the selected WildKernel release, the NoMount green CI run, and target matrix.

## Artifacts

Each target has a flashable AnyKernel3 ZIP, raw `Image`, final `.config`,
summary, and SHA256 values. The NoMount ZIP is built from the exact same
NoMount commit as the built-in driver.

## Flashing

Flash manually only after checking firmware/KMI compatibility. Test the
`6.1.118` artifact first on a device currently running that kernel series.
Keep a known-good boot image for rollback. CI validates compilation and static
feature gates; it cannot prove boot, radio, camera, biometric, or sleep health.
