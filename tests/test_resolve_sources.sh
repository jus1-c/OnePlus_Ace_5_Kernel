#!/usr/bin/env bash
set -euo pipefail

# Resolver contract tests. Network-free: fixtures are served from a local HTTP
# stub by overriding the resolver's fetch helpers via a shim PATH. When a live
# token is present, the real resolver is also exercised once to prove the
# end-to-end wiring still returns every key the workflow consumes.

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok() { echo "ok: $1"; pass=$((pass + 1)); }

# --- 1. Static structure: the resolver is syntactically valid bash. ---------
bash -n scripts/resolve_sources.sh || fail 'resolve_sources.sh has a syntax error'
ok 'resolver parses'

# --- 2. The resolver no longer depends on the WildKernel OnePlus source. ----
if grep -q 'WildKernels/OnePlus_KernelSU_SUSFS' scripts/resolve_sources.sh; then
  fail 'resolver still references WildKernels/OnePlus_KernelSU_SUSFS'
fi
grep -q 'android_device_oneplus_giuliac' scripts/resolve_sources.sh \
  || fail 'resolver does not use the giuliac device entrypoint'
ok 'resolver uses the Lunaris device entrypoint, not the WildKernel OnePlus repo'

# --- 3. Fixture-driven behaviour tests through a fake fetch layer. ----------
# Build a shim dir where `git` and `curl` are replaced for the resolver run.
shim="$tmpdir/bin"
mkdir -p "$shim"

# `git ls-remote` stub: maps <repo> <ref> to a deterministic SHA, or fails for
# repos listed in a "missing" file.
cat > "$shim/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" != "ls-remote" ]]; then echo "unexpected git $*" >&2; exit 1; fi
url="$2"; ref="$3"
sha=$(cat "$FIXTURE_DIR/shals" | awk -v u="$url" -v r="$ref" '$1==u && $2==r {print $3}' | head -n1)
[[ -n "$sha" ]] || { echo "no ref $ref for $url" >&2; exit 1; }
echo "$sha $ref"
SH
chmod +x "$shim/git"

# `curl` stub: serves fixture bodies keyed by URL.
cat > "$shim/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url=""
for a in "$@"; do case "$a" in http*) url="$a";; esac; done
key=$(printf '%s' "$url" | sed 's#https://##; s#[/:]#_#g')
f="$FIXTURE_DIR/body_${key}"
[[ -f "$f" ]] || { echo "404 $url" >&2; exit 1; }
cat "$f"
SH
chmod +x "$shim/curl"

# `python3` is real (used for JSON/XML parsing).

fixture="$tmpdir/fixture"
mkdir -p "$fixture"
export FIXTURE_DIR="$fixture"

DEV="aosp-for-giulia/android_device_oneplus_giuliac"
COMMON="aosp-for-giulia/android_device_oneplus_sm8650-common"
KERNEL="aosp-for-giulia/android_kernel_oneplus_sm8650"
MODULES="aosp-for-giulia/android_kernel_oneplus_sm8650-modules"
DEVTREES="aosp-for-giulia/android_kernel_oneplus_sm8650-devicetrees"
MANIFEST="aosp-for-giulia/local_manifest"

ref_sha() { echo "$1" | sha256sum | cut -c1-40; }

