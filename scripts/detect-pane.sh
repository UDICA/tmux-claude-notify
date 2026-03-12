#!/usr/bin/env bash
# detect-pane.sh — Walks process tree to find the tmux pane that launched this script
#
# Claude Code hooks do NOT receive $TMUX_PANE. This script walks the process
# tree from its own PID upward, matching each ancestor against tmux's pane PIDs.
#
# Output: pane_id (e.g., %42) on stdout, or exit 1 if not found
# Max depth: 20 levels

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

MAX_DEPTH=20

# Get parent PID for a given PID
_get_ppid() {
    local pid="$1"
    local os
    os=$(get_os)

    if [[ "$os" == "linux" ]] && [[ -f "/proc/$pid/status" ]]; then
        # Linux/WSL: read from /proc
        awk '/^PPid:/ { print $2 }' "/proc/$pid/status" 2>/dev/null
    else
        # macOS or fallback: use ps
        ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' '
    fi
}

# Build a map of pane_pid -> pane_id from tmux
_get_pane_map() {
    tmux list-panes -a -F '#{pane_pid} #{pane_id}' 2>/dev/null
}

# Main detection logic
detect_pane() {
    local start_pid="${1:-$$}"
    local pane_map
    pane_map=$(_get_pane_map)

    if [[ -z "$pane_map" ]]; then
        log_debug "detect-pane: no tmux panes found"
        return 1
    fi

    local current_pid="$start_pid"
    local depth=0

    while (( depth < MAX_DEPTH )); do
        if [[ -z "$current_pid" ]] || [[ "$current_pid" == "0" ]] || [[ "$current_pid" == "1" ]]; then
            break
        fi

        # Check if this PID matches any tmux pane
        local match
        match=$(echo "$pane_map" | awk -v pid="$current_pid" '$1 == pid { print $2; exit }')

        if [[ -n "$match" ]]; then
            log_debug "detect-pane: found pane $match at depth $depth (pid $current_pid)"
            echo "$match"
            return 0
        fi

        # Walk up
        current_pid=$(_get_ppid "$current_pid")
        ((depth++))
    done

    log_debug "detect-pane: no matching pane found after $depth levels (start_pid=$start_pid)"
    return 1
}

# Run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    detect_pane "$@"
fi
