#!/usr/bin/env bash
# test_component.sh — Component tests for popup-interactive.sh and related scripts

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_SOCKET="test-cn-comp-$$"
WRAPPER_DIR="/tmp/tmux-wrapper-comp-$$"
SENDKEYS_LOG="/tmp/tmux-sendkeys-$$"
mkdir -p "$WRAPPER_DIR"
cat > "$WRAPPER_DIR/tmux" <<WRAP
#!/bin/bash
# Log send-keys calls for test verification
if [[ "\$1" == "send-keys" ]]; then
    echo "send-keys \$*" >> "$SENDKEYS_LOG"
fi
exec /usr/bin/tmux -L "$TEST_SOCKET" "\$@"
WRAP
chmod +x "$WRAPPER_DIR/tmux"
export PATH="$WRAPPER_DIR:$PATH"

CANARY="/tmp/test-canary-$$"
POPUP_IN="/tmp/popup-stdin-$$"
POPUP_OUT="/tmp/popup-out-$$"

cleanup() {
    pkill -f "popup-interactive.sh" 2>/dev/null || true
    pkill -f "popup-manager.sh" 2>/dev/null || true
    tmux kill-server 2>/dev/null || true
    rm -rf "/tmp/tmux-claude-notify-test-comp-$$" "$WRAPPER_DIR" \
           "$CANARY" "$POPUP_IN" "$POPUP_OUT" "$SENDKEYS_LOG"
}
trap cleanup EXIT

tmux new-session -d -s test -x 220 -y 50
sleep 0.3

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0

assert() {
    local desc="$1"; shift
    if eval "$*"; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC}: $desc"
        ((FAIL++))
    fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
        ((FAIL++))
    fi
}

# Poll helpers
poll_file() {
    local path="$1" timeout="${2:-5}" interval=0.5 elapsed=0
    while (( $(echo "$elapsed < $timeout" | bc -l) )); do
        [[ -f "$path" && -s "$path" ]] && return 0
        sleep "$interval"
        elapsed=$(echo "$elapsed + $interval" | bc -l)
    done
    return 1
}

poll_proc_exit() {
    local pid="$1" timeout="${2:-5}" interval=0.3 elapsed=0
    while (( $(echo "$elapsed < $timeout" | bc -l) )); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep "$interval"
        elapsed=$(echo "$elapsed + $interval" | bc -l)
    done
    return 1
}

export QUEUE_DIR="/tmp/tmux-claude-notify-test-comp-$$"
unset _VARIABLES_SH_LOADED
source "$PROJECT_DIR/scripts/helpers.sh"
export -n _VARIABLES_SH_LOADED
ensure_queue_dir

tmux set-option -g "$OPTION_ENABLED" "on"
tmux set-option -g "$OPTION_BELL" "off"
tmux set-option -g "$OPTION_REFRESH_INTERVAL" "0.5"

# Get the target pane and its TTY device
TARGET_PANE=$(tmux list-panes -t test -F '#{pane_id}' | head -1)
TARGET_TTY=$(tmux display-message -t "$TARGET_PANE" -p '#{pane_tty}' 2>/dev/null)

echo "=== Component Tests ==="
echo ""

# Helper: write text to TARGET_PANE display via its TTY device
# Text appears in tmux capture-pane output for that pane
write_to_pane() {
    local tty_dev="$1" text="$2"
    if [[ -n "$tty_dev" && -e "$tty_dev" ]]; then
        printf '%s\n' "$text" > "$tty_dev"
        sleep 0.2
    fi
}

# Helper: launch popup-interactive with timed input via FIFO
# $1 = target pane, $2 = event type, $3 = message
# $4 = shell snippet generating input (piped to popup stdin)
# Sets POPUP_PID and WRITER_PID
launch_popup_with_input() {
    local target="$1" event="${2:-permission}" message="${3:-test}" input_cmd="${4:-sleep 10}"
    rm -f "$POPUP_IN" "$POPUP_OUT"
    mkfifo "$POPUP_IN"
    # Writer: background process that generates input then closes FIFO
    eval "($input_cmd) > '$POPUP_IN'" &
    WRITER_PID=$!
    # Launch popup with FIFO as stdin
    bash "$PROJECT_DIR/scripts/popup-interactive.sh" "$target" "$event" "$message" \
        < "$POPUP_IN" > "$POPUP_OUT" 2>&1 &
    POPUP_PID=$!
}

# Helper: cleanup after each popup test
cleanup_popup() {
    kill "$POPUP_PID" 2>/dev/null || true
    kill "$WRITER_PID" 2>/dev/null || true
    wait "$POPUP_PID" 2>/dev/null || true
    wait "$WRITER_PID" 2>/dev/null || true
    rm -f "$POPUP_IN" "$POPUP_OUT"
}

# ============================================================
# Test 1: Render test — popup-interactive renders target pane content
# ============================================================
echo "--- Test 1: Render test ---"

write_to_pane "$TARGET_TTY" "HELLO_MARKER_12345"

# Writer: hold FIFO open for 3s then send Escape
launch_popup_with_input "$TARGET_PANE" permission "render test" \
    "sleep 3; printf \$'\\\\e'"

