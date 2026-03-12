#!/usr/bin/env bash
# test_phase1.sh — Tests for Phase 1: Skeleton and Infrastructure
# Uses an isolated tmux server to avoid affecting the user's session

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Isolated tmux server
TEST_SOCKET="test-cn-$$"
cleanup() {
    tmux -L "$TEST_SOCKET" kill-server 2>/dev/null || true
    rm -rf "/tmp/tmux-claude-notify-test-$$"
}
trap cleanup EXIT

# Start isolated tmux server
tmux -L "$TEST_SOCKET" new-session -d -s test -x 120 -y 40

# Override tmux command to use isolated server
tmux() { command tmux -L "$TEST_SOCKET" "$@"; }
export -f tmux

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

echo "=== Phase 1 Tests ==="
echo ""

# --- Test: variables.sh loads ---
echo "--- variables.sh ---"
source "$PROJECT_DIR/scripts/variables.sh"
assert "OPTION_ENABLED is set" '[[ -n "$OPTION_ENABLED" ]]'
assert "OPTION_BELL is set" '[[ -n "$OPTION_BELL" ]]'
assert_eq "DEFAULT_ENABLED is 'on'" "on" "$DEFAULT_ENABLED"
assert_eq "DEFAULT_POPUP_WIDTH is '80%'" "80%" "$DEFAULT_POPUP_WIDTH"
assert_eq "DEFAULT_STALE_TTL is '300'" "300" "$DEFAULT_STALE_TTL"
assert "QUEUE_DIR is set" '[[ -n "$QUEUE_DIR" ]]'
assert "PLUGIN_DIR is set" '[[ -n "$PLUGIN_DIR" ]]'

# --- Test: helpers.sh loads ---
echo ""
echo "--- helpers.sh ---"
source "$PROJECT_DIR/scripts/helpers.sh"
assert "get_os returns linux or macos" '[[ "$(get_os)" =~ ^(linux|macos|unknown)$ ]]'

# --- Test: option read/write ---
echo ""
echo "--- Option Read/Write ---"
tmux set-option -g "@test-claude-notify-opt" "test_value"
assert_eq "get_option reads set value" "test_value" "$(get_option '@test-claude-notify-opt' 'fallback')"
assert_eq "get_option returns default for unset" "fallback" "$(get_option '@test-claude-notify-unset' 'fallback')"
tmux set-option -gu "@test-claude-notify-opt"

# --- Test: set_default_option ---
echo ""
echo "--- set_default_option ---"
set_default_option "@test-claude-default" "mydefault"
assert_eq "set_default_option sets value" "mydefault" "$(get_option '@test-claude-default' '')"
tmux set-option -g "@test-claude-default" "override"
set_default_option "@test-claude-default" "mydefault"
assert_eq "set_default_option does not overwrite" "override" "$(get_option '@test-claude-default' '')"
tmux set-option -gu "@test-claude-default"

# --- Test: Queue operations ---
echo ""
echo "--- Queue Operations ---"

# Override QUEUE_DIR for test isolation
QUEUE_DIR="/tmp/tmux-claude-notify-test-$$"

ensure_queue_dir
assert "queue dir created" '[[ -d "$QUEUE_DIR" ]]'

assert "queue starts empty" queue_is_empty

queue_push "%42" "permission" "session1" "Allow file read?"
assert "queue not empty after push" '! queue_is_empty'

queue_push "%43" "stop" "session2" "Process stopped"
assert_eq "queue count is 2" "2" "$(queue_count)"

entry=$(queue_peek)
assert "peek returns first entry" '[[ "$entry" == *"%42"* ]]'

entry=$(queue_pop)
pane=$(parse_pane_id "$entry")
event=$(parse_event_type "$entry")
msg=$(parse_message "$entry")
assert_eq "popped pane_id" "%42" "$pane"
assert_eq "popped event_type" "permission" "$event"
assert_eq "popped message" "Allow file read?" "$msg"
assert_eq "queue count after pop" "1" "$(queue_count)"

queue_pop >/dev/null
assert "queue empty after all pops" queue_is_empty
assert "pop from empty returns error" '! queue_pop 2>/dev/null'

# --- Test: Locking ---
echo ""
echo "--- Locking ---"
acquire_lock
assert "lock acquired" true
release_lock
assert "lock released" true

# --- Test: Plugin loads (claude-notify.tmux) ---
echo ""
echo "--- Plugin Load ---"
# Source plugin in current shell (which already has tmux override)
source "$PROJECT_DIR/claude-notify.tmux"
assert_eq "enabled option set" "on" "$(get_option "$OPTION_ENABLED" "")"
assert_eq "bell option set" "on" "$(get_option "$OPTION_BELL" "")"
assert_eq "popup-width option set" "80%" "$(get_option "$OPTION_POPUP_WIDTH" "")"
assert_eq "bell-action set to any" "any" "$(tmux show-option -gv bell-action)"

echo ""
echo "================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "================================"

exit "$FAIL"
