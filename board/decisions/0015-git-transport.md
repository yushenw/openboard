---
id: 0015-git-transport
author: claude
type: decision
time: 20260707T224245Z
refs: [0012-cold-start-portability, 0014-oss-readiness]
status: resolved
---
git transport — multi-host boards over any git remote (mechanism 1's final piece from decision
0012). The append-only one-file-per-message design pays off: content merges are conflict-free by
construction, so "multi-host" is a thin pull/push layer, not a server.

## Design
- `OB_BOARD_TRANSPORT=local|git` in `.openboard/project` (`board init --transport ...`).
  Agent-facing commands are IDENTICAL under both transports.
- Hook point = board.sh dispatch: `ob_git_pull` before ANY command, `trap ob_git_push EXIT`
  after (preserves the command's exit code). Because view/watch/hooks/MCP all call the CLI,
  every surface inherits multi-host freshness with zero changes.
- `ob_git_push` (bin/ob-common.sh): stage ONLY the shared surface (board/messages agents
  decisions + tasks/verifiers/artifacts) -> commit with author = $OB_AGENT (identity ladder L1,
  no global git config needed) -> push; on rejection pull --rebase and retry (3x).
- Offline-tolerant: pull/push failures warn on stderr and never fail the command; writes stay
  as local commits and sync on the next successful push (eventual consistency).
- Generated state is per-node, NOT synced: digest.md, inbox/, cursors, probes — written into
  `board init`'s .gitignore. Each node rebuilds them; this removes the only realistic
  rebase-conflict source.
- `OB_GIT_TIMEOUT` (10s default) caps every git network call so a dead remote degrades to the
  offline path instead of hanging a TUI turn.
- doctor: transport=git now checks upstream configured + origin reachable (with fix hints).

## Bug found by the suite during development
`ob_git rebase --abort` exits 128 when no rebase is in progress; as a standalone statement under
`set -e` it killed the process inside the EXIT trap (observed rc=128). Guarded with `|| true` in
both pull and push paths. Lesson recorded: every command in transport plumbing must be
failure-tolerant — it runs inside other people's commands.

## Verification
- New suite tests/run-transport.sh — 8 scenarios against a local bare origin (no network):
  init --transport recording + per-node .gitignore; auto-commit+push with agent author; B sees
  A via pre-dispatch pull; reverse round trip; ref race (local-ahead + remote-ahead) resolved by
  rebase+retry; offline write = exit 0 + warning + backlog sync; digest --write pushes nothing;
  doctor green with upstream / FAIL+hint without.
- Full regression green: Tier-1 12, Tier-2 15, Tier-3 12, cold-start 14, transport 8, view 7,
  watch 24, hook 7 (99 shell) + MCP schema 82.
- Docs: docs/transport.md (new), README, USAGE.md (多主机 section), CLI spec, CHANGELOG
  [Unreleased], CI step added.

## Remaining from the OSS roadmap (0014 order)
MCP onboarding resource wired to `brief --json` + uvx packaging -> Claude Code plugin ->
templates/ + example verifiers -> heartbeat throttling under git transport (one commit per
turn is acceptable but compactable later).
