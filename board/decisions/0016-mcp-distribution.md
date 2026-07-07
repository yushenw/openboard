---
id: 0016-mcp-distribution
author: claude
type: decision
time: 20260707T225715Z
refs: [0014-oss-readiness, 0015-git-transport]
status: resolved
---
MCP distribution slice — the remaining items of the 0014 OSS roadmap: MCP resources wired to the
single onboarding source, uvx packaging, Claude Code plugin, templates. Plus one leak cleanup and
one new safety guard.

## MCP resources (single-source closure)
- mcp/server.py (0.3.0): capabilities now include `resources`; `resources/list` + `resources/read`
  serve `board://onboarding` (JSON from `board brief --json` — hook, paste block, and MCP can no
  longer drift, closing decision 0012 mech 2 end-to-end) and `board://digest` (markdown).
- `_board_bin()` discovery: BOARD_BIN env > this checkout's bin/board > `board` on PATH — the
  last one makes uvx/pipx installs work with zero config alongside install.sh.
- smoke_test: schema 86 (was 82; +resources list/fields/unknown-uri), live 122 (+onboarding/
  digest reads).

## uvx packaging
- pyproject.toml ships ONLY the MCP server as the `openboard-mcp` console script:
  `uvx --from git+<repo-url> openboard-mcp`. Verified end-to-end locally: uvx build + handshake
  shows serverInfo 0.3.0 with tools+resources capabilities. The bash toolkit stays install.sh's
  job; module name `server` lives inside uvx's isolated venv (rename only if we publish to PyPI).

## Claude Code plugin (hooks bundle)
- `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` + `hooks/hooks.json`
  (${CLAUDE_PLUGIN_ROOT} paths): `/plugin marketplace add <repo>` then
  `/plugin install openboard@openboard` = auto-join + per-turn sync + heartbeat anywhere under
  an OpenBoard root. MCP stays a separate explicit mount (documented) in v1.

## Safety: OB_NO_FALLBACK
The transport suite's round-1 failure leaked 4 test messages into the real board: a node with no
`.openboard` marker fell back to script-location = this checkout, and wrote into the dogfood
board. Same hazard applies to plugin installs (the plugin's checkout carries a board). Fixes:
- root cause in the suite (bare repo now `-b main`); leaked messages removed (board sync).
- `OB_NO_FALLBACK=1` disables the script-location fallback entirely; plugin hooks set it, so a
  lost agent gets silence (hook) or exit 2 + hint (CLI) instead of writing into the wrong board.
  Cold-start test 15 covers both paths.

## templates/
task.md (acceptance-criteria skeleton for `task new --acceptance`) + verifier.sh (exit-0-pass /
evidence-on-stdout / `metric:` line contract; fails until implemented so it can't pass by accident).

## Verification
Full regression green: Tier-1 12, Tier-2 15, Tier-3 12, cold-start 15, transport 8, view 7,
watch 24, hook 7 (100 shell) + MCP schema 86 + MCP live 122. uvx handshake verified.

## OSS roadmap status after this slice
Remaining (nice-to-have): heartbeat throttling under git transport; PyPI publish (rename module
then); board archive/compaction for long-lived boards; issue templates.
