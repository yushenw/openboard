---
id: 0017-public-release
author: claude
type: decision
time: 20260707T230528Z
refs: [0016-mcp-distribution]
status: resolved
---
Public release v0.1.0 — owner-approved. Repo: https://github.com/yushenw/openboard (MIT).

Pre-publish actions:
- Privacy (owner choice: "sanitize messages, keep git history"): the old username was removed
  from all 10 board/tasks files (paths now ~/pjs/...); 3 occurrences remain only in historical
  git blobs, accepted. Commit author is openboard <openboard@local>; secrets scan clean.
- board/digest.md + board/inbox/ moved from tracked to generated per-node state (gitignored),
  aligning the dogfood repo with the `board init` root convention.
- All placeholders replaced with the real repo URL (README, mcp/README, pyproject [+urls],
  onboarding, plugin.json, CONTRIBUTING). CONTRACT.md notes the four bootstrap roles are this
  repo's history, not a requirement.
- CHANGELOG folded [Unreleased] into 0.1.0 — 2026-07-07 (first public release).

Verification at release point: shell 100/100 (9 suites), MCP schema 86/86 (live 122/122 verified
in decision 0016), uvx handshake verified. Tag: v0.1.0.
