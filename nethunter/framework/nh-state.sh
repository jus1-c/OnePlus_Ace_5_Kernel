#!/bin/bash
# NetHunter takeover state machine
# Usage: source nh-state.sh

NH_STATE_DIR="${NH_STATE_DIR:-/data/adb/nethunter}"
NH_LOCK_DIR="${NH_LOCK_DIR:-/data/adb/nethunter}"

nh_get_state() {
  local radio="$1"
  local state_file="$NH_STATE_DIR/${radio}.state"
  if [ -f "$state_file" ]; then
    cat "$state_file"
  else
    echo "IDLE"
  fi
}

nh_set_state() {
  local radio="$1"
  local state="$2"
  mkdir -p "$NH_STATE_DIR"
  echo "$state" > "$NH_STATE_DIR/${radio}.state"
}

nh_acquire_lock() {
  local radio="$1"
  local lockfile="$NH_LOCK_DIR/${radio}.lock"
  mkdir -p "$NH_LOCK_DIR"
  exec 200>"$lockfile"
  if ! flock -n 200; then
    echo "ERROR: ${radio} already locked" >&2
    return 1
  fi
  nh_set_state "$radio" "QUIESCE"
  return 0
}

nh_release_lock() {
  local radio="$1"
  local lockfile="$NH_LOCK_DIR/${radio}.lock"
  nh_set_state "$radio" "IDLE"
  flock -u 200 2>/dev/null || true
  rm -f "$lockfile"
}
