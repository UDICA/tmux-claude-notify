# Comprehensive Test Plan for tmux-claude-notify

## Overview

A fully automated, layered test suite that closes all 13 identified coverage gaps in the tmux-claude-notify plugin. Includes a queue delimiter fix (`|` → `\x1f`) to resolve a real bug discovered during gap analysis. All tests run headless via `tests/run_all.sh` with no human interaction required.

## Prerequisites

- tmux >= 3.2
- jq
- bash >= 4.0
- All tests use isolated tmux servers (unique socket per test file) — never touch the user's live session

## Part 1: Delimiter Fix

### Problem

The queue format uses `|` as a field delimiter: `timestamp|pane_id|event_type|session_id|message`. Tool inputs from Claude Code regularly contain pipes (e.g., `cat file | grep pattern`), which corrupts `parse_message` and any downstream field parsing.

### Solution

Replace `|` with `\x1f` (ASCII Unit Separator, `$'\x1f'` in bash). This character:
- Is the ASCII character designed for delimiting fields in records
- Cannot appear in human-readable text or tool inputs
- Is supported by `cut -d` and all standard text utilities

### Files Changed

**`scripts/helpers.sh`:**
- `queue_push`: Change the `echo` line to use `$'\x1f'` between fields
- `parse_field`: Change `cut -d'|'` to `cut -d$'\x1f'`
- `clean_stale_entries`: Change `cut -d'|'` to `cut -d$'\x1f'`

**Existing test files (`tests/test_phase{1,3,4}.sh`):**
- Update any assertions that construct or match `|`-delimited queue lines to use `\x1f`
- Phase 2 and Phase 5 tests don't interact with the raw queue format and need no changes

