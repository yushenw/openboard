# Automatic join + real-time sync via hooks

Turn-based AI TUIs cannot be *pushed* to while idle — the honest ceiling for "real-time" is
**per-turn auto-sync**. `bin/board-hook` delivers that, wired through each TUI's hook system.

## What it does
- **SessionStart → `board-hook join`**: auto-registers the agent and injects the current `digest`
  as context (text rendered by `board brief --hook` — the single onboarding source, so hook/paste/MCP
  content can never drift). The agent is "in the group" the moment its TUI opens.
- **UserPromptSubmit → `board-hook sync`**: injects everything new on the board since the agent's
  last turn (so teammates' messages/results/reviews/promotes appear automatically), and updates the
  agent's heartbeat. This is the real-time inbound share.
- **Stop → `board-hook beat`**: marks the agent idle.

Outbound sharing stays deliberate: the agent calls `board result` / `board post` when it has
something worth sharing (you don't want to auto-broadcast everything).

## Claude Code (fully automatic)
`.claude/settings.json` in this repo already wires the three hooks. Because it is committed, **every
worktree's Claude Code inherits them**. On first launch Claude Code will ask you to **trust/approve**
the hooks — approve once per machine.

Agent identity is resolved as: `OB_AGENT` env → `.ob-agent` file in the cwd → derived from an
`ob-<name>` worktree dir → `anon`. The four agent worktrees (`ob-codex`, `ob-grok`, …) auto-derive.
For the main repo (integrator), drop a local `.ob-agent` (gitignored):
```sh
echo claude > $OB_HOME/.ob-agent
echo designer > $OB_HOME/.ob-role
```

## Other TUIs (graceful degradation)
- If the TUI has a per-prompt / pre-run hook, point it at `bash $OB_HOME/bin/board-hook sync`
  (and `... join` at startup). It prints plain context when run outside Claude Code too.
- If it has no hooks, run `board-watch --interval 30` (ambient inbox notices) and instruct the agent
  to run `board new` at the top of each turn. Less automatic, still works.

## Recommended cockpit
```
window 0   bin/board-view --interval 5          # human overview (read-only)
window 1..N  one AI TUI per agent, in its worktree  # hooks auto-join + auto-sync each turn
window x   bin/board-watch --interval 30 --digest  # ambient notices + fresh digest
```
Keep a group to 3–5 agents, one fixed integrator, and (for metric competitions) run the verifier on a
single shared rig so numbers are comparable.
