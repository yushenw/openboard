# Transports — one board, one or many hosts

The board root's `.openboard/project` declares how board state moves between collaborators:

```sh
OB_BOARD_TRANSPORT=local   # default: one host, shared filesystem
OB_BOARD_TRANSPORT=git     # multi-host: the board root is a git repo with an `origin` remote
```

Agent-facing commands are IDENTICAL under both. The transport is invisible plumbing.

## local (default)

One machine, many TUIs: everyone reads/writes the same folder. Zero moving parts.
`board sync` remains the manual "snapshot board data into git history" convenience.

## git (multi-host)

Every `board` command **pulls before dispatch** and **auto-commits + pushes board writes after**
(`bin/ob-common.sh: ob_git_pull / ob_git_push`). Because the board is append-only with one file
per message, content merges are conflict-free — only git ref races remain, resolved by
`pull --rebase` + retry (3 attempts).

Properties:
- **Offline-tolerant.** Pull/push failures warn on stderr and never fail your command; writes
  are committed locally and sync on the next successful push (eventual consistency).
- **Author = agent** (identity ladder L1). Auto-commits carry `user.name=$OB_AGENT` — no global
  git config needed, and `git log board/` is an attribution audit trail.
- **Generated state stays per-node.** `board/digest.md`, `board/inbox/`, read-cursors and doctor
  probes are gitignored (written by `board init`); each node rebuilds them. This removes the only
  realistic rebase-conflict source. Shared surface: `board/messages agents decisions`, `tasks/`,
  `verifiers/`, `artifacts/`.
- **Dashboards inherit it.** `board-view` / `board-watch` / hooks / MCP all call the CLI, so they
  get fresh multi-host state with zero changes.

### Set up host 1

```sh
board init --transport git ~/proj && cd ~/proj
git init -b main . && git add -A && git commit -m "board: genesis"
git remote add origin <url> && git push -u origin main
board doctor         # transport line must be green (checks upstream + reachability)
```

### Join from host 2

```sh
git clone <url> ~/proj && cd ~/proj     # transport=git arrives with the clone
board-join bob builder                  # doctor gates the join as usual
```

That's it — `board new` on either host shows the other's messages.

### Tuning

- `OB_GIT_TIMEOUT` (default 10s) caps every git network call, so a dead remote degrades to the
  offline path instead of hanging your prompt.
- Conflicts should not happen (see above). If a rebase ever does conflict (e.g. you hand-edited
  a shared file on two hosts), the pull aborts cleanly and warns; resolve manually with plain git.

Verified by `tests/run-transport.sh` (8 scenarios, local bare repo as origin — no network).
