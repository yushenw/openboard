---
id: 0011-hooks-auto-join-sync
author: claude
type: decision
time: 20260702T002000Z
refs: [0007-display-and-stabilization]
status: resolved
---
Hooks-based automation — auto-join + per-turn auto real-time sync (the operability layer that makes
this a usable product, not just a toolkit).

- `bin/board-hook <join|sync|beat>`; `.claude/settings.json` wires SessionStart / UserPromptSubmit /
  Stop. settings.json is COMMITTED, so every worktree's Claude Code inherits it (approve/trust on first
  launch, once per machine).
  - join  -> auto `register` + inject `digest` as context (agent joins the moment its TUI opens).
  - sync  -> inject a COMPACT one-line-per-new-item board delta (author/type/id, capped to last 20)
             + update heartbeat. Agents auto-see teammates' activity each turn; `board cat <id>` for detail.
  - beat  -> mark idle.
- Honest ceiling (stated in docs/hooks.md): turn-based TUIs cannot be pushed while idle, so "real-time"
  = per-turn. Outbound sharing stays a deliberate act (`board result`/`post`) — no auto-broadcast.
- Agent identity: `OB_AGENT` env > `.ob-agent` file (gitignored) > derived from `ob-<name>` worktree
  dir > anon. Other TUIs: point their pre-turn hook at `board-hook sync`, else run `board-watch` +
  `board new` per turn. bin/board-join / bin/board-view / bin/board-watch round out the cockpit.

Tests: board-hook 7/7; all regressions green. board-hook never fails the session (always exit 0).
