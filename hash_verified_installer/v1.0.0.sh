#!/usr/bin/env bash
# hash_verified_installer.sh
# Usage: hash_verified_installer <sha256_hash> <max_blocks> <download_timeout> <url> <target_path>
# Notes:
#        (1) Resets Target Parent Permissions to 700
#        (2) Block Size is 128K

set -Ceuo pipefail

for cmd in locale mv rm sync dd base64 curl sha256sum stat realpath mktemp install timeout; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo >&2 "${error_map[2]}: '$cmd'"
    exit 2
  fi
done

export LC_ALL=C || {
  echo >&2 "FATAL: Failed to set C locale"
  exit 255
}
if ! locale | grep -qx 'LC_ALL=C'; then
  echo >&2 "FATAL: Local check failed"
  exit 255
fi

readonly expected_hash="$1"
readonly max_blocks="$2"
readonly download_timeout="$3"
readonly url="$4"
readonly target="$5"

readonly error_map=(
  "" # Index 0 unused

  # Basic validation (1-2)
  "Must run as root"         #1
  "Required command missing" #2

  # Path safety (3-4)
  "Invalid target path format" #3
  "Symlink component in path"  #4

  # Directory operations (5)
  "Directory creation failed" #5

  # Atomic write (6)
  "Atomic file creation failed" #6

  # Stat/Realpath checks (7-9)
  "File stat check failed"           #7
  "Canonical path resolution failed" #8
  "Canonical path mismatch"          #9

  # Secure environment (10)
  "Secure working directory failure" #10

  # Temp file (11)
  "Temporary file allocation failed" #11

  # Data transfer (12-14)
  "Data write error during download" #12
  "Download timed out"               #13
  "Network download failure"         #14

  # Integrity check (15)
  "Checksum verification failed" #15

  # Final install (16-17)
  "File installation failed"        #16
  "Backup directory stat failed"    #17
  "Target directory stat different" #18
  "Post-install path divergence"    #19
)

if [ "$EUID" -ne 0 ]; then
  echo >&2 "${error_map[1]}"
  exit 1
fi

readonly regex='^[_.:/a-zA-Z0-9 -]+$'
if [[ ! "$target" =~ $regex ]]; then
  readonly bad_target=$(base64 -w0 <<<"$target")
  echo >&2 "${error_map[3]}: BASE64:'$bad_target'"
  exit 3
fi

verify_path_components() {
  local path_to_check="$1"
  local current=""
  local -a parts
  local full_path
  local part

  IFS='/' read -r -a parts <<<"${path_to_check#/}"

  for part in "${parts[@]}"; do
    current="${current:+${current}/}${part}"
    full_path="/${current}"

    if [ -L "$full_path" ]; then
      echo >&2 "${error_map[4]}: '$full_path'"
      return 4
    fi
  done
}

# Create parent directory for target
readonly target_dir=$(dirname "$target")

if ! verify_path_components "$target_dir"; then
  echo >&2 "${error_map[4]}: Pre-creation path anomaly"
  exit 4
fi

if ! install -d -m0700 -o root -g root "$target_dir"; then
  echo >&2 "${error_map[5]}: '$target_dir'"
  exit 5
fi

readonly target_temp=$(mktemp -p "$(dirname "$target")" "$(basename "$target").temp.XXXXXXXXXX")
trap "rm -f '$target_temp'" EXIT

# Atomic write check.
if ! dd if=/dev/null of="$target_temp" bs=1 count=0 conv=excl,fsync 2>/dev/null; then
  echo >&2 "${error_map[6]}: detection at '$target_temp'"
  exit 6
fi

# Path Validation Part 1: Check inode retrieval
if ! target_dir_inode=$(stat -c '%i' "$(dirname "$target_temp")" 2>/dev/null) &&
  target_temp_inode=$(stat -c '%i' "$target_temp" 2>/dev/null); then
  rm -f "$target_temp"
  echo >&2 "${error_map[7]}: stat verification failed"
  exit 7
fi
readonly target_dir_inode target_temp_inode

# Path Validation Part 2: Resolve canonical path
if ! canonical_path=$(realpath -e -- "$target_temp" 2>/dev/null); then
  rm -f "$target_temp"
  echo >&2 "${error_map[8]}: realpath verification failed"
  exit 8
