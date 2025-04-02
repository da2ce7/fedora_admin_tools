#!/usr/bin/env bash
# /usr/local/bin/add-groups-pam.sh
# Automatically add users with UID ≥1000 to specified groups on first login
# PAM configuration: session optional pam_exec.so add-groups-pam.sh group1 group2...

set -Ceuo pipefail  # Strict mode: Catch errors early
readonly MIN_UID=1000
readonly TARGET_GROUPS=("$@")  # Capture all groups from arguments

log() {
  local priority="${1:-info}"
  logger -t "pam_auto_group" -p "user.${priority}" "${*:2}"
}

validate_pam_env() {
  [[ "$PAM_TYPE" == 'open_session' ]] || return 1
  [[ -n "${PAM_USER:-}" ]] || { log err 'Missing PAM_USER'; return 1; }
}

user_in_all_groups() {
  local user="$1"
  local existing_groups
  existing_groups=$(id -nG "$user" 2>/dev/null || echo "")
  for group in "${TARGET_GROUPS[@]}"; do
    if ! grep -qwF "$group" <<< "$existing_groups"; then
      return 1  # User is missing at least one group
    fi
  done
  return 0  # User has all groups
}

main() {
  validate_pam_env || return 0  # Skip non-session operations
  [[ ${#TARGET_GROUPS[@]} -gt 0 ]] || { log err "No target groups specified"; return 1; }

  local user="${PAM_USER:?}"
  local current_uid
  current_uid=$(id -u "$user" 2>/dev/null) || { log notice "Invalid user: $user"; return 0; }

  (( current_uid >= MIN_UID )) || return 0  # Skip system users

  if user_in_all_groups "$user"; then
    log debug "User $user already in all groups: ${TARGET_GROUPS[*]}"
    return 0
  fi

  # Add to missing groups
  if usermod -aG "$(IFS=,; echo "${TARGET_GROUPS[*]}")" "$user"; then
    log notice "Added $user to groups: ${TARGET_GROUPS[*]} (UID: $current_uid)"
  else
    log err "Failed to add $user to ${TARGET_GROUPS[*]}"
    return 1
  fi
}

declare -i exit_code=0
main || exit_code=$?
(( exit_code )) && log err "Script exited with code $exit_code"
exit "$exit_code"
