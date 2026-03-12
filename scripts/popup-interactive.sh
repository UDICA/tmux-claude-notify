#!/usr/bin/env bash
# popup-interactive.sh — Runs inside tmux display-popup
#
# Captures target pane content (with colors) at regular intervals,
# displays it in the popup, and accepts user input at the bottom.
#
# Usage: popup-interactive.sh <pane_id> <event_type> <message>
#
# Controls:
#   Enter       — send typed line to target pane
#   Escape      — dismiss popup
#   Digits 1-9  — quick approve (type digit + Enter)
#
# Auto-close: detects Claude spinner chars → Claude resumed → closes popup

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

TARGET_PANE="${1:-}"
EVENT_TYPE="${2:-unknown}"
MESSAGE="${3:-Notification}"

if [[ -z "$TARGET_PANE" ]]; then
    echo "Usage: popup-interactive.sh <pane_id> [event_type] [message]"
    exit 1
fi

# Read options
REFRESH_INTERVAL=$(get_option "$OPTION_REFRESH_INTERVAL" "$DEFAULT_REFRESH_INTERVAL")

# Spinner characters indicating Claude is working (not waiting for input)
SPINNER_CHARS=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

# State
LINE_BUFFER=""
LAST_CAPTURE=""

# --- Display Functions ---

_get_terminal_size() {
    local rows cols
    rows=$(tput lines 2>/dev/null || echo 24)
    cols=$(tput cols 2>/dev/null || echo 80)
    echo "$rows $cols"
}

_render() {
    local rows cols
    read -r rows cols < <(_get_terminal_size)

    # Reserve lines: 1 for header, 1 for separator, 1 for input prompt, 1 for status
    local content_rows=$((rows - 4))
    if ((content_rows < 1)); then
        content_rows=1
    fi

    # Move cursor home (no screen clear — avoids flicker)
    printf '\033[H'

    # Header — show window name + pane index for identification
    local window_info
    window_info=$(tmux display-message -t "$TARGET_PANE" -p '#{window_name}:#{pane_index}' 2>/dev/null || echo "?:?")
    local header=" ${EVENT_TYPE} | ${window_info} (${TARGET_PANE}) "
    printf '\033[7m'  # reverse video
    printf "%-${cols}s" "$header"
    printf '\033[0m\n'

    # Capture target pane content (with ANSI colors)
    local capture
    capture=$(tmux capture-pane -t "$TARGET_PANE" -p -e -S "-${content_rows}" 2>/dev/null) || {
        printf '\033[2J\033[H'
        printf '\033[31mPane %s no longer exists\033[0m\n' "$TARGET_PANE"
        sleep 1
        exit 0
    }
    LAST_CAPTURE="$capture"

    # Display captured content (last N lines, each line padded to clear previous content)
    local line_num=0
    while IFS= read -r line; do
        printf '%s\033[K\n' "$line"
        ((line_num++))
    done < <(echo "$capture" | tail -n "$content_rows")
    # Clear any remaining lines from previous render
    while ((line_num < content_rows)); do
        printf '\033[K\n'
        ((line_num++))
    done

    # Move to bottom area
    printf '\033[%d;1H' "$((rows - 1))"

    # Separator
    printf '\033[90m'
    printf '%*s' "$cols" '' | tr ' ' '─'
    printf '\033[0m'

    # Input prompt
    printf '\033[%d;1H' "$rows"
    printf '\033[1m> \033[0m%s\033[K' "$LINE_BUFFER"
}

_check_pane_alive() {
    tmux display-message -t "$TARGET_PANE" -p '#{pane_id}' &>/dev/null
}

_check_resumed() {
    # Check if last capture contains spinner characters → Claude is working
    # Uses bash array + pattern matching (portable, no grep -P needed)
    if [[ -n "$LAST_CAPTURE" ]]; then
        local char
        for char in "${SPINNER_CHARS[@]}"; do
            if [[ "$LAST_CAPTURE" == *"$char"* ]]; then
                log_debug "popup-interactive: detected spinner, Claude resumed"
                return 0  # resumed
            fi
        done
    fi
    return 1  # not resumed
}

_send_line() {
    local line="$1"
    if [[ -n "$line" ]]; then
        # Send text + newline as a single literal string
        # Using -l with embedded newline avoids tmux interpreting "Enter"
        # as a key name (which can trigger copy-mode in vi-mode setups)
        tmux send-keys -t "$TARGET_PANE" -l "${line}
"
        log_debug "popup-interactive: sent line to $TARGET_PANE: $line"
    fi
}

# --- Signal handling ---

_cleanup() {
    clear_active_pane
    # Restore terminal
    printf '\033[?25h'  # show cursor
    tput cnorm 2>/dev/null || true
}
trap _cleanup EXIT

# --- Main Loop ---

# Mark this pane as active
set_active_pane "$TARGET_PANE"

# Show cursor
printf '\033[?25h'

# Initial render
_render

while true; do
    # Read a single character with timeout
    # IFS= prevents space/tab from being stripped by read
    if IFS= read -rsn1 -t "$REFRESH_INTERVAL" char; then
        case "$char" in
            $'\e')  # Escape key — dismiss popup
                log_debug "popup-interactive: dismissed by user"
                exit 0
                ;;
            $'\n'|'')  # Enter — send buffer
                if [[ -n "$LINE_BUFFER" ]]; then
                    _send_line "$LINE_BUFFER"
                    LINE_BUFFER=""
                fi
                ;;
            $'\x7f'|$'\b')  # Backspace
                if [[ -n "$LINE_BUFFER" ]]; then
                    LINE_BUFFER="${LINE_BUFFER%?}"
                fi
                ;;
            *)
                LINE_BUFFER+="$char"
                ;;
        esac
    fi

    # Refresh display
    if ! _check_pane_alive; then
        printf '\033[2J\033[H'
        printf '\033[31mPane %s no longer exists. Closing...\033[0m\n' "$TARGET_PANE"
        sleep 1
        exit 0
    fi

    _render

    # Check if Claude resumed (spinner detected)
    if _check_resumed; then
        printf '\033[2J\033[H'
        printf '\033[32mClaude resumed working. Auto-closing...\033[0m\n'
        sleep 0.5
        exit 0
    fi
done
