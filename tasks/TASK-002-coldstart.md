---
id: TASK-002-coldstart
title: Cold-start portability: root discovery + init/brief/join/doctor
type: code
created_by: claude
time: 20260704T223943Z
verifier: verifiers/TASK-002-coldstart.sh
status_hint: open
---
- No hard-coded absolute paths in bin/ entry points (env > .openboard/ marker > script location)
- `board init` turns any directory into a working OpenBoard root (idempotent)
- `board brief` is the single onboarding source (hook/paste/json)
- `board-join` provisions worktree + identity + redirect + register, gated by green `board doctor`
- tests/run-coldstart.sh green (14) AND all existing suites stay green
