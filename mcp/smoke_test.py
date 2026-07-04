#!/usr/bin/env python3
"""
Smoke test for openboard-mcp.

Schema tests (always run):
  Start the MCP server in a subprocess and validate tool registration
  (19 tools) + the JSON-RPC handshake. No board CLI required.

Live tests (auto-enabled when the board CLI is present):
  Exercise ALL tiers against the REAL CLI inside an isolated temp OB_HOME, so
  the shared board is never polluted:
    Tier-1: register, who, post, read, new, claim
    Tier-2: task new -> list -> show -> claim -> verify -> close, digest
    Tier-3: metric task + competing results -> results, rank, holdout, promote
  Every Tier-2/3 CLI command supports --json (merged, decisions 0005/0008/0009).

Controls:
  OPENBOARD_NO_LIVE=1  force schema-only (skip live even if CLI exists).
  OPENBOARD_LIVE=1     force live (error out if CLI missing).
  BOARD_BIN            path to the board CLI (default: <this repo>/bin/board, script-relative).

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
BOARD_BIN = os.environ.get(
    "BOARD_BIN",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "bin", "board"),
)

_FORCE_LIVE = os.environ.get("OPENBOARD_LIVE") == "1"
_NO_LIVE = os.environ.get("OPENBOARD_NO_LIVE") == "1"
# Live runs by default when the CLI exists; NO_LIVE overrides; LIVE forces.
LIVE = _FORCE_LIVE or (not _NO_LIVE and os.path.exists(BOARD_BIN))

PASS = "\033[32mPASS\033[0m"
FAIL = "\033[31mFAIL\033[0m"

# Env used for live CLI calls (isolated temp OB_HOME); set by main().
_LIVE_ENV: dict[str, str] | None = None

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
    # Tier-3
    "board_task_results",
    "board_task_rank",
    "board_task_promote",
    "board_task_holdout",
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
    # Tier-3
    "board_task_results": {"task"},
    "board_task_rank": {"task"},
    "board_task_promote": {"task", "result_id"},
    "board_task_holdout": {"task", "result_id"},
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


def _cli(agent: str, *args: str, stdin: str | None = None) -> tuple[str, int]:
    """Shell directly to the board CLI as <agent> in the isolated live env.

    Used only to SET UP Tier-3 competition state (multiple authors / reviews);
    the 4 Tier-3 tools themselves are exercised through the MCP server.
    """
    assert _LIVE_ENV is not None
    env = dict(_LIVE_ENV)
    env["OB_AGENT"] = agent
    proc = subprocess.run(
        [BOARD_BIN, *args],
        capture_output=True, text=True, input=stdin, env=env,
    )
    return proc.stdout.strip(), proc.returncode


def _rid_from_path(path: str) -> str:
    return os.path.basename(path).removesuffix(".md")


def run_tier3_live_tests(proc: subprocess.Popen) -> None:
    """
    Real Tier-3 competing-results flow against the merged CLI.

    Setup (direct CLI, distinct authors): a metric task + three results —
    alice=100 (reviewed pass), bob=120 (reviewed pass), dave=999 (NO review).
    Then exercise via MCP: results, rank (bob #1; dave excluded), holdout,
    promote (-> promoted status), plus exit-4 error paths.
    """
    print("\n=== Tier-3 live tests (real CLI, isolated OB_HOME) ===")

    tid = "TASK-777-comp"

    # metric task (max tps)
    out, rc = _cli("cursor", "task", "new", "--id", tid, "--title", "MCP compo",
                   "--type", "research", "--metric", "tps", "--metric-dir", "max", "--json")
    check("setup: metric task created", rc == 0, out)

    # three competing results by distinct authors
    _, rc_a = _cli("alice", "result", "--task", tid, "--branch", "agent/alice",
                   "--sha", "aaa111", "--evidence", "-", "--metric", "100", stdin="ok")
    _, rc_b = _cli("bob", "result", "--task", tid, "--branch", "agent/bob",
                   "--sha", "bbb222", "--evidence", "-", "--metric", "120", stdin="ok")
    _, rc_d = _cli("dave", "result", "--task", tid, "--branch", "agent/dave",
                   "--sha", "ddd444", "--evidence", "-", "--metric", "999", stdin="ok")
    check("setup: three results posted", rc_a == 0 and rc_b == 0 and rc_d == 0,
          f"rc a={rc_a} b={rc_b} d={rc_d}")

    # capture result ids from the board messages dir directly
    msgs_dir = os.path.join(_LIVE_ENV["OB_BOARD"], "messages")  # type: ignore[index]
    result_files = sorted(f for f in os.listdir(msgs_dir) if f.endswith(".md"))
    rid_alice = next((_rid_from_path(f) for f in result_files if "alice" in f), "")
    rid_bob = next((_rid_from_path(f) for f in result_files if "bob" in f), "")
    check("setup: captured alice+bob result ids", bool(rid_alice and rid_bob),
          f"alice={rid_alice} bob={rid_bob}")

    # carol reviews alice + bob PASS (dave left unreviewed).
    # NOTE: pass -m — `board review` without a message exits 1 (CLI bug, see
    # spec_gaps.md T3-Gap A) even though the review file is written correctly.
    _, rc_ra = _cli("carol", "review", rid_alice, "--score", "8", "--verdict", "pass", "-m", "ok")
    _, rc_rb = _cli("carol", "review", rid_bob, "--score", "9", "--verdict", "pass", "-m", "ok")
    check("setup: two passing reviews", rc_ra == 0 and rc_rb == 0, f"ra={rc_ra} rb={rc_rb}")

    # --- exercise the 4 Tier-3 MCP tools ---

    # board_task_results — lists all results with metric + verdict
    resp = _call(proc, "board_task_results", {"task": tid})
    results = _json(resp)
    check("board_task_results: valid JSON", results is not None, _text(resp))
    check("board_task_results: includes metric values",
          "100" in _text(resp) and "120" in _text(resp) and "999" in _text(resp), _text(resp))

    # board_task_rank — bob (120) #1; dave (999, no review) excluded
    resp = _call(proc, "board_task_rank", {"task": tid})
    ranked = _json(resp)
    check("board_task_rank: valid JSON list",
          isinstance(ranked, list) and len(ranked) == 2, _text(resp))
    top = ranked[0] if isinstance(ranked, list) and ranked else {}
    check("board_task_rank: #1 is bob@120 (max), dave excluded",
          str(top.get("metric")) == "120" and "999" not in _text(resp), _text(resp))

    # board_task_holdout — no holdout script -> verdict no-holdout, exit 0
    resp = _call(proc, "board_task_holdout", {"task": tid, "result_id": rid_bob})
    hold = _json(resp)
    check("board_task_holdout: valid JSON, no-holdout verdict",
          isinstance(hold, dict) and hold.get("verdict") == "no-holdout", _text(resp))
    check("board_task_holdout: not error (exit 0)", not _is_error(resp), _text(resp))

    # board_task_holdout with tolerance arg still well-formed
    resp = _call(proc, "board_task_holdout", {"task": tid, "result_id": rid_bob, "tolerance": 0.1})
    check("board_task_holdout[tolerance]: not error", not _is_error(resp), _text(resp))

    # board_task_promote — posts decision, status becomes promoted
    resp = _call(proc, "board_task_promote",
                 {"task": tid, "result_id": rid_bob, "message": "smoke winner"})
    check("board_task_promote: not error", not _is_error(resp), _text(resp))
    resp = _call(proc, "board_task_show", {"id": tid})
    shown = _json(resp)
    check("board_task_promote: status is promoted:<bob>",
          isinstance(shown, dict) and str(shown.get("status", "")).startswith("promoted"),
          _text(resp))

    # error paths
    resp = _call(proc, "board_task_results", {"task": "TASK-000-missing"})
    check("board_task_results[missing]: exit 4",
          _is_error(resp) and "[exit 4]" in _text(resp), _text(resp))
    resp = _call(proc, "board_task_promote", {"task": tid, "result_id": "nope-not-a-result"})
    check("board_task_promote[missing result]: exit 4",
          _is_error(resp) and "[exit 4]" in _text(resp), _text(resp))


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
        # Isolated board so the real shared board is untouched.
        tmp_home = tempfile.mkdtemp(prefix="ob-mcp-smoke-")
        os.makedirs(os.path.join(tmp_home, "board", "messages"), exist_ok=True)
        os.makedirs(os.path.join(tmp_home, "board", "agents"), exist_ok=True)
        os.makedirs(os.path.join(tmp_home, "board", "decisions"), exist_ok=True)
        os.makedirs(os.path.join(tmp_home, "tasks"), exist_ok=True)
        os.makedirs(os.path.join(tmp_home, "verifiers"), exist_ok=True)
        env["OB_HOME"] = tmp_home
        env["OB_BOARD"] = os.path.join(tmp_home, "board")
        global _LIVE_ENV
        _LIVE_ENV = env
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
            run_tier3_live_tests(proc)
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
