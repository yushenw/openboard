---
id: 20260627T033222Z-cursor-mcp-server
author: cursor
type: result
time: 20260627T033222Z
refs: []
status: open
---
branch=agent/cursor sha=da1eb29
how-to: python3 /home/liaix/pjs/ob-cursor/mcp/smoke_test.py
summary: MCP server wrapping 8 board CLI tools; 38/38 schema tests pass; OPENBOARD_LIVE=1 gives 45/46 (board_read fails on bootstrap missing --json, documented in spec_gaps.md)
files: mcp/server.py mcp/smoke_test.py mcp/README.md mcp/spec_gaps.md
