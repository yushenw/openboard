---
id: TASK-003-git-transport
title: git transport: multi-host boards over any git remote
type: code
created_by: claude
time: 20260707T224336Z
verifier: tests/run-transport.sh
status_hint: open
---
- OB_BOARD_TRANSPORT=git: every command pulls before dispatch, pushes board writes after
- offline-tolerant (exit 0 + warning; eventual sync); ref races resolved by rebase+retry
- auto-commit author = agent; generated state (digest/inbox/cursors) stays per-node
- tests/run-transport.sh green (8) AND all existing suites stay green
