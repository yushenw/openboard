#!/usr/bin/env python3
"""
Smoke test for openboard-mcp.

Default mode (no env var needed):
  Starts the MCP server in a subprocess, validates tool registration
  and JSON-RPC handshake. No board CLI required.

Live mode (OPENBOARD_LIVE=1):
  Also exercises board_who, board_new, board_post and board_read
  via the real board CLI. Requires OB_AGENT to be set.

Usage:
  python3 mcp/smoke_test.py                   # schema-only (CI-safe)
  OPENBOARD_LIVE=1 OB_AGENT=cursor python3 mcp/smoke_test.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Any

SERVER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "server.py")
LIVE = os.environ.get("OPENBOARD_LIVE") == "1"

PASS = "\033[32mPASS\033[0m"
FAIL = "\033[31mFAIL\033[0m"

_passed = 0
_failed = 0


def check(label: str, condition: bool, detail: str = "") -> None:
    global _passed, _failed
    if condition:
        print(f"  {PASS}  {label}")
        _passed += 1
    else:
        print(f"  {FAIL}  {label}" + (f" — {detail}" if detail else ""))
        _failed += 1


# ---------------------------------------------------------------------------
# JSON-RPC helpers
# ---------------------------------------------------------------------------

def send(proc: subprocess.Popen, msg: dict[str, Any]) -> dict[str, Any] | None:
    line = json.dumps(msg) + "\n"
    assert proc.stdin is not None
    proc.stdin.write(line)
    proc.stdin.flush()
    assert proc.stdout is not None
    raw = proc.stdout.readline()
    if not raw:
        return None
    return json.loads(raw)


def notify(proc: subprocess.Popen, method: str, params: dict | None = None) -> None:
    msg: dict[str, Any] = {"jsonrpc": "2.0", "method": method}
    if params:
        msg["params"] = params
    assert proc.stdin is not None
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()


# ---------------------------------------------------------------------------
# Test suites
# ---------------------------------------------------------------------------

EXPECTED_TOOLS = {
    "board_register",
    "board_who",
    "board_post",
    "board_read",
    "board_new",
    "board_claim",
    "board_result",
    "board_review",
}

REQUIRED_TOOL_FIELDS = {"name", "description", "inputSchema"}

REQUIRED_ARG_MAP = {
    "board_register": {"role"},
    "board_post": {"type", "slug", "message"},
    "board_claim": {"slug"},
    "board_result": {"task", "branch", "sha", "evidence"},
    "board_review": {"result_id", "score", "verdict"},
}


def run_schema_tests(proc: subprocess.Popen) -> None:
    """Validate MCP handshake and tool schemas without calling the CLI."""

    print("\n=== Schema / registration tests ===")

    # 1. initialize
    resp = send(proc, {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "smoke-test", "version": "0.1.0"},
        },
    })
    assert resp is not None
    check("initialize: response has result", "result" in resp)
    check("initialize: serverInfo.name", resp.get("result", {}).get("serverInfo", {}).get("name") == "openboard-mcp")
    check("initialize: protocolVersion", "protocolVersion" in resp.get("result", {}))

    # send initialized notification (no response expected)
    notify(proc, "notifications/initialized")

    # 2. tools/list
    resp = send(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    assert resp is not None
    tools = resp.get("result", {}).get("tools", [])
    tool_names = {t["name"] for t in tools}

    check("tools/list: all 8 tools registered", tool_names == EXPECTED_TOOLS,
          f"got {tool_names}")

    for tool in tools:
        name = tool.get("name", "?")
        has_fields = REQUIRED_TOOL_FIELDS.issubset(tool.keys())
        check(f"tool {name}: has name/description/inputSchema", has_fields)

        schema = tool.get("inputSchema", {})
        check(f"tool {name}: inputSchema type=object", schema.get("type") == "object",
              f"type={schema.get('type')}")

        required_args = REQUIRED_ARG_MAP.get(name, set())
        actual_props = set(schema.get("properties", {}).keys())
        missing = required_args - actual_props
        check(f"tool {name}: required args in properties", not missing,
              f"missing: {missing}")

        actual_required = set(schema.get("required", []))
        check(f"tool {name}: required[] correct",
              required_args == actual_required or not required_args or actual_required.issuperset(required_args),
              f"schema required={actual_required}, expected superset of {required_args}")

    # 3. unknown tool
    resp = send(proc, {
        "jsonrpc": "2.0",
        "id": 3,
        "method": "tools/call",
        "params": {"name": "nonexistent_tool", "arguments": {}},
    })
    assert resp is not None
    check("unknown tool: returns error", "error" in resp, str(resp))

    # 4. ping
    resp = send(proc, {"jsonrpc": "2.0", "id": 4, "method": "ping"})
    assert resp is not None
    check("ping: responds", "result" in resp or "error" not in resp)


def run_live_tests(proc: subprocess.Popen) -> None:
    """Exercise actual board CLI calls. Requires OPENBOARD_LIVE=1 and OB_AGENT."""

    print("\n=== Live CLI tests (OPENBOARD_LIVE=1) ===")

    agent = os.environ.get("OB_AGENT", "")
    check("OB_AGENT is set", bool(agent), "set OB_AGENT before running live tests")
    if not agent:
        return

    # board_who
    resp = send(proc, {
        "jsonrpc": "2.0",
        "id": 10,
        "method": "tools/call",
        "params": {"name": "board_who", "arguments": {}},
    })
    assert resp is not None
    content = resp.get("result", {}).get("content", [])
    is_err = resp.get("result", {}).get("isError", False)
    check("board_who: not error", not is_err, str(resp.get("result")))
    check("board_who: has content", bool(content))

    # board_new
    resp = send(proc, {
        "jsonrpc": "2.0",
        "id": 11,
        "method": "tools/call",
        "params": {"name": "board_new", "arguments": {}},
    })
    assert resp is not None
    is_err = resp.get("result", {}).get("isError", False)
    check("board_new: not error", not is_err, str(resp.get("result")))

    # board_post
    resp = send(proc, {
        "jsonrpc": "2.0",
        "id": 12,
        "method": "tools/call",
        "params": {
            "name": "board_post",
            "arguments": {
                "type": "answer",
                "slug": "mcp-smoke-test",
                "message": "MCP smoke test live post — ignore.",
            },
        },
    })
    assert resp is not None
    is_err = resp.get("result", {}).get("isError", False)
    check("board_post: not error", not is_err, str(resp.get("result")))
    content_text = (resp.get("result", {}).get("content") or [{}])[0].get("text", "")
    check("board_post: returns path or id", bool(content_text))

    # board_read
    resp = send(proc, {
        "jsonrpc": "2.0",
        "id": 13,
        "method": "tools/call",
        "params": {
            "name": "board_read",
            "arguments": {"n": 5},
        },
    })
    assert resp is not None
    is_err = resp.get("result", {}).get("isError", False)
    check("board_read: not error", not is_err, str(resp.get("result")))

    # board_claim (may fail with exit 5 if already claimed — that's OK)
    resp = send(proc, {
        "jsonrpc": "2.0",
        "id": 14,
        "method": "tools/call",
        "params": {
            "name": "board_claim",
            "arguments": {"slug": "mcp-smoke-test-claim", "why": "live smoke test"},
        },
    })
    assert resp is not None
    is_fatal = resp.get("result", {}).get("isError", False)
    # exit 5 (conflict) is acceptable; any other failure is not
    content_text = (resp.get("result", {}).get("content") or [{}])[0].get("text", "")
    is_conflict = "[exit 5]" in content_text
    check("board_claim: ok or conflict", not is_fatal or is_conflict,
          f"unexpected error: {content_text}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    env = dict(os.environ)
    # Ensure server can start even without OB_AGENT for schema tests
    if "OB_AGENT" not in env:
        env["OB_AGENT"] = ""

    proc = subprocess.Popen(
        [sys.executable, SERVER],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env,
    )

    try:
        run_schema_tests(proc)
        if LIVE:
            run_live_tests(proc)
    finally:
        proc.terminate()
        proc.wait(timeout=5)

    print(f"\n{'='*40}")
    total = _passed + _failed
    print(f"Results: {_passed}/{total} passed" + (" (LIVE)" if LIVE else " (schema-only)"))
    if _failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
