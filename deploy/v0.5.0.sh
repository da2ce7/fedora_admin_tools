bash -c '
set -euox pipefail

required_vars=(DEPLOY_DATA DEPLOY_COMPRESSED_HASH PAYLOAD_HASH PAYLOAD_URL PAYLOAD_INSTALL_PATH PAYLOAD_EXCESSIVE_SIZE)
for var in "${required_vars[@]}"; do
    : "${!var:?Missing $var}"
done

  if [[ ! "$PAYLOAD_EXCESSIVE_SIZE" =~ ^[0-9]+$ ]]; then
    echo >&2 "Invalid PAYLOAD_EXCESSIVE_SIZE"
    exit 105
  fi

# 1. Deploy installer with COMPRESSED hash check
install -d -m0700 -o root -g root /root/.sai || exit $?
compressed_file=$(mktemp -p /root/.sai) || exit $?
extracted_file=$(mktemp -p /root/.sai) || exit $?
trap 'rm -f "$compressed_file" "$extracted_file"' EXIT

# Validate compressed artifact before decompression
printf "%s" "$DEPLOY_DATA" | base64 -d > "$compressed_file"|| {
    echo >&2 "Base64 decode failed"; exit 101; }
sha256sum --strict -c <<< "$DEPLOY_COMPRESSED_HASH  $compressed_file" || {
    echo >&2 "Compressed hash mismatch"; exit 102; }

combined_size=0
if ! combined_size=$(set -o pipefail; gunzip --stdout "$compressed_file" | \
                     tee "$extracted_file" | wc -c); then
  if [[ $? -eq 1 ]]; then
    echo >&2 "Decompression failed: Corrupted compressed stream"
  else
    echo >&2 "I/O failure during decompression pipeline"
  fi
  exit 103
fi

sync -f "$extracted_file"

verified_size=$(stat -c '%s' "$extracted_file")
if (( combined_size != verified_size )); then
    echo >&2 "FS corruption detected: Pipe wrote $verified_size bytes (expect $combined_size)"
    exit 104
fi

if ! install -d -m0700 -o root -g root /root/bin/; then
  echo >&2 "unable to install the bin directory"
  exit 104
fi

if ! install -m500 -o root -g root -T "$extracted_file" /root/bin/hash_verified_install; then
  echo >&2 "unable to install the installer"
  exit 105
fi

install -m0500   || exit $?

# 3. Install payload with block size validation
/root/bin/hash_verified_install \
    "$PAYLOAD_HASH" \
    1024 \
    $(( (PAYLOAD_EXCESSIVE_SIZE + 1023) / 1024 )) \
    10 \
    "$PAYLOAD_URL" \
    "$PAYLOAD_INSTALL_PATH" || exit $?

if ! [[ -x "/root/bin/hash_verified_install" ]]; then
       echo >&2 "Installed tool is not executable"
       exit 106
   fi

 exec "$PAYLOAD_INSTALL_PATH"
'
