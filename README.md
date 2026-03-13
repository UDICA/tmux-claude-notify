# tmux-claude-notify

Tmux popup notifications for Claude Code. Never miss a waiting permission prompt or completed task again.

## Problem

When running multiple Claude Code sessions across tmux windows/panes, permission prompts and task completions happen silently. You switch to another window and return minutes later only to find Claude was waiting for approval — or finished long ago.

## Solution

This plugin watches for Claude Code events and shows a tmux popup wherever you are. The popup displays a read-only preview of Claude's pane and lets you switch to it, snooze, or dismiss.

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
        "hooks": [
          {"type": "command", "command": "~/.tmux/plugins/tmux-claude-notify/scripts/notification-handler.sh"}
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {"type": "command", "command": "~/.tmux/plugins/tmux-claude-notify/scripts/notification-handler.sh"}
        ]
      }
    ]
  }
}
```

## How It Works

1. Claude Code fires a hook (Notification or Stop) when it needs attention or finishes a task
2. The handler reads JSON from stdin, walks the process tree to find the source tmux pane
3. A notification is queued and a tmux bell fires (cross-window alert)
4. A popup opens showing a read-only preview of Claude's pane
5. You choose: switch to Claude's window, snooze, or dismiss
6. If the notification comes from a pane in your current window, a brief status bar message is shown instead of a popup

## Popup Controls

| Key | Normal Mode | Snooze Mode |
|-----|-------------|-------------|
| Enter | Switch to Claude's window | Confirm snooze |
| s | Enter snooze mode | Cycle duration (30s → 60s → 2m → 5m → 10m → 30m) |
| Escape | Dismiss popup | Cancel snooze → normal mode |
| q | Dismiss popup | Cancel snooze → normal mode |

### Snooze

Press `s` to enter snooze mode, then `s` again to cycle through durations. Press Enter to confirm — the notification is re-queued after the timer expires.

## When Does the Popup Trigger?

| Event | Hook | What it means |
|-------|------|---------------|
| Permission prompt | Notification | Claude is blocked waiting for your approval |
| Task completion | Stop | Claude finished working — you can review and continue |
| Error/failure | Stop | Claude hit an error and stopped |

## Options

Configure in `~/.tmux.conf`:

```tmux
set -g @claude-notify-enabled 'on'           # Master toggle (default: on)
set -g @claude-notify-bell 'on'              # Ring tmux bell (default: on)
set -g @claude-notify-popup-width '80%'      # Popup width (default: 80%)
set -g @claude-notify-popup-height '60%'     # Popup height (default: 60%)
set -g @claude-notify-popup-border 'rounded' # Border style (default: rounded)
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

## Architecture

```
tmux-claude-notify/
├── claude-notify.tmux              # TPM entry point: sets defaults, keybinding, hooks
├── scripts/
│   ├── variables.sh                # Option names, defaults, path constants
│   ├── helpers.sh                  # Queue ops, locking, option reading, OS detection
│   ├── detect-pane.sh              # Process tree walker → finds source tmux pane
│   ├── notification-handler.sh     # Called by Claude Code hooks (reads JSON stdin)
│   ├── popup-manager.sh            # Single-instance queue consumer + popup lifecycle
│   ├── popup-interactive.sh        # Runs inside popup: read-only preview + actions
│   ├── status-count.sh             # Outputs pending count for status bar
│   └── setup.sh                    # Claude Code settings.json configuration
└── tests/
    └── ...                         # 49+ automated tests across 8 files
```

### Data Flow

```
Claude Code (pane %42)
  → Hook fires → notification-handler.sh
    → Reads JSON, walks PID tree → finds pane %42
    → Fixes copy mode if hook trigger caused it
    → Writes to file queue (/tmp/tmux-claude-notify-<uid>-<server_pid>/)
    → Fires tmux bell
    → Launches popup-manager.sh (single instance)
      → Reads queue, opens display-popup (or status message if same window)
        → popup-interactive.sh shows read-only pane preview
        → User action: switch / snooze / dismiss
        → Next queued notification pops up
```

### Key Design Decisions

1. **Read-only popup** (not input forwarding) — avoids terminal state issues with Claude's TUI
2. **Intent files** (not exit codes) — `display-popup -E` always exits 0 to prevent escape sequence leakage
3. **Same-window detection** — shows a status bar message instead of a popup when Claude is in the current window, avoiding alternate screen buffer conflicts
4. **Copy mode workaround** — Claude's hook mechanism can trigger copy mode on the pane; the plugin detects and exits it automatically
5. **File-based queue** (not tmux options) — survives detach, handles concurrent access
6. **Process tree walking** (not PID registration) — zero-configuration pane detection
7. **tmux bell** (not platform-specific sounds) — portable, terminal handles the actual sound
8. **`\x1f` delimiter** (not `|`) — ASCII Unit Separator cannot appear in tool inputs

## Running Tests

Run the full test suite:

```bash
bash tests/run_all.sh
```

Filter to specific tests:

```bash
bash tests/run_all.sh --filter unit         # only unit tests
bash tests/run_all.sh --filter phase1       # only phase 1
bash tests/run_all.sh --filter integration  # only integration tests
```

All tests use isolated tmux servers and never touch the user's live session.

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

## License

MIT
