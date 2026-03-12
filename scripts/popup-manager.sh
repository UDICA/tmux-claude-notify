#!/usr/bin/env bash
# popup-manager.sh — Queue consumer + popup lifecycle loop (stub, implemented in Phase 4)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

case "${1:-}" in
    --recheck)
        # Re-check queue after client reattach (Phase 6)
        exit 0
        ;;
    *)
        # Normal popup manager launch (Phase 4)
        exit 0
        ;;
esac
