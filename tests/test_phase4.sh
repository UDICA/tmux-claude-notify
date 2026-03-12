#!/usr/bin/env bash
# test_phase4.sh — Tests for Phase 4: Interactive Popup System

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Isolated tmux server with PATH wrapper
TEST_SOCKET="test-cn-$$"
WRAPPER_DIR="/tmp/tmux-wrapper-$$"
mkdir -p "$WRAPPER_DIR"
cat > "$WRAPPER_DIR/tmux" <<WRAP
#!/bin/bash
exec /usr/bin/tmux -L "$TEST_SOCKET" "\$@"
WRAP
chmod +x "$WRAPPER_DIR/tmux"
export PATH="$WRAPPER_DIR:$PATH"

cleanup() {
    tmux kill-server 2>/dev/null || true
    rm -rf "/tmp/tmux-claude-notify-test-$$" "$WRAPPER_DIR"
}
trap cleanup EXIT

tmux new-session -d -s test -x 120 -y 40
sleep 0.3

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0

assert() {
    local desc="$1"
    shift
    if eval "$*"; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC}: $desc"
        ((FAIL++))
    fi
}

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}PASS${NC}: $desc"
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
        ((FAIL++))
    fi
}

echo "=== Phase 4 Tests: Popup System ==="
echo ""

# Set up test queue dir
export QUEUE_DIR="/tmp/tmux-claude-notify-test-$$"
unset _VARIABLES_SH_LOADED
source "$PROJECT_DIR/scripts/helpers.sh"
export -n _VARIABLES_SH_LOADED
ensure_queue_dir

tmux set-option -g "$OPTION_ENABLED" "on"
tmux set-option -g "$OPTION_BELL" "off"

# --- Test: status-count.sh ---
echo "--- status-count.sh ---"

# Empty queue → no output
output=$(bash "$PROJECT_DIR/scripts/status-count.sh" 2>/dev/null)
assert "status-count empty when no notifications" '[[ -z "$output" ]]'

# Push entries → shows count
queue_push "%0" "permission" "s1" "test1"
queue_push "%0" "permission" "s2" "test2"
output=$(bash "$PROJECT_DIR/scripts/status-count.sh" 2>/dev/null)
assert_eq "status-count shows 2" "2" "$output"

# Pop one → shows 1
queue_pop >/dev/null
output=$(bash "$PROJECT_DIR/scripts/status-count.sh" 2>/dev/null)
assert_eq "status-count shows 1 after pop" "1" "$output"

# Drain
queue_pop >/dev/null

# --- Test: popup-manager single instance ---
echo ""
echo "--- popup-manager single instance ---"

# Start manager in background (it will exit quickly since queue is empty)
bash "$PROJECT_DIR/scripts/popup-manager.sh" &
mgr_pid=$!
sleep 0.3

# Check PID file was created and cleaned up
# Manager exits immediately on empty queue, so PID file should be gone
wait "$mgr_pid" 2>/dev/null || true
pf="$(_pid_file)"
assert "popup-manager cleans up PID file on exit" '[[ ! -f "$pf" || ! -s "$pf" ]]'

# --- Test: popup-manager processes queue entries ---
echo ""
echo "--- Queue Processing ---"

# Get pane ID from test session
test_pane=$(tmux list-panes -t test -F '#{pane_id}' | head -1)

# Push a notification for a valid pane
queue_push "$test_pane" "permission" "s1" "Allow Bash?"
assert "entry queued" '! queue_is_empty'

# Run popup-manager — it will try to open display-popup, which will fail
# in this context (no real client), but it should still process the queue
bash "$PROJECT_DIR/scripts/popup-manager.sh" 2>/dev/null &
mgr_pid=$!
sleep 0.5
kill "$mgr_pid" 2>/dev/null || true
wait "$mgr_pid" 2>/dev/null || true

# Queue should have been consumed (popped by manager)
count=$(queue_count)
assert "queue consumed by popup-manager" '[[ "$count" -eq 0 ]]'

# --- Test: popup-manager --recheck mode ---
echo ""
echo "--- Recheck Mode ---"

# --recheck with no running manager should not crash
bash "$PROJECT_DIR/scripts/popup-manager.sh" --recheck 2>/dev/null
assert "recheck exits cleanly" '[[ $? -eq 0 ]]'

# --- Test: stale entry cleanup ---
echo ""
echo "--- Stale Entry Cleanup ---"

# Push an entry with an expired timestamp (manually write to queue file)
old_ts=$(($(date +%s) - 600))  # 10 minutes ago, TTL is 300
ensure_queue_dir
acquire_lock
echo "${old_ts}|%99|permission|s1|old entry" >> "$(_queue_file)"
release_lock

count_before=$(queue_count)
clean_stale_entries
count_after=$(queue_count)

assert "stale entry removed" '[[ "$count_after" -lt "$count_before" ]]'

# --- Test: resume detection heuristic ---
echo ""
echo "--- Resume Detection ---"

# Spinner pattern from popup-interactive.sh
local_spinner='[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]'

test_spinner='Some output ⠋ Processing...'
assert "spinner detected in text" 'echo "$test_spinner" | grep -qP "$local_spinner"'

test_no_spinner='Some output without spinner'
assert "no spinner in normal text" '! echo "$test_no_spinner" | grep -qP "$local_spinner"'

test_waiting='? Allow Bash tool? (y/n)'
assert "no spinner in permission prompt" '! echo "$test_waiting" | grep -qP "$local_spinner"'

echo ""
echo "================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "================================"

exit "$FAIL"
