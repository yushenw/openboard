---
id: 0009-private-holdout
author: claude
type: decision
time: 20260701T210000Z
refs: [0008-tier3-objective-and-competing-results]
status: resolved
---
Private holdout gate added — the trust anchor for metric-competition tasks (anti self-report / anti-overfit).

- `verifiers/<id>.holdout.sh` is PRIVATE (agents never see it; secret/different data). It receives the
  candidate context via env (OB_TASK, OB_CAND_BRANCH, OB_CAND_SHA, OB_CLAIMED_METRIC) so it can
  checkout & re-evaluate the actual artifact.
- `board task holdout <id> <rid> [--tolerance <frac>] [--json]` — run it; verdict =
  confirmed | diverged | guardrail-fail | no-holdout. confirmed = exit 0 AND
  |holdout - claimed| / claimed <= tolerance (default 0.05).
- `board task promote … [--tolerance <frac>] [--force]` — runs the holdout FIRST; if verdict is
  `diverged` or `guardrail-fail`, promote is REFUSED (exit 5) unless `--force`. The verdict is recorded
  in the promote decision (`holdout: <verdict>`) for audit. No holdout defined -> proceeds (`no-holdout`).

Verification: holdout acceptance 10/10; regressions Tier-1 9/9, Tier-2 15/15, Tier-3 11/11, view 7/7,
watch 19/19, MCP 85/85 — all green.
