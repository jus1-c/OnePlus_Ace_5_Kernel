#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

[[ -n "${GH_TOKEN:-}" ]] || { echo 'GH_TOKEN is required' >&2; exit 2; }

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

scripts/audit_wild_release.sh --tag v2.2.0-r4 --output "$tmpdir/current.json"
jq -e '.status == "pass" and (.control_plane.changes | length == 0)' "$tmpdir/current.json" >/dev/null

if scripts/audit_wild_release.sh --tag v2.2.0-r3 --output "$tmpdir/drift.json"; then
  echo 'Expected older release audit to fail' >&2
  exit 1
fi
jq -e '.status == "fail" and (.reasons | length > 0)' "$tmpdir/drift.json" >/dev/null

jq '.actions.build_kernel_blob_sha = "0000000000000000000000000000000000000000"' \
  config/wild-reviewed.json > "$tmpdir/action-drift-baseline.json"
if scripts/audit_wild_release.sh --tag v2.2.0-r4 --baseline "$tmpdir/action-drift-baseline.json" --output "$tmpdir/action-drift.json"; then
  echo 'Expected control-plane drift audit to fail' >&2
  exit 1
fi
jq -e '.status == "fail" and (.control_plane.changes | length == 1)' "$tmpdir/action-drift.json" >/dev/null

jq '.ace5_config_schema.key_types.susfs = "string"' config/wild-reviewed.json > "$tmpdir/schema-drift-baseline.json"
if scripts/audit_wild_release.sh --tag v2.2.0-r4 --baseline "$tmpdir/schema-drift-baseline.json" --output "$tmpdir/schema-drift.json"; then
  echo 'Expected config schema drift audit to fail' >&2
  exit 1
fi
jq -e '.status == "fail" and (.ace5.schema_errors | length > 0)' "$tmpdir/schema-drift.json" >/dev/null

echo 'WildKernel audit tests passed'
