#!/usr/bin/env bash
# test_phase3.sh — Tests for Phase 3: Notification Handler

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Isolated tmux server — use a PATH wrapper so all subprocesses use it
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

echo "=== Phase 3 Tests: Notification Handler ==="
echo ""

# Set up test queue dir
export QUEUE_DIR="/tmp/tmux-claude-notify-test-$$"
# Unset source guard for local sourcing, but don't export it
# so subprocesses get a clean start
unset _VARIABLES_SH_LOADED
source "$PROJECT_DIR/scripts/helpers.sh"
ensure_queue_dir
# Unexport _VARIABLES_SH_LOADED so handler subprocess sources variables.sh fresh
export -n _VARIABLES_SH_LOADED

# Set plugin as enabled
tmux set-option -g "$OPTION_ENABLED" "on"
tmux set-option -g "$OPTION_BELL" "off"

# --- Test: Handler processes JSON via stdin ---
echo "--- JSON Parsing ---"

json='{"type":"permission","session_id":"sess123","tool_name":"Bash","tool_input":"rm -rf /"}'
echo "$json" | bash "$PROJECT_DIR/scripts/notification-handler.sh" 2>/dev/null || true

count=$(queue_count)
assert "queue has entry after notification" '[[ "$count" -ge 1 ]]'

if [[ "$count" -ge 1 ]]; then
    entry=$(queue_pop)
    event=$(parse_event_type "$entry")
    msg=$(parse_message "$entry")
    assert_eq "event type parsed" "permission" "$event"
    assert "message contains tool name" '[[ "$msg" == *"Bash"* ]]'
    assert "message contains tool input" '[[ "$msg" == *"rm -rf"* ]]'
fi

# --- Test: Handler with simple message ---
echo ""
echo "--- Simple Message ---"

json='{"type":"stop","message":"Process completed"}'
echo "$json" | bash "$PROJECT_DIR/scripts/notification-handler.sh" 2>/dev/null || true

count=$(queue_count)
assert "queue has entry for stop event" '[[ "$count" -ge 1 ]]'

if [[ "$count" -ge 1 ]]; then
    entry=$(queue_pop)
    event=$(parse_event_type "$entry")
    assert_eq "stop event type" "stop" "$event"
fi

# --- Test: Handler does nothing when disabled ---
echo ""
echo "--- Disabled Plugin ---"

tmux set-option -g "$OPTION_ENABLED" "off"

while ! queue_is_empty; do queue_pop >/dev/null; done

json='{"type":"permission","message":"Should be ignored"}'
echo "$json" | bash "$PROJECT_DIR/scripts/notification-handler.sh" 2>/dev/null || true

assert "queue stays empty when disabled" queue_is_empty

tmux set-option -g "$OPTION_ENABLED" "on"

# --- Test: Handler handles empty input ---
echo ""
echo "--- Empty Input ---"
echo "" | bash "$PROJECT_DIR/scripts/notification-handler.sh" 2>/dev/null
exit_code=$?
assert "exits non-zero on empty input" '[[ "$exit_code" -ne 0 ]]'

echo ""
echo "================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "================================"

exit "$FAIL"
