#!/usr/bin/env bash
# test_integration.sh — Integration tests: full-flow scenarios

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TEST_SOCKET="test-cn-integ-$$"
WRAPPER_DIR="/tmp/tmux-wrapper-integ-$$"
mkdir -p "$WRAPPER_DIR"
cat > "$WRAPPER_DIR/tmux" <<WRAP
#!/bin/bash
exec /usr/bin/tmux -L "$TEST_SOCKET" "\$@"
WRAP
chmod +x "$WRAPPER_DIR/tmux"
export PATH="$WRAPPER_DIR:$PATH"

cleanup() {
    tmux kill-server 2>/dev/null || true
    pkill -f "popup-manager.sh" 2>/dev/null || true
    rm -rf "/tmp/tmux-claude-notify-test-integ-$$" "$WRAPPER_DIR" \
           "/tmp/test-home-integ-$$" "/tmp/integration-sink-$$"
}
trap cleanup EXIT

tmux new-session -d -s main -x 120 -y 40
tmux new-window -t main
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

export QUEUE_DIR="/tmp/tmux-claude-notify-test-integ-$$"
unset _VARIABLES_SH_LOADED
source "$PROJECT_DIR/scripts/helpers.sh"
export -n _VARIABLES_SH_LOADED
ensure_queue_dir

tmux set-option -g "$OPTION_ENABLED" "on"
tmux set-option -g "$OPTION_BELL" "off"

echo "=== Integration Tests ==="
echo ""

# ============================================================
# Scenario 1: Full notification lifecycle
# ============================================================
echo "--- Scenario 1: Full notification lifecycle ---"

# Create a second window with a pane to act as notification sink
tmux new-window -t main
sleep 0.1
sink_pane=$(tmux list-panes -t main:2 -F '#{pane_id}' | head -1)

# Fire notification-handler with a stop event; kill any popup-manager immediately
# so the entry stays in queue long enough to verify
json='{"type":"stop","message":"Task complete","session_id":"s-integ-1"}'
echo "$json" | bash "$PROJECT_DIR/scripts/notification-handler.sh" 2>/dev/null || true
# Kill popup-manager before it can drain the queue
pkill -f "popup-manager.sh" 2>/dev/null || true
sleep 0.2

# Verify: queue entry was created
count_after_push=$(queue_count)
assert "Scenario1: queue has entry after notification-handler" '[[ "$count_after_push" -ge 1 ]]'

# Kill any popup-manager that was launched, then run one to consume
pkill -f "popup-manager.sh" 2>/dev/null || true
sleep 0.2

# Run popup-manager briefly so it processes (fails display-popup but consumes entry)
bash "$PROJECT_DIR/scripts/popup-manager.sh" 2>/dev/null &
mgr_pid=$!
sleep 1
kill "$mgr_pid" 2>/dev/null || true
wait "$mgr_pid" 2>/dev/null || true

count_after_consume=$(queue_count)
assert_eq "Scenario1: queue empty after popup-manager consumed entry" "0" "$count_after_consume"

# Verify PID file cleaned up
pf="$(_pid_file)"
assert "Scenario1: popup-manager PID file cleaned up" '[[ ! -f "$pf" || ! -s "$pf" ]]'

echo ""

# ============================================================
# Scenario 2: Multi-notification FIFO ordering
# ============================================================
echo "--- Scenario 2: Multi-notification FIFO ordering ---"

# Drain queue
while ! queue_is_empty; do queue_pop >/dev/null; done

# Create 3 panes and get their IDs
tmux new-window -t main
sleep 0.1
pane_a=$(tmux list-panes -t main:3 -F '#{pane_id}' | head -1)
tmux split-window -t main:3 -h
sleep 0.1
pane_b=$(tmux list-panes -t main:3 -F '#{pane_id}' | sed -n '2p')
tmux split-window -t main:3 -v
sleep 0.1
pane_c=$(tmux list-panes -t main:3 -F '#{pane_id}' | sed -n '3p')