sleep 2.0

# Check popup output for the marker (before it exits)
popup_out=$(cat "$POPUP_OUT" 2>/dev/null || true)
assert "popup-interactive renders target pane content" '[[ "$popup_out" == *"HELLO_MARKER_12345"* ]]'

cleanup_popup
sleep 0.3

# ============================================================
# Test 2: Enter key — writes "switch" intent file
# ============================================================
echo ""
echo "--- Test 2: Enter writes switch intent ---"

intent_file="${QUEUE_DIR}/popup-intent"
rm -f "$intent_file"

# Writer: wait 1.5s then send Enter
launch_popup_with_input "$TARGET_PANE" permission "enter test" \
    "sleep 1.5; printf \$'\\\\n'"

sleep 1.5
poll_proc_exit "$POPUP_PID" 4
wait "$POPUP_PID" 2>/dev/null

intent=$(cat "$intent_file" 2>/dev/null || echo "none")
assert "Enter key writes switch intent" '[[ "$intent" == "switch" ]]'
rm -f "$intent_file"

cleanup_popup

# ============================================================
# Test 3: Escape dismissal — Escape key exits popup-interactive
# ============================================================
echo ""
echo "--- Test 3: Escape dismissal ---"

# Writer: wait 1.5s then send Escape
launch_popup_with_input "$TARGET_PANE" permission "escape test" \
    "sleep 1.5; printf \$'\\\\e'"

sleep 1.5
# Popup should exit shortly after Escape is received
if poll_proc_exit "$POPUP_PID" 4; then
    echo -e "${GREEN}PASS${NC}: Escape dismissal exits popup-interactive"
    ((PASS++))
else
    echo -e "${RED}FAIL${NC}: Escape dismissal — popup-interactive still running"
    ((FAIL++))
fi

cleanup_popup

# ============================================================
# Test 4: q key — exits with code 0 (dismiss) and snooze mode
# ============================================================
echo ""
echo "--- Test 4: q dismiss and snooze Enter ---"

# Test q dismiss
launch_popup_with_input "$TARGET_PANE" permission "q test" \
    "sleep 1.5; printf 'q'"

sleep 1.5
poll_proc_exit "$POPUP_PID" 4
wait "$POPUP_PID" 2>/dev/null
q_exit=$?
assert "q key exits with code 0 (dismiss)" '[[ "$q_exit" -eq 0 ]]'

cleanup_popup
sleep 0.3

# Test snooze: press s then Enter → writes snooze intent
rm -f "$intent_file"
launch_popup_with_input "$TARGET_PANE" permission "snooze test" \
    "sleep 1.5; printf 's'; sleep 0.3; printf \$'\\\\n'"

sleep 2.5
poll_proc_exit "$POPUP_PID" 4
wait "$POPUP_PID" 2>/dev/null

intent=$(cat "$intent_file" 2>/dev/null || echo "none")
assert "s + Enter writes snooze intent" '[[ "$intent" == "snooze" ]]'
rm -f "$intent_file"

cleanup_popup

# ============================================================
# Test 5: Dead pane auto-close — popup exits when target pane dies
# ============================================================
echo ""
echo "--- Test 5: Dead pane auto-close ---"

# Create a temporary pane to target
tmux split-window -t test -v
sleep 0.3
TEMP_PANE=$(tmux list-panes -t test -F '#{pane_id}' | tail -1)

# Writer: keep popup open indefinitely (don't send Escape)
launch_popup_with_input "$TEMP_PANE" permission "dead pane test" "sleep 30"

sleep 1.5

# Kill the temp pane — popup checks on next render (which happens on
# the 10s read timeout). But _render also fails immediately when
# capture-pane can't find the pane, so the popup exits.
tmux kill-pane -t "$TEMP_PANE" 2>/dev/null || true
sleep 0.5

# Dead pane detection now happens on the 10s read timeout, so we
# need a longer poll window
if poll_proc_exit "$POPUP_PID" 15; then
    echo -e "${GREEN}PASS${NC}: popup-interactive auto-closes when target pane dies"
    ((PASS++))
else
    echo -e "${RED}FAIL${NC}: popup-interactive did not exit after target pane died"
    ((FAIL++))
fi

cleanup_popup

# ============================================================
# Test 6: Snooze file written on snooze exit
# ============================================================
echo ""
echo "--- Test 6: Snooze request file ---"

snooze_file="${QUEUE_DIR}/snooze-request"
rm -f "$snooze_file"

# Writer: press s (enter snooze mode), then s again (cycle to 60s), then Enter (confirm)
launch_popup_with_input "$TARGET_PANE" permission "snooze file test" \
    "sleep 1.5; printf 's'; sleep 0.3; printf 's'; sleep 0.3; printf \$'\\\\n'"

sleep 3.0
cleanup_popup

if [[ -f "$snooze_file" ]]; then
    snooze_val=$(cat "$snooze_file")
    assert "snooze request file written with 60s" '[[ "$snooze_val" -eq 60 ]]'
else
    echo -e "${RED}FAIL${NC}: snooze request file not created"
    ((FAIL++))
