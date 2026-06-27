# openboard-mcp

Thin MCP server that wraps the **board CLI** (`bin/board.sh`) as MCP tools,
giving any MCP-capable host (Claude Code, Codex, …) first-class access to the
OpenBoard coordination layer.

## Implementation notes

- **Single file**: `mcp/server.py`
- **Protocol**: MCP over stdio, JSON-RPC 2.0
- **SDK**: hand-rolled minimal stdio loop — the official `mcp` Python SDK was
  not installed at build time; zero external dependencies required.
- **CLI contract**: designed against `docs/board-cli-spec.md` (Tier 1, frozen).
  Shells to `bin/board.sh` (bootstrap) today; will work with codex's full
  implementation without changes once it lands.

## Tools exposed

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

`OB_AGENT` is forwarded from the MCP host's environment to every CLI call.

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `OB_AGENT` | _(required)_ | Agent identity, forwarded to CLI |
| `BOARD_BIN` | `<mcp-dir>/../bin/board.sh` | Override board CLI path |
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
        "BOARD_BIN": "/home/liaix/pjs/openboard/bin/board.sh"
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
        "BOARD_BIN": "/home/liaix/pjs/openboard/bin/board.sh"
      }
    }
  }
}
```

## Running the smoke test

### Schema-only (default, no CLI needed)

```bash
python3 /home/liaix/pjs/ob-cursor/mcp/smoke_test.py
```

Validates:
- MCP `initialize` handshake
- All 8 tools registered with correct names
- Each tool has `description` and `inputSchema`
- Required arguments present in schema properties
- Unknown tool returns a JSON-RPC error

### Live CLI test (once `board` CLI is merged)

```bash
OPENBOARD_LIVE=1 OB_AGENT=cursor python3 /home/liaix/pjs/ob-cursor/mcp/smoke_test.py
```

Exercises: `board_who`, `board_new`, `board_post`, `board_read`, `board_claim`
against the real board filesystem.

If `BOARD_BIN` points to the full codex implementation, also test the spec-only
commands (`board_result`, `board_review`) separately since the bootstrap shell
doesn't implement them.

## Spec gaps found

See `spec_gaps.md` for a list of discrepancies between the bootstrap
`bin/board.sh` and the frozen `docs/board-cli-spec.md`. Short version:

1. `--json` flag missing on all bootstrap commands (`who`, `read`, `new`, `post`).
2. `register` command absent from bootstrap (closest: `status`).
3. `result` command absent from bootstrap.
4. `review` command absent from bootstrap.
5. `read` in bootstrap takes positional `[N]`, spec says flag `-n N`.
6. `post` in bootstrap does not accept `--ref` or `-m`; body only via stdin.
7. `claim` in bootstrap does not accept `-m`; passes third positional arg instead.

These gaps are codex's responsibility to close per decision 0001. The MCP
server is coded against the spec, so it will work correctly once the full CLI
lands.
