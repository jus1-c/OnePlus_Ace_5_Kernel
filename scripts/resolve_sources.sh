#!/usr/bin/env bash
set -euo pipefail

# Resolve every source this run will build from, once, and pin each to a SHA.
#
# Kernel sources come from the Lunaris (aosp-for-giulia) tree, discovered
# through the device entrypoint rather than by picking kernel HEAD directly:
#
#   android_device_oneplus_giuliac@lunaris
#     -> android_device_oneplus_sm8650-common@lunaris  (names the kernel repos)
#     -> aosp-for-giulia/local_manifest@lunaris        (branch + path per repo)
#
# The three kernel repos are synced as siblings (kernel, -modules,
# -devicetrees) because the kernel tree reaches into them through cross-repo
# symlinks. Feature integration sources (GKI repo + its patch sources) are
# resolved from their own upstreams and locked to a SHA for the run.

lunaris_org="${LUNARIS_ORG:-aosp-for-giulia}"
device_repo="${DEVICE_REPO:-${lunaris_org}/android_device_oneplus_giuliac}"
device_branch="${DEVICE_BRANCH:-lunaris}"
common_repo="${COMMON_REPO:-${lunaris_org}/android_device_oneplus_sm8650-common}"
manifest_repo="${MANIFEST_REPO:-${lunaris_org}/local_manifest}"
manifest_branch="${MANIFEST_BRANCH:-lunaris}"

gki_repo="${GKI_REPO:-WildKernels/GKI_KernelSU_SUSFS}"
gki_branch="${GKI_BRANCH:-main}"
bakasu_repo="${BAKASU_REPO:-Baka-SU/BakaSU}"
nomount_repo="${NOMOUNT_REPO:-maxsteeel/nomount}"
kernel_patches_repo="${KERNEL_PATCHES_REPO:-WildKernels/kernel_patches}"
vpnhide_repo="${VPNHIDE_REPO:-okhsunrog/vpnhide}"
bbg_repo="${BBG_REPO:-vc-teahouse/Baseband-guard}"
droidspaces_repo="${DROIDSPACES_REPO:-ravindu644/Droidspaces-OSS}"
loader_repo="${LOADER_REPO:-maxsteeel/ko-loader}"
anykernel3_repo="${ANYKERNEL3_REPO:-WildKernels/AnyKernel3}"
anykernel3_branch="${ANYKERNEL3_BRANCH:-gki-2.0}"
toolchain_repo="${TOOLCHAIN_REPO:-realahnet/clang-r563880c}"
toolchain_branch="${TOOLCHAIN_BRANCH:-master}"

api() {
  local headers=(
    -H 'Accept: application/vnd.github+json'
    -H 'X-GitHub-Api-Version: 2022-11-28'
  )
  if [[ -n "${GH_TOKEN:-}" ]]; then
    headers+=(-H "Authorization: Bearer ${GH_TOKEN}")
  fi
  curl --fail --silent --show-error --location "${headers[@]}" "$1"
}

raw() {
  curl --fail --silent --show-error --location "$1"
}

resolve_ref() {
  local repository="$1" ref="$2"
  git ls-remote "https://github.com/${repository}.git" "refs/heads/${ref}" "refs/tags/${ref}" "refs/tags/${ref}^{}" |
    awk '{ print $1 }' | tail -n1
}

is_sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

# ---------------------------------------------------------------------------
# 1. Discover the kernel repo set through the device -> common chain.
# ---------------------------------------------------------------------------
common_name="$(
  raw "https://raw.githubusercontent.com/${device_repo}/${device_branch}/lineage.dependencies" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(next((p["repository"] for p in d if "sm8650-common" in p["repository"]), ""))'
)"
[[ -n "$common_name" ]] || { echo "Cannot find sm8650-common dependency in ${device_repo}@${device_branch}" >&2; exit 1; }
common_repo="${lunaris_org}/${common_name}"

