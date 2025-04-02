#!/usr/bin/env bash
# install-auto-groups-pam.sh
# Usage: ./install-auto-groups-pam.sh ADD_GROUPS_PAM_PATH GROUP1 [GROUP2...]

set -eo pipefail # Exit on error

[[ $# -lt 2 ]] && {
    echo "ERROR: Usage: $0 ADD_GROUPS_PAM_PATH GROUP1 [GROUP2...]" >&2
    exit 1
}

# Configuration
FEATURE_NAME="auto-groups"
ADD_GROUPS_PAM_PATH="$1"
shift
TARGET_GROUPS=("$@") # Remaining arguments after script path

# Check dependencies
command -v authselect >/dev/null 2>&1 || {
    echo "ERROR: authselect not found. This script requires RHEL/CentOS/Fedora." >&2
    exit 1
}

# Validate root
[[ $EUID -eq 0 ]] || {
    echo "ERROR: Must be root to configure PAM policies" >&2
    exit 1
}

# Check if ADD_GROUPS_PAM_PATH exists
[[ -x "$ADD_GROUPS_PAM_PATH" ]] || {
    echo "ERROR: PAM helper script missing: $ADD_GROUPS_PAM_PATH" >&2
    exit 1
}

# Get target groups from args
[[ ${#TARGET_GROUPS[@]} -eq 0 ]] && {
    echo "ERROR: No groups specified" >&2
    exit 1
}

# Verify all groups exist
missing_groups=()
for group in "${TARGET_GROUPS[@]}"; do
    getent group "$group" >/dev/null || missing_groups+=("$group")
done
[[ ${#missing_groups[@]} -gt 0 ]] && {
    echo "ERROR: Missing system groups: ${missing_groups[*]}" >&2
    exit 1
}

# Create authselect feature directory
FEATURE_DIR="/etc/authselect/features/${FEATURE_NAME}"
echo "Creating authselect feature: ${FEATURE_NAME}"
mkdir -p "${FEATURE_DIR}"

# Create PAM configuration file for the feature
cat > "${FEATURE_DIR}/system-auth.pam" <<EOF
# Insert after pam_limits.so in session stack
type:        session
control:     optional
module:      pam_exec.so
options:     "${ADD_GROUPS_PAM_PATH} ${TARGET_GROUPS[*]}"
insert_after: .*/pam_limits\.so
EOF

# Apply the feature
echo "Applying authselect configuration"
current_profile=$(authselect current --raw | awk '{print $1}')
current_features=$(authselect current --raw | awk '{$1=""; print $0}' | xargs)

authselect select "${current_profile}" ${current_features} with-feature "${FEATURE_NAME}" with-sudo --force || {
    echo "ERROR: Failed to apply authselect feature" >&2
    exit 1
}

# SELinux context (if enabled)
if command -v selinuxenabled >/dev/null && selinuxenabled; then
    restorecon -v "$ADD_GROUPS_PAM_PATH"
fi

# Test configuration
echo "Running basic sanity check..."
if ! authselect test | grep -q 'PAM syntax check: OK'; then
    echo "CRITICAL: PAM validation failed:" >&2
    authselect test >&2
    exit 1
fi

# Restart critical services
systemctl try-reload-or-restart systemd-logind.service >/dev/null 2>&1 || true

echo "Success! Feature '${FEATURE_NAME}' installed."
echo "New users will be added to groups: ${TARGET_GROUPS[*]} on first login"