**No changes to:**
- `notification-handler.sh` (calls `queue_push`, doesn't construct the format)
- `popup-manager.sh` (calls `parse_*` functions, doesn't parse directly)
- `popup-interactive.sh` (doesn't read the queue)
- `variables.sh`, `detect-pane.sh`, `setup.sh`, `status-count.sh`

## Part 2: Unit Test Layer (`tests/test_unit.sh`)

Tests individual functions in isolation. ~18 tests.

### macOS Mock Tests

**mkdir-based locking (4 tests):**
1. Override `_supports_flock() { return 1; }` → call `acquire_lock` → verify `lock.d` directory created
2. Call `release_lock` → verify `lock.d` directory removed
3. Background process tries `acquire_lock` while lock is held → verify it blocks (doesn't return immediately)
4. Release lock → verify background process acquires it within 1 second

**ps-based PID walk (2 tests):**
1. Call `_get_ppid $$` via `ps -o ppid=` path (by temporarily making `/proc/$$/status` inaccessible or overriding `get_os` to return `macos`) → verify result matches the real PPID
2. Verify result is numeric and non-empty

### Queue Edge Cases

**Dead-pane pruning (2 tests):**
1. Push entry for pane `%99999` (non-existent) → call `clean_stale_entries` → verify entry removed
2. Push 3 entries: one TTL-expired, one dead-pane, one valid → call `clean_stale_entries` → verify only valid entry survives

**Special characters in messages (2 tests):**
1. Push message containing `|`, `"`, `'`, backticks, dollar signs, spaces → pop → verify all fields parse correctly and message is intact
2. Push message `cat file | grep pattern | wc -l` → pop → verify message round-trips intact

### Spinner Detection (4 tests)

Source `popup-interactive.sh`'s spinner array definition, then test the matching logic directly:

1. Text containing `⠋` → detection returns 0 (resumed)
2. Plain text without spinners → detection returns 1 (not resumed)
3. Permission prompt `? Allow Bash tool? (y/n)` → detection returns 1
4. Text with ANSI escapes wrapping a spinner char (`\033[1m⠙\033[0m`) → detection returns 0

### status-count.sh Disabled (1 test)

1. Set `@claude-notify-enabled off` → run `status-count.sh` → verify empty output

### setup.sh Untested Branches (3 tests)

1. `--configure` with no existing `settings.json` → pipe "y" → verify file created from scratch with `.hooks.Notification` and `.hooks.Stop`
2. `--configure` user answers "n" → verify settings.json unchanged (or not created)
3. `--check-only` when hooks ARE configured → verify exit code 0 and no tmux display-message called (capture tmux messages via a wrapper or check exit silently)

## Part 3: Component Test Layer (`tests/test_component.sh`)

Tests each script end-to-end in a controlled tmux environment. ~10 tests.

### popup-interactive.sh Direct Invocation

Run `popup-interactive.sh` in a test pane (not inside `display-popup`), pointing at a separate target pane. Interact via `tmux send-keys` to the popup pane, verify via `tmux capture-pane`.

**Setup for each test:**
- Pane A (target): runs a known command
- Pane B (popup): runs `popup-interactive.sh <pane_A_id> permission "test"`
- Timing: allow 1-2 seconds for the popup script to start and render

**Tests:**

1. **Render test**: Target pane echoes `HELLO_MARKER_12345` → capture popup pane → verify marker appears in output
2. **Input forwarding**: Target pane runs `read line && echo "$line" > /tmp/test-canary-$$` → send "yes" + Enter to popup pane → wait → verify canary file contains "yes"
3. **Escape dismissal**: Send Escape key to popup pane → wait up to 2s → verify popup-interactive.sh process exited
4. **Backspace handling**: Target pane runs `read line && echo "$line" > /tmp/test-canary-$$` → send "abc" then Backspace then Enter to popup pane → verify canary contains "ab"
5. **Dead pane auto-close**: Kill target pane → verify popup-interactive.sh exits within 3 seconds
6. **Spinner auto-close**: Target pane echoes a spinner char `⠋` → verify popup-interactive.sh exits within 2 seconds (2 × refresh interval + buffer)

### Concurrent Notification Handlers (1 test)

7. Fire 3 `notification-handler.sh` processes simultaneously (pipe JSON, background each with `&`) → `wait` for all → verify queue has exactly 3 entries → verify only 1 popup-manager PID file exists (or 0 if manager already exited)

### Multi-Entry Popup Manager (1 test)

8. Push 3 entries for a valid pane → run `popup-manager.sh` → since `display-popup` fails without a real client, verify all 3 entries were consumed (queue empty)

### Notification Handler Pane Fallback (1 test)

9. Run `notification-handler.sh` from a context where `detect_pane` fails (e.g., set start PID to 1) → verify it falls back to the active pane and still queues successfully

### Bell Firing (1 test)

10. Set `@claude-notify-bell on` → push a notification via the handler → verify `tmux run-shell` was invoked for the target pane (check by monitoring the pane's bell flag or by capturing the handler's debug log with `@claude-notify-debug on`)

## Part 4: Integration Test Layer (`tests/test_integration.sh`)

Full-flow scenarios in a real tmux session with multiple panes/windows. 6 scenarios, ~15 assertions.

### Scenario 1: Full Notification Lifecycle

1. Create isolated tmux server with 2 windows
2. Window 1 pane runs `cat > /tmp/integration-sink-$$` (waits for input)
3. Pipe permission JSON to `notification-handler.sh` (with QUEUE_DIR set, PATH wrapper active)
4. Verify: queue entry created (queue_count >= 1)
5. Verify: popup-manager was launched (PID file exists or process running)
6. Popup-manager attempts `display-popup` which fails (no attached client) — verify entry was still consumed from queue

### Scenario 2: Multi-Notification FIFO Ordering

1. Create 3 panes
2. Push notifications for pane1, pane2, pane3 in order with small timestamp gaps
3. Pop all entries → verify pane IDs come out in push order (FIFO)

### Scenario 3: Stale + Dead + Valid Mixed Queue

1. Manually write a TTL-expired entry (timestamp = now - 600)
2. Push entry for a pane, then kill that pane
3. Push a valid entry for a live pane
4. Run `popup-manager.sh` → verify only 1 entry was processed (the valid one)
5. Verify queue is empty (stale and dead entries cleaned)

### Scenario 4: Detach/Reattach Recovery

1. Push a notification to the queue
2. Call `popup-manager.sh --recheck` → verify it processes the queue (entry consumed)
3. Start a popup-manager in the background, verify it's running (PID file exists)
4. Call `popup-manager.sh --recheck` → verify it exits immediately without starting a second instance

### Scenario 5: Handler Disabled Mid-Flight

1. Enable plugin, fire handler → verify queue count = 1
2. Drain queue
3. Disable plugin (`@claude-notify-enabled off`)
4. Fire handler → verify queue count still = 0
5. Re-enable plugin
6. Fire handler → verify queue count = 1

### Scenario 6: Setup Round-Trip

1. Create fresh `$TEST_HOME/.claude/` with no `settings.json`
2. Run `setup.sh --configure` with "y" piped → verify file created with hooks
3. Run `setup.sh --check-only` → verify exit 0, no warnings
4. Verify the configured handler path points to a real executable file

## Part 5: Test Runner (`tests/run_all.sh`)

### Behavior

- Runs all test files sequentially in a fixed order:
  1. `test_phase1.sh` through `test_phase5.sh` (existing)
  2. `test_unit.sh` (new)
  3. `test_component.sh` (new)
  4. `test_integration.sh` (new)
- Each test file creates and destroys its own isolated tmux server
- Captures pass/fail counts from each file's summary line (parses `N passed, M failed`)
- Prints aggregate table at the end
- Exits non-zero if any file had failures

### Arguments

- `--filter <pattern>` — run only test files matching the pattern (e.g., `--filter unit`, `--filter phase1`)
- No arguments — run all tests

### Timeout

- Each test file gets a 60-second timeout (`timeout 60 bash test_file.sh`)
- If a test hangs, it's killed and reported as a failure with "TIMEOUT" in the summary

### Output Format

```
=== tmux-claude-notify Test Suite ===

[1/8] test_phase1.sh ............ 29 passed, 0 failed
[2/8] test_phase2.sh ............  9 passed, 0 failed
[3/8] test_phase3.sh ............  8 passed, 0 failed
[4/8] test_phase4.sh ............ 11 passed, 0 failed
[5/8] test_phase5.sh ............ 14 passed, 0 failed
[6/8] test_unit.sh .............. 18 passed, 0 failed
[7/8] test_component.sh ......... 10 passed, 0 failed
[8/8] test_integration.sh ....... 15 passed, 0 failed

==========================================
TOTAL: 114 passed, 0 failed
==========================================
```

## Gap Coverage Matrix

| # | Gap | Covered By |
|---|-----|-----------|
| 1 | popup-interactive.sh untested | Component: 6 tests (render, input, escape, backspace, dead-pane, spinner) |
| 2 | macOS `_get_ppid` fallback | Unit: 2 mocked tests |
| 3 | Bell firing | Component: 1 test (debug log verification) |
| 4 | Pane fallback in handler | Component: 1 test |
| 5 | Dead-pane pruning in `clean_stale_entries` | Unit: 2 tests |
| 6 | Setup with no existing settings.json | Unit: 1 test |
| 7 | Setup abort path (user says "n") | Unit: 1 test |
| 8 | `after-client-attached` recheck | Integration scenario 4 |
| 9 | Concurrent handler invocations | Component: 1 test |
| 10 | Lock release ordering | Implicitly by concurrent tests |
| 11 | Messages with `|` (delimiter bug) | Fixed (`\x1f`) + Unit: 2 tests |
| 12 | status-count.sh when disabled | Unit: 1 test |
| 13 | Multi-entry popup-manager | Component: 1 test + Integration scenario 2 |

## Estimated Totals

- **Existing tests**: 71 (phases 1–5, updated for `\x1f` delimiter)
- **New tests**: ~43 (18 unit + 10 component + 15 integration)
- **Grand total**: ~114 automated tests
- **New files**: 4 (`test_unit.sh`, `test_component.sh`, `test_integration.sh`, `run_all.sh`)
- **Modified files**: 3 (`helpers.sh` delimiter fix, `test_phase1.sh`, `test_phase3.sh` delimiter assertions)