mapfile -t kernel_names < <(
  raw "https://raw.githubusercontent.com/${common_repo}/${device_branch}/lineage.dependencies" |
    python3 -c 'import json,sys; d=json.load(sys.stdin); [print(p["repository"]) for p in d if p["repository"].startswith("android_kernel_oneplus_sm8650")]'
)
[[ "${#kernel_names[@]}" -ge 1 ]] || { echo "No sm8650 kernel repos named in ${common_repo}@${device_branch}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 2. Branch + path per kernel repo come from the Lunaris local manifest.
#    Never auto-pick a kernel HEAD: only resolve the branch it declares.
# ---------------------------------------------------------------------------
manifest_xml="$(raw "https://raw.githubusercontent.com/${manifest_repo}/${manifest_branch}/local_manifest.xml")"

manifest_entry() {
  local repo_name="$1"
  MANIFEST_XML="$manifest_xml" python3 -c '
import os, sys, xml.etree.ElementTree as ET
root = ET.fromstring(os.environ["MANIFEST_XML"])
want = sys.argv[1]
for p in root.findall("project"):
    if p.get("name") == want:
        print("{}\t{}".format(p.get("revision", ""), p.get("path", "")))
        break
' "$repo_name"
}

kernel_repo=""; kernel_branch=""; kernel_path=""
modules_repo=""; modules_branch=""; modules_path=""
devicetrees_repo=""; devicetrees_branch=""; devicetrees_path=""

for name in "${kernel_names[@]}"; do
  entry="$(manifest_entry "${lunaris_org}/${name}")"
  [[ -n "$entry" ]] || { echo "Kernel repo ${name} not present in ${manifest_repo}@${manifest_branch}" >&2; exit 1; }
  rev="${entry%%$'\t'*}"; path="${entry#*$'\t'}"
  [[ -n "$rev" && -n "$path" ]] || { echo "Missing revision/path for ${name}" >&2; exit 1; }
  case "$name" in
    *-modules)      modules_repo="${lunaris_org}/${name}"; modules_branch="$rev"; modules_path="$path" ;;
    *-devicetrees)  devicetrees_repo="${lunaris_org}/${name}"; devicetrees_branch="$rev"; devicetrees_path="$path" ;;
    *)              kernel_repo="${lunaris_org}/${name}"; kernel_branch="$rev"; kernel_path="$path" ;;
  esac
done

[[ -n "$kernel_repo" ]] || { echo 'Kernel repo not resolved from manifest' >&2; exit 1; }
[[ -n "$modules_repo" ]] || { echo 'Kernel modules repo not resolved from manifest' >&2; exit 1; }
[[ -n "$devicetrees_repo" ]] || { echo 'Kernel devicetrees repo not resolved from manifest' >&2; exit 1; }

# Siblings must sit next to the kernel dir: the kernel tree symlinks into
# ../sm8650-modules and ../sm8650-devicetrees from within its own tree.
kernel_parent="$(dirname "$kernel_path")"
modules_path="${kernel_parent}/$(basename "$modules_path")"
devicetrees_path="${kernel_parent}/$(basename "$devicetrees_path")"

kernel_sha=$(resolve_ref "$kernel_repo" "$kernel_branch")
modules_sha=$(resolve_ref "$modules_repo" "$modules_branch")
devicetrees_sha=$(resolve_ref "$devicetrees_repo" "$devicetrees_branch")
for sha in "$kernel_sha" "$modules_sha" "$devicetrees_sha"; do
  is_sha "$sha" || { echo "Cannot resolve a kernel source branch to a SHA ($sha)" >&2; exit 1; }
