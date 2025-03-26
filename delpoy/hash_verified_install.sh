#!/usr/bin/env bash
# hash_verified_install.sh
# Usage: hash_verified_install <sha256_hash> <max_bytes> <url> <target_path>

set -Ceo pipefail


h="$1"
too_big="$2"
url="$3"
target="$4"

error_map=("" "Tempdir fail" "mktemp fail" "Download fail" "Size breach"
  "Hash invalid" "Target invalid")
ec=0

# Validate target path is writable
if ! dd if=/dev/null of="$target" bs=1 count=0 conv=excl,fsync 2>/dev/null; then
  ec=6
  echo >&2 "${error_map[6]}"
  exit 6
fi
chmod 600 "$target"

# Verify canonicalization (no symlink hijacking)
actual_inode=$(stat -c '%i' "$target") &&
  canonical_path=$(realpath -e -- "$target") &&
  [[ "$canonical_path" == "$target" ]] || {
  rm -f "$target"
  ec=6
  echo >&2 "${error_map[6]}"
  exit 6
}

# Create secure tempdir
install -d -m0700 -o root -g root /root/.sai || {
  ec=1
  exit 1
}
temp_file=$(mktemp -p /root/.sai) || {
  ec=2
  exit 2
}
trap 'rm -f "$temp_file"' EXIT

# Download with strict size limits
if ! timeout 10 curl --tlsv1.2 --tlsv1.3 -fsSL --proto-redir -all,https "$url" |
  dd bs=1 count="$too_big" of="$temp_file" conv=excl,fsync 2>/dev/null; then
  ec=3
  rm -f "$target"
  exit 3
fi

# Validate SHA256
((ec == 0)) && ! sha256sum --strict -c <<<"$h  $temp_file" &>/dev/null && {
  ec=5
  rm -f "$target"
  exit 5
}

# Atomic install
if ((ec == 0)); then
  install -m700 -o root -g root -T "$temp_file" "$target"
else
  rm -f "$target"
fi

exit "${ec:-0}"
