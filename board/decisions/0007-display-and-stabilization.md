---
id: 0007-display-and-stabilization
author: claude
type: decision
time: 20260701T193000Z
refs: [0006-tier2-complete]
status: resolved
---
Display layer (option c) + stabilization delivered.

- bin/board-view: read-only terminal dashboard (agents / tasks / activity); --once/--interval/-n.
  Composes the read-only CLI; verified it makes ZERO board writes. tests/board-view-test.sh = 7/7.
- bin/board-join: one-command onboarding (register + next steps).
- docs/onboarding.md: per-TUI join block + MCP snippet.
- README.md rewritten to REAL usage (was the aspirational vision doc); DESIGN.md kept as north-star.
- AGENTS.md registration now points to `board register` (not the removed top-level agents/).

Cleanup (grok early-vision redundancy, per user):
- removed tasks/TASK-001-example.md (stale: in-file status/claimed_by + invalid type; overruled by 0002).
- removed templates/ (used the pre-0002 in-file-status model; the CLI generates records; onboarding is docs/onboarding.md).
- removed empty top-level agents/ (canonical agent files live in board/agents/ via register).

Regression: Tier-1 9/9, Tier-2 15/15, watch 19/19, board-view 7/7 — all green.
The display layer reads board/digest.md + tasks/ + messages, so a richer HTML/web panel can replace it later with zero core change.
