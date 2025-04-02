#!/usr/bin/env bash
# hash_verified_installer.sh
# Usage: hash_verified_installer <sha256_hash> <max_blocks> <download_timeout> <url> <target_path>
# Notes:
#        (1) Run as Root
#        (2) File and its immediate parent directory are set to root:root 700
#        (3) Block Size is 128K

set -Ceuo pipefail


readonly error_map=(
  "" # Index 0 unused

  # Basic validation (1)
  "Error 1: Must run as root"
  "Error 2: Command not found"
  "Error 3: Failed to set C locale"
  "Error 4: Local check failed"
  "Error 5: Must be a positive integer"

  # Index 6-9 unused
  ""
  ""
  ""
  ""
  
  # Path safety (10-12)
  "Error 10: Path must be absolute"
  "Error 11: Invalid target path format"
  "Error 12: Symlink component in path"

  # Directory operations (13)
  "Error 13: Directory creation failed"

  # Stat/Realpath checks (14-16)
  "Error 14: File stat check failed"
  "Error 15: Canonical path resolution failed"
  "Error 16: Canonical path mismatch"

  # Working Environment (17)
  "Error 17: Working directory failure"

  # Lockfile (18-19)
  "Error 18: Lock file handle acquisition failed"
  "Error 19: Lock acquisition timeout/failure"

  # Temp file (20)
  "Error 20: Temporary file allocation failed"

  # Data transfer (21-23)
  "Error 21: Data write error during download"
  "Error 22: Download timed out"
  "Error 23: Network download failure"

  # Integrity check (24)
  "Error 24: Checksum verification failed"

  # Final install (25-28)
  "Error 25: File installation failed"
  "Error 26: Directory stat check failed"
  "Error 27: Target directory stat different"
  "Error 28: Post-install path divergence"
)

if [ "$EUID" -ne 0 ]; then
  echo >&2 "${error_map[1]}"
  exit 1
fi

for cmd in flock locale mv rm sync dd base64 curl sha256sum stat realpath mktemp install timeout; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo >&2 "${error_map[2]}: '$cmd'"
    exit 2
  fi
done

export LC_ALL=C || {
  echo >&2 "${error_map[3]}"
  exit 3
}
if ! locale | grep -qx 'LC_ALL=C'; then
  echo >&2 "${error_map[4]}"
  exit 4
fi

readonly expected_hash="$1"

validate_positive_int() {
  [[ "$1" =~ ^[[:digit:]]+$ ]] && (( $1 > 0 )) || return 255
}

validate_positive_int "$2" || {
  echo >&2 "${error_map[5]}: <max_blocks> "
  exit 5
}
declare -i max_blocks="$2"
readonly max_blocks

validate_positive_int "$3" || {
  echo >&2 "${error_map[5]}: <download_timeout>"
  exit 5
}
declare -i download_timeout="$3"
readonly download_timeout

readonly url="$4"
readonly target="$5"

target_base64=$(base64 -w0 <<<"$target")
readonly target_base64

