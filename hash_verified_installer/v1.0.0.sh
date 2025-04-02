#!/usr/bin/env bash
# hash_verified_installer.sh
# Usage: hash_verified_installer <sha256_hash> <max_blocks> <download_timeout> <url> <target_path>
# Notes:
#        (1) Run as Root
#        (2) File and its immediate parent directory are set to root:root 700
#        (3) Block Size is 128K

set -Ceuo pipefail

for cmd in locale mv rm sync dd base64 curl sha256sum stat realpath mktemp install timeout; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo >&2 "Required command missing: '$cmd'"
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

  # Basic validation (1)
  "Error 1: Must run as root"

  # Path safety (2-4)
  "Error 2: Path must be absolute"
  "Error 3: Invalid target path format"
  "Error 4: Symlink component in path"

  # Directory operations (5)
  "Error 5: Directory creation failed"

  # Atomic write (6)
  "Error 6: Atomic file creation failed"

  # Stat/Realpath checks (7-9)
  "Error 7: File stat check failed"
  "Error 8: Canonical path resolution failed"
  "Error 9: Canonical path mismatch"

  # Secure environment (10)
  "Error 10: Secure working directory failure"

  # Lockfile (11-12)
  "Error 11: Lock file handle acquisition failed"
  "Error 12: Lock acquisition timeout/failure"

  # Temp file (13)
  "Error 13: Temporary file allocation failed"

  # Data transfer (14-16)
  "Error 14: Data write error during download"
  "Error 15: Download timed out"
  "Error 16: Network download failure"

  # Integrity check (17)
  "Error 17: Checksum verification failed"

  # Final install (18-21)
  "Error 18: File installation failed"
  "Error 19: Backup directory stat failed"
  "Error 20: Target directory stat different"
  "Error 21: Post-install path divergence"
)

if [ "$EUID" -ne 0 ]; then
  echo >&2 "${error_map[1]}"
  exit 1
fi

readonly target_base64=$(base64 -w0 <<<"$target")

