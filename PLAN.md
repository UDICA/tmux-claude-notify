# Project Plan: tmux-claude-notify

## Overview
Tmux plugin that shows interactive popups when Claude Code needs permission approval, allowing users to respond without switching windows.

## Phase 1: Skeleton and Infrastructure
### Tasks
- [ ] Task 1.1: `claude-notify.tmux` — TPM entry, options, keybinding, queue dir, bell config — Status: pending
- [ ] Task 1.2: `scripts/variables.sh` — option names, path constants, defaults — Status: pending
- [ ] Task 1.3: `scripts/helpers.sh` — queue ops, locking, option reading, OS detection — Status: pending
- [ ] Task 1.4: Tests — plugin loads, options set, queue push/pop, locking — Status: pending

## Phase 2: Pane Detection
### Tasks
- [ ] Task 2.1: `scripts/detect-pane.sh` — process tree walker — Status: pending
- [ ] Task 2.2: Tests — verify detected pane matches actual — Status: pending

## Phase 3: Notification Handler
### Tasks
- [ ] Task 3.1: `scripts/notification-handler.sh` — JSON stdin, detect-pane, queue, bell, popup-manager — Status: pending
- [ ] Task 3.2: Tests — mock JSON, verify queue entry, verify alerts — Status: pending

## Phase 4: Interactive Popup System
### Tasks
- [ ] Task 4.1: `scripts/popup-interactive.sh` — capture/display/input loop — Status: pending
- [ ] Task 4.2: `scripts/popup-manager.sh` — single-instance queue consumer — Status: pending
- [ ] Task 4.3: `scripts/status-count.sh` — pending count for status bar — Status: pending
- [ ] Task 4.4: Tests — queue processing, stale cleanup, resume detection — Status: pending

## Phase 5: Setup and Configuration
### Tasks
- [ ] Task 5.1: `scripts/setup.sh` — check-only and configure modes — Status: pending
- [ ] Task 5.2: Tests — setup detects hooks correctly — Status: pending

## Phase 6: Edge Cases and Hardening
### Tasks
- [ ] Task 6.1: Detach/reattach — after-client-attached hook — Status: pending
- [ ] Task 6.2: Claude session ends mid-popup — detect pane gone — Status: pending
- [ ] Task 6.3: Multiple tmux servers — namespace queue dir — Status: pending
- [ ] Task 6.4: Race conditions — all ops locked, single instance — Status: pending
- [ ] Task 6.5: macOS portability — mkdir locking, ps-based PID walk — Status: pending

## Phase 7: Documentation and Publishing
### Tasks
- [ ] Task 7.1: README.md — Status: pending
- [ ] Task 7.2: LICENSE — MIT — Status: pending

## Current Status
- **Active phase**: Phase 1
- **Active task**: Task 1.1
- **Last completed**: None
- **Blockers**: none
- **Next steps**: Implement variables.sh, then claude-notify.tmux
