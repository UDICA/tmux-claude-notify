#!/usr/bin/env bash
# claude-notify.tmux — TPM entry point for tmux-claude-notify

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
source "${CURRENT_DIR}/scripts/helpers.sh"

# Set default options
set_default_option "$OPTION_ENABLED" "$DEFAULT_ENABLED"
set_default_option "$OPTION_BELL" "$DEFAULT_BELL"
set_default_option "$OPTION_POPUP_WIDTH" "$DEFAULT_POPUP_WIDTH"
set_default_option "$OPTION_POPUP_HEIGHT" "$DEFAULT_POPUP_HEIGHT"
set_default_option "$OPTION_POPUP_BORDER" "$DEFAULT_POPUP_BORDER"
set_default_option "$OPTION_REFRESH_INTERVAL" "$DEFAULT_REFRESH_INTERVAL"
set_default_option "$OPTION_STALE_TTL" "$DEFAULT_STALE_TTL"
set_default_option "$OPTION_DEBUG" "$DEFAULT_DEBUG"

# Create queue directory
ensure_queue_dir

# Configure bell behavior for cross-window alerts
tmux set-option -g bell-action any
tmux set-option -g window-status-bell-style "fg=yellow,bg=red,bold"

# Keybinding: prefix + C-n to manually open popup manager
tmux bind-key C-n run-shell "${CURRENT_DIR}/scripts/popup-manager.sh"

# Hook: re-check queue on client attach (handles detach/reattach)
tmux set-hook -g after-client-attached "run-shell '${CURRENT_DIR}/scripts/popup-manager.sh --recheck'"

# Run setup check (silent — shows message only if unconfigured)
tmux run-shell "${CURRENT_DIR}/scripts/setup.sh --check-only"
