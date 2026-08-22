#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [--repo owner/name] [--tag tag] [--baseline path] [--output path]" >&2
  exit 2
}

repo="${WILD_REPO:-WildKernels/OnePlus_KernelSU_SUSFS}"
tag=""
baseline="config/wild-reviewed.json"
output="wild-audit.json"

while (($#)); do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    --tag) tag="$2"; shift 2 ;;
    --baseline) baseline="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    *) usage ;;
  esac
done

command -v curl >/dev/null || { echo 'curl is required' >&2; exit 1; }
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }
command -v git >/dev/null || { echo 'git is required' >&2; exit 1; }
[[ -f "$baseline" ]] || { echo "Baseline not found: $baseline" >&2; exit 1; }

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

fail() {
  echo "$1" >&2
  exit 1
}

baseline_tag=$(jq -r '.reviewed_tag' "$baseline")
baseline_commit=$(jq -r '.wild_commit' "$baseline")
baseline_tree_sha=$(jq -r '.wild_tree_sha' "$baseline")
[[ "$baseline_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$ ]] || fail 'Invalid baseline WildKernel tag'
[[ "$baseline_commit" =~ ^[0-9a-f]{40}$ ]] || fail 'Invalid baseline WildKernel commit'
[[ "$baseline_tree_sha" =~ ^[0-9a-f]{40}$ ]] || fail 'Invalid baseline WildKernel tree SHA'

if [[ -z "$tag" ]]; then
  tag=$(api "https://api.github.com/repos/${repo}/releases?per_page=100" |
    jq -r '[.[] | select(.draft == false and .prerelease == false)][0].tag_name // empty')
fi
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-r[0-9]+$ ]] || fail "Invalid stable WildKernel tag: $tag"

candidate_commit=$(git ls-remote "https://github.com/${repo}.git" \
  "refs/tags/${tag}" "refs/tags/${tag}^{}" | awk '{ print $1 }' | tail -n1)
[[ "$candidate_commit" =~ ^[0-9a-f]{40}$ ]] || fail "Cannot resolve tag: $tag"

tree_sha=$(api "https://api.github.com/repos/${repo}/commits/${candidate_commit}" |
  jq -r '.commit.tree.sha // empty')
[[ "$tree_sha" =~ ^[0-9a-f]{40}$ ]] || fail "Cannot resolve tree for tag: $tag"
[[ "$candidate_commit" != "$baseline_commit" || "$tree_sha" == "$baseline_tree_sha" ]] || fail 'Reviewed WildKernel commit tree differs from baseline lock'

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fetch_blob_sha() {
  local path="$1"
  api "https://api.github.com/repos/${repo}/contents/${path}?ref=${candidate_commit}" |
    jq -r '.sha // empty'
}

fetch_blob_content() {
  local path="$1" destination="$2"
  api "https://api.github.com/repos/${repo}/contents/${path}?ref=${candidate_commit}" |
    jq -r '.content // empty' | base64 -d > "$destination"
}

build_sha=$(fetch_blob_sha .github/actions/build-kernel/action.yml)
sync_sha=$(fetch_blob_sha .github/actions/kernel-source-sync/action.yml)
release_sha=$(fetch_blob_sha .github/workflows/build-kernel-release.yml)
for sha in "$build_sha" "$sync_sha" "$release_sha"; do
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail "Required upstream control-plane blob missing at $tag"
done

baseline_build_sha=$(jq -r '.actions.build_kernel_blob_sha' "$baseline")
baseline_sync_sha=$(jq -r '.actions.kernel_source_sync_blob_sha' "$baseline")
baseline_release_sha=$(jq -r '.actions.build_kernel_release_workflow_blob_sha' "$baseline")

tree=$(api "https://api.github.com/repos/${repo}/git/trees/${tree_sha}?recursive=1")
[[ "$(jq -r '.truncated // false' <<< "$tree")" == false ]] || fail "WildKernel tree is truncated at $tag"
config_pattern=$(jq -r '.ace5_config_schema.root_pattern' "$baseline")
manifest_pattern=$(jq -r '.ace5_config_schema.manifest_pattern' "$baseline")
configs=$(jq -c --arg pattern "$config_pattern" '[.tree[] | select(.type == "blob" and (.path | test($pattern))) | .path]' <<< "$tree")
manifests=$(jq -c --arg pattern "$manifest_pattern" '[.tree[] | select(.type == "blob" and (.path | test($pattern))) | .path]' <<< "$tree")
[[ "$configs" != '[]' ]] || fail "No Ace 5 A16 configs found at $tag"
[[ "$manifests" != '[]' ]] || fail "No Ace 5 A16 manifests found at $tag"

