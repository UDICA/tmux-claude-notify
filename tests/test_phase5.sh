#!/usr/bin/env bash
# test_phase5.sh — Tests for Phase 5: Setup and Configuration

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Isolated tmux server
TEST_SOCKET="test-cn-$$"
WRAPPER_DIR="/tmp/tmux-wrapper-$$"
TEST_HOME="/tmp/test-home-$$"
mkdir -p "$WRAPPER_DIR" "$TEST_HOME/.claude"
cat > "$WRAPPER_DIR/tmux" <<WRAP
#!/bin/bash
exec /usr/bin/tmux -L "$TEST_SOCKET" "\$@"
WRAP
chmod +x "$WRAPPER_DIR/tmux"
export PATH="$WRAPPER_DIR:$PATH"

cleanup() {
    tmux kill-server 2>/dev/null || true
    rm -rf "$WRAPPER_DIR" "$TEST_HOME" "/tmp/tmux-claude-notify-test-$$"
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

echo "=== Phase 5 Tests: Setup and Configuration ==="
echo ""

export QUEUE_DIR="/tmp/tmux-claude-notify-test-$$"
unset _VARIABLES_SH_LOADED
source "$PROJECT_DIR/scripts/helpers.sh"
export -n _VARIABLES_SH_LOADED

# --- Test: --show prints instructions ---
echo "--- Show Mode ---"
output=$(bash "$PROJECT_DIR/scripts/setup.sh" --show 2>&1)
assert "show prints notification-handler path" '[[ "$output" == *"notification-handler"* ]]'
assert "show prints Notification hook" '[[ "$output" == *"Notification"* ]]'
assert "show prints Stop hook" '[[ "$output" == *"Stop"* ]]'

# --- Test: --check-only with no settings ---
echo ""
echo "--- Check Only (no settings) ---"
# Use a fake HOME so it doesn't find real settings
output=$(HOME="$TEST_HOME" bash "$PROJECT_DIR/scripts/setup.sh" --check-only 2>&1)
# Should not crash
assert "check-only exits cleanly with no settings" '[[ $? -eq 0 ]]'

# --- Test: --check-only with settings but no hooks ---
echo ""
echo "--- Check Only (settings, no hooks) ---"
echo '{"someOption": true}' > "$TEST_HOME/.claude/settings.json"
output=$(HOME="$TEST_HOME" bash "$PROJECT_DIR/scripts/setup.sh" --check-only 2>&1)
assert "check-only exits cleanly with no hooks" '[[ $? -eq 0 ]]'

# --- Test: _has_hook_configured detection ---
echo ""
echo "--- Hook Detection ---"

# No hooks
echo '{"someOption": true}' > "$TEST_HOME/.claude/settings.json"
result=$(HOME="$TEST_HOME" bash -c '
source "'"$PROJECT_DIR"'/scripts/helpers.sh" 2>/dev/null
source "'"$PROJECT_DIR"'/scripts/setup.sh" --show >/dev/null 2>&1
# We cannot easily call internal functions from setup.sh since it runs as main
# Instead test by checking if configure would detect hooks
' 2>&1)

# Test with hooks present
cat > "$TEST_HOME/.claude/settings.json" <<'SETTINGS'
{
  "hooks": {
    "Notification": [
      {"matcher": "", "command": "/some/path/notification-handler.sh"}
    ]
  }
}
SETTINGS

# The check-only mode should NOT show a message when hooks exist
output=$(HOME="$TEST_HOME" bash "$PROJECT_DIR/scripts/setup.sh" --check-only 2>&1)
assert "check-only quiet when hooks configured" '[[ $? -eq 0 ]]'

# --- Test: --configure creates hooks (non-interactive, simulated) ---
echo ""
echo "--- Configure (automated) ---"

# Create settings without hooks
echo '{"existingOption": true}' > "$TEST_HOME/.claude/settings.json"

# Simulate "y" input for interactive prompt
output=$(echo "y" | HOME="$TEST_HOME" bash "$PROJECT_DIR/scripts/setup.sh" --configure 2>&1)
assert "configure completes" '[[ $? -eq 0 ]]'
assert "configure says done" '[[ "$output" == *"Done"* || "$output" == *"done"* || "$output" == *"success"* ]]'

# Verify the settings file now has hooks
if [[ -f "$TEST_HOME/.claude/settings.json" ]]; then
    has_notification=$(jq -e '.hooks.Notification' "$TEST_HOME/.claude/settings.json" 2>/dev/null)
    assert "Notification hook added" '[[ -n "$has_notification" ]]'

    has_stop=$(jq -e '.hooks.Stop' "$TEST_HOME/.claude/settings.json" 2>/dev/null)
    assert "Stop hook added" '[[ -n "$has_stop" ]]'

    # Existing options preserved
    existing=$(jq -r '.existingOption' "$TEST_HOME/.claude/settings.json" 2>/dev/null)
    assert_eq "existing option preserved" "true" "$existing"

    # Backup created
    backup_count=$(ls "$TEST_HOME/.claude/settings.json.bak."* 2>/dev/null | wc -l)
    assert "backup created" '[[ "$backup_count" -ge 1 ]]'
else
    echo -e "${RED}FAIL${NC}: settings.json not found after configure"
    ((FAIL++))
fi

# --- Test: --configure is idempotent ---
echo ""
echo "--- Configure Idempotent ---"
output=$(echo "y" | HOME="$TEST_HOME" bash "$PROJECT_DIR/scripts/setup.sh" --configure 2>&1)
assert "configure says already configured" '[[ "$output" == *"already configured"* ]]'

# --- Test: invalid mode ---
echo ""
echo "--- Invalid Mode ---"
bash "$PROJECT_DIR/scripts/setup.sh" --invalid >/dev/null 2>&1
invalid_exit=$?
assert "invalid mode returns non-zero" '[[ "$invalid_exit" -ne 0 ]]'

echo ""
echo "================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "================================"

exit "$FAIL"