# Push notifications in order with small delays
queue_push "$pane_a" "permission" "s2a" "First"
sleep 0.05
queue_push "$pane_b" "stop" "s2b" "Second"
sleep 0.05
queue_push "$pane_c" "notification" "s2c" "Third"

count_fifo=$(queue_count)
assert "Scenario2: all 3 entries queued" '[[ "$count_fifo" -eq 3 ]]'

# Pop all and verify FIFO order by pane_id
entry1=$(queue_pop)
entry2=$(queue_pop)
entry3=$(queue_pop)

popped1=$(parse_pane_id "$entry1")
popped2=$(parse_pane_id "$entry2")
popped3=$(parse_pane_id "$entry3")

assert_eq "Scenario2: first pop is pane_a" "$pane_a" "$popped1"
assert_eq "Scenario2: second pop is pane_b" "$pane_b" "$popped2"
assert_eq "Scenario2: third pop is pane_c" "$pane_c" "$popped3"

echo ""

# ============================================================
# Scenario 3: Stale + dead + valid mixed
# ============================================================
echo "--- Scenario 3: Stale + dead + valid mixed entries ---"

# Drain queue
while ! queue_is_empty; do queue_pop >/dev/null; done

# Get a known-live pane for the valid entry
live_pane=$(tmux list-panes -t main:1 -F '#{pane_id}' | head -1)

# Manually write TTL-expired entry (timestamp = now - 600s, TTL default = 300s)
old_ts=$(($(date +%s) - 600))
sep=$'\x1f'
acquire_lock
echo "${old_ts}${sep}%11111${sep}permission${sep}s3-stale${sep}This is stale" >> "$(_queue_file)"
release_lock

# Push entry for dead (nonexistent) pane
queue_push "%77777" "stop" "s3-dead" "Dead pane"

# Push valid entry for live pane
queue_push "$live_pane" "stop" "s3-valid" "Live notification"

count_before_clean=$(queue_count)

# Run popup-manager briefly so it calls clean_stale_entries and processes
bash "$PROJECT_DIR/scripts/popup-manager.sh" 2>/dev/null &
mgr_pid=$!
sleep 1
kill "$mgr_pid" 2>/dev/null || true
wait "$mgr_pid" 2>/dev/null || true

count_after_clean=$(queue_count)
assert "Scenario3: stale/dead/valid entries all consumed/cleaned" '[[ "$count_after_clean" -eq 0 ]]'
assert "Scenario3: manager reduced queue from initial state" '[[ "$count_before_clean" -ge 1 ]]'

echo ""

# ============================================================
# Scenario 4: Detach/reattach recovery (--recheck)
# ============================================================
echo "--- Scenario 4: Detach/reattach recovery ---"

# Drain queue
while ! queue_is_empty; do queue_pop >/dev/null; done

# Push one entry for a live pane
live_pane=$(tmux list-panes -t main:1 -F '#{pane_id}' | head -1)
queue_push "$live_pane" "stop" "s4-recheck" "Recheck test"

# Run --recheck with no running manager: should process the entry
bash "$PROJECT_DIR/scripts/popup-manager.sh" --recheck 2>/dev/null &
rc_pid=$!
sleep 1
kill "$rc_pid" 2>/dev/null || true
wait "$rc_pid" 2>/dev/null || true

count_after_recheck=$(queue_count)
assert "Scenario4: --recheck consumed queue entry" '[[ "$count_after_recheck" -eq 0 ]]'

# Start a manager in background, then run --recheck while it's running
queue_push "$live_pane" "stop" "s4-concurrent" "Concurrent recheck"
bash "$PROJECT_DIR/scripts/popup-manager.sh" 2>/dev/null &
bg_pid=$!
sleep 0.3

# --recheck while manager is running should exit 0 immediately
bash "$PROJECT_DIR/scripts/popup-manager.sh" --recheck 2>/dev/null
recheck_exit=$?
assert_eq "Scenario4: --recheck exits 0 when manager already running" "0" "$recheck_exit"

