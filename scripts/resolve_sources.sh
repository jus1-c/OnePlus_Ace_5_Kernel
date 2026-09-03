#!/usr/bin/env bash
set -euo pipefail

repo="${WILD_REPO:-WildKernels/OnePlus_KernelSU_SUSFS}"
resukisu_repo="${RESUKISU_REPO:-ReSukiSU/ReSukiSU}"
nomount_repo="${NOMOUNT_REPO:-Bouteillepleine/NoMount-Suite}"
nomount_branch="${NOMOUNT_BRANCH:-main}"
nomount_tag="${NOMOUNT_TAG:-}"
kernel_patches_repo="${KERNEL_PATCHES_REPO:-WildKernels/kernel_patches}"
wild_release_json=$(mktemp)
trap 'rm -f "$wild_release_json"' EXIT

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

resolve_ref() {
  local repository="$1" ref="$2"
  git ls-remote "https://github.com/${repository}.git" "refs/heads/${ref}" "refs/tags/${ref}" "refs/tags/${ref}^{}" |
    awk '{ print $1 }' | tail -n1
}

api "https://api.github.com/repos/${repo}/releases?per_page=100" > "$wild_release_json"
wild_release=$(jq -c '[.[] | select(.draft == false and .prerelease == false)][0] // empty' "$wild_release_json")
wild_tag=$(jq -r '.tag_name // empty' <<< "$wild_release")
[[ -n "$wild_tag" ]] || { echo 'No stable WildKernel release found' >&2; exit 1; }
wild_sha=$(resolve_ref "$repo" "$wild_tag")
[[ "$wild_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "Cannot resolve WildKernel tag $wild_tag" >&2; exit 1; }

release_body=$(jq -r '.body // ""' <<< "$wild_release")
wild_published_at=$(jq -r '.published_at // empty' <<< "$wild_release")
[[ -n "$wild_published_at" ]] || { echo "Missing publish time for $wild_tag" >&2; exit 1; }
# SUSFS: Fetch directly from upstream GitLab (simonpunk/susfs4ksu) instead of WildKernels
# Uses gki-android14-6.1 branch HEAD for latest KernelSU compatibility (v2.3.0+)
susfs_sha=$(curl --fail --silent --show-error \
  "https://gitlab.com/api/v4/projects/simonpunk%2Fsusfs4ksu/repository/branches/gki-android14-6.1" | \
  jq -r '.commit.id // empty')
[[ "$susfs_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "Cannot resolve SUSFS upstream branch gki-android14-6.1" >&2; exit 1; }
echo "SUSFS upstream: simonpunk/susfs4ksu@gki-android14-6.1 (${susfs_sha:0:8})" >&2

resukisu_sha=$(api "https://api.github.com/repos/${resukisu_repo}/commits/main" | jq -r '.sha // empty')
[[ "$resukisu_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'Cannot resolve ReSukiSU main' >&2; exit 1; }

# NoMount Suite: pinned to a release tag (engine + userspace must flash as a pair).
nomount_sha=''
nomount_run_url=''
if [[ "$nomount_tag" == latest ]]; then
  nomount_tag=$(api "https://api.github.com/repos/${nomount_repo}/releases/latest" | jq -r '.tag_name // empty')
fi
[[ -n "$nomount_tag" ]] || { echo "No NoMount Suite tag configured (set NOMOUNT_TAG)" >&2; exit 1; }
nomount_sha=$(api "https://api.github.com/repos/${nomount_repo}/commits/${nomount_tag}" | jq -r '.sha // empty')
[[ "$nomount_sha" =~ ^[0-9a-f]{40}$ ]] || { echo "Cannot resolve NoMount Suite tag ${nomount_tag}" >&2; exit 1; }
echo "NoMount Suite pinned to release ${nomount_tag} (${nomount_sha:0:8})" >&2

kernel_patches_sha=$(api "https://api.github.com/repos/${kernel_patches_repo}/commits?sha=main&until=${wild_published_at}&per_page=1" | jq -r '.[0].sha // empty')
[[ "$kernel_patches_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'Cannot resolve kernel_patches main' >&2; exit 1; }

bbg_repo='vc-teahouse/Baseband-guard'
bbg_sha=$(api "https://api.github.com/repos/${bbg_repo}/commits/main" | jq -r '.sha // empty')
[[ "$bbg_sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'Cannot resolve Baseband Guard main' >&2; exit 1; }

configs=$(api "https://api.github.com/repos/${repo}/git/trees/${wild_sha}?recursive=1" |
  jq -c '[.tree[] | select(.path | test("^configs/a16/OP-ACE-5(-[0-9]+\\.[0-9]+\\.[0-9]+)?\\.json$")) | .path]')
[[ "$configs" != '[]' ]] || { echo "No Ace 5 A16 configs in $wild_tag" >&2; exit 1; }

manifests=$(api "https://api.github.com/repos/${repo}/git/trees/${wild_sha}?recursive=1" |
  jq -c '[.tree[] | select(.path | test("^manifests/a16/oneplus_ace5(_[0-9]+\\.[0-9]+\\.[0-9]+)?_w\\.xml$")) | .path]')
[[ "$manifests" != '[]' ]] || { echo "No Ace 5 A16 manifests in $wild_tag" >&2; exit 1; }

  jq -n \
  --arg wild_repo "$repo" \
  --arg wild_tag "$wild_tag" \
  --arg wild_sha "$wild_sha" \
  --arg wild_published_at "$wild_published_at" \
  --arg susfs_sha "$susfs_sha" \
  --arg resukisu_repo "$resukisu_repo" \
  --arg resukisu_sha "$resukisu_sha" \
  --arg nomount_repo "$nomount_repo" \
  --arg nomount_branch "$nomount_branch" \
  --arg nomount_tag "${nomount_tag:-}" \
  --arg nomount_sha "$nomount_sha" \
  --arg nomount_run_url "$nomount_run_url" \
  --arg kernel_patches_repo "$kernel_patches_repo" \
  --arg kernel_patches_sha "$kernel_patches_sha" \
  --arg bbg_repo "$bbg_repo" \
  --arg bbg_sha "$bbg_sha" \
  --argjson configs "$configs" \
  --argjson manifests "$manifests" \
  '{wild_repo:$wild_repo,wild_release:$wild_tag,wild_sha:$wild_sha,wild_published_at:$wild_published_at,susfs_sha:$susfs_sha,
    resukisu_repo:$resukisu_repo,resukisu_sha:$resukisu_sha,
     nomount_repo:$nomount_repo,nomount_branch:$nomount_branch,nomount_tag:$nomount_tag,nomount_sha:$nomount_sha,nomount_run_url:$nomount_run_url,
    kernel_patches_repo:$kernel_patches_repo,kernel_patches_sha:$kernel_patches_sha,
    bbg_repo:$bbg_repo,bbg_sha:$bbg_sha,
    configs:$configs,manifests:$manifests}'
