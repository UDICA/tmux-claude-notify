# tmux-claude-notify

Interactive tmux popups for Claude Code permission prompts. Never miss a waiting approval again.

## Problem

When running multiple Claude Code sessions across tmux windows/panes, permission prompts block silently. You switch to another window and return minutes later only to find Claude was waiting for approval the entire time.

## Solution

This plugin watches for Claude Code notifications and shows an interactive tmux popup wherever you are, letting you approve/respond without switching windows. When Claude resumes working, the popup auto-closes.

## Requirements

- tmux >= 3.2 (display-popup support)
- jq (JSON parsing)
- bash >= 4.0
- Claude Code with hooks support

## Installation

### With TPM (recommended)

Add to `~/.tmux.conf`:

```tmux
set -g @plugin 'your-username/tmux-claude-notify'
```

Then press `prefix + I` to install.

### Manual

```bash
git clone https://github.com/your-username/tmux-claude-notify ~/.tmux/plugins/tmux-claude-notify
```

Add to `~/.tmux.conf`:

```tmux
run-shell ~/.tmux/plugins/tmux-claude-notify/claude-notify.tmux
```

Reload tmux: `tmux source ~/.tmux.conf`

## Hook Configuration

The plugin needs Claude Code hooks to send notifications. Run the setup script:

```bash
~/.tmux/plugins/tmux-claude-notify/scripts/setup.sh --configure
```

This will:
1. Find your Claude Code `settings.json`
2. Back up existing settings
3. Add `Notification` and `Stop` hooks pointing to the plugin's handler

### Manual Hook Configuration

If you prefer, add these hooks to `~/.claude/settings.json` manually:

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "command": "~/.tmux/plugins/tmux-claude-notify/scripts/notification-handler.sh"
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "command": "~/.tmux/plugins/tmux-claude-notify/scripts/notification-handler.sh"
      }
    ]
  }
}
```

## How It Works

1. Claude Code fires a hook (Notification/Stop) when it needs attention
2. The handler reads JSON from stdin, walks the process tree to find the source tmux pane
3. A notification is queued and a tmux bell fires (cross-window alert)
4. An interactive popup opens showing the target pane's content
5. You type a response — it's sent to Claude via `send-keys`
6. When Claude resumes (spinner detected), the popup auto-closes
7. Next queued notification pops up automatically

## Popup Controls

| Key | Action |
|-----|--------|
| Type + Enter | Send text to Claude's pane |
| Escape | Dismiss popup |
| 1-9 + Enter | Quick number input (for menu selections) |
| Backspace | Delete last character |

## Options

Configure in `~/.tmux.conf`:

```tmux
set -g @claude-notify-enabled 'on'           # Master toggle (default: on)
set -g @claude-notify-bell 'on'              # Ring tmux bell (default: on)
set -g @claude-notify-popup-width '80%'      # Popup width (default: 80%)
set -g @claude-notify-popup-height '60%'     # Popup height (default: 60%)
set -g @claude-notify-popup-border 'rounded' # Border style (default: rounded)
set -g @claude-notify-refresh-interval '0.5' # Refresh rate in seconds (default: 0.5)
set -g @claude-notify-stale-ttl '300'        # Queue entry TTL in seconds (default: 300)
set -g @claude-notify-debug 'off'            # Debug logging (default: off)
```

## Status Bar Integration

Show pending notification count in your status bar:

```tmux
set -g status-right "#{?#{!=:#(~/.tmux/plugins/tmux-claude-notify/scripts/status-count.sh),},Claude: #(~/.tmux/plugins/tmux-claude-notify/scripts/status-count.sh) ,}..."
```

## Keybinding

The plugin binds `prefix + C-n` to manually trigger the popup manager (useful if a notification was missed).

## Troubleshooting

### Popup doesn't appear

1. Check hooks are configured: `cat ~/.claude/settings.json | jq .hooks`
2. Enable debug logging: `tmux set -g @claude-notify-debug on`
3. Check debug log: `cat /tmp/tmux-claude-notify-$(id -u)-*/debug.log`
4. Verify tmux version supports display-popup: `tmux display-popup echo test`

### Bell doesn't ring

- Ensure bell-action is set: `tmux show -g bell-action` (should be `any`)
- Check your terminal's bell settings (some terminals disable audible bell)

### Queue not clearing

- Check for stale entries: entries older than `@claude-notify-stale-ttl` are auto-cleaned
- Manually clear: `rm /tmp/tmux-claude-notify-$(id -u)-*/queue`

### Multiple tmux servers

Each tmux server gets its own queue directory (namespaced by server PID). No conflicts.

## Architecture

```
Claude Code (pane %42)
  → Hook fires → notification-handler.sh
    → Reads JSON, walks PID tree → finds pane %42
    → Writes to file queue (/tmp/tmux-claude-notify-<uid>-<pid>/)
    → Fires tmux bell
    → Launches popup-manager.sh
      → Reads queue, opens display-popup
        → popup-interactive.sh captures pane + handles input
        → Detects spinner → auto-closes
        → Next queued notification pops up
```

## License

MIT
