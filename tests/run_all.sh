#!/usr/bin/env bash
# run_all.sh — Orchestrates all tmux-claude-notify test files
#
# Usage:
#   tests/run_all.sh              # Run all tests
#   tests/run_all.sh --filter X   # Run only test files matching X

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse args
FILTER=""
if [[ "${1:-}" == "--filter" ]]; then
    FILTER="${2:-}"
fi

# Test files in execution order
TEST_FILES=(
    test_phase1.sh
    test_phase2.sh
    test_phase3.sh
    test_phase4.sh
    test_phase5.sh
    test_unit.sh
    test_component.sh
    test_integration.sh
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
FILE_COUNT=${#TEST_FILES[@]}
RESULTS=()

echo "=== tmux-claude-notify Test Suite ==="
echo ""

for i in "${!TEST_FILES[@]}"; do
    file="${TEST_FILES[$i]}"
    idx=$((i + 1))

    # Apply filter
    if [[ -n "$FILTER" && "$file" != *"$FILTER"* ]]; then
        continue
    fi

    # Check if file exists
    if [[ ! -f "$SCRIPT_DIR/$file" ]]; then
        printf "[%d/%d] %-30s %bSKIP (not found)%b\n" "$idx" "$FILE_COUNT" "$file" "$YELLOW" "$NC"
        RESULTS+=("$file|0|0|skip")
        ((TOTAL_SKIP++))
        continue
    fi

    # Run with timeout
    output=$(timeout 60 bash "$SCRIPT_DIR/$file" 2>&1)
    exit_code=$?

    if [[ $exit_code -eq 124 ]]; then
        # Timeout
        printf "[%d/%d] %-30s %bTIMEOUT%b\n" "$idx" "$FILE_COUNT" "$file" "$RED" "$NC"
        RESULTS+=("$file|0|1|timeout")
        ((TOTAL_FAIL++))
        continue
    fi

    # Parse pass/fail from output (last lines: "N passed, M failed")
    pass=$(echo "$output" | grep -oP '\d+ passed' | grep -oP '\d+' | tail -1)
    fail=$(echo "$output" | grep -oP '\d+ failed' | grep -oP '\d+' | tail -1)
    pass=${pass:-0}
    fail=${fail:-0}

    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))

    if [[ "$fail" -eq 0 ]]; then
        printf "[%d/%d] %-30s %b%d passed%b, %d failed\n" "$idx" "$FILE_COUNT" "$file" "$GREEN" "$pass" "$NC" "$fail"
    else
        printf "[%d/%d] %-30s %d passed, %b%d failed%b\n" "$idx" "$FILE_COUNT" "$file" "$pass" "$RED" "$fail" "$NC"
    fi
    RESULTS+=("$file|$pass|$fail|done")
done

echo ""
echo "=========================================="
if [[ "$TOTAL_FAIL" -eq 0 ]]; then
    echo -e "TOTAL: ${GREEN}${TOTAL_PASS} passed${NC}, ${TOTAL_FAIL} failed"
else
    echo -e "TOTAL: ${TOTAL_PASS} passed, ${RED}${TOTAL_FAIL} failed${NC}"
fi
if [[ "$TOTAL_SKIP" -gt 0 ]]; then
    echo -e "       ${YELLOW}${TOTAL_SKIP} skipped${NC}"
fi
echo "=========================================="

exit "$TOTAL_FAIL"