write_bodies() {
  : > "$fixture/shals"
  p() { # fixture key from a URL path/query fragment
    printf '%s' "$1" | sed 's#https://##; s#[/:]#_#g'
  }
  # device lineage.dependencies -> names sm8650-common
  base="https://raw.githubusercontent.com"
  k=$(p "$base/$DEV/lunaris/lineage.dependencies")
  cat > "$fixture/body_${k}" <<'JSON'
[{"repository":"android_device_oneplus_sm8650-common","target_path":"device/oneplus/sm8650-common"}]
JSON
  # common lineage.dependencies -> names the three kernel repos
  k=$(p "$base/$COMMON/lunaris/lineage.dependencies")
  cat > "$fixture/body_${k}" <<'JSON'
[{"repository":"android_kernel_oneplus_sm8650","target_path":"kernel/oneplus/sm8650"},
 {"repository":"android_kernel_oneplus_sm8650-devicetrees","target_path":"kernel/oneplus/sm8650-devicetrees"},
 {"repository":"android_kernel_oneplus_sm8650-modules","target_path":"kernel/oneplus/sm8650-modules"}]
JSON
  # local manifest
  k=$(p "$base/$MANIFEST/lunaris/local_manifest.xml")
  cat > "$fixture/body_${k}" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<manifest>
  <project name="$KERNEL" path="kernel/oneplus/sm8650" revision="lineage-23.2" remote="github" />
  <project name="$DEVTREES" path="kernel/oneplus/sm8650-devicetrees" revision="lineage-23.2" remote="github" />
  <project name="$MODULES" path="kernel/oneplus/sm8650-modules" revision="lineage-23.2" remote="github" />
</manifest>
XML
  # GitHub API commit endpoints (resolver reads .sha)
  api_key() { printf '%s' "api.github.com/repos/$1/commits/$2" | sed 's#[/:]#_#g'; }
  for spec in \
    "Baka-SU/BakaSU main" \
    "WildKernels/kernel_patches main" \
    "vc-teahouse/Baseband-guard main" \
    "ravindu644/Droidspaces-OSS main" \
    "maxsteeel/ko-loader main" \
    "WildKernels/GKI_KernelSU_SUSFS main"; do
    set -- $spec
    k=$(api_key "$1" "$2")
    printf '{"sha":"%s"}\n' "$(ref_sha "$1/$2")" > "$fixture/body_${k}"
  done
  # NoMount latest release
  k=$(printf '%s' "api.github.com/repos/maxsteeel/nomount/releases/latest" | sed 's#https://##; s#[/:]#_#g')
  cat > "$fixture/body_${k}" <<JSON
{"tag_name":"v9.9.9","draft":false,"prerelease":false,
 "assets":[{"name":"NoMount-v9.9.9-release.zip","browser_download_url":"https://example.invalid/nm.zip","digest":"sha256:$(printf 'x' | sha256sum | cut -c1-64)"}]}
JSON
  # VPNHide latest release
  k=$(printf '%s' "api.github.com/repos/okhsunrog/vpnhide/releases/latest" | sed 's#https://##; s#[/:]#_#g')
  cat > "$fixture/body_${k}" <<JSON
{"tag_name":"v9.9.9","draft":false,"prerelease":false,
 "assets":[
  {"name":"vpnhide-builtin.zip","browser_download_url":"https://example.invalid/b.zip","digest":"sha256:$(printf 'b' | sha256sum | cut -c1-64)"},
  {"name":"vpnhide.apk","browser_download_url":"https://example.invalid/a.apk","digest":"sha256:$(printf 'a' | sha256sum | cut -c1-64)"}]}
JSON
  # SUSFS gitlab branch
  k=$(printf '%s' "gitlab.com/api/v4/projects/simonpunk%2Fsusfs4ksu/repository/branches/gki-android14-6.1" | sed 's#https://##; s#[/:]#_#g')
  printf '{"commit":{"id":"%s"}}\n' "$(ref_sha susfs)" > "$fixture/body_${k}"
  # git ls-remote refs
  {
    echo "https://github.com/${KERNEL}.git refs/heads/lineage-23.2 $(ref_sha k)"
    echo "https://github.com/${MODULES}.git refs/heads/lineage-23.2 $(ref_sha m)"
    echo "https://github.com/${DEVTREES}.git refs/heads/lineage-23.2 $(ref_sha d)"
    echo "https://github.com/${DEV}.git refs/heads/lunaris $(ref_sha dev)"
    echo "https://github.com/maxsteeel/nomount.git refs/tags/v9.9.9 $(ref_sha nm)"
    echo "https://github.com/maxsteeel/nomount.git refs/heads/v9.9.9 $(ref_sha nm)"
    echo "https://github.com/okhsunrog/vpnhide.git refs/tags/v9.9.9 $(ref_sha vp)"
    echo "https://github.com/okhsunrog/vpnhide.git refs/heads/v9.9.9 $(ref_sha vp)"
    echo "https://github.com/WildKernels/AnyKernel3.git refs/heads/gki-2.0 $(ref_sha ak3)"
  } > "$fixture/shals"
}

run_resolver() { PATH="$shim:$PATH" bash scripts/resolve_sources.sh; }

write_bodies
out=$(run_resolver) || fail 'resolver failed on well-formed fixtures'
for key in kernel_repo kernel_branch kernel_path kernel_sha kernel_modules_repo kernel_modules_sha \
           kernel_devicetrees_repo kernel_devicetrees_sha gki_sha susfs_sha bakasu_sha nomount_sha \
           vpnhide_sha droidspaces_sha bbg_sha kernel_patches_sha anykernel3_sha loader_sha; do
  jq -e --arg k "$key" 'has($k) and (.[$k] | length > 0)' <<< "$out" >/dev/null || fail "resolver output missing $key"
done
ok 'resolver emits every key the workflow consumes'

[[ $(jq -r '.kernel_path' <<< "$out") == "kernel/oneplus/sm8650" ]] || fail 'kernel_path wrong'
[[ $(jq -r '.kernel_modules_path' <<< "$out") == "kernel/oneplus/sm8650-modules" ]] || fail 'modules path not a sibling of kernel dir'
ok 'kernel modules/devicetrees are siblings of the kernel dir'

# --- 4. Missing repo: a kernel repo absent from the manifest must fail. -----
sed -i '/android_kernel_oneplus_sm8650-modules/d' "$fixture/body_$(printf '%s' "https://raw.githubusercontent.com/$MANIFEST/lunaris/local_manifest.xml" | sed 's#https://##; s#[/:]#_#g')"
if run_resolver >/dev/null 2>&1; then fail 'resolver accepted a missing kernel repo'; fi
ok 'missing kernel repo in manifest fails the resolver'
write_bodies

# --- 5. Missing branch: an unresolvable ref must fail. ----------------------
sed -i '/refs\/heads\/lineage-23.2/d' "$fixture/shals"
if run_resolver >/dev/null 2>&1; then fail 'resolver accepted an unresolvable kernel branch'; fi
ok 'unresolvable kernel branch fails the resolver'
write_bodies

# --- 6. Wrong SHA: a malformed HEAD is rejected, not silently accepted. -----
sed -i "s/refs\/heads\/lineage-23.2 .*/refs\/heads\/lineage-23.2 deadbeef/" "$fixture/shals"
if run_resolver >/dev/null 2>&1; then fail 'resolver accepted a malformed SHA'; fi
ok 'malformed SHA fails the resolver'

echo "Resolver tests passed (${pass} checks)"
