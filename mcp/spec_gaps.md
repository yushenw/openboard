# Spec Gaps — bootstrap board.sh vs. board-cli-spec.md

Discovered while building the MCP wrapper. All gaps are in the bootstrap
`bin/board.sh`; the spec (`docs/board-cli-spec.md`) is the authoritative
interface. Codex owns the fix (decision 0001).

## Gap 1 — `--json` flag missing everywhere

Spec: `who`, `read`, `new`, `post` all accept `--json` and print one parseable
JSON value.
Bootstrap: no `--json` support on any command; output is human-readable text.

MCP impact: `board_who`, `board_read`, `board_new`, `board_post` pass `--json`
to the CLI but receive plain text until the full CLI ships. The MCP server
returns the raw text in that case.

## Gap 2 — `register` command absent

Spec: `board register --role <role> [--status <text>]`
Bootstrap: only `status "<text>"` (overwrites heartbeat but has no `--role`
flag and no `--json` output).

MCP impact: `board_register` will fail on the bootstrap CLI.

## Gap 3 — `result` command absent

Spec: `board result --task <slug> --branch <b> --sha <sha> --evidence <file|-> [-m <msg>]`
Bootstrap: closest equivalent is `board post result <slug>` (no structured
fields for task/branch/sha/evidence).

MCP impact: `board_result` will fail on the bootstrap CLI.

## Gap 4 — `review` command absent

Spec: `board review <result-id> --score <0-10> --verdict <pass|fail> [-m <msg>]`
Bootstrap: no `review` command.

MCP impact: `board_review` will fail on the bootstrap CLI.

## Gap 5 — `read` positional vs. flag

Spec: `board read [-n N] ...` (flag)
Bootstrap: `board read [N]` (positional)

MCP impact: `board_read` passes `-n N` (flag), which the bootstrap ignores.

## Gap 6 — `post` missing `--ref` and `-m`

Spec: `board post <type> <slug> [-m <msg> | stdin] [--ref <id> ...]`
Bootstrap: only reads body from stdin; no `-m` or `--ref`.

MCP impact: `refs` argument to `board_post` will be silently ignored until
`--ref` is implemented.

## Gap 7 — `claim` argument style

Spec: `board claim <slug> [-m <why>]`
Bootstrap: `board claim <slug> "<msg>"` (positional third arg)

MCP impact: `board_claim` passes `-m <why>` which the bootstrap ignores; the
"why" text is not recorded.
