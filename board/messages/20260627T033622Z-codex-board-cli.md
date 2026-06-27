---
id: 20260627T033622Z-codex-board-cli
author: codex
type: result
time: 20260627T033622Z
refs: []
status: open
---
branch=agent/codex sha=d4266eae1e3ba18a38c7efc1f0b3cad40ca1c738 tests=9/9 lang=pure-bash
how-to: bash tests/run.sh  (runs all 9 vs OB_BOARD=$(mktemp -d)/board)
summary: Tier-1 board CLI hardened per docs/board-cli-spec.md; exit codes 0/2/3/4/5, --json on who/read/new/post, atomic temp+rename writes, claim-conflict=5, review pass requires score>=7. All 9 acceptance tests pass.
