#!/usr/bin/env bash
# /etc/profile.d/ssh-connection-agent.sh

set -Ceuo pipefail

ssh_agent_guard() {
    shopt -s huponexit 2>/dev/null

    local ssh_ppid session_id pgid

    # Capture critical process identifiers
    ssh_ppid=$(ps -o ppid= -p $$ | tr -d ' ') || return 1
    session_id=$(ps -o sid= -p $$ | tr -d ' ') || return 1
    pgid=$(ps -o pgid= -p $$ | tr -d ' ') || return 1

    if [[ -v container || -f /.dockerenv ]]; then
        echo >&2 "Container detected - agent confinement disabled"
        return 0
    fi

    # Set up isolated environment
    local agent_dir agent_sock agent_conf
    agent_dir=$(mktemp -d -p "$HOME/.ssh" ".agent-${session_id}-XXXXXX") || return 1
    chmod 700 "$agent_dir" || {
        rm -rf "$agent_dir"
        return 1
    }

    agent_sock="${agent_dir}/socket"
    agent_conf="${agent_dir}/config"

    # Configure agent isolation
    printf "Host *\n  IdentityAgent %s\n  IdentitiesOnly yes\n" "$agent_sock" >"$agent_conf" || {
        rm -rf "$agent_dir"
        return 1
    }
    chmod 600 "$agent_conf" || {
        rm -rf "$agent_dir"
        return 1
    }

    # Start agent with session-bound lifecycle
    SSH_AUTH_SOCK="$agent_sock"
    export SSH_AUTH_SOCK SSH_CONFIG="$agent_conf" SSH_AUTH_SOCK_ISOLATED=1

    if ! ssh-agent -s -a "$agent_sock" >/dev/null; then
        rm -rf "$agent_dir"
        return 1
    fi
    local agent_pid=$!

    # Session-bound monitoring (no activity checks)
    (
        while kill -0 "$ssh_ppid" 2>/dev/null && # SSH parent alive?
            kill -0 -"$pgid" 2>/dev/null; do     # Process group exists?
            sleep 10                             # Check every 10 seconds
        done

        # Cleanup when session terminates
        kill -TERM "$agent_pid" 2>/dev/null
        rm -rf "$agent_dir"
    ) &
    disown

    cleanup() {
        kill -TERM "$agent_pid" "$!" 2>/dev/null
        rm -rf "$agent_dir"
    }
    trap 'cleanup' EXIT HUP TERM INT QUIT ABRT

    return 0
}

if [[ -n "$SSH_TTY" && -t 0 && $- == *i* ]]; then
    if ((EUID == 0)); then
        # Privilege check
        echo >&2 "Agent confinement disabled for root"

    else
        # Dependency checks
        if ((${BASH_VERSINFO[0]} < 4 || (${BASH_VERSINFO[0]} == 4 && ${BASH_VERSINFO[1]} < 2))); then
            echo >&2 "Requires Bash >=4.2"
            exit 1
        fi

        # Security validation
        [[ ! -O "$SSH_TTY" ]] && {
            echo >&2 "TTY ownership mismatch"
            exit 1
        }

        # Socket validation
        if [[ -n "${SSH_AUTH_SOCK:-}" && ! -S "$SSH_AUTH_SOCK" ]]; then
            echo >&2 "Invalid SSH_AUTH_SOCK: $SSH_AUTH_SOCK"
            unset SSH_AUTH_SOCK
        fi

        # Process group check
        if ! kill -0 -$(ps -o pgid= -p $$ | tr -d ' ') 2>/dev/null; then
            echo >&2 "Process group validation failed"
            exit 1
        fi

        # Main guard
        if ! ssh_agent_guard; then
            echo >&2 "SSH agent confinement failed"
            exit 1
        fi

    fi
fi
