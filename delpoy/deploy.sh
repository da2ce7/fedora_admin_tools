bash -c '
set -Ceuox pipefail  # -e: exit on error, -u: fail on undefined var

# 1. Deploy hash_verified_install tool
install -d -m0700 -o root -g root /root/.sai || exit $?
temp_file=$(mktemp -p /root/.sai) || exit $?
trap '\''rm -f "$temp_file"'\'' EXIT

echo "$DEPLOY_DATA" | base64 -d | gunzip >| "$temp_file" || {
    echo >&2 "Decompression failed"; exit 1; }

sha256sum --strict -c <<< "$DEPLOY_DATA_HASH  $temp_file" || {
    echo >&2 "Hash validation failed"; exit 57; }

echo $DEPLOY_DATA_HASH

mkdir -p /root/bin && chmod 700 /root/bin
install -m 0500 -o root -g root -T "$temp_file" /root/bin/hash_verified_install

# 2. Use deployed tool to install payload
/root/bin/hash_verified_install \
    "$PAYLOAD_HASH" \
    1024\
    $(( (PAYLOAD_MAX_SIZE + 1023) / 1024 ))\
    10\
    "$PAYLOAD_URL" \
    "$PAYLOAD_INSTALL_PATH" || exit $?

# 3. Only execute if intended and executable
if [[ -x "$PAYLOAD_INSTALL_PATH" ]]; then
    "$PAYLOAD_INSTALL_PATH"
fi

echo "DONE"

sleep infinity
'