done
device_sha=$(resolve_ref "$device_repo" "$device_branch")
is_sha "$device_sha" || { echo "Cannot resolve ${device_repo}@${device_branch}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 3. Feature integration sources, locked to a SHA for this run.
# ---------------------------------------------------------------------------
gki_sha=$(api "https://api.github.com/repos/${gki_repo}/commits/${gki_branch}" | jq -r '.sha // empty')
is_sha "$gki_sha" || { echo "Cannot resolve ${gki_repo}@${gki_branch}" >&2; exit 1; }

susfs_sha=$(curl --fail --silent --show-error \
  "https://gitlab.com/api/v4/projects/simonpunk%2Fsusfs4ksu/repository/branches/gki-android14-6.1" |
  jq -r '.commit.id // empty')
is_sha "$susfs_sha" || { echo 'Cannot resolve SUSFS gki-android14-6.1' >&2; exit 1; }

bakasu_sha=$(api "https://api.github.com/repos/${bakasu_repo}/commits/main" | jq -r '.sha // empty')
is_sha "$bakasu_sha" || { echo 'Cannot resolve BakaSU main' >&2; exit 1; }

kernel_patches_sha=$(api "https://api.github.com/repos/${kernel_patches_repo}/commits/main" | jq -r '.sha // empty')
is_sha "$kernel_patches_sha" || { echo 'Cannot resolve kernel_patches main' >&2; exit 1; }

bbg_sha=$(api "https://api.github.com/repos/${bbg_repo}/commits/main" | jq -r '.sha // empty')
is_sha "$bbg_sha" || { echo 'Cannot resolve Baseband Guard main' >&2; exit 1; }

droidspaces_sha=$(api "https://api.github.com/repos/${droidspaces_repo}/commits/main" | jq -r '.sha // empty')
is_sha "$droidspaces_sha" || { echo 'Cannot resolve Droidspaces main' >&2; exit 1; }

loader_sha=$(api "https://api.github.com/repos/${loader_repo}/commits/main" | jq -r '.sha // empty')
is_sha "$loader_sha" || { echo 'Cannot resolve ko-loader main' >&2; exit 1; }

anykernel3_sha=$(resolve_ref "$anykernel3_repo" "$anykernel3_branch")
is_sha "$anykernel3_sha" || { echo "Cannot resolve ${anykernel3_repo}@${anykernel3_branch}" >&2; exit 1; }

nomount_release=$(api "https://api.github.com/repos/${nomount_repo}/releases/latest")
nomount_tag=$(jq -r '.tag_name // empty' <<< "$nomount_release")
[[ -n "$nomount_tag" ]] || { echo "No latest NoMount release in $nomount_repo" >&2; exit 1; }
if ! jq -e '.draft == false and .prerelease == false' <<< "$nomount_release" >/dev/null; then
  echo "Latest NoMount release is draft or prerelease: $nomount_tag" >&2
  exit 1
fi
nomount_sha=$(resolve_ref "$nomount_repo" "$nomount_tag")
is_sha "$nomount_sha" || { echo "Cannot resolve NoMount tag $nomount_tag" >&2; exit 1; }
nomount_asset=$(jq -er '
  [.assets[] | select(.name | test("^NoMount-.*\\.zip$"))] as $matches |
  if ($matches | length) != 1 then error("expected exactly one NoMount-*.zip asset, found \($matches | length)")
  elif (($matches[0].digest // "") | test("^sha256:[0-9a-f]{64}$") | not) then error("NoMount asset lacks SHA-256 digest")
  else {name:$matches[0].name,url:$matches[0].browser_download_url,sha256:($matches[0].digest | sub("^sha256:"; ""))}
  end
' <<< "$nomount_release")

vpnhide_release=$(api "https://api.github.com/repos/${vpnhide_repo}/releases/latest")
vpnhide_tag=$(jq -r '.tag_name // empty' <<< "$vpnhide_release")
[[ -n "$vpnhide_tag" ]] || { echo "No latest VPNHide release in $vpnhide_repo" >&2; exit 1; }
if ! jq -e '.draft == false and .prerelease == false' <<< "$vpnhide_release" >/dev/null; then
  echo "Latest VPNHide release is draft or prerelease: $vpnhide_tag" >&2
  exit 1
fi
vpnhide_sha=$(resolve_ref "$vpnhide_repo" "$vpnhide_tag")
is_sha "$vpnhide_sha" || { echo "Cannot resolve VPNHide tag $vpnhide_tag" >&2; exit 1; }
vpnhide_asset() {
  local name="$1"
  jq -er --arg name "$name" '
    [.assets[] | select(.name == $name)] as $matches |
    if ($matches | length) != 1 then error("expected one asset: " + $name)
    elif (($matches[0].digest // "") | test("^sha256:[0-9a-f]{64}$") | not) then error("asset lacks SHA-256 digest: " + $name)
    else {url:$matches[0].browser_download_url,sha256:($matches[0].digest | sub("^sha256:"; ""))}
    end
  ' <<< "$vpnhide_release"
}
vpnhide_builtin=$(vpnhide_asset 'vpnhide-builtin.zip')
vpnhide_apk=$(vpnhide_asset 'vpnhide.apk')

# ---------------------------------------------------------------------------
# 4. Emit the run snapshot.
# ---------------------------------------------------------------------------
jq -n \
  --arg device_repo "$device_repo" \
  --arg device_branch "$device_branch" \
  --arg device_sha "$device_sha" \
  --arg common_repo "$common_repo" \
  --arg manifest_repo "$manifest_repo" \
  --arg manifest_branch "$manifest_branch" \
  --arg kernel_repo "$kernel_repo" \
  --arg kernel_branch "$kernel_branch" \
  --arg kernel_path "$kernel_path" \
  --arg kernel_sha "$kernel_sha" \
  --arg kernel_modules_repo "$modules_repo" \
  --arg kernel_modules_branch "$modules_branch" \
  --arg kernel_modules_path "$modules_path" \
  --arg kernel_modules_sha "$modules_sha" \
  --arg kernel_devicetrees_repo "$devicetrees_repo" \
  --arg kernel_devicetrees_branch "$devicetrees_branch" \
  --arg kernel_devicetrees_path "$devicetrees_path" \
  --arg kernel_devicetrees_sha "$devicetrees_sha" \
  --arg gki_repo "$gki_repo" \
  --arg gki_branch "$gki_branch" \
  --arg gki_sha "$gki_sha" \
  --arg susfs_sha "$susfs_sha" \
  --arg bakasu_repo "$bakasu_repo" \
  --arg bakasu_sha "$bakasu_sha" \
  --arg nomount_repo "$nomount_repo" \
  --arg nomount_tag "$nomount_tag" \
  --arg nomount_sha "$nomount_sha" \
  --arg nomount_asset_name "$(jq -r '.name' <<< "$nomount_asset")" \
  --arg nomount_asset_url "$(jq -r '.url' <<< "$nomount_asset")" \
  --arg nomount_asset_sha256 "$(jq -r '.sha256' <<< "$nomount_asset")" \
  --arg kernel_patches_repo "$kernel_patches_repo" \
  --arg kernel_patches_sha "$kernel_patches_sha" \
  --arg vpnhide_repo "$vpnhide_repo" \
  --arg vpnhide_tag "$vpnhide_tag" \
  --arg vpnhide_sha "$vpnhide_sha" \
  --arg vpnhide_builtin_url "$(jq -r '.url' <<< "$vpnhide_builtin")" \
  --arg vpnhide_builtin_sha256 "$(jq -r '.sha256' <<< "$vpnhide_builtin")" \
  --arg vpnhide_apk_url "$(jq -r '.url' <<< "$vpnhide_apk")" \
  --arg vpnhide_apk_sha256 "$(jq -r '.sha256' <<< "$vpnhide_apk")" \
  --arg bbg_repo "$bbg_repo" \
  --arg bbg_sha "$bbg_sha" \
  --arg droidspaces_repo "$droidspaces_repo" \
  --arg droidspaces_sha "$droidspaces_sha" \
  --arg loader_repo "$loader_repo" \
  --arg loader_sha "$loader_sha" \
  --arg anykernel3_repo "$anykernel3_repo" \
  --arg anykernel3_branch "$anykernel3_branch" \
  --arg anykernel3_sha "$anykernel3_sha" \
  '{device_repo:$device_repo,device_branch:$device_branch,device_sha:$device_sha,
    common_repo:$common_repo,
    manifest_repo:$manifest_repo,manifest_branch:$manifest_branch,
    kernel_repo:$kernel_repo,kernel_branch:$kernel_branch,kernel_path:$kernel_path,kernel_sha:$kernel_sha,
    kernel_modules_repo:$kernel_modules_repo,kernel_modules_branch:$kernel_modules_branch,kernel_modules_path:$kernel_modules_path,kernel_modules_sha:$kernel_modules_sha,
    kernel_devicetrees_repo:$kernel_devicetrees_repo,kernel_devicetrees_branch:$kernel_devicetrees_branch,kernel_devicetrees_path:$kernel_devicetrees_path,kernel_devicetrees_sha:$kernel_devicetrees_sha,
    gki_repo:$gki_repo,gki_branch:$gki_branch,gki_sha:$gki_sha,
    susfs_sha:$susfs_sha,
    bakasu_repo:$bakasu_repo,bakasu_sha:$bakasu_sha,
    nomount_repo:$nomount_repo,nomount_tag:$nomount_tag,nomount_sha:$nomount_sha,
    nomount_asset_name:$nomount_asset_name,nomount_asset_url:$nomount_asset_url,nomount_asset_sha256:$nomount_asset_sha256,
    kernel_patches_repo:$kernel_patches_repo,kernel_patches_sha:$kernel_patches_sha,
    vpnhide_repo:$vpnhide_repo,vpnhide_tag:$vpnhide_tag,vpnhide_sha:$vpnhide_sha,
    vpnhide_builtin_url:$vpnhide_builtin_url,vpnhide_builtin_sha256:$vpnhide_builtin_sha256,
    vpnhide_apk_url:$vpnhide_apk_url,vpnhide_apk_sha256:$vpnhide_apk_sha256,
    bbg_repo:$bbg_repo,bbg_sha:$bbg_sha,
    droidspaces_repo:$droidspaces_repo,droidspaces_sha:$droidspaces_sha,
    loader_repo:$loader_repo,loader_sha:$loader_sha,
    anykernel3_repo:$anykernel3_repo,anykernel3_branch:$anykernel3_branch,anykernel3_sha:$anykernel3_sha}'