required_keys=$(jq -c '.ace5_config_schema.required_keys' "$baseline")
key_types=$(jq -c '.ace5_config_schema.key_types' "$baseline")
reviewed_paths=$(jq -c '.ace5_config_schema.reviewed_paths' "$baseline")
schema_errors='[]'
contract_errors='[]'
config_rows='[]'
while IFS= read -r config_path; do
  config_file="$tmpdir/$(basename "$config_path")"
  fetch_blob_content "$config_path" "$config_file"
  if ! jq empty "$config_file" >/dev/null 2>&1; then
    schema_errors=$(jq -c --arg path "$config_path" '. + [{path:$path,error:"invalid JSON"}]' <<< "$schema_errors")
    continue
  fi
  keys=$(jq -c 'keys | sort' "$config_file")
  missing=$(jq -c --argjson required "$required_keys" --argjson actual "$keys" '$required - $actual' <<< '{}')
  extra=$(jq -c --argjson required "$required_keys" --argjson actual "$keys" '$actual - $required' <<< '{}')
  if [[ "$missing" != '[]' || "$extra" != '[]' ]]; then
    schema_errors=$(jq -c --arg path "$config_path" --argjson missing "$missing" --argjson extra "$extra" \
      '. + [{path:$path,missing:$missing,extra:$extra}]' <<< "$schema_errors")
  fi
  type_errors=$(jq -c --argjson expected "$key_types" '
    [to_entries[] | (.value | type) as $actual |
      select($expected[.key] != $actual) |
      {key:.key,expected:$expected[.key],actual:$actual}]
  ' "$config_file")
  if [[ "$type_errors" != '[]' ]]; then
    schema_errors=$(jq -c --arg path "$config_path" --argjson type_errors "$type_errors" \
      '. + [{path:$path,type_errors:$type_errors}]' <<< "$schema_errors")
  fi
  contract=$(jq -c '
    (.model | test("^OP-ACE-5(-[0-9]+\\.[0-9]+\\.[0-9]+)?$")) and
    (.manifest | test("^oneplus_ace5(_[0-9]+\\.[0-9]+\\.[0-9]+)?_w\\.xml$")) and
    (.soc == "pineapple") and
    (.branch == "wild/sm8650") and
    (.android_version == "android14") and
    (.kernel_version == "6.1") and
    (.os_version == "A16") and
    (.lto == "thin") and
    (.rust_build == false) and
    (.hmbird == false) and
    (.susfs == true) and (.opt == true) and (.ds == true) and (.bbg == true) and
    (.bbr == true) and (.bbr3 == true) and (.ttl == true) and (.ip_set == true) and
    (.unicode == true) and (.ntsync == true)
  ' "$config_file")
  if [[ "$contract" != true ]]; then
    contract_errors=$(jq -c --arg path "$config_path" '. + [{path:$path,error:"Ace 5 feature contract changed"}]' <<< "$contract_errors")
  fi
  config_rows=$(jq -c --arg path "$config_path" --argjson keys "$keys" '. + [{path:$path,keys:$keys}]' <<< "$config_rows")
done < <(jq -r '.[]' <<< "$configs")

manifest_errors='[]'
while IFS= read -r manifest_path; do
  manifest_file="$tmpdir/$(basename "$manifest_path")"
  fetch_blob_content "$manifest_path" "$manifest_file"
  if ! xmllint --noout "$manifest_file" >/dev/null 2>&1; then
    manifest_errors=$(jq -c --arg path "$manifest_path" '. + [{path:$path,error:"invalid XML"}]' <<< "$manifest_errors")
  fi
done < <(jq -r '.[]' <<< "$manifests")

candidate_paths=$(jq -cn --argjson configs "$configs" --argjson manifests "$manifests" '$configs + $manifests')
path_errors=$(jq -c --argjson reviewed "$reviewed_paths" --argjson candidate "$candidate_paths" \
  '$candidate - $reviewed | {added:.,removed:($reviewed - $candidate)}' <<< '{}')

release=$(api "https://api.github.com/repos/${repo}/releases/tags/${tag}")
published_at=$(jq -r '.published_at // empty' <<< "$release")
[[ -n "$published_at" ]] || fail "Missing publish time for $tag"
release_body=$(jq -r '.body // ""' <<< "$release")
candidate_susfs_sha=$(printf '%s\n' "$release_body" | awk '/android14-6\.1/ { if (match($0, /[0-9a-f]{40}/)) { print substr($0, RSTART, RLENGTH); exit } }')
if [[ ! "$candidate_susfs_sha" =~ ^[0-9a-f]{40}$ ]]; then
  candidate_susfs_sha=$(api "https://api.github.com/repos/${repo}/contents/README.md?ref=${candidate_commit}" |
    jq -r '.content // empty' | base64 -d 2>/dev/null |
    awk '/android14-6\.1/ { if (match($0, /[0-9a-f]{40}/)) { print substr($0, RSTART, RLENGTH); exit } }')
fi
[[ "$candidate_susfs_sha" =~ ^[0-9a-f]{40}$ ]] || fail "No SUSFS SHA for android14-6.1 in $tag"
kernel_patches_repo="WildKernels/kernel_patches"
candidate_kernel_patches_sha=$(api "https://api.github.com/repos/${kernel_patches_repo}/commits?sha=main&until=${published_at}&per_page=1" |
  jq -r '.[0].sha // empty')
[[ "$candidate_kernel_patches_sha" =~ ^[0-9a-f]{40}$ ]] || fail "Cannot resolve kernel_patches for $tag"
baseline_susfs_sha=$(jq -r '.susfs_release_commit' "$baseline")
baseline_kernel_patches_sha=$(jq -r '.kernel_patches_commit' "$baseline")

compare=$(api "https://api.github.com/repos/${repo}/compare/${baseline_commit}...${candidate_commit}")
compare_status=$(jq -r '.status // empty' <<< "$compare")
[[ "$compare_status" =~ ^(ahead|behind|identical|diverged)$ ]] || fail "Cannot compare candidate with reviewed WildKernel commit"
compare_files=$(jq -c '[.files[]? | {filename,status,additions,deletions}]' <<< "$compare")
compare_commits=$(jq -c '[.commits[]? | {sha:.sha,message:.commit.message}]' <<< "$compare")
[[ "$(jq 'length' <<< "$compare_files")" -lt 300 ]] || fail "WildKernel compare file list may be truncated"

control_plane_changes='[]'
[[ "$build_sha" == "$baseline_build_sha" ]] || control_plane_changes=$(jq -c --arg path '.github/actions/build-kernel/action.yml' --arg old "$baseline_build_sha" --arg new "$build_sha" '. + [{path:$path,baseline:$old,candidate:$new}]' <<< "$control_plane_changes")
[[ "$sync_sha" == "$baseline_sync_sha" ]] || control_plane_changes=$(jq -c --arg path '.github/actions/kernel-source-sync/action.yml' --arg old "$baseline_sync_sha" --arg new "$sync_sha" '. + [{path:$path,baseline:$old,candidate:$new}]' <<< "$control_plane_changes")
[[ "$release_sha" == "$baseline_release_sha" ]] || control_plane_changes=$(jq -c --arg path '.github/workflows/build-kernel-release.yml' --arg old "$baseline_release_sha" --arg new "$release_sha" '. + [{path:$path,baseline:$old,candidate:$new}]' <<< "$control_plane_changes")
[[ "$candidate_susfs_sha" == "$baseline_susfs_sha" ]] || control_plane_changes=$(jq -c --arg path 'SUSFS release commit' --arg old "$baseline_susfs_sha" --arg new "$candidate_susfs_sha" '. + [{path:$path,baseline:$old,candidate:$new}]' <<< "$control_plane_changes")
[[ "$candidate_kernel_patches_sha" == "$baseline_kernel_patches_sha" ]] || control_plane_changes=$(jq -c --arg path 'WildKernels/kernel_patches' --arg old "$baseline_kernel_patches_sha" --arg new "$candidate_kernel_patches_sha" '. + [{path:$path,baseline:$old,candidate:$new}]' <<< "$control_plane_changes")

status='pass'
reasons='[]'
if [[ "$tag" != "$baseline_tag" ]]; then
  reasons=$(jq -c --arg reason "Candidate stable release differs from reviewed baseline" '. + [$reason]' <<< "$reasons")
fi
if [[ "$control_plane_changes" != '[]' ]]; then
  status='fail'
  reasons=$(jq -c --arg reason "WildKernel control-plane files changed since reviewed baseline" '. + [$reason]' <<< "$reasons")
fi
if [[ "$tag" == "$baseline_tag" && "$candidate_commit" != "$baseline_commit" ]]; then
  status='fail'
  reasons=$(jq -c --arg reason "Reviewed tag resolves to a different commit" '. + [$reason]' <<< "$reasons")
fi
if [[ "$compare_status" != ahead && "$compare_status" != identical ]]; then
  status='fail'
  reasons=$(jq -c --arg reason "Candidate is not descended from reviewed WildKernel commit" '. + [$reason]' <<< "$reasons")
fi
if [[ "$(jq -c '.added + .removed' <<< "$path_errors")" != '[]' ]]; then
  status='fail'
  reasons=$(jq -c --arg reason "Ace 5 config or manifest path set changed" '. + [$reason]' <<< "$reasons")
fi
if [[ "$schema_errors" != '[]' ]]; then
  status='fail'
  reasons=$(jq -c --arg reason "Ace 5 config schema changed or became invalid" '. + [$reason]' <<< "$reasons")
fi
if [[ "$contract_errors" != '[]' ]]; then
  status='fail'
  reasons=$(jq -c --arg reason "Ace 5 feature contract changed" '. + [$reason]' <<< "$reasons")
fi
if [[ "$manifest_errors" != '[]' ]]; then
  status='fail'
  reasons=$(jq -c --arg reason "Ace 5 manifest XML is invalid" '. + [$reason]' <<< "$reasons")
fi

jq -n \
  --arg repo "$repo" \
  --arg tag "$tag" \
  --arg candidate_commit "$candidate_commit" \
  --arg tree_sha "$tree_sha" \
  --arg baseline_tag "$baseline_tag" \
  --arg baseline_commit "$baseline_commit" \
  --arg baseline_tree_sha "$baseline_tree_sha" \
  --arg build_sha "$build_sha" \
  --arg sync_sha "$sync_sha" \
  --arg release_sha "$release_sha" \
  --arg baseline_build_sha "$baseline_build_sha" \
  --arg baseline_sync_sha "$baseline_sync_sha" \
  --arg baseline_release_sha "$baseline_release_sha" \
  --arg candidate_susfs_sha "$candidate_susfs_sha" \
  --arg baseline_susfs_sha "$baseline_susfs_sha" \
  --arg candidate_kernel_patches_sha "$candidate_kernel_patches_sha" \
  --arg baseline_kernel_patches_sha "$baseline_kernel_patches_sha" \
  --arg status "$status" \
  --arg compare_url "https://github.com/${repo}/compare/${baseline_commit}...${candidate_commit}" \
  --arg compare_status "$compare_status" \
  --argjson configs "$configs" \
  --argjson manifests "$manifests" \
  --argjson config_rows "$config_rows" \
  --argjson control_plane_changes "$control_plane_changes" \
  --argjson schema_errors "$schema_errors" \
  --argjson contract_errors "$contract_errors" \
  --argjson manifest_errors "$manifest_errors" \
  --argjson path_errors "$path_errors" \
  --argjson compare_files "$compare_files" \
  --argjson compare_commits "$compare_commits" \
  --argjson reasons "$reasons" \
  '{status:$status,repository:$repo,candidate:{tag:$tag,commit:$candidate_commit,tree_sha:$tree_sha,susfs_commit:$candidate_susfs_sha,kernel_patches_commit:$candidate_kernel_patches_sha},baseline:{tag:$baseline_tag,commit:$baseline_commit,tree_sha:$baseline_tree_sha,susfs_commit:$baseline_susfs_sha,kernel_patches_commit:$baseline_kernel_patches_sha},compare:{url:$compare_url,status:$compare_status,files:$compare_files,commits:$compare_commits},control_plane:{candidate:{build_kernel:$build_sha,kernel_source_sync:$sync_sha,release_workflow:$release_sha},baseline:{build_kernel:$baseline_build_sha,kernel_source_sync:$baseline_sync_sha,release_workflow:$baseline_release_sha},changes:$control_plane_changes},ace5:{configs:$configs,manifests:$manifests,path_changes:$path_errors,config_schema:$config_rows,schema_errors:$schema_errors,contract_errors:$contract_errors,manifest_errors:$manifest_errors},reasons:$reasons}' > "$output"

if [[ "$status" != pass ]]; then
  echo "WildKernel audit failed for $tag; see $output" >&2
  exit 1
fi
echo "WildKernel audit passed for $tag"
