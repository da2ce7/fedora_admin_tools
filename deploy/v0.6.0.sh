bash -c '
#!/bin/bash
set -euox pipefail

# Configuration and validation
required_environment_vars=(
    INSTALLER_BASE64
    INSTALLER_COMPRESSED_HASH
    PAYLOAD_ACTUAL_HASH
    PAYLOAD_SOURCE_URL
    TARGET_INSTALL_PATH
    PAYLOAD_MAX_SIZE
)

for var in "${required_environment_vars[@]}"; do
    : "${!var:?Missing required environment variable $var}"
done

if [[ ! "$PAYLOAD_MAX_SIZE" =~ ^[0-9]+$ ]]; then
    echo >&2 "Invalid PAYLOAD_MAX_SIZE value"
    exit 105
fi

# Secure workspace setup
readonly WORKDIR="/root/.secure_installation"
readonly BIN_DIR="/root/bin"
readonly INSTALLER_SCRIPT_PATH="$BIN_DIR/verified_installer"

install -d -m0700 -o root -g root "$WORKDIR" || exit $?
compressed_installer_tempfile=$(mktemp -p "$WORKDIR") || exit $?
trap "rm -f -- \"$compressed_installer_tempfile\"" EXIT

# Installer deployment with integrity validation
printf "%s" "$INSTALLER_BASE64" | base64 -d > "$compressed_installer_tempfile" || {
    echo >&2 "Base64 decoding failed for installer"; exit 101; }

sha256sum --strict -c <<< "$INSTALLER_COMPRESSED_HASH  $compressed_installer_tempfile" || {
    echo >&2 "Installer checksum verification failed"; exit 102; }

# Secure installation directory setup
if ! install -d -m0700 -o root -g root "$BIN_DIR"; then
    echo >&2 "Failed to create secure bin directory"
    exit 104
fi

# Decompress and install verification tool
if ! xz -dT0 "$compressed_installer_tempfile" |
    install -C -m500 -o root -g root -T /dev/stdin "$INSTALLER_SCRIPT_PATH"
then
    pipeline_exit_code=$?
    [[ -f "$INSTALLER_SCRIPT_PATH" ]] && rm -f "$INSTALLER_SCRIPT_PATH"
    case $pipeline_exit_code in
        1) echo >&2 "Decompression failed: Stream integrity issues";;
        2) echo >&2 "I/O error during decompression pipeline";;
        127) echo >&2 "Storage failure during installation";;
        *) echo >&2 "Unexpected pipeline failure: $pipeline_exit_code";;
    esac
    exit 103
fi

# Final installer validation
if [[ ! -x "$INSTALLER_SCRIPT_PATH" ]]; then
    echo >&2 "Installer script permission validation failed"
    exit 106
fi

# Payload installation with size validation
"$INSTALLER_SCRIPT_PATH" \
    "$PAYLOAD_ACTUAL_HASH" \
    1 \
    $PAYLOAD_MAX_SIZE \
    10 \
    "$PAYLOAD_SOURCE_URL" \
    "$TARGET_INSTALL_PATH" || exit $?

if ! [[ -x "$TARGET_INSTALL_PATH" ]]; then
    echo >&2 "Installed payload executable check failed"
    exit 106
fi

exec "$TARGET_INSTALL_PATH"
'
