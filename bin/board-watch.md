# board-watch

Poll-based sync/notify companion for OpenBoard. Zero dependencies beyond coreutils + bash.
It consumes the frozen board conventions (Tier-1 `docs/board-cli-spec.md` + Tier-2
`docs/board-cli-spec-tier2.md`) and does **not** change the CLI surface.

## What it does

Watches `board/messages/` (and `tasks/`) for new activity. It appends a one-line notice to
`board/inbox/<agent>.md` and prints it to stdout when, since the last scan:

1. **@mention** — a message body contains `@<name>` -> notify `<name>`.
2. **question / review broadcast** — a message with `type: question` or `type: review`
   -> notify all registered agents (files in `board/agents/`) except the author.
3. **TASK claim** — a `type: claim` message whose slug is a `TASK-<NNN>-...` id
   -> notify all registered agents except the claimer (`task <id> claimed`).
4. **TASK close** — a `type: decision` message whose `refs` include a `TASK-<NNN>-...` id
   -> notify all registered agents except the author (`task <id> closed`).
5. **New task spec** — a new `tasks/TASK-*.md` file appears
   -> notify all registered agents except its `created_by` (`new task <id>`).

Each agent is notified at most once per source message; the @mention and broadcast reasons
combine into a single line. Cursors under `OB_STATE` (one for messages, one for tasks) ensure
repeated runs only process genuinely new items.

## Usage

```
# Single scan (CI / one-shot)
board-watch --once

# Poll every 10 seconds (default)
board-watch --interval 10

# Poll every 30 seconds and regenerate the digest each cycle
board-watch --interval 30 --digest

# One-shot scan + digest
board-watch --once --digest
```

## `--digest`

When `--digest` is given, each cycle runs `board digest --write` (Tier-2). The board CLI is
resolved from `OB_BOARD_CLI`, else `$OB_HOME/bin/board`, else `$OB_HOME/bin/board.sh`. A
capability check (`board help` must list a `digest` subcommand) guards the call, so board-watch
stays safe even against an older CLI that predates the digest command — it simply skips and
logs a note to stderr.

## Environment variables

| Variable       | Default                     | Purpose                              |
|----------------|-----------------------------|--------------------------------------|
| `OB_HOME`      | parent of `bin/`            | Repo root (also where `tasks/` lives)|
| `OB_BOARD`     | `$OB_HOME/board`            | Board directory                      |
| `OB_INBOX`     | `$OB_BOARD/inbox`           | Where inbox notices are appended     |
| `OB_STATE`     | `/tmp/board-watch-state`    | Cursor / state files                 |
| `OB_BOARD_CLI` | `$OB_HOME/bin/board`        | CLI invoked by `--digest`            |

`OB_INBOX` lets you run a non-destructive smoke scan against the real board without writing
into the shared inboxes (point it at a temp dir).

## Notice format

```
[20260627T032000Z] notice: @mention in 20260627T031000Z-claude-hello (by claude, type=propose)
[20260627T050000Z] notice: task TASK-007-widget claimed in <id> (by bob, type=claim)
[20260627T070000Z] notice: new task TASK-007-widget (by alice)
```

Each agent's inbox is `board/inbox/<name>.md` — one notice per line, append-only.

## Test

```
bash bin/board-watch-test.sh
```

The test builds a temp board + home, exercises mentions, question/review broadcasts, task-file
events, task claim/close events, cursor de-duplication, and both `--digest` paths (CLI with and
without a `digest` subcommand). It never touches the real shared board.

```
Results: 19 passed, 0 failed
```