[[ "$target" != /* ]] && {
  echo >&2 "${error_map[10]}: base64:'$target_base64'"
  exit 10
}

readonly safe_path_regex='^[_.:/a-zA-Z0-9 -]+$'
if [[ ! "$target" =~ $safe_path_regex ]]; then
  echo >&2 "${error_map[11]}: allowed: '$safe_path_regex'; actual (base64 enc):'$target_base64'"
  exit 11
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
      echo >&2 "${error_map[12]}: '$full_path'"
      return 12
    fi
  done
}

# Create parent directory for target
target_dir=$(dirname "$target")
readonly target_dir

if ! verify_path_components "$target_dir"; then
  echo >&2 "${error_map[12]}: Pre-creation path anomaly"
  exit 12
fi

# install -d with -m/-o/-g applies changes only to target directory (and path ancestors if created)
if ! install -d -m0700 -o root -g root "$target_dir"; then
  echo >&2 "${error_map[13]}: '$target_dir'"
  exit 13
fi

# Path Validation Part 1: Check inode retrieval
if ! target_dir_inode=$(stat -c '%i' "$target_dir"); then
  echo >&2 "${error_map[14]}: stat verification failed"
  exit 14
fi
readonly target_dir_inode

# Path Validation Part 2: Resolve canonical path
if ! canonical_dir_path=$(realpath -e -- "$target_dir"); then
  echo >&2 "${error_map[15]}: realpath verification failed"
  exit 15
fi
readonly canonical_dir_path

# Path Validation Part 3: Verify path match
if [[ "$canonical_dir_path" != "$target_dir" ]]; then
  echo >&2 "${error_map[16]}: canonical vs target mismatch"
  exit 16
fi

# Create working directory
if ! install -d -m0700 -o root -g root /root/.sai; then
  echo >&2 "${error_map[17]}: /root/.sai"
  exit 17
fi

readonly LOCK_ROOT="/root/.sai/locks"
if ! install -d -m0700 -o root -g root "$LOCK_ROOT"; then
  echo >&2 "${error_map[17]}: $LOCK_ROOT"
  exit 17
fi

target_hash=$(printf "%s" "$target" | sha256sum | cut -d' ' -f1)
readonly target_hash
readonly per_target_lock="${LOCK_ROOT}/${target_hash}.lock"

exec {lock_fd}>|"$per_target_lock" || {
  echo >&2 "${error_map[18]}: FD allocation"
  exit 18
}
readonly lock_fd

if ! flock -x -w 30 $lock_fd; then
  echo >&2 "${error_map[19]}: ${per_target_lock}"
  exit 19
fi

echo "${target}" >&$lock_fd
echo "${expected_hash}" >&$lock_fd
install_id=$(cat /proc/sys/kernel/random/uuid)
readonly install_id
echo "${install_id}" >&$lock_fd

trap "flock -u $lock_fd; exec $lock_fd>&-;" EXIT

# Create temporary file
if ! download_temp=$(mktemp -p /root/.sai); then
  echo >&2 "${error_map[20]}: '$download_temp'"
  exit 20
fi
readonly download_temp
trap "flock -u $lock_fd; exec $lock_fd>&-; rm -f '$download_temp'" EXIT

# Download with size limit
set +e
{
  echo "${install_id}"
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
  echo >&2 "${error_map[21]}: dd(exit '$dd_status')"
  exit 21

  # Timeout classification
elif ((timeout_status == 124)); then
  echo >&2 "${error_map[22]}: ${download_timeout}s timeout"
  exit 22

# Network failure
elif ((timeout_status > 0)); then
  echo >&2 "${error_map[23]}: curl(exit '$timeout_status')"
  exit 23
fi

sync "$download_temp"

actual_checksum=$(sha256sum "$download_temp" | cut -d' ' -f1)
readonly actual_checksum
if ! sha256sum --strict -c <(printf "%s  %s\n" "$expected_hash" "$download_temp") &>/dev/null; then
  echo >&2 "${error_map[24]}: Verification Failed"$'\n'
  echo >&2 "Actual Checksum:   '${actual_checksum}'"
  echo >&2 "Expected Checksum: '${expected_hash}'"
  exit 24
fi

target_swap=$(mktemp -u -p "$(dirname "$target")" "$(basename "$target").swap.XXXXXXXXXX")
readonly target_swap
trap "flock -u $lock_fd; exec $lock_fd>&-;\
  rm -f '$download_temp' '$target_swap'" EXIT

if ! install -m700 -o root -g root -T "$download_temp" "$target_swap"; then
  echo >&2 "${error_map[25]}: '$target_swap'"
  exit 25
fi

target_swap_dir=$(dirname "$target_swap")
readonly target_swap_dir
if ! target_swap_dir_inode=$(stat -c '%i' "$target_swap_dir"); then
  echo >&2 "${error_map[26]}: ${target_swap_dir}"
  exit 26
fi
readonly target_swap_dir_inode

if [[ "$target_swap_dir_inode" != "$target_dir_inode" ]]; then
  {
    echo >&2 "${error_map[27]}"
    exit 27
  }
fi

if [ -f "$target" ]; then
  exec {fd_swap}<>"$target_swap" && exec {fd_target}<>"$target" || exit
  readonly fd_swap fd_target

  trap "flock -u $lock_fd; exec $lock_fd>&-; \
    rm -f '$download_temp' '$target_swap'; \
    exec $fd_swap>&-; exec $fd_target>&-;" EXIT

  target_real_path=$(realpath -e -- "$target")
  readonly target_real_path
  if [[ "$target" != "$target_real_path" ]]; then
    echo >&2 "${error_map[28]}: Pre-swap path divergence:"
    echo >&2 "target: '${target}'" && echo >&2 "real: '${target_real_path}'"
    exit 28
  fi
  mv --no-target-directory --exchange "${target_swap}" "${target}" &&
    sync "${target}" "${target_swap}"
else
  exec {fd_swap}<>"$target_swap" || exit
  trap "flock -u $lock_fd; exec $lock_fd>&-; \
    rm -f '$download_temp' '$target_swap'; \
    exec $fd_swap>&-;" EXIT

  mv --no-target-directory --no-clobber "${target_swap}" "${target}" && sync "${target}"

  target_real_path=$(realpath -e -- "$target")
  readonly target_real_path
  if [[ "$target" != "$target_real_path" ]]; then
    rm --force "${target}"
    echo >&2 "${error_map[28]}: Post-install path divergence:"
    echo >&2 "target: '${target}'" && echo >&2 "real: '${target_real_path}'"
    exit 28
  fi
fi

echo "install: SHA256:'${expected_hash}' to '${target}'"
exit 0
