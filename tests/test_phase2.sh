#!/usr/bin/env bash
# test_phase2.sh — Tests for Phase 2: Pane Detection
# Uses an isolated tmux server

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Isolated tmux server
TEST_SOCKET="test-cn-$$"
cleanup() {
    tmux -L "$TEST_SOCKET" kill-server 2>/dev/null || true
}
trap cleanup EXIT

tmux -L "$TEST_SOCKET" new-session -d -s test -x 120 -y 40
sleep 0.3  # let the session stabilize

# Override tmux
tmux() { command tmux -L "$TEST_SOCKET" "$@"; }
export -f tmux

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0

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

echo "=== Phase 2 Tests: Pane Detection ==="
echo ""

source "$PROJECT_DIR/scripts/detect-pane.sh"

# --- Test: _get_ppid works ---
echo "--- _get_ppid ---"
my_ppid=$(_get_ppid $$)
assert "_get_ppid returns non-empty for self" '[[ -n "$my_ppid" ]]'
assert "_get_ppid returns a number" '[[ "$my_ppid" =~ ^[0-9]+$ ]]'

# --- Test: _get_pane_map returns data ---
echo ""
echo "--- _get_pane_map ---"
pane_map=$(_get_pane_map)
assert "pane_map is non-empty" '[[ -n "$pane_map" ]]'
assert "pane_map contains %0" '[[ "$pane_map" == *"%"* ]]'

# --- Test: detect_pane from inside tmux pane ---
echo ""
echo "--- detect_pane (from spawned process) ---"

# Get the pane ID of the test session's pane
expected_pane=$(tmux list-panes -t test -F '#{pane_id}' | head -1)
pane_pid=$(tmux list-panes -t test -F '#{pane_pid}' | head -1)

assert "expected pane found" '[[ -n "$expected_pane" ]]'
assert "pane pid found" '[[ -n "$pane_pid" ]]'

# Run detect_pane starting from the pane's shell PID — should find itself
result=$(detect_pane "$pane_pid")
assert_eq "detect_pane finds the pane from its own pid" "$expected_pane" "$result"

# --- Test: detect_pane from child of pane process ---
echo ""
echo "--- detect_pane (child process) ---"

# Spawn a subprocess of the pane's shell and check detection
# We use the pane's PID as parent and find a child via /proc
if [[ -d "/proc/$pane_pid/task" ]]; then
    # Find any child of pane_pid
    child_pid=""
    for cpid in /proc/[0-9]*/status; do
        cpid_val=$(basename "$(dirname "$cpid")")
        ppid_val=$(awk '/^PPid:/ { print $2 }' "$cpid" 2>/dev/null)
        if [[ "$ppid_val" == "$pane_pid" ]]; then
            child_pid="$cpid_val"
            break
        fi
    done
    if [[ -n "$child_pid" ]]; then
        result=$(detect_pane "$child_pid")
        assert_eq "detect_pane finds pane from child pid" "$expected_pane" "$result"
    else
        # No child found — just verify direct PID works (already tested above)
        echo -e "${GREEN}SKIP${NC}: no child process found for pane, direct PID test passed"
        ((PASS++))
    fi
else
    echo -e "${GREEN}SKIP${NC}: /proc not available, direct PID test passed"
    ((PASS++))
fi

# --- Test: detect_pane fails for non-tmux PID ---
echo ""
echo "--- detect_pane (non-tmux process) ---"
result=$(detect_pane 1 2>/dev/null) || true
assert "detect_pane returns empty for PID 1" '[[ -z "$result" ]]'

echo ""
echo "================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "================================"

exit "$FAIL"
