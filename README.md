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
5. You type a response -- it's sent to Claude via `send-keys`
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
│   ├── popup-interactive.sh        # Runs inside popup: capture/display/input loop
│   ├── status-count.sh             # Outputs pending count for status bar
│   └── setup.sh                    # Claude Code settings.json configuration
├── tests/
│   ├── run_all.sh                  # Test orchestrator (timeouts, filtering, reporting)
│   ├── test_phase1.sh              # Infrastructure: variables, helpers, queue, locking
│   ├── test_phase2.sh              # Pane detection: PID tree walking
│   ├── test_phase3.sh              # Notification handler: JSON parsing, queuing
│   ├── test_phase4.sh              # Popup system: manager lifecycle, spinner detection
│   ├── test_phase5.sh              # Setup: configuration modes, idempotency
│   ├── test_unit.sh                # Unit: macOS mocks, queue edge cases, spinners
│   ├── test_component.sh           # Component: TUI interaction, concurrent handlers
│   └── test_integration.sh         # Integration: full-flow scenarios
├── README.md
├── LICENSE
└── PLAN.md
```

### Data Flow

```
Claude Code (pane %42)
  → Hook fires → notification-handler.sh
    → Reads JSON, walks PID tree → finds pane %42
    → Writes to file queue (/tmp/tmux-claude-notify-<uid>-<server_pid>/)
    → Fires tmux bell
    → Launches popup-manager.sh (single instance)
      → Reads queue, opens display-popup
        → popup-interactive.sh captures pane + handles input
        → Detects spinner → auto-closes
        → Next queued notification pops up
```

### Component Details

**`variables.sh`** -- Central configuration. Defines all `@claude-notify-*` option names, their defaults, and derives the queue directory path from UID + tmux server PID. Path constants are non-readonly to allow test overrides.

**`helpers.sh`** -- Core library sourced by all scripts. Queue operations (`push`/`pop`/`peek`/`count`/`clean_stale_entries`), portable locking (`flock` on Linux, `mkdir`-based on macOS), option reading, field parsing, and debug logging. Queue format uses `\x1f` (ASCII Unit Separator) as the field delimiter -- chosen because it cannot appear in human-readable text or tool inputs, unlike `|` which appears in shell pipelines.

**`detect-pane.sh`** -- Solves a key problem: Claude Code hooks do not receive `$TMUX_PANE`. This script walks the process tree from its own PID upward (via `/proc` on Linux or `ps` on macOS), matching each ancestor against `tmux list-panes -a`, up to 20 levels deep. Can be sourced or run standalone.

**`notification-handler.sh`** -- Entry point called by Claude Code hooks. Reads JSON from stdin via `jq`, extracts event type and tool information, calls `detect_pane` (falling back to the active pane), pushes to the queue, fires a bell, and launches `popup-manager.sh` via `nohup`/`disown` if one isn't already running.

**`popup-manager.sh`** -- Single-instance queue consumer with an atomic singleton guard (check + PID write under the same lock to prevent TOCTOU races). Processes queue entries one at a time, opening `tmux display-popup -E` for each. Supports `--recheck` mode for the `after-client-attached` hook (handles detach/reattach recovery). Cleans stale entries (expired TTL, dead panes) on each cycle.

**`popup-interactive.sh`** -- Runs inside the popup. Single-process event loop using `read -rsn1 -t $interval`: on timeout, refreshes the display by capturing the target pane with ANSI colors; on input, accumulates characters in a line buffer. Enter sends the buffer via `tmux send-keys -l`. Escape dismisses. Auto-closes when spinner characters (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) are detected in the captured output, indicating Claude resumed working.

**`setup.sh`** -- Three modes: `--check-only` (silent, shows tmux message if hooks are unconfigured), `--configure` (interactive -- backs up settings.json, merges hooks via jq), `--show` (prints manual instructions).

### Queue Design

- **Directory**: `/tmp/tmux-claude-notify-<uid>-<server_pid>/`
- **Queue file**: `queue` -- one entry per line: `timestamp\x1fpane_id\x1fevent_type\x1fsession_id\x1fmessage`
- **Lock file**: `lock` -- `flock` (Linux) or `mkdir lock.d` (macOS)
- **Active file**: `active` -- pane_id of current popup
- **PID file**: `popup-pid` -- ensures single popup-manager instance
- Stale entries (dead panes, expired TTL) cleaned on every queue read

### Key Design Decisions

1. **Line-buffered input** (not char-by-char forwarding) -- prevents accidental input to Claude
2. **Single-process popup** (not dual-process) -- avoids output interleaving
3. **File-based queue** (not tmux options) -- survives detach, handles concurrent access
4. **Process tree walking** (not PID registration) -- zero-configuration pane detection
5. **`capture-pane` + `send-keys`** (not pane swapping) -- only viable approach for `display-popup`
6. **tmux bell** (not platform-specific sounds) -- portable, terminal handles the actual sound
7. **`\x1f` delimiter** (not `|`) -- ASCII Unit Separator cannot appear in tool inputs

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

All tests use isolated tmux servers (unique socket per test file) and never touch the user's live session. Each test file creates and destroys its own server.

### Test Coverage

126 automated tests across 8 files:

| File | Tests | Scope |
|------|-------|-------|
| test_phase1.sh | 29 | Variables, helpers, queue ops, locking, plugin load |
| test_phase2.sh | 9 | PID tree walking, pane detection |
| test_phase3.sh | 8 | JSON parsing, notification queuing, disabled plugin |
| test_phase4.sh | 11 | Popup manager, stale cleanup, spinner detection |
| test_phase5.sh | 14 | Setup modes, configure, check-only, idempotency |
| test_unit.sh | 21 | macOS locking/PID mocks, queue edge cases, special chars |
| test_component.sh | 15 | Popup TUI, concurrent handlers, bell, pane fallback |
| test_integration.sh | 19 | Full lifecycle, FIFO order, reattach, disable toggle |

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
