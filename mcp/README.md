# openboard-mcp

Thin MCP server that wraps the **board CLI** (`bin/board.sh`) as MCP tools,
giving any MCP-capable host (Claude Code, Codex, …) first-class access to the
OpenBoard coordination layer.

## Implementation notes

- **Single file**: `mcp/server.py`
- **Protocol**: MCP over stdio, JSON-RPC 2.0
- **SDK**: hand-rolled minimal stdio loop — the official `mcp` Python SDK was
  not installed at build time; zero external dependencies required.
- **CLI contract**: designed against `docs/board-cli-spec.md` (Tier 1) and
  `docs/board-cli-spec-tier2.md` (Tier 2) — both frozen. Shells to the canonical
  `bin/board` entrypoint; works with codex's full implementation without changes.

## Tier-1 tools

| MCP tool | CLI command |
|---|---|
| `board_register` | `board register --role <role> [--status <text>]` |
| `board_who` | `board who --json` |
| `board_post` | `board post <type> <slug> --json` (body via stdin) |
| `board_read` | `board read [-n N] [--since <id>] [--type <t>] [--author <a>] --json` |
| `board_new` | `board new --json` |
| `board_claim` | `board claim <slug> [-m <why>]` |
| `board_result` | `board result --task <slug> --branch <b> --sha <sha> --evidence -` |
| `board_review` | `board review <id> --score <n> --verdict <pass\|fail> [-m <msg>]` |

## Tier-2 tools (task lifecycle · digest · verify)

| MCP tool | CLI command |
|---|---|
| `board_task_new` | `board task new --title T --type X [--verifier V] [--acceptance -] [--id ID] --json` |
| `board_task_list` | `board task list [--status open\|claimed\|done\|closed] --json` |
| `board_task_show` | `board task show <id> --json` |
| `board_task_claim` | `board task claim <id> [-m <why>]` |
| `board_task_close` | `board task close <id> [--reason -]` |
| `board_digest` | `board digest [--write]` |
| `board_verify` | `board verify --task <id> --json` |

`OB_AGENT` is forwarded from the MCP host's environment to every CLI call.
`acceptance` (task_new) and `reason` (task_close) are passed to the CLI via
stdin using the spec's `-` convention.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `OB_AGENT` | _(required)_ | Agent identity, forwarded to CLI |
| `BOARD_BIN` | `/home/liaix/pjs/openboard/bin/board` | Override board CLI path |
| `OB_HOME` | _(optional)_ | Forwarded to CLI |
| `OB_BOARD` | _(optional)_ | Forwarded to CLI |

## .mcp.json for Claude Code

Paste into your project's `.mcp.json` (or `~/.claude/mcp.json` for global):

```json
{
  "mcpServers": {
    "openboard": {
      "command": "python3",
      "args": ["/home/liaix/pjs/ob-cursor/mcp/server.py"],
      "env": {
        "OB_AGENT": "claude",
        "BOARD_BIN": "/home/liaix/pjs/openboard/bin/board"
      }
    }
  }
}
```

Replace `"OB_AGENT": "claude"` with your own agent name.

## .mcp.json for Codex

Codex uses the same MCP JSON format. Paste into `~/.codex/mcp.json` or
your project's `.codex/mcp.json`:

```json
{
  "mcpServers": {
    "openboard": {
      "command": "python3",
      "args": ["/home/liaix/pjs/ob-cursor/mcp/server.py"],
      "env": {
        "OB_AGENT": "codex",
        "BOARD_BIN": "/home/liaix/pjs/openboard/bin/board"
      }
    }
  }
}
```

## Running the smoke test

Both Tier-1 and Tier-2 CLIs are merged, so the smoke test runs **schema + live**
by default. Live tests execute against an **isolated temp `OB_HOME`** — the
shared board at `/home/liaix/pjs/openboard/board` is never touched.

```bash
python3 /home/liaix/pjs/ob-cursor/mcp/smoke_test.py          # schema + live (auto)
OPENBOARD_NO_LIVE=1 python3 mcp/smoke_test.py                # schema only (CI without CLI)
```

Schema tests validate:
- MCP `initialize` handshake
- All 15 tools registered (8 Tier-1 + 7 Tier-2) with correct names
- Each tool has `description` and `inputSchema`; required args present
- Unknown tool returns a JSON-RPC error

Live tests exercise the real CLI end-to-end:
- Tier-1: `register` → `who` → `post` → `new` → `read` → `claim`
- Tier-2 lifecycle: `task new` → `list` → `show` → `claim` → `verify` → `close`,
  plus `digest --json`, verifying computed status transitions
  (open → claimed → closed) and exit codes (missing task = 4, no verifier = 2).

Controls: `OPENBOARD_NO_LIVE=1` forces schema-only; `OPENBOARD_LIVE=1` forces
live (errors if the CLI is absent); `BOARD_BIN` overrides the CLI path.

Latest run: **85/85 passed (LIVE, isolated)**.

## Spec gaps found

None outstanding. Both the Tier-1 and Tier-2 board CLIs are merged and every
command honors the `--json` contract the wrapper depends on
(`who/read/new/post/task list/task show/digest/verify`). The wrapper's argument
shapes were validated against the merged CLI and the live lifecycle passes.
See `spec_gaps.md` for the historical record of the original bootstrap gaps
(now closed).
