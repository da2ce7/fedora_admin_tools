#!/usr/bin/env bash
# /usr/local/bin/add-groups-pam.sh
# Automatically add users with UID ≥1000 to specified groups on first login
# Requires: PAM configuration: session optional pam_exec.so add-groups-pam.sh GROUP1 [GROUP2...]

set -Ceuo pipefail    # Strict mode: (C) No clobbering, (e) Exit on error, (u) Unset detection, (o pipefail) Pipeline errors
readonly MIN_UID=1000 # Minimum UID for user processing

# Configure syslog logging with priority handling
log() {
    local priority="${1:-notice}"
    logger -t "pam_auto_group" -p "user.${priority}" "${*:2}"
}

validate_environment() {
    # Verify PAM execution context
    [[ "$PAM_TYPE" == 'open_session' ]] || {
        log debug "Skipping non-session operation: $PAM_TYPE"
        return 1
    }
    [[ -n "${PAM_USER:-}" ]] || {
        log err "Missing PAM_USER variable"
        return 1
    }

    # Validate group arguments
    [[ ${#TARGET_GROUPS[@]} -gt 0 ]] || {
        log err "No target groups specified"
        return 1
    }

    # Verify group existence
    local missing_groups=()
    for group in "${TARGET_GROUPS[@]}"; do
        getent group "$group" >/dev/null || missing_groups+=("$group")
    done

    [[ ${#missing_groups[@]} -eq 0 ]] || {
        log err "Missing system groups: ${missing_groups[*]}"
        return 1
    }
}

user_requires_groups() {
    local user="$1"
    local current_groups
    current_groups=$(id -nG "$user" 2>/dev/null) || {
        log notice "Nonexistent user: $user"
        return 1
    }

    # Determine missing groups using pattern matching
    local missing_groups=()
    for group in "${TARGET_GROUPS[@]}"; do
        [[ "$current_groups" =~ (^|[[:space:]])$group($|[[:space:]]) ]] || missing_groups+=("$group")
    done

    [[ ${#missing_groups[@]} -gt 0 ]] && {
        printf '%s\n' "${missing_groups[@]}"
        return 0
    }
    return 1
}

main() {
    # Initial validation
    validate_environment || return 1

    local user="$PAM_USER"
    local current_uid
    current_uid=$(id -u "$user") || {
        log err "Failed to get UID for user: $user"
        return 1
    }

    # Skip system users
    ((current_uid >= MIN_UID)) || {
        log debug "Skipping system user: $user (UID: $current_uid)"
        return 0
    }

    # Find missing groups
    local missing_groups
    missing_groups=$(user_requires_groups "$user") || {
        log debug "User $user already in all groups: ${TARGET_GROUPS[*]}"
        return 0
    }

    # Add missing groups in single operation
    if usermod -aG "$(paste -sd, <<<"$missing_groups")" "$user"; then
        log notice "Added $user (UID:$current_uid) to groups: $(tr '\n' ' ' <<<"$missing_groups")"
    else
        log err "Failed to add $user to groups: $(tr '\n' ' ' <<<"$missing_groups")"
        return 1
    fi
}

# Handle PAM arguments safely
declare -a TARGET_GROUPS=()
for arg in "$@"; do
    [[ "$arg" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || {
        log err "Invalid group name: $arg"
        exit 1
    }
    TARGET_GROUPS+=("$arg")
done

if [ "$EUID" -ne 0 ]; then
    log err "Requires root privileges"
    exit 1
fi

if [ "$(id -ur)" != "$EUID" ]; then 
    logger -t pam_auto_group "UID/EUID mismatch"
    exit 1
fi

# Execution flow
declare -i exit_code=0
main || exit_code=$?

((exit_code == 0)) || log warning "Script exit code: $exit_code"
exit "$exit_code"
