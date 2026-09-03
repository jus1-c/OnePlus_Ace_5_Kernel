#!/bin/bash
# NetHunter fail-closed fingerprint verification
# Usage: source nh-fingerprint.sh

nh_check_fingerprint() {
  local prop_file="$1"
  local radio="$2"
  local ko_path="$3"

  local expected_target expected_vermagic expected_scm expected_sha
  expected_target=$(grep "^target=" "$prop_file" | cut -d= -f2)
  expected_vermagic=$(grep "^kernel_vermagic=" "$prop_file" | cut -d= -f2)
  expected_scm=$(grep "^scmversion=" "$prop_file" | cut -d= -f2)
  expected_sha=$(grep "^sha256_${radio}=" "$prop_file" | cut -d= -f2)

  local actual_target actual_vermagic actual_scm actual_sha
  actual_target=$(nh_get_target_model)
  actual_vermagic=$(nh_get_running_vermagic)
  actual_scm=$(nh_get_running_scmversion)
  actual_sha=$(sha256sum "$ko_path" | cut -d' ' -f1)

  if [ "$actual_target" != "$expected_target" ]; then
    echo "MISMATCH_TARGET"
    return 1
  fi
  if [ "$actual_vermagic" != "$expected_vermagic" ]; then
    echo "MISMATCH_VERMAGIC"
    return 1
  fi
  if [ "$actual_scm" != "$expected_scm" ]; then
    echo "MISMATCH_SCMVERSION"
    return 1
  fi
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "MISMATCH_SHA256"
    return 1
  fi

  echo "OK"
  return 0
}

nh_get_target_model() {
  getprop ro.product.model 2>/dev/null || echo "UNKNOWN"
}

nh_get_running_vermagic() {
  uname -r 2>/dev/null || echo "UNKNOWN"
}

nh_get_running_scmversion() {
  cat /proc/version 2>/dev/null | grep -oP 'scmversion\s+\K\S+' || echo "UNKNOWN"
}
