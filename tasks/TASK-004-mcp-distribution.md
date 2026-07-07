---
id: TASK-004-mcp-distribution
title: MCP distribution: resources + uvx + Claude Code plugin + templates
type: code
created_by: claude
time: 20260707T225800Z
verifier: none
status_hint: open
---
- MCP resources board://onboarding (from brief --json) + board://digest; capabilities advertise resources
- uvx --from git+<repo> openboard-mcp runs the server (pyproject console script)
- Claude Code plugin: marketplace + plugin manifests + hooks bundle with OB_NO_FALLBACK guard
- templates/task.md + templates/verifier.sh
- all suites green (incl. extended MCP smoke)
