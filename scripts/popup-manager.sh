#!/usr/bin/env bash
# popup-manager.sh — Queue consumer + popup lifecycle loop
#
# Single-instance process that reads from the notification queue
# and opens tmux display-popup for each entry. When a popup closes,
# it processes the next queued entry.
#
# Usage:
#   popup-manager.sh             # Normal mode
#   popup-manager.sh --recheck   # Re-check queue (e.g., after reattach)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# --- Single-instance guard (atomic via lock) ---

_try_acquire_singleton() {
    # Atomic check-and-register under lock to prevent TOCTOU race
    acquire_lock
    if is_popup_manager_running; then
        release_lock
        return 1
    fi
    set_popup_manager_pid $$
    release_lock
    return 0
}

if [[ "${1:-}" == "--recheck" ]]; then
    if is_popup_manager_running; then
        log_debug "popup-manager: --recheck, manager already running"
        exit 0
    fi
fi

if ! _try_acquire_singleton; then
    log_debug "popup-manager: already running, exiting"
    exit 0
fi

_cleanup() {
    clear_popup_manager_pid
    clear_active_pane
    log_debug "popup-manager: exiting"
}
trap _cleanup EXIT

log_debug "popup-manager: started (pid=$$)"

# --- Main Queue Consumer Loop ---

_process_queue() {
    while true; do
        # Clean stale entries first
        clean_stale_entries

        # Check for next entry
        if queue_is_empty; then
            log_debug "popup-manager: queue empty, exiting"
            return 0
        fi

        local entry
        entry=$(queue_pop) || {
            log_debug "popup-manager: queue_pop failed"
            return 0
        }

        local pane_id event_type session_id message
        pane_id=$(parse_pane_id "$entry")
        event_type=$(parse_event_type "$entry")
        session_id=$(parse_session_id "$entry")
        message=$(parse_message "$entry")

        log_debug "popup-manager: processing pane=$pane_id type=$event_type"

        # Check if pane still exists
        if ! tmux display-message -t "$pane_id" -p '#{pane_id}' &>/dev/null; then
            log_debug "popup-manager: pane $pane_id is dead, skipping"
            continue
        fi

        # Read popup dimensions from options
        local width height border
        width=$(get_option "$OPTION_POPUP_WIDTH" "$DEFAULT_POPUP_WIDTH")
        height=$(get_option "$OPTION_POPUP_HEIGHT" "$DEFAULT_POPUP_HEIGHT")
        border=$(get_option "$OPTION_POPUP_BORDER" "$DEFAULT_POPUP_BORDER")

        # Resolve window name and pane index for a descriptive title
        local window_info
        window_info=$(tmux display-message -t "$pane_id" -p '#{window_name}:#{pane_index}' 2>/dev/null || echo "?:?")
        local popup_title=" Claude: ${event_type} | ${window_info} "

        # Open display-popup with interactive script
        # -E flag: close popup when the command exits
        # The popup runs popup-interactive.sh which handles capture/display/input
        tmux display-popup \
            -w "$width" \
            -h "$height" \
            -b "$border" \
            -T "$popup_title" \
            -E \
            "bash '${SCRIPT_DIR}/popup-interactive.sh' '${pane_id}' '${event_type}' '${message}'" \
            2>/dev/null || {
                log_debug "popup-manager: display-popup failed for pane=$pane_id"
            }

        # Popup closed — clear active pane and process next entry
        clear_active_pane

        # Brief pause between popups
        sleep 0.2
    done
}

_process_queue
