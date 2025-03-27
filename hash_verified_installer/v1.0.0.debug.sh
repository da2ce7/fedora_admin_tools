#!/usr/bin/env bash
# hash_verified_installer.sh
# Usage: hash_verified_installer <sha256_hash> <max_blocks> <download_timeout> <url> <target_path>

set -Ceuox pipefail

h="$1"
max_blocks="$2"
download_timeout="$3"
url="$4"
target="$5"

error_map=(
  "" # Index 0 unused

  # Dependency errors (1-3)
  "Required command missing"             #1
  "Target path exists"                   #2
  "File stat check failed post-creation" #3

  # Path validation errors (4-5)
  "Path resolution failed" #4
  "Path mismatch detected" #5

  # Filesystem errors (6-7)
  "Secure directory creation failed" #6
  "Temp file allocation failed"      #7

  # Network errors (8-9)
  "Download timed out"      #8
  "Network transfer failed" #9

  # I/O errors (10)
  "Data write failed" #10

  # Verification errors (11)
  "Checksum mismatch" #11

  # Installation errors (12)
  "Final installation failed" #12

  # Administration errors  (13)
  "Must run as root" #13
)

if [ "$EUID" -ne 0 ]; then
  echo >&2 "${error_map[13]}"
  exit 13
fi

# Check system dependencies
for cmd in curl sha256sum stat realpath mktemp install timeout; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo >&2 "${error_map[1]}: $cmd"
    exit 1
  fi
done

verify_path_components() {
  local path_to_check="$1"
  local current=""

  # Split path into components
  IFS='/' read -r -a parts <<<"${path_to_check#/}"

  for part in "${parts[@]}"; do
    current="${current:+${current}/}${part}"
    local full_path="/${current}"

    # Resolve without following terminal symlinks
    if [ -L "$full_path" ]; then
      echo >&2 "ALERT: Symlink detected in path: $full_path"
      return 5
    fi
  done
}

# Create parent directory for target
target_dir=$(dirname "$target")

if ! verify_path_components "$target_dir"; then
  echo >&2 "${error_map[5]}: Pre-creation path anomaly"
  exit 5
fi

if ! install -d -m0700 -o root -g root "$target_dir"; then
  echo >&2 "${error_map[6]}: $target_dir"
  exit 6
fi

# Purge any existing payload
rm -f "$target" 2>/dev/null || :

# Atomic write check.
if ! dd if=/dev/null of="$target" bs=1 count=0 conv=excl,fsync 2>/dev/null; then
  echo >&2 "${error_map[2]}: detection at $target"
  exit 2
fi

# Path Validation Part 1: Check inode retrieval
if ! actual_inode=$(stat -c '%i' "$target" 2>/dev/null); then
  rm -f "$target"
  echo >&2 "${error_map[3]}: stat verification failed"
  exit 3
fi

# Path Validation Part 2: Resolve canonical path
if ! canonical_path=$(realpath -e -- "$target" 2>/dev/null); then
  rm -f "$target"
  echo >&2 "${error_map[4]}: realpath verification failed"
  exit 4
fi

# Path Validation Part 3: Verify path match
if [[ "$canonical_path" != "$target" ]]; then
  rm -f "$target"
  echo >&2 "${error_map[5]}: canonical vs target mismatch"
  exit 5
fi

# Create secure working directory
if ! install -d -m0700 -o root -g root /root/.sai; then
  echo >&2 "${error_map[6]}: /root/.sai"
  exit 6
fi

# Test without exclusivity lock
dd if=/dev/zero of=/root/.sai/test.img bs=128K count=1 status=progress
# Test raw partition write
dd if=/dev/urandom of=/root/.sai/stress.img bs=1M count=100
rm -f /root/.sai/test.img /root/.sai/stress.img

# Create temporary file
if ! temp_file=$(mktemp -p /root/.sai); then
  echo >&2 "${error_map[7]}: $temp_file"
  exit 7
fi
trap 'rm -f "$temp_file"' EXIT

# Test url
curl --max-time 10 --tlsv1.2 --tlsv1.3 -fsSL --proto-redir all,https "$url" | wc -c

# Download with size limit
set +e
{
  timeout "$download_timeout" curl --retry 1024 --retry-delay 1 \
    --tlsv1.2 --tlsv1.3 -fsSL --proto-redir all,https "$url" |
    dd bs=128K count="$max_blocks" of="$temp_file" oflag=direct conv=fsync 2>/dev/null
}
declare -a pipe_status=("${PIPESTATUS[@]}")
set -e

timeout_status="${pipe_status[0]}"
dd_status="${pipe_status[1]}"

if ((dd_status > 0)); then
  rm -f "$target"
  echo >&2 "${error_map[10]}: dd(exit $dd_status)"
  exit 10 # Data write error

elif ((timeout_status == 124)); then
  rm -f "$target"
  echo >&2 "${error_map[8]}: ${download_timeout}s timeout"
  exit 8 # Timeout classification

elif ((timeout_status > 0)); then
  rm -f "$target"
  echo >&2 "${error_map[9]}: curl(exit $timeout_status)"
  exit 9 # Network failure
fi

sync "$temp_file"

# Verify checksum
if ! sha256sum --strict -c <<<"$h  $temp_file" >/dev/null 2>&1; then
  rm -f "$target"
  echo >&2 "${error_map[11]}: Expected $h"
  exit 11
fi

# Install final file
if ! install -m700 -o root -g root -T "$temp_file" "$target"; then
  rm -f "$target"
  echo >&2 "${error_map[12]}: $target"
  exit 12
fi

exit 0
