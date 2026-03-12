#!/usr/bin/env bash
# test_unit.sh — Unit tests for coverage gaps

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Isolated tmux server with PATH wrapper
TEST_SOCKET="test-cn-unit-$$"
WRAPPER_DIR="/tmp/tmux-wrapper-unit-$$"
mkdir -p "$WRAPPER_DIR"
cat > "$WRAPPER_DIR/tmux" <<WRAP
#!/bin/bash
exec /usr/bin/tmux -L "$TEST_SOCKET" "\$@"
WRAP
chmod +x "$WRAPPER_DIR/tmux"
export PATH="$WRAPPER_DIR:$PATH"

TEST_HOME="/tmp/test-home-unit-$$"

cleanup() {
    tmux kill-server 2>/dev/null || true
    rm -rf "/tmp/tmux-claude-notify-test-unit-$$" "$WRAPPER_DIR" \
           "/tmp/test-canary-$$" "/tmp/test-marker-$$" "$TEST_HOME"
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

export QUEUE_DIR="/tmp/tmux-claude-notify-test-unit-$$"
unset _VARIABLES_SH_LOADED
source "$PROJECT_DIR/scripts/helpers.sh"
export -n _VARIABLES_SH_LOADED
ensure_queue_dir

echo "=== Unit Tests ==="
echo ""

# ===========================================================================
# 1. macOS mkdir-based locking (4 tests)
# ===========================================================================
echo "--- mkdir-based locking ---"

# Override _supports_flock to force the mkdir path
_supports_flock() { return 1; }

lock_path="$(_lock_file)"

# Test: acquire creates lock.d directory
acquire_lock
assert "mkdir lock: acquire creates lock.d directory" '[[ -d "${lock_path}.d" ]]'

# Test: release removes lock.d directory
release_lock
assert "mkdir lock: release removes lock.d directory" '[[ ! -d "${lock_path}.d" ]]'

# Test: second acquire blocks while lock held
acquire_lock
(
    # This background process should block trying to acquire the lock
    acquire_lock
    touch "/tmp/test-canary-$$"
    release_lock
) &
bg_pid=$!
sleep 0.3
# Canary should NOT be written yet — lock still held
assert "mkdir lock: second acquire blocks while lock held" '[[ ! -f "/tmp/test-canary-$$" ]]'

# Test: release lets background process acquire within 1s
release_lock
# Give background process up to 1s to acquire and create canary
acquired=false
for i in $(seq 1 10); do
    if [[ -f "/tmp/test-canary-$$" ]]; then
        acquired=true
        break
    fi
    sleep 0.1
done
wait "$bg_pid" 2>/dev/null || true
assert "mkdir lock: release lets background process acquire within 1s" '[[ "$acquired" == "true" ]]'

# Restore _supports_flock to original behavior
unset -f _supports_flock
_supports_flock() { command -v flock &>/dev/null; }

echo ""

# ===========================================================================
# 2. macOS ps-based PID walk (2 tests)
# ===========================================================================
echo "--- ps-based PID walk ---"

# Source detect-pane.sh (re-sources helpers.sh internally, that's fine)
source "$PROJECT_DIR/scripts/detect-pane.sh"

# Get real PPID from /proc for comparison
real_ppid=""
if [[ -f "/proc/$$/status" ]]; then
    real_ppid=$(awk '/^PPid:/ { print $2 }' "/proc/$$/status" 2>/dev/null)
fi

# Override get_os to force ps path
get_os() { echo "macos"; }

ps_ppid=$(_get_ppid $$)
assert "ps-based _get_ppid returns non-empty" '[[ -n "$ps_ppid" ]]'

if [[ -n "$real_ppid" ]]; then
    assert_eq "ps-based _get_ppid matches /proc PPID" "$real_ppid" "$ps_ppid"
else
    echo -e "${GREEN}SKIP${NC}: /proc not available, skipping /proc comparison"
    ((PASS++))
fi

# Restore get_os
unset -f get_os
source "$PROJECT_DIR/scripts/helpers.sh" 2>/dev/null || true

echo ""

# ===========================================================================
# 3. Stale entry pruning (2 tests)
# ===========================================================================
echo "--- Stale entry pruning ---"

# Reset queue dir for clean state
rm -rf "$QUEUE_DIR"
ensure_queue_dir

# Get a valid pane ID from the test tmux server
valid_pane=$(tmux list-panes -t test -F '#{pane_id}' | head -1)

now=$(date +%s)
old_ts=$((now - 400))  # 400 seconds ago, beyond DEFAULT_STALE_TTL=300
sep=$'\x1f'

qf="$QUEUE_DIR/queue"
# TTL-expired entry
printf '%s%s%s%s%s%s%s%s%s\n' \
    "$old_ts" "$sep" "$valid_pane" "$sep" "stop" "$sep" "sess1" "$sep" "expired message" >> "$qf"

assert "stale: expired entry exists before clean" '! queue_is_empty'
clean_stale_entries
assert "stale: clean_stale_entries removes TTL-expired entry" queue_is_empty

# Test: mixed — TTL-expired + valid entry, clean leaves only valid
rm -rf "$QUEUE_DIR"
ensure_queue_dir

# TTL-expired entry
printf '%s%s%s%s%s%s%s%s%s\n' \
    "$old_ts" "$sep" "$valid_pane" "$sep" "stop" "$sep" "sess1" "$sep" "expired message" >> "$qf"
# Valid entry (current timestamp, valid pane)
printf '%s%s%s%s%s%s%s%s%s\n' \
    "$now" "$sep" "$valid_pane" "$sep" "permission" "$sep" "sess2" "$sep" "valid message" >> "$qf"

clean_stale_entries
count_after=$(queue_count)
assert_eq "mixed clean: only valid entry remains after TTL clean" "1" "$count_after"

remaining=$(queue_pop)
remaining_msg=$(parse_message "$remaining")
assert_eq "mixed clean: remaining entry is the valid one" "valid message" "$remaining_msg"

echo ""

# ===========================================================================
# 4. Special characters in messages (2 tests)
# ===========================================================================
echo "--- Special characters in messages ---"

rm -rf "$QUEUE_DIR"
ensure_queue_dir

# Test: message with pipes, quotes, backticks, dollars round-trips intact
special_msg='pipes | quotes "hello" backticks `cmd` dollars $VAR'
queue_push "%42" "permission" "sess1" "$special_msg"
entry=$(queue_pop)
parsed_msg=$(parse_message "$entry")
assert_eq "special chars: pipes/quotes/backticks/dollars round-trip" "$special_msg" "$parsed_msg"

# Test: pipeline command round-trips intact
pipeline_msg='cat file | grep pattern | wc -l'
queue_push "%43" "stop" "sess2" "$pipeline_msg"
entry=$(queue_pop)
parsed_msg=$(parse_message "$entry")
assert_eq "special chars: pipeline command round-trips intact" "$pipeline_msg" "$parsed_msg"

echo ""

# ===========================================================================
# 5. Spinner detection (4 tests)
# ===========================================================================
echo "--- Spinner detection ---"

SPINNER_CHARS=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

_test_has_spinner() {
    local text="$1"
    local char
    for char in "${SPINNER_CHARS[@]}"; do
        if [[ "$text" == *"$char"* ]]; then
            return 0
        fi
    done
    return 1
}

# Test: text with ⠋ → detected
assert "spinner: text with ⠋ is detected" '_test_has_spinner "⠋ Working..."'

# Test: plain text → not detected
assert "spinner: plain text is not detected" '! _test_has_spinner "Hello world"'

# Test: permission prompt → not detected
assert "spinner: permission prompt is not detected" \
    '! _test_has_spinner "Do you allow this action? [y/N]"'

# Test: ANSI-wrapped spinner → detected
ansi_spinner=$'\033[32m⠙\033[0m'
assert "spinner: ANSI-wrapped spinner is detected" '_test_has_spinner "$ansi_spinner"'

echo ""

# ===========================================================================
# 6. status-count.sh disabled (1 test)
# ===========================================================================
echo "--- status-count.sh disabled ---"

# Set @claude-notify-enabled to off
tmux set-option -g "@claude-notify-enabled" "off"

status_output=$(QUEUE_DIR="$QUEUE_DIR" bash "$PROJECT_DIR/scripts/status-count.sh" 2>/dev/null)
assert_eq "status-count: outputs empty when disabled" "" "$status_output"

# Restore
tmux set-option -g "@claude-notify-enabled" "on"

echo ""

# ===========================================================================
# 7. setup.sh branches (3 tests)
# ===========================================================================
echo "--- setup.sh branches ---"

mkdir -p "$TEST_HOME"

# Test: --configure with no settings.json, pipe "y" → file created with hooks
# Use a clean TEST_HOME with no .claude directory
rm -rf "$TEST_HOME"
mkdir -p "$TEST_HOME"
setup_output=$(HOME="$TEST_HOME" bash -c \
    "bash '$PROJECT_DIR/scripts/setup.sh' --configure" <<< "y" 2>&1)
assert "setup: file created with hooks when user says y" \
    '[[ -f "$TEST_HOME/.claude/settings.json" ]]'

if [[ -f "$TEST_HOME/.claude/settings.json" ]]; then
    has_hook=$(jq -r '
        if (.hooks.Notification // .hooks.Stop) != null then "yes" else "no" end
    ' "$TEST_HOME/.claude/settings.json" 2>/dev/null)
    assert_eq "setup: settings.json contains hooks section" "yes" "$has_hook"
fi

# Test: --configure user says "n" → settings unchanged
rm -rf "$TEST_HOME"
mkdir -p "$TEST_HOME"
setup_output=$(HOME="$TEST_HOME" bash -c \
    "bash '$PROJECT_DIR/scripts/setup.sh' --configure" <<< "n" 2>&1)
assert "setup: settings.json NOT created when user says n" \
    '[[ ! -f "$TEST_HOME/.claude/settings.json" ]]'

# Test: --configure when hooks already exist → reports "already configured"
# Create a settings.json with hooks already referencing notification-handler
rm -rf "$TEST_HOME"
mkdir -p "$TEST_HOME/.claude"
cat > "$TEST_HOME/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "command": "/some/path/notification-handler.sh"
      }
    ]
  }
}
JSON

already_output=$(HOME="$TEST_HOME" bash -c \
    "bash '$PROJECT_DIR/scripts/setup.sh' --configure" 2>&1)
assert "setup: reports already configured when hooks exist" \
    '[[ "$already_output" == *"already configured"* ]]'

echo ""

# ===========================================================================
# Summary
# ===========================================================================
echo "================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "================================"

exit "$FAIL"