fi
rm -f "$snooze_file"

# ============================================================
# Test 7: Concurrent handlers — 3 simultaneous notification-handler.sh
# ============================================================
echo ""
echo "--- Test 7: Concurrent handlers ---"

# Drain queue first
while ! queue_is_empty; do queue_pop >/dev/null; done

# Prevent popup-manager from consuming entries by faking a running manager
# (use our own shell PID so kill-0 check in is_popup_manager_running succeeds)
echo "$$" > "$(_pid_file)"

# Fire 3 handlers simultaneously
echo '{"type":"permission","message":"test1"}' | bash "$PROJECT_DIR/scripts/notification-handler.sh" 2>/dev/null &
echo '{"type":"permission","message":"test2"}' | bash "$PROJECT_DIR/scripts/notification-handler.sh" 2>/dev/null &
echo '{"type":"permission","message":"test3"}' | bash "$PROJECT_DIR/scripts/notification-handler.sh" 2>/dev/null &
wait
sleep 0.5

count=$(queue_count)
assert "concurrent handlers: queue has 3 entries" '[[ "$count" -eq 3 ]]'

# All handlers should have seen the fake manager PID and not spawned new ones
mgr_count=$(pgrep -f "popup-manager.sh" 2>/dev/null | wc -l | tr -d ' ')
assert "concurrent handlers: at most 1 popup-manager running" '[[ "$mgr_count" -le 1 ]]'

# Clean up fake PID file and drain queue
rm -f "$(_pid_file)"
while ! queue_is_empty; do queue_pop >/dev/null; done
pkill -f "popup-manager.sh" 2>/dev/null || true
sleep 0.3

# ============================================================
# Test 8: Multi-entry manager — popup-manager processes all queued entries
# ============================================================
echo ""
echo "--- Test 8: Multi-entry manager ---"

# Drain queue first
while ! queue_is_empty; do queue_pop >/dev/null; done

# Push 3 entries directly into the queue
queue_push "$TARGET_PANE" "permission" "s1" "Allow entry 1?"
queue_push "$TARGET_PANE" "permission" "s2" "Allow entry 2?"
queue_push "$TARGET_PANE" "permission" "s3" "Allow entry 3?"

count_before=$(queue_count)
assert "multi-entry manager: 3 entries queued before run" '[[ "$count_before" -eq 3 ]]'

# Run popup-manager briefly — it will fail display-popup (no attached client)
# but should still pop and attempt all entries
bash "$PROJECT_DIR/scripts/popup-manager.sh" 2>/dev/null &
mgr_pid=$!
sleep 1.5
kill "$mgr_pid" 2>/dev/null || true
wait "$mgr_pid" 2>/dev/null || true
sleep 0.3

count_after=$(queue_count)
assert "multi-entry manager: queue consumed by popup-manager" '[[ "$count_after" -eq 0 ]]'

# ============================================================
# Test 9: Pane fallback — handler queues even without TMUX_PANE
# ============================================================
echo ""
echo "--- Test 9: Pane fallback ---"

# Drain queue first
while ! queue_is_empty; do queue_pop >/dev/null; done

# Fake a running manager so handler doesn't spawn one
echo "$$" > "$(_pid_file)"

# Run handler from current process context (process tree includes test tmux pane)
echo '{"type":"stop","message":"fallback test"}' \
    | bash "$PROJECT_DIR/scripts/notification-handler.sh" 2>/dev/null || true
sleep 0.3

count=$(queue_count)
assert "pane fallback: handler queues notification" '[[ "$count" -ge 1 ]]'

if [[ "$count" -ge 1 ]]; then
    entry=$(queue_pop)
    queued_pane=$(parse_pane_id "$entry")
    assert "pane fallback: queued entry has a non-empty pane ID" '[[ -n "$queued_pane" ]]'
fi

# Clean up
rm -f "$(_pid_file)"
while ! queue_is_empty; do queue_pop >/dev/null; done

# ============================================================
# Test 10: Bell firing — debug log written when bell+debug enabled
# ============================================================
echo ""
echo "--- Test 10: Bell firing + debug log ---"

# Drain queue first
while ! queue_is_empty; do queue_pop >/dev/null; done

# Fake a running manager so handler doesn't spawn one
echo "$$" > "$(_pid_file)"

# Enable bell and debug
tmux set-option -g "$OPTION_BELL" "on"
tmux set-option -g "$OPTION_DEBUG" "on"

DEBUG_LOG="$(_debug_log)"
rm -f "$DEBUG_LOG"

echo '{"type":"permission","message":"debug bell test"}' \
    | bash "$PROJECT_DIR/scripts/notification-handler.sh" 2>/dev/null || true
sleep 0.3

assert "bell+debug: debug.log has content" '[[ -f "$DEBUG_LOG" && -s "$DEBUG_LOG" ]]'

# Restore options
tmux set-option -g "$OPTION_BELL" "off"
tmux set-option -g "$OPTION_DEBUG" "off"
rm -f "$(_pid_file)"

# Drain queue
while ! queue_is_empty; do queue_pop >/dev/null; done

echo ""
echo "================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "================================"
exit "$FAIL"