fi
readonly canonical_path

# Path Validation Part 3: Verify path match
if [[ "$canonical_path" != "$target_temp" ]]; then
  rm -f "$target_temp"
  echo >&2 "${error_map[9]}: canonical vs target mismatch"
  exit 9
fi

# Create secure working directory
if ! install -d -m0700 -o root -g root /root/.sai; then
  echo >&2 "${error_map[10]}: /root/.sai"
  exit 10
fi

# Create temporary file
if ! download_temp=$(mktemp -p /root/.sai); then
  echo >&2 "${error_map[11]}: '$download_temp'"
  exit 11
fi
readonly download_temp
trap "rm -f '$download_temp' '$target_temp'" EXIT

# Download with size limit
set +e
{
  readonly install_id=$(cat /proc/sys/kernel/random/uuid | tee /dev/stderr)
  timeout "$download_timeout" \
    curl -H "X-Correlation-ID: $install_id" --no-progress-meter -S \
    --retry 1024 --retry-delay 1 --tlsv1.2 --tlsv1.3 -fL \
    --proto-redir all,https "$url" |
    dd bs=128K count="$max_blocks" of="$download_temp" oflag=direct conv=fsync
}
pipe_status=("${PIPESTATUS[@]}")
readonly -a pipe_status
set -e

readonly timeout_status="${pipe_status[0]}"
readonly dd_status="${pipe_status[1]}"

# Data write error
if ((dd_status > 0)); then
  echo >&2 "${error_map[12]}: dd(exit '$dd_status')"
  exit 12

  # Timeout classification
elif ((timeout_status == 124)); then
  echo >&2 "${error_map[13]}: ${download_timeout}s timeout"
  exit 13

# Network failure
elif ((timeout_status > 0)); then
  echo >&2 "${error_map[14]}: curl(exit '$timeout_status')"
  exit 14
fi

sync "$download_temp"

readonly actual_checksum=$(sha256sum "$download_temp" | cut -d' ' -f1)
if ! sha256sum --strict -c <(printf "%s  %s\n" "$expected_hash" "$download_temp") &>/dev/null; then
  echo >&2 "${error_map[15]}: Verification Failed"$'\n'
  echo >&2 "Actual Checksum:   '${actual_checksum}'"
  echo >&2 "Expected Checksum: '${expected_hash}'"
  exit 15
fi

# Install final file
if ! install -m700 -o root -g root -T "$download_temp" "$target_temp"; then
  rm -f "$target_temp"
  echo >&2 "${error_map[16]}: '$target_temp'"
  exit 16
fi

readonly target_backup=$(mktemp -p "$(dirname "$target")" "$(basename "$target").backup.XXXXXXXXXX")
trap "rm -f '$download_temp' '$target_temp' '$target_backup'" EXIT

if ! target_backup_dir_inode=$(stat -c '%i' "$(dirname "$target_backup")" 2>/dev/null); then
  echo >&2 "${error_map[17]}: stat verification failed"
  exit 17
fi
readonly target_backup_dir_inode

if [[ "$target_backup_dir_inode" != "$target_dir_inode" ]]; then
  {
    echo >&2 "${error_map[18]}: "
    exit 18
  }
fi

if [ -f "$target" ]; then
  exec {fd}<>"$target" || exit
  mv -f "${target}" "${target_backup}" && sync "${target_backup}"
  exec {fd}>&- || exit
fi

exec {fd}<>"$target_temp" || exit
mv "${target_temp}" "${target}" && sync "${target}"
exec {fd}>&- || exit

readonly actual_path=$(realpath -e -- "$target")
if [[ "$actual_path" != "$canonical_path" ]]; then
  if [ -f "$target_backup" ]; then
    exec {fd}<>"$target_backup" || exit
    mv -f "${target_backup}" "${target}" && sync "${target}"
    exec {fd}>&- || exit
  fi
  rm -f "$canonical_path" "$actual_path"
  echo >&2 "${error_map[19]}: Post-install path divergence"
  exit 19
fi

echo "install: SHA256:'${expected_hash}' to '${actual_path}'"
exit 0
