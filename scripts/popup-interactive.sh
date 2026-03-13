#!/usr/bin/env bash
# popup-interactive.sh — Runs inside tmux display-popup
#
# Shows a read-only preview of the target pane and offers actions:
#   Enter   — switch to Claude's window (exit 10)
#   Escape  — dismiss popup (exit 0)
#   q       — dismiss popup (exit 0)
#   s       — cycle snooze duration, Enter to confirm (exit 20)
#
# Usage: popup-interactive.sh <pane_id> <event_type> <message> [session_id]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

# --- Constants ---

SNOOZE_DURATIONS=(30 60 120 300 600 1800)
SNOOZE_LABELS=("30s" "60s" "2m" "5m" "10m" "30m")

# --- Functions ---

_render() {
    local target_pane="$1"
    local event_type="$2"
    local mode="$3"
    local snooze_index="$4"

    local rows cols
    rows=$(tput lines 2>/dev/null || echo 24)
    cols=$(tput cols 2>/dev/null || echo 80)

    # Reserve lines: 1 header, 1 separator, 1 action bar
    local content_rows=$((rows - 3))
    if ((content_rows < 1)); then
        content_rows=1
    fi

    # Clear screen and move home
    printf '\033[2J\033[H'

    # Header
    local window_info
    window_info=$(tmux display-message -t "$target_pane" -p '#{window_name}:#{pane_index}' 2>/dev/null || echo "?:?")
    local header=" ${event_type} | ${window_info} "
    printf '\033[7m%-*s\033[0m\n' "$cols" "$header"

    # Capture target pane content (with ANSI colors) — read-only snapshot
    local capture
    capture=$(tmux capture-pane -t "$target_pane" -p -e -S "-${content_rows}" 2>/dev/null) || {
        printf '\033[31mPane %s no longer exists\033[0m\n' "$target_pane"
        sleep 1
        return 1
    }

    # Display captured content
    local line_num=0
    while IFS= read -r line; do
        printf '%s\n' "$line"
        ((line_num++))
    done < <(echo "$capture" | tail -n "$content_rows")
    # Pad remaining lines
    while ((line_num < content_rows)); do
        printf '\n'
        ((line_num++))
    done

    # Separator
    printf '\033[90m'
    printf '%*s' "$cols" '' | tr ' ' '─'
    printf '\033[0m'

    # Action bar
    printf '\033[%d;1H' "$rows"
    if [[ "$mode" == "snooze" ]]; then
        printf '  Snooze: \033[1;33m%s\033[0m  [s] cycle  [Enter] confirm  [Esc] cancel' "${SNOOZE_LABELS[$snooze_index]}"
    else
        printf '  [Enter] Switch  [s] Snooze  [Esc/q] Dismiss'
    fi

    # Reset attributes at end to avoid leaking state
    printf '\033[0m'
}

_EXITING=0
_safe_exit() {
    # Guard against re-entry from EXIT trap
    if [[ "$_EXITING" -eq 1 ]]; then return; fi
    _EXITING=1
    local intent="$1"
    clear_active_pane
    # Write intent to file so popup-manager knows what to do.
    # The actual window switch is handled by popup-manager AFTER the popup
    # is fully closed, to avoid popup teardown interfering with the switch.
    if [[ "$intent" != "dismiss" ]]; then
        echo "$intent" > "${QUEUE_DIR}/popup-intent"
    fi
    printf '\033[0m\033[?25h\033[2J\033[H'
    tput cnorm 2>/dev/null || true
    exit 0
}

_write_snooze_request() {
    local seconds="$1"
    echo "$seconds" > "${QUEUE_DIR}/snooze-request"
    log_debug "popup-interactive: snooze request ${seconds}s written"
}

# --- Main ---

main() {
    local target_pane="${1:-}"
    local event_type="${2:-unknown}"
    local message="${3:-Notification}"
    local session_id="${4:-unknown}"

    # Export to global for _safe_exit to access
    _TARGET_PANE="$target_pane"

    if [[ -z "$target_pane" ]]; then
        echo "Usage: popup-interactive.sh <pane_id> [event_type] [message] [session_id]"
        exit 1
    fi

    trap '_safe_exit dismiss' EXIT

    set_active_pane "$target_pane"

    # Flush any buffered input from popup setup
    sleep 0.3
    while IFS= read -rsn1 -t 0.01 _discard; do :; done

    local mode="normal"
    local snooze_index=0

    # Render once
    _render "$target_pane" "$event_type" "$mode" "$snooze_index" || _safe_exit "dismiss"

    # Wait for input — no continuous refresh, no escape sequence output during wait
    while true; do
        local char=""
        if IFS= read -rsn1 -t 10 char; then
            case "$char" in
                $'\e')
                    # Distinguish standalone Escape from escape sequences
                    local seq=""
                    if IFS= read -rsn1 -t 0.05 next_char; then
                        seq="$next_char"
                        while IFS= read -rsn1 -t 0.01 extra; do
                            seq+="$extra"
                        done
                        log_debug "popup-interactive: ignored escape sequence: ESC+${seq}"
                    else
                        if [[ "$mode" == "snooze" ]]; then
                            mode="normal"
                            _render "$target_pane" "$event_type" "$mode" "$snooze_index" || _safe_exit "dismiss"
                        else
                            log_debug "popup-interactive: dismissed by user (Escape)"
                            _safe_exit "dismiss"
                        fi
                    fi
                    ;;
                $'\n'|'')  # Enter
                    if [[ "$mode" == "snooze" ]]; then
                        _write_snooze_request "${SNOOZE_DURATIONS[$snooze_index]}"
                        log_debug "popup-interactive: snooze confirmed (${SNOOZE_LABELS[$snooze_index]})"
                        _safe_exit "snooze"
                    else
                        log_debug "popup-interactive: switch to window (pane=$target_pane)"
                        _safe_exit "switch"
                    fi
                    ;;
                q)
                    if [[ "$mode" == "snooze" ]]; then
                        mode="normal"
                        _render "$target_pane" "$event_type" "$mode" "$snooze_index" || _safe_exit "dismiss"
                    else
                        log_debug "popup-interactive: dismissed by user (q)"
                        _safe_exit "dismiss"
                    fi
                    ;;
                s)
                    if [[ "$mode" == "normal" ]]; then
                        mode="snooze"
                        snooze_index=0
                    else
                        snooze_index=$(( (snooze_index + 1) % ${#SNOOZE_DURATIONS[@]} ))
                    fi
                    _render "$target_pane" "$event_type" "$mode" "$snooze_index" || _safe_exit "dismiss"
                    ;;
                *)
                    ;;
            esac
        else
            # Timeout (10s) — re-render to update preview and check pane alive
            if ! tmux display-message -t "$target_pane" -p '#{pane_id}' &>/dev/null; then
                log_debug "popup-interactive: pane $target_pane died"
                _safe_exit "dismiss"
            fi
            _render "$target_pane" "$event_type" "$mode" "$snooze_index" || _safe_exit "dismiss"
        fi
    done
}

main "$@"
