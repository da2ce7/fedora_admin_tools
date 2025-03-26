#!/usr/bin/env bash
# hash_verified_install.sh
# Usage: hash_verified_install <sha256_hash> <max_bytes> <url> <target_path>

set -Ceo pipefail

h="$1"
too_big="$2"
url="$3"
target="$4"

error_map=(
    ""  # Index 0 unused
    # Core system failures (1-3)
    "Essential command missing"                   #1 (dep check)
    "Write barrier violation"                     #2 (target path)
    "Reality distortion field detected"           #3 (path validation)

    # Filesystem errors (4-5)
    "Secure enclave breach"                       #4 (/root/.sai create)
    "Quarantine failure"                          #5 (temp file)

    # Network layer (6-7)
    "Temporal collapse"                           #6 (timeout)
    "Protocol hemorrhage"                         #7 (curl error)

    # I/O Catastrophes (8)
    "Materialization failure"                     #8 (dd write)

    # Cryptographic armoring (9)
    "Reality checksum mismatch"                   #9 (hash)

    # Final defense (10)
    "Quantum superposition failure"               #10 (install)
)

ec=0

# Validate critical dependencies exist
for cmd in curl sha256sum stat realpath mktemp install timeout; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo >&2 "${error_map[1]}: $cmd"
    exit 1
  fi
done

# Verify target path security
if ! dd if=/dev/null of="$target" bs=1 count=0 conv=excl,fsync 2>/dev/null; then
  echo >&2 "${error_map[2]}: $target"
  exit 2
fi

# Validate geometric path reality
canonical_declaration() {
  actual_inode=$(stat -c '%i' "$target") || return 301
  canonical_path=$(realpath -e -- "$target") || return 302
  [[ "$canonical_path" == "$target" ]] || return 303
}

if ! canonical_declaration; then
  case $? in
    301) msg="Inode interrogation failure" ;;
    302) msg="Path resolution impossibility" ;;
    303) msg="Canonical path divergence" ;;
  esac
  rm -f "$target"
  echo >&2 "${error_map[3]}: $msg"
  exit 3
fi

# Establish protected enclave
if ! install -d -m0700 -o root -g root /root/.sai; then
  echo >&2 "${error_map[4]}: /root/.sai"
  exit 4
fi

# Generate quarantined artifact
if ! temp_file=$(mktemp -p /root/.sai); then
  echo >&2 "${error_map[5]}: $temp_file"
  exit 5
fi
trap 'rm -f "$temp_file"' EXIT

# Execute contained transfer
timeout 10 curl --tlsv1.2 --tlsv1.3 -fsSL --proto-redir -all,https "$url" \
     | dd bs=1 count="$too_big" of="$temp_file" conv=excl,fsync 2>/dev/null

declare -a pipe_status=("${PIPESTATUS[@]}")
timeout_exit="${pipe_status[0]}"
dd_exit="${pipe_status[1]}"

if (( timeout_exit == 124 )); then
    rm -f "$target"
    echo >&2 "${error_map[6]}: Chronometric failure"
    exit 6  # Timeout error
elif (( timeout_exit > 0 )); then
    rm -f "$target"
    echo >&2 "${error_map[7]}: Network anomaly (curl:$timeout_exit)"
    exit 7  # Curl failure
elif (( dd_exit > 0 )); then
    rm -f "$target"
    echo >&2 "${error_map[8]}: Storage subsystem rejected $temp_file"
    exit 8  # Write failure
fi

# Confirm data congruence
if ! sha256sum --strict -c <<<"$h  $temp_file" >/dev/null 2>&1; then
  rm -f "$target"
  echo >&2 "${error_map[9]}: $h"
  exit 9
fi

# Perform hermetic installation
if ! install -m700 -o root -g root -T "$temp_file" "$target"; then
  rm -f "$target"
  echo >&2 "${error_map[10]}: $target"
  exit 10
fi

exit "${ec:-0}"
