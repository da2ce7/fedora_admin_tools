#!/bin/bash
# make_install_data.sh - Generate secure installation parameters from installer script
set -Ceuo pipefail

usage() {
    echo >&2 "Usage: $0 <path/to/installer.script>"
    exit 1
}

# Validate input
(($# != 1)) && usage
input_file="$1"

[[ -f "$input_file" && -r "$input_file" ]] || {
    echo >&2 "Error: Cannot read input file '$input_file'"
    exit 2
}

# Generate outputs in deterministic order
{
    xz -9e --stdout "$input_file" | \
    tee >(INST_BASE64=$(base64 -w0) && echo "INST_BASE64='$INST_BASE64'") \
        >(INST_COMP_HASH=$(sha256sum | cut -d' ' -f1) && echo "INST_COMP_HASH='$INST_COMP_HASH'") \
        >/dev/null
} 2>&1 | grep -P "INST_(BASE64|COMP_HASH)='" | sort -r