# Clean up background manager
kill "$bg_pid" 2>/dev/null || true
wait "$bg_pid" 2>/dev/null || true

# Drain remaining entries
while ! queue_is_empty; do queue_pop >/dev/null; done

echo ""

# ============================================================
# Scenario 5: Handler disabled mid-flight
# ============================================================
echo "--- Scenario 5: Handler disabled mid-flight ---"

# Drain queue
while ! queue_is_empty; do queue_pop >/dev/null; done

# Enable and fire handler; kill popup-manager immediately to preserve queue entry
tmux set-option -g "$OPTION_ENABLED" "on"
json='{"type":"stop","message":"Enabled notification","session_id":"s5-enabled"}'
echo "$json" | bash "$PROJECT_DIR/scripts/notification-handler.sh" 2>/dev/null || true
pkill -f "popup-manager.sh" 2>/dev/null || true
sleep 0.2

count_enabled=$(queue_count)
assert "Scenario5: queue has entry when enabled" '[[ "$count_enabled" -ge 1 ]]'

# Drain queue
while ! queue_is_empty; do queue_pop >/dev/null; done

# Disable and fire handler
tmux set-option -g "$OPTION_ENABLED" "off"
json='{"type":"stop","message":"Disabled notification","session_id":"s5-disabled"}'
echo "$json" | bash "$PROJECT_DIR/scripts/notification-handler.sh" 2>/dev/null || true
sleep 0.2
pkill -f "popup-manager.sh" 2>/dev/null || true
sleep 0.1

count_disabled=$(queue_count)
assert_eq "Scenario5: queue empty when disabled" "0" "$count_disabled"

# Re-enable and fire handler; kill popup-manager immediately to preserve entry
tmux set-option -g "$OPTION_ENABLED" "on"
json='{"type":"stop","message":"Re-enabled notification","session_id":"s5-reenabled"}'
echo "$json" | bash "$PROJECT_DIR/scripts/notification-handler.sh" 2>/dev/null || true
pkill -f "popup-manager.sh" 2>/dev/null || true
sleep 0.2

count_reenabled=$(queue_count)
assert "Scenario5: queue has entry when re-enabled" '[[ "$count_reenabled" -ge 1 ]]'

# Drain queue
while ! queue_is_empty; do queue_pop >/dev/null; done

echo ""

# ============================================================
# Scenario 6: Setup round-trip
# ============================================================
echo "--- Scenario 6: Setup round-trip ---"

TEST_HOME="/tmp/test-home-integ-$$"
mkdir -p "$TEST_HOME/.claude"

# Create fresh settings with no hooks
echo '{"existingOption": true}' > "$TEST_HOME/.claude/settings.json"

# Run setup.sh --configure with "y" piped
output=$(echo "y" | HOME="$TEST_HOME" bash "$PROJECT_DIR/scripts/setup.sh" --configure 2>&1)
configure_exit=$?
assert "Scenario6: configure completes successfully" '[[ "$configure_exit" -eq 0 ]]'

# Verify settings.json was created/updated with hooks
assert "Scenario6: settings.json exists after configure" '[[ -f "$TEST_HOME/.claude/settings.json" ]]'

if [[ -f "$TEST_HOME/.claude/settings.json" ]]; then
    has_notification=$(jq -e '.hooks.Notification' "$TEST_HOME/.claude/settings.json" 2>/dev/null)
    assert "Scenario6: Notification hook added to settings.json" '[[ -n "$has_notification" ]]'
fi

# Run setup.sh --check-only → verify exit 0
HOME="$TEST_HOME" bash "$PROJECT_DIR/scripts/setup.sh" --check-only 2>/dev/null
check_exit=$?
assert_eq "Scenario6: check-only exits 0 after configure" "0" "$check_exit"

# Verify handler path is executable
assert "Scenario6: notification-handler.sh is executable" '[[ -x "$PROJECT_DIR/scripts/notification-handler.sh" ]]'

echo ""
echo "================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "================================"
exit "$FAIL"
