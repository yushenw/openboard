#!/usr/bin/env python3
"""
Smoke test for openboard-mcp.

Schema tests (always run):
  Start the MCP server in a subprocess and validate tool registration
  (15 tools) + the JSON-RPC handshake. No board CLI required.

Live tests (auto-enabled when the board CLI is present):
  Exercise BOTH tiers against the REAL CLI inside an isolated temp OB_HOME, so
  the shared board is never polluted:
    Tier-1: register, who, post, read, new, claim
    Tier-2: task new -> list -> show -> claim -> verify -> close, digest
  All Tier-2 CLI commands now support --json (merged, decision 0005).

Controls:
  OPENBOARD_NO_LIVE=1  force schema-only (skip live even if CLI exists).
  OPENBOARD_LIVE=1     force live (error out if CLI missing).
  BOARD_BIN            path to the board CLI (default /home/liaix/pjs/openboard/bin/board).

Usage:
  python3 mcp/smoke_test.py                       # schema + live (auto)
  OPENBOARD_NO_LIVE=1 python3 mcp/smoke_test.py   # schema only
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
from typing import Any

SERVER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "server.py")
BOARD_BIN = os.environ.get("BOARD_BIN", "/home/liaix/pjs/openboard/bin/board")

_FORCE_LIVE = os.environ.get("OPENBOARD_LIVE") == "1"
_NO_LIVE = os.environ.get("OPENBOARD_NO_LIVE") == "1"
# Live runs by default when the CLI exists; NO_LIVE overrides; LIVE forces.
LIVE = _FORCE_LIVE or (not _NO_LIVE and os.path.exists(BOARD_BIN))

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
    # Tier-1
    "board_register",
    "board_who",
    "board_post",
    "board_read",
    "board_new",
    "board_claim",
    "board_result",
    "board_review",
    # Tier-2
    "board_task_new",
    "board_task_list",
    "board_task_show",
    "board_task_claim",
    "board_task_close",
    "board_digest",
    "board_verify",
}

REQUIRED_TOOL_FIELDS = {"name", "description", "inputSchema"}

REQUIRED_ARG_MAP = {
    # Tier-1
    "board_register": {"role"},
    "board_post": {"type", "slug", "message"},
    "board_claim": {"slug"},
    "board_result": {"task", "branch", "sha", "evidence"},
    "board_review": {"result_id", "score", "verdict"},
    # Tier-2
    "board_task_new": {"title", "type"},
    "board_task_show": {"id"},
    "board_task_claim": {"id"},
    "board_task_close": {"id"},
    "board_verify": {"task"},
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

    check(f"tools/list: all {len(EXPECTED_TOOLS)} tools registered",
          tool_names == EXPECTED_TOOLS,
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


_RID = [100]


def _call(proc: subprocess.Popen, name: str, arguments: dict) -> dict[str, Any]:
    _RID[0] += 1
    resp = send(proc, {
        "jsonrpc": "2.0",
        "id": _RID[0],
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments},
    })
    assert resp is not None
    return resp


def _text(resp: dict[str, Any]) -> str:
    return (resp.get("result", {}).get("content") or [{}])[0].get("text", "")


def _is_error(resp: dict[str, Any]) -> bool:
    return resp.get("result", {}).get("isError", False)


def _json(resp: dict[str, Any]) -> Any:
    try:
        return json.loads(_text(resp))
    except (ValueError, TypeError):
        return None


def run_live_tests(proc: subprocess.Popen) -> None:
    """
    Exercise the REAL board CLI for both tiers inside an isolated temp OB_HOME
    (set up by main()), so the shared board is never touched.
    """
    print("\n=== Tier-1 live tests (real CLI, isolated OB_HOME) ===")

    # register — needed so who/tasks have an author in the fresh board
    resp = _call(proc, "board_register", {"role": "reviewer", "status": "smoke test"})
    check("board_register: not error", not _is_error(resp), _text(resp))

    # who --json returns the just-registered agent
    resp = _call(proc, "board_who", {})
    who = _json(resp)
    check("board_who: valid JSON", who is not None, _text(resp))
    check("board_who: lists registered agent",
          isinstance(who, list) and any("cursor" in json.dumps(a) for a in who),
          _text(resp))

    # post --json returns {id, path}
    resp = _call(proc, "board_post", {
        "type": "answer", "slug": "mcp-smoke", "message": "isolated smoke post",
    })
    posted = _json(resp)
    check("board_post: returns id+path JSON",
          isinstance(posted, dict) and "id" in posted and "path" in posted, _text(resp))

    # new --json returns unseen messages
    resp = _call(proc, "board_new", {})
    check("board_new: not error", not _is_error(resp), _text(resp))

    # read --json filtered by type
    resp = _call(proc, "board_read", {"n": 5, "type": "answer"})
    check("board_read: not error", not _is_error(resp), _text(resp))

    # claim a fresh slug (fresh board -> should succeed)
    resp = _call(proc, "board_claim", {"slug": "mcp-smoke-claim", "why": "live smoke"})
    check("board_claim: succeeds on fresh board", not _is_error(resp), _text(resp))


def run_tier2_live_tests(proc: subprocess.Popen) -> None:
    """
    Real Tier-2 lifecycle against the merged CLI (all commands support --json):
    task new -> list -> show -> claim -> verify -> close, plus digest.
    """
    print("\n=== Tier-2 live tests (real CLI, isolated OB_HOME) ===")

    # task new --json -> {id, path}
    resp = _call(proc, "board_task_new", {
        "title": "Smoke lifecycle task",
        "type": "other",
        "acceptance": "- the wrapper works\n",
    })
    created = _json(resp)
    check("board_task_new: returns id+path JSON",
          isinstance(created, dict) and "id" in created and "path" in created, _text(resp))
    task_id = created.get("id") if isinstance(created, dict) else None
    if not task_id:
        check("board_task_new: got task id", False, "cannot continue Tier-2 lifecycle")
        return

    # task list --json includes the new task as open
    resp = _call(proc, "board_task_list", {})
    listed = _json(resp)
    check("board_task_list: valid JSON", listed is not None, _text(resp))
    check("board_task_list: contains new task", task_id in json.dumps(listed), _text(resp))

    # task list filtered by status=open
    resp = _call(proc, "board_task_list", {"status": "open"})
    check("board_task_list[status=open]: not error", not _is_error(resp), _text(resp))

    # task show --json
    resp = _call(proc, "board_task_show", {"id": task_id})
    shown = _json(resp)
    check("board_task_show: valid JSON with id",
          isinstance(shown, dict) and shown.get("id") == task_id, _text(resp))

    # task claim -> list should now show claimed:<agent>
    resp = _call(proc, "board_task_claim", {"id": task_id, "why": "smoke claim"})
    check("board_task_claim: not error", not _is_error(resp), _text(resp))
    resp = _call(proc, "board_task_list", {"status": "claimed"})
    check("board_task_list[status=claimed]: shows claimed task",
          task_id in _text(resp), _text(resp))

    # verify on a task with no verifier -> exit 2 (usage) -> isError, well-formed
    resp = _call(proc, "board_verify", {"task": task_id})
    check("board_verify: reports missing verifier as error",
          _is_error(resp) and "[exit 2]" in _text(resp), _text(resp))

    # nonexistent task -> exit 4
    resp = _call(proc, "board_task_show", {"id": "TASK-999-nope"})
    check("board_task_show[missing]: exit 4",
          _is_error(resp) and "[exit 4]" in _text(resp), _text(resp))

    # digest --json returns valid JSON
    resp = _call(proc, "board_digest", {})
    dig = _json(resp)
    check("board_digest: valid JSON", dig is not None, _text(resp))

    # task close -> list should show closed
    resp = _call(proc, "board_task_close", {"id": task_id, "reason": "smoke done"})
    check("board_task_close: not error", not _is_error(resp), _text(resp))
    resp = _call(proc, "board_task_list", {"status": "closed"})
    check("board_task_list[status=closed]: shows closed task",
          task_id in _text(resp), _text(resp))


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    env = dict(os.environ)
    # Force the wrapper to shell to the real board CLI.
    env["BOARD_BIN"] = BOARD_BIN
    # Live tests use a throwaway agent identity unless one is provided.
    env.setdefault("OB_AGENT", "cursor")

    tmp_home: str | None = None
    if LIVE:
        if not os.path.exists(BOARD_BIN):
            print(f"OPENBOARD_LIVE forced but board CLI not found: {BOARD_BIN}", file=sys.stderr)
            sys.exit(2)
        # Isolated board so the shared /home/liaix/pjs/openboard/board is untouched.
        tmp_home = tempfile.mkdtemp(prefix="ob-mcp-smoke-")
        os.makedirs(os.path.join(tmp_home, "board", "messages"), exist_ok=True)
        os.makedirs(os.path.join(tmp_home, "board", "agents"), exist_ok=True)
        os.makedirs(os.path.join(tmp_home, "board", "decisions"), exist_ok=True)
        os.makedirs(os.path.join(tmp_home, "tasks"), exist_ok=True)
        os.makedirs(os.path.join(tmp_home, "verifiers"), exist_ok=True)
        env["OB_HOME"] = tmp_home
        env["OB_BOARD"] = os.path.join(tmp_home, "board")
        print(f"[live] isolated OB_HOME={tmp_home}", file=sys.stderr)

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
            run_tier2_live_tests(proc)
    finally:
        proc.terminate()
        proc.wait(timeout=5)
        if tmp_home:
            shutil.rmtree(tmp_home, ignore_errors=True)

    print(f"\n{'='*40}")
    total = _passed + _failed
    mode = "LIVE (isolated)" if LIVE else "schema-only"
    print(f"Results: {_passed}/{total} passed ({mode})")
    if _failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
