#!/usr/bin/env python3
"""Restore the SUSFS "root glue" that a root implementation may omit.

The SUSFS `50_add_susfs_in_gki-*.patch` only `extern`s
`struct selinux_state fake_state` (in security/selinux/hooks.c and
selinuxfs.c) and expects the root implementation to define and populate it.
susfs4ksu ships that glue for the kernelsu flavor as
`kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch`; a root that has not
synced it (e.g. BakaSU main HEAD, whose selinux_hide.c delegates to SUSFS when
the manual hook is present) links `undefined symbol: fake_state` and, once
defined, would NULL-deref state->policy.

This script applies the same glue inside the root's selinux_hide.c, guarded so
it is a no-op when the root tree already provides it:

  * define `struct selinux_state fake_state;` next to the SUSFS manual-hook
    `__maybe_static` marker, and
  * populate `fake_state.policy = backup_sepolicy` in the SUSFS enable path
    (security_context_to_sid_core() dereferences state->policy).

Usage: apply_susfs_root_glue.py <path/to/root/kernel/feature/selinux_hide.c>
Exit 0 on success or no-op; non-zero only when an anchor that must exist is
missing while the file clearly needs the glue.
"""

import sys

DEF_ANCHOR = (
    "#ifdef KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE\n"
    "#define __maybe_static\n"
)
DEF_BLOCK = (
    "#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)\n"
    "struct selinux_state fake_state;\n"
    "#endif\n"
)

POP_ANCHOR = (
    "#ifndef KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE\n"
    "    hook_selinux_status_open();"
)
POP_BLOCK = (
    "#ifdef KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE\n"
    "#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 6, 0)\n"
    "    fake_state.initialized = true;\n"
    "    fake_state.policy = backup_sepolicy;\n"
    "#endif\n"
    "#endif\n\n"
)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2

    path = sys.argv[1]
    try:
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
    except OSError as exc:
        print(f"cannot read {path}: {exc}", file=sys.stderr)
        return 1

    # Only a SUSFS-manual-hook build needs the glue at all.
    if "KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE" not in src:
        print("selinux_hide.c does not use the SUSFS manual hook; nothing to do")
        return 0

    out = src
    changed = False

    if "struct selinux_state fake_state;" not in out:
        if DEF_ANCHOR not in out:
            print("definition anchor not found; root tree layout changed", file=sys.stderr)
            return 1
        out = out.replace(DEF_ANCHOR, DEF_ANCHOR + DEF_BLOCK, 1)
        changed = True

    if "fake_state.policy" not in out:
        if POP_ANCHOR not in out:
            print("population anchor not found; root tree layout changed", file=sys.stderr)
            return 1
        out = out.replace(POP_ANCHOR, POP_BLOCK + POP_ANCHOR, 1)
        changed = True

    if changed:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(out)
        print(f"applied SUSFS root glue to {path}")
    else:
        print("SUSFS root glue already present; nothing to do")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