[[ "$target" != /* ]] && {
  echo >&2 "${error_map[2]}: base64:'$target_base64'"
  exit 2
}

readonly safe_path_regex='^[_.:/a-zA-Z0-9 -]+$'
if [[ ! "$target" =~ $safe_path_regex ]]; then
  echo >&2 "${error_map[3]}: allowed: '$safe_path_regex'; actual (base64 enc):'$target_base64'"
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

# install -d with -m/-o/-g applies changes only to target directory (and path ancestors if created)
if ! install -d -m0700 -o root -g root "$target_dir"; then
  echo >&2 "${error_map[5]}: '$target_dir'"
  exit 5
fi

readonly target_temp=$(mktemp -u -p "$(dirname "$target")" "$(basename "$target").temp.XXXXXXXXXX")
trap "rm -f '$target_temp'" EXIT

# Create temporary target
if ! dd if=/dev/null of="$target_temp" bs=1 count=0 conv=excl,fsync 1>&2; then
  echo >&2 "${error_map[6]}: Failed to create '$target_temp' atomically"
  exit 6
fi

# Path Validation Part 1: Check inode retrieval
if ! target_temp_dir_inode=$(stat -c '%i' "$(dirname "$target_temp")" 1>&2) &&
  target_temp_inode=$(stat -c '%i' "$target_temp" 1>&2); then
  rm -f "$target_temp"
  echo >&2 "${error_map[7]}: stat verification failed"
  exit 7
fi
readonly target_temp_dir_inode target_temp_inode

# Path Validation Part 2: Resolve canonical path
if ! canonical_path=$(realpath -e -- "$target_temp"); then
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

readonly LOCK_ROOT="/root/.sai/locks"
if ! install -d -m0700 -o root -g root "$LOCK_ROOT"; then
  echo >&2 "${error_map[10]}: $LOCK_ROOT"
  exit 10
fi

readonly target_hash=$(printf "%s" "$target" | sha256sum | cut -d' ' -f1)
readonly per_target_lock="${LOCK_ROOT}/${target_hash}.lock"

exec {lock_fd}>|"$per_target_lock" || {
  echo >&2 "${error_map[11]}: FD allocation"
  exit 11
}

if ! flock -x -w 30 "$lock_fd"; then
  echo >&2 "${error_map[12]}: ${per_target_lock}"
  exit 12
fi

echo ${target} >&"$lock_fd"
echo ${expected_hash} >&"$lock_fd"
readonly install_id=$(cat /proc/sys/kernel/random/uuid)
echo ${install_id} >&"$lock_fd"

trap "flock -u "$lock_fd"; exec {lock_fd}>&-; rm -f '$target_temp'" EXIT

# Create temporary file
if ! download_temp=$(mktemp -p /root/.sai); then
  echo >&2 "${error_map[13]}: '$download_temp'"
  exit 13
fi
readonly download_temp
trap "flock -u "$lock_fd"; exec {lock_fd}>&-; rm -f '$download_temp' '$target_temp'" EXIT

# Download with size limit
set +e
{
  echo ${install_id}
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
  echo >&2 "${error_map[14]}: dd(exit '$dd_status')"
  exit 14

  # Timeout classification
elif ((timeout_status == 124)); then
  echo >&2 "${error_map[15]}: ${download_timeout}s timeout"
  exit 15

# Network failure
elif ((timeout_status > 0)); then
  echo >&2 "${error_map[16]}: curl(exit '$timeout_status')"
  exit 16
fi

sync "$download_temp"

readonly actual_checksum=$(sha256sum "$download_temp" | cut -d' ' -f1)
if ! sha256sum --strict -c <(printf "%s  %s\n" "$expected_hash" "$download_temp") &>/dev/null; then
  echo >&2 "${error_map[17]}: Verification Failed"$'\n'
  echo >&2 "Actual Checksum:   '${actual_checksum}'"
  echo >&2 "Expected Checksum: '${expected_hash}'"
  exit 17
fi

# Install final file
if ! install -m700 -o root -g root -T "$download_temp" "$target_temp"; then
  rm -f "$target_temp"
  echo >&2 "${error_map[18]}: '$target_temp'"
  exit 18
fi

readonly target_backup=$(mktemp -u -p "$(dirname "$target")" "$(basename "$target").backup.XXXXXXXXXX")
trap "flock -u "$lock_fd"; exec {lock_fd}>&-; rm -f '$download_temp' '$target_temp' '$target_backup'" EXIT

if ! target_dir_inode=$(stat -c '%i' "$(dirname "$target")" 1>&2); then
  echo >&2 "${error_map[19]}: stat verification failed"
  exit 19
fi
readonly target_dir_inode

if [[ "$target_dir_inode" != "$target_temp_dir_inode" ]]; then
  {
    echo >&2 "${error_map[20]}: "
    exit 20
  }
fi

readonly install_target = 

if [ -f "$target" ]; then
  exec {fd}<>"$target" || exit
  mv -T "${target}" "${target_backup}" && sync "${target_backup}"
  exec {fd}>&- || exit
fi

exec {fd}<>"$target_temp" || exit
mv -T "${target_temp}" "${target}" && sync "${target}"
exec {fd}>&- || exit

readonly target_real_path=$(realpath -e -- "$target")
if [[ "$target" != "$target_real_path" ]]; then
  if [ -f "$target_backup" ]; then
    exec {fd}<>"$target_backup" || exit
    mv -Tf "${target_backup}" "${target}" && sync "${target}"
    exec {fd}>&- || exit
  fi
  rm -f "$target_real_path" "$target"
  echo >&2 "${error_map[21]}: Post-install path divergence"
  exit 21
fi

echo "install: SHA256:'${expected_hash}' to '${actual_path}'"
exit 0
