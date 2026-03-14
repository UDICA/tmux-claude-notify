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

        # If the target pane is in the currently visible window, don't show a popup.
        # display-popup on the same window can disrupt the pane's terminal state
        # (e.g., Claude Code's TUI alternate screen → copy mode).
        # Instead, show a brief tmux message — the user can already see Claude waiting.
        local pane_window_id current_window_id
        pane_window_id=$(tmux display-message -t "$pane_id" -p '#{window_id}' 2>/dev/null)
        current_window_id=$(tmux display-message -p '#{window_id}' 2>/dev/null)
        if [[ "$pane_window_id" == "$current_window_id" ]]; then
            log_debug "popup-manager: pane $pane_id is in current window, using message instead of popup"
            tmux display-message "Claude needs attention in pane ${pane_id} (${event_type})" 2>/dev/null || true
            # Exit copy mode if the hook trigger caused it
            sleep 0.5
            local in_mode_same
            in_mode_same=$(tmux display-message -t "$pane_id" -p '#{pane_in_mode}' 2>/dev/null || echo "0")
            if [[ "$in_mode_same" == "1" ]]; then
                tmux send-keys -t "$pane_id" q 2>/dev/null || true
                log_debug "popup-manager: exited copy mode on same-window pane $pane_id"
            fi
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

        # Find the most recently active client to display the popup on
        local target_client
        target_client=$(tmux list-clients -F '#{client_activity} #{client_name}' 2>/dev/null \
            | sort -rn | head -1 | cut -d' ' -f2-)

        # Open display-popup with interactive script
        # -E flag: close popup when the command exits
        # -c flag: target a specific client (avoids wrong-client failures)
        local popup_cmd="bash '${SCRIPT_DIR}/popup-interactive.sh' '${pane_id}' '${event_type}' '${message}' '${session_id}'"
        local intent_file="${QUEUE_DIR}/popup-intent"
        rm -f "$intent_file"

        if [[ -n "$target_client" ]]; then
            tmux display-popup -c "$target_client" \
                -w "$width" -h "$height" -b "$border" \
                -T "$popup_title" -E "$popup_cmd" \
                2>/dev/null || true
        else
            tmux display-popup \
                -w "$width" -h "$height" -b "$border" \
                -T "$popup_title" -E "$popup_cmd" \
                2>/dev/null || true
        fi

        # Read intent from file (popup always exits 0 to avoid escape leakage)
        local intent="dismiss"
        if [[ -f "$intent_file" ]]; then
            intent=$(cat "$intent_file")
            rm -f "$intent_file"
        fi

        case "$intent" in
            switch)
                # Switch after popup is fully closed to avoid teardown interference
                sleep 0.3
                # Exit copy mode if the hook trigger caused it
                local in_mode
                in_mode=$(tmux display-message -t "$pane_id" -p '#{pane_in_mode}' 2>/dev/null || echo "0")
                if [[ "$in_mode" == "1" ]]; then
                    tmux send-keys -t "$pane_id" q 2>/dev/null || true
                    log_debug "popup-manager: exited copy mode on pane $pane_id"
                    sleep 0.2
                fi
                local target_window
                target_window=$(tmux display-message -t "$pane_id" -p '#{session_name}:#{window_index}' 2>/dev/null || true)
                if [[ -n "$target_window" ]]; then
                    tmux select-window -t "$target_window" 2>/dev/null || true
                    tmux select-pane -t "$pane_id" 2>/dev/null || true
                fi
                log_debug "popup-manager: switched to $target_window pane $pane_id"
                ;;
            snooze)
                local snooze_file="${QUEUE_DIR}/snooze-request"
                local snooze_secs=30
                if [[ -f "$snooze_file" ]]; then
                    snooze_secs=$(cat "$snooze_file")
                    rm -f "$snooze_file"
                fi
                log_debug "popup-manager: snooze ${snooze_secs}s for pane $pane_id"
                (
                    sleep "$snooze_secs"
                    source "${SCRIPT_DIR}/helpers.sh"
                    queue_push "$pane_id" "$event_type" "$session_id" "$message"
                    tmux run-shell -b "bash '${SCRIPT_DIR}/popup-manager.sh'" 2>/dev/null || true
                ) &
                disown
                ;;
            *)
                log_debug "popup-manager: popup dismissed for pane=$pane_id"
                ;;
        esac

        # Popup closed — clear active pane and process next entry
        clear_active_pane

        # Brief pause between popups
        sleep 0.2
    done
}

_process_queue
