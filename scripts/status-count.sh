#!/usr/bin/env bash
# status-count.sh — Outputs pending notification count for tmux status bar
#
# Usage in tmux.conf:
#   set -g status-right "#(~/.tmux/plugins/tmux-claude-notify/scripts/status-count.sh)"
#
# Output: "N" if count > 0, empty string if 0 (for clean status bar)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh" 2>/dev/null

if ! is_enabled 2>/dev/null; then
    exit 0
fi

count=$(queue_count 2>/dev/null)
if [[ "$count" -gt 0 ]] 2>/dev/null; then
    echo "${count}"
fi
