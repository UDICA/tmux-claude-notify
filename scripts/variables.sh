#!/usr/bin/env bash
# variables.sh — Option names, defaults, and path constants

# Source guard — prevent double-sourcing readonly errors
[[ -n "${_VARIABLES_SH_LOADED:-}" ]] && return 0
_VARIABLES_SH_LOADED=1

# Plugin option names (tmux user options)
readonly OPTION_ENABLED="@claude-notify-enabled"
readonly OPTION_BELL="@claude-notify-bell"
readonly OPTION_POPUP_WIDTH="@claude-notify-popup-width"
readonly OPTION_POPUP_HEIGHT="@claude-notify-popup-height"
readonly OPTION_POPUP_BORDER="@claude-notify-popup-border"
readonly OPTION_REFRESH_INTERVAL="@claude-notify-refresh-interval"
readonly OPTION_STALE_TTL="@claude-notify-stale-ttl"
readonly OPTION_DEBUG="@claude-notify-debug"

# Default values
readonly DEFAULT_ENABLED="on"
readonly DEFAULT_BELL="on"
readonly DEFAULT_POPUP_WIDTH="80%"
readonly DEFAULT_POPUP_HEIGHT="60%"
readonly DEFAULT_POPUP_BORDER="rounded"
readonly DEFAULT_REFRESH_INTERVAL="0.5"
readonly DEFAULT_STALE_TTL="300"
readonly DEFAULT_DEBUG="off"

# Queue directory — namespaced by UID and tmux server PID
_get_queue_dir() {
    local server_pid
    server_pid=$(tmux display-message -p '#{pid}' 2>/dev/null || echo "unknown")
    echo "/tmp/tmux-claude-notify-$(id -u)-${server_pid}"
}

# Path constants — NOT readonly so tests can override QUEUE_DIR
# Other scripts should treat these as read-only in production
QUEUE_DIR="${QUEUE_DIR:-$(_get_queue_dir)}"
QUEUE_FILE="${QUEUE_DIR}/queue"
LOCK_FILE="${QUEUE_DIR}/lock"
ACTIVE_FILE="${QUEUE_DIR}/active"
PID_FILE="${QUEUE_DIR}/popup-pid"
DEBUG_LOG="${QUEUE_DIR}/debug.log"

# Plugin directory (resolved relative to this script)
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="${PLUGIN_DIR}/scripts"
