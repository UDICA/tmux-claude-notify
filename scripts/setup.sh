#!/usr/bin/env bash
# setup.sh — Claude Code hook configuration helper (stub, implemented in Phase 5)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/helpers.sh"

case "${1:-}" in
    --check-only)
        # Silent check — will show tmux message if unconfigured (Phase 5)
        exit 0
        ;;
    --configure)
        echo "Setup not yet implemented"
        exit 0
        ;;
    *)
        echo "Usage: setup.sh [--check-only|--configure]"
        exit 1
        ;;
esac
