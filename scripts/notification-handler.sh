#!/usr/bin/env bash
# notification-handler.sh — Called by Claude Code hooks (Notification/Stop)
#
# Reads JSON from stdin, detects source pane, queues notification,
# fires bell alert, and launches popup-manager if needed.
#
# Usage (in Claude Code hooks config):
#   notification-handler.sh    (reads JSON from stdin)
#   notification-handler.sh --test '{"type":"permission","message":"Allow?"}'

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"
source "${SCRIPT_DIR}/detect-pane.sh"

# Check if plugin is enabled
if ! is_enabled; then
    exit 0
fi

# --- Read JSON input ---

json_input=""
if [[ "${1:-}" == "--test" ]]; then
    # Test mode: JSON passed as argument
    json_input="${2:-}"
elif [[ ! -t 0 ]]; then
    # Normal mode: read from stdin
    json_input=$(cat)
fi

if [[ -z "$json_input" ]]; then
    log_debug "notification-handler: no JSON input received"
    exit 1
fi

# --- Parse JSON ---

# Extract fields using jq
event_type=$(echo "$json_input" | jq -r '.type // "unknown"' 2>/dev/null)
session_id=$(echo "$json_input" | jq -r '.session_id // .sessionId // "unknown"' 2>/dev/null)
message=$(echo "$json_input" | jq -r '.message // .title // .tool_name // "Notification"' 2>/dev/null)

# For permission/tool prompts, build a more descriptive message
tool_name=$(echo "$json_input" | jq -r '.tool_name // empty' 2>/dev/null || true)
if [[ -n "$tool_name" && "$tool_name" != "null" ]]; then
    tool_input=$(echo "$json_input" | jq -r '.tool_input // empty' 2>/dev/null | head -c 200 || true)
    if [[ -n "$tool_input" && "$tool_input" != "null" ]]; then
        message="${tool_name}: ${tool_input}"
    else
        message="$tool_name"
    fi
fi

log_debug "notification-handler: type=$event_type session=$session_id message=$message"

# --- Detect source pane ---

pane_id=$(detect_pane)
if [[ -z "$pane_id" ]]; then
    log_debug "notification-handler: could not detect source pane"
    # Fall back to the active pane as last resort
    pane_id=$(tmux display-message -p '#{pane_id}' 2>/dev/null || echo "")
    if [[ -z "$pane_id" ]]; then
        log_debug "notification-handler: no pane available at all, exiting"
        exit 1
    fi
fi

log_debug "notification-handler: detected pane=$pane_id"

# --- Queue the notification ---

queue_push "$pane_id" "$event_type" "$session_id" "$message"

# --- Fire bell alert ---

bell_on=$(get_option "$OPTION_BELL" "$DEFAULT_BELL")
if [[ "$bell_on" == "on" ]]; then
    tmux run-shell -t "$pane_id" "printf '\\a'" 2>/dev/null || true
fi

# --- Fix copy mode caused by hook invocation ---
# Claude Code's hook mechanism can put the pane into copy mode.
# Detect and exit it so the user sees a normal pane when they switch.
(
    sleep 0.5
    in_mode=$(tmux display-message -t "$pane_id" -p '#{pane_in_mode}' 2>/dev/null || echo "0")
    if [[ "$in_mode" == "1" ]]; then
        tmux send-keys -t "$pane_id" q 2>/dev/null || true
        log_debug "notification-handler: exited copy mode on pane $pane_id"
    fi
) &

# --- Launch popup manager if not running ---

if ! is_popup_manager_running; then
    log_debug "notification-handler: launching popup-manager"
    # Use tmux run-shell so popup-manager has client context for display-popup
    # (nohup/disown detaches from the client, causing display-popup to fail)
    tmux run-shell -b "bash '${SCRIPT_DIR}/popup-manager.sh'" 2>/dev/null || {
        # Fallback to nohup if tmux run-shell fails
        nohup bash "${SCRIPT_DIR}/popup-manager.sh" </dev/null >/dev/null 2>&1 &
        disown
    }
fi
