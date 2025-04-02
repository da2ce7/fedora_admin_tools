#!/usr/bin/env bash
# install-auto-groups-pam.sh
# Usage: ./install-auto-groups-pam.sh ADD_GROUPS_PAM_PATH GROUP1 [GROUP2...]

set -eo pipefail # Exit on error

[[ $# -lt 2 ]] && {
    echo "ERROR: Usage: $0 ADD_GROUPS_PAM_PATH GROUP1 [GROUP2...]" >&2
    exit 1
}

# Configuration
AUTHSELECT_PROFILE="custom/auto_groups"
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

# check if ADD_GROUPS_PAM_PATH exists
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

# Configure authselect profile
current_profile="$(authselect current --raw)"
if ! authselect list | grep -q "^${AUTHSELECT_PROFILE}$"; then
    echo "Creating authselect profile: ${AUTHSELECT_PROFILE}"
    authselect create-profile "${AUTHSELECT_PROFILE}" --base-on "$current_profile" >/dev/null || {
        echo "ERROR: Failed to create authselect profile" >&2
        exit 1
    }
fi

# Add PAM configuration
pam_file="/etc/authselect/${AUTHSELECT_PROFILE}/system-auth"
insert_line="session     optional      pam_exec.so ${ADD_GROUPS_PAM_PATH} ${TARGET_GROUPS[*]}"

if ! grep -qF "pam_exec.so ${ADD_GROUPS_PAM_PATH}" "$pam_file"; then
    echo "Updating PAM configuration in ${pam_file}"
    # Insert session line
    sed -i "/pam_limits.so/a ${insert_line}" "$pam_file" || {
        echo "ERROR: Failed to modify PAM config" >&2
        exit 1
    }
fi

# Apply authselect changes
echo "Applying authselect configuration"
authselect select "${AUTHSELECT_PROFILE}" with-sudo --force >/dev/null || {
    echo "ERROR: Failed to apply authselect profile" >&2
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

# Restart critical services (no reboot needed)
systemctl try-reload-or-restart systemd-logind.service >/dev/null 2>&1 || true

echo "Success! Configuration complete."
echo "New users will be added to groups: ${TARGET_GROUPS[*]} on first login"
