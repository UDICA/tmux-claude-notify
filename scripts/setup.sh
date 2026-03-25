#!/usr/bin/env bash
# setup.sh — Interactive Claude Code settings.json configuration
#
# Usage:
#   setup.sh --check-only    Silent check, shows tmux message if unconfigured
#   setup.sh --configure     Interactive setup: detect, backup, configure hooks
#   setup.sh --show          Show manual hook configuration instructions

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HANDLER_PATH="${SCRIPT_DIR}/notification-handler.sh"

# Claude Code settings locations
CLAUDE_SETTINGS_PATHS=(
    "$HOME/.claude/settings.json"
    "$HOME/.config/claude/settings.json"
)

# --- Helpers ---

_find_settings_file() {
    for path in "${CLAUDE_SETTINGS_PATHS[@]}"; do
        if [[ -f "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    return 1
}

_has_hook_configured() {
    local settings_file="$1"
    if [[ ! -f "$settings_file" ]]; then
        return 1
    fi
    # Check if our handler is already referenced in hooks
    # Supports both old format (.command at top level) and new format (.hooks[].command)
    jq -e '
        [
            (.hooks // {}) |
            to_entries[] |
            .value[] |
            (
                # New format: matcher + hooks array
                (.hooks // [] | .[].command // empty),
                # Old format: matcher + command
                (.command // empty)
            ) |
            test("notification-handler")
        ] | any
    ' "$settings_file" &>/dev/null
}

_show_manual_instructions() {
    cat <<MANUAL

  tmux-claude-notify — Manual Hook Configuration
  ================================================

  Add the following to your Claude Code settings.json
  (typically at ~/.claude/settings.json):

  {
    "hooks": {
      "Notification": [
        {
          "matcher": "",
          "hooks": [
            {"type": "command", "command": "${HANDLER_PATH}"}
          ]
        }
      ],
      "Stop": [
        {
          "matcher": "",
          "hooks": [
            {"type": "command", "command": "${HANDLER_PATH}"}
          ]
        }
      ]
    }
  }

  Notification: fires when Claude needs input (e.g. permission prompts)
  Stop: fires when Claude finishes a task or hits an error

  The handler reads JSON from stdin (provided by Claude Code)
  and creates tmux notifications automatically.

  If you already have hooks configured, merge the above
  into your existing hooks configuration.

MANUAL
}

# --- Modes ---

_check_only() {
    # Silent check — show tmux message if unconfigured
    local settings_file
    settings_file=$(_find_settings_file) || {
        tmux display-message -d 5000 \
            "tmux-claude-notify: No Claude Code settings found. Run: #{@claude-notify-plugin-dir}/scripts/setup.sh --configure" \
            2>/dev/null || true
        return 0
    }

    if ! _has_hook_configured "$settings_file"; then
        tmux display-message -d 5000 \
            "tmux-claude-notify: Hooks not configured. Run: ${PLUGIN_DIR}/scripts/setup.sh --configure" \
            2>/dev/null || true
    fi
}

_configure() {
    echo ""
    echo "  tmux-claude-notify — Setup"
    echo "  =========================="
    echo ""

    # 1. Find or create settings file
    local settings_file
    settings_file=$(_find_settings_file) || {
        settings_file="$HOME/.claude/settings.json"
        echo "  No Claude Code settings.json found."
        echo "  Will create: $settings_file"
        echo ""
    }

    echo "  Settings file: $settings_file"

    # 2. Check if hooks already configured
    if _has_hook_configured "$settings_file"; then
        echo "  Hooks already configured! Nothing to do."
        echo ""
        return 0
    fi

    # 3. Ask for confirmation
    echo ""
    echo "  This will add notification hooks to your Claude Code settings."
    echo "  Handler: $HANDLER_PATH"
    echo ""
    read -rp "  Proceed? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo ""
        echo "  Aborted. For manual setup, run: setup.sh --show"
        return 0
    fi

    # 4. Backup existing settings
    if [[ -f "$settings_file" ]]; then
        local backup="${settings_file}.bak.$(date +%s)"
        cp "$settings_file" "$backup"
        echo "  Backup saved: $backup"
    fi

    # 5. Merge hooks into settings
    local hooks_json
    hooks_json=$(cat <<HOOKS
{
  "Notification": [
    {
      "matcher": "",
      "hooks": [
        {"type": "command", "command": "${HANDLER_PATH}"}
      ]
    }
  ],
  "Stop": [
    {
      "matcher": "",
      "hooks": [
        {"type": "command", "command": "${HANDLER_PATH}"}
      ]
    }
  ]
}
HOOKS
)

    if [[ -f "$settings_file" ]]; then
        # Merge with existing settings
        local existing
        existing=$(cat "$settings_file")
        echo "$existing" | jq --argjson hooks "$hooks_json" '
            .hooks = ((.hooks // {}) * $hooks)
        ' > "$settings_file"
    else
        # Create new settings file
        mkdir -p "$(dirname "$settings_file")"
        echo "$hooks_json" | jq '{hooks: .}' > "$settings_file"
    fi

    echo ""
    echo "  Done! Hooks configured successfully."
    echo "  Claude Code will now send notifications to tmux-claude-notify."
    echo ""
}

# --- Main ---

case "${1:-}" in
    --check-only)
        _check_only
        ;;
    --configure)
        _configure
        ;;
    --show)
        _show_manual_instructions
        ;;
    *)
        echo "Usage: setup.sh [--check-only|--configure|--show]"
        echo ""
        echo "  --check-only  Silent check, shows tmux message if unconfigured"
        echo "  --configure   Interactive setup: detect, backup, configure hooks"
        echo "  --show        Show manual hook configuration instructions"
        exit 1
        ;;
esac
