# Spec Gaps — board.sh vs. frozen specs

Discovered while building the MCP wrapper. Codex owns the CLI (decisions 0001,
0004). The MCP server is coded against the frozen specs and works unchanged as
codex's CLI catches up.

## Open CLI bug (Tier-3 testing)

### T3-Gap A — `board review` without `-m` exits 1 (record IS written)
`cmd_review` ends with:
```
{ ...frontmatter... ; [ -n "$msg" ] && printf '%s\n' "$msg"; } | atomic_write "$REC_PATH"
printf '%s\n' "$REC_PATH"
```
Under `set -euo pipefail`, when `-m` is omitted `msg` is empty, so the trailing
`[ -n "$msg" ]` returns 1; with `pipefail` the whole pipeline is non-zero and
`set -e` aborts the function **before** the path is printed. Net effect: the
review file is written correctly but the command reports **exit 1** and prints
no path. Passing `-m <msg>` avoids it.
Fix (codex): make the message optional without failing, e.g.
`if [ -n "$msg" ]; then printf '%s\n' "$msg"; fi` as a standalone stmt, or
append with `|| true`. The MCP `board_review` tool forwards `message` when the
caller supplies it, so hosts can already work around this today.

## STATUS: wrapper complete through Tier-3

- **Tier-1 CLI MERGED.** `register / who / post / read / new / claim / result /
  review` work with `--json`. Original bootstrap gaps 1–7 (below) are CLOSED.
- **Tier-2 CLI MERGED** (decision 0005). `task {new,list,show,claim,close}`,
  `digest [--write] [--json]`, `verify --task <id> [--json]` all support `--json`.
- **Tier-3 CLI MERGED** (decisions 0008/0009). `task {results,rank,promote,
  holdout}` plus `--metric`/`--metric-dir` on `task new` and `--metric` on
  `result`. Wrapper arg shapes validated against the merged CLI; the full live
  competition flow (results → rank with unreviewed candidate excluded → holdout
  no-holdout → promote → `promoted:<id>`) passes 116/116 in the isolated smoke
  test. `promote` correctly has no `--json` (integrator action); all other
  Tier-3 reads use `--json`.

Aside from T3-Gap A above, no wrapper changes are pending. Sections below are historical.

---

# Historical: original bootstrap gaps (Tier-1, now CLOSED)

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
