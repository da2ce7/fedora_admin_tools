bash -c '
#!/bin/bash
set -euo pipefail

# Validate environment
req_env_vars=(
    INST_BASE64 INST_COMP_HASH
    PAYLOAD_HASH PAYLOAD_SOURCE_URL
)
for var in "${req_env_vars[@]}"; do : "${!var:?Missing $var}"; done

readonly WORKDIR="/root/.sai" BIN_DIR="/root/bin"
readonly INST_SCRIPT_PATH="$BIN_DIR/verified_installer"
readonly PAYLOAD_INSTALL_PATH="$BIN_DIR/payload"
install -d -m0700 -o root -g root "$WORKDIR" "$BIN_DIR" || exit $?

comp_inst_tempfile=$(mktemp -p "$WORKDIR") || exit $?
trap "rm -f -- \"$comp_inst_tempfile\"" EXIT

# Installer handling
base64 -d <<<"$INST_BASE64" >"$comp_inst_tempfile" || {
    echo >&2 "Base64 decode failed"
    exit 102
}
sha256sum --strict -c <<<"$INST_COMP_HASH  $comp_inst_tempfile" || {
    echo >&2 "Installer checksum mismatch"
    exit 103
}

xzcat -d "$comp_inst_tempfile" | install -C -m500 -o root -g root /dev/stdin \
    "$INST_SCRIPT_PATH" || {
    [[ -f "$INST_SCRIPT_PATH" ]] && rm -f "$INST_SCRIPT_PATH"
    case $? in
    1) msg="Decompression integrity error" ;;
    2) msg="I/O error during decompression" ;;
    127) msg="Storage failure" ;;
    *) msg="Unexpected pipeline failure" ;;
    esac
    echo >&2 "$msg"
    exit 104
}

[[ -x "$INST_SCRIPT_PATH" ]] || {
    echo >&2 "Permission error"
    exit 105
}

sha256sum "$INST_SCRIPT_PATH"

"$INST_SCRIPT_PATH" "$PAYLOAD_HASH" 1 10 \
    "$PAYLOAD_SOURCE_URL" PAYLOAD_INSTALL_PATH
[[ -x "$PAYLOAD_INSTALL_PATH" ]] || {
    echo >&2 "Payload validation failed"
    exit 106
}

if LD_PRELOAD="" stdbuf -oL -eL "$PAYLOAD_INSTALL_PATH" "$INST_SCRIPT_PATH" >/proc/1/fd/1 2>/proc/1/fd/2; then
    echo "Payload completed successfully" >/proc/1/fd/1
else
    EXIT_CODE=$?
    echo "Payload failed (exit $EXIT_CODE)" >/proc/1/fd/2
    exit $EXIT_CODE
fi

trap "echo rcv\ shutdown\ signal; exit 0" TERM HUP INT QUIT

while true; do
    sleep 365d &
    wait $!
done
'
