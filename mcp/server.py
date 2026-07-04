#!/usr/bin/env python3
"""
openboard-mcp — MCP server wrapping the board CLI as MCP tools.

Protocol : MCP over stdio, JSON-RPC 2.0.
SDK note : hand-rolled stdio loop (official `mcp` SDK was not importable at
           build time; this file has zero external dependencies).

Tools wrap both Tier-1 (register/who/post/read/new/claim/result/review) and
Tier-2 (task new/list/show/claim/close, digest, verify) board CLI surfaces.

Configuration (env vars):
  OB_AGENT   — required; identity forwarded to every board CLI call.
  BOARD_BIN  — path to the board CLI (default: <this repo>/bin/board, script-relative).
  OB_HOME    — passed through to the CLI (optional override).
  OB_BOARD   — passed through to the CLI (optional override).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Any

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

VERSION = "0.2.0"
PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "openboard-mcp"

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
# Canonical entrypoint: the board CLI in THIS checkout (mcp/ sits beside bin/).
# Override with BOARD_BIN. The CLI resolves the board root itself (env OB_HOME >
# `.openboard/` marker > its own location), so no absolute path is baked in.
_DEFAULT_BOARD_BIN = os.path.join(os.path.dirname(_THIS_DIR), "bin", "board")

# ---------------------------------------------------------------------------
# CLI helpers
# ---------------------------------------------------------------------------

def _board_bin() -> str:
    return os.environ.get("BOARD_BIN", _DEFAULT_BOARD_BIN)


def _run_board(
    *args: str,
    stdin_data: str | None = None,
) -> tuple[str | None, str, int]:
    """
    Run the board CLI with *args.
    Returns (stdout, stderr, returncode).
    OB_AGENT must be set in environment before calling.
    """
    env = dict(os.environ)  # forward everything, including OB_AGENT / OB_HOME / OB_BOARD
    cmd = [_board_bin()] + list(args)

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            input=stdin_data,
            env=env,
        )
        return result.stdout, result.stderr, result.returncode
    except FileNotFoundError:
        return None, f"Board CLI not found: {_board_bin()}", -1
    except Exception as exc:  # pylint: disable=broad-except
        return None, str(exc), -1


def _ok_content(text: str) -> dict[str, Any]:
    """Return a successful MCP tool content block."""
    return {"content": [{"type": "text", "text": text.strip()}]}


def _err_content(message: str, code: int | None = None) -> dict[str, Any]:
    """Return an error MCP tool content block (isError=True)."""
    detail = f"[exit {code}] {message}" if code is not None else message
    return {
        "content": [{"type": "text", "text": detail}],
        "isError": True,
    }


def _board_result(stdout: str | None, stderr: str, rc: int) -> dict[str, Any]:
    """Convert CLI run result to MCP tool response."""
    if rc == 0:
        text = stdout or ""
        # Try to parse JSON; if it's already JSON just pass it through as text
        return _ok_content(text)
    return _err_content(stderr or f"exit code {rc}", rc)


# ---------------------------------------------------------------------------
# Tool definitions
# ---------------------------------------------------------------------------

TOOLS: list[dict[str, Any]] = [
    {
        "name": "board_register",
        "description": (
            "Register this agent on the board with a role and optional status. "
            "Idempotent — safe to call multiple times."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "role": {
                    "type": "string",
                    "description": "Agent role, e.g. designer / executor / reviewer / integrator.",
                },
                "status": {
                    "type": "string",
                    "description": "Optional human-readable status text.",
                },
            },
            "required": ["role"],
        },
    },
    {
        "name": "board_who",
        "description": "List all registered agents with their role and last-updated timestamp.",
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
    {
        "name": "board_post",
        "description": (
            "Post a message to the board. "
            "Returns the message id and file path as JSON."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "type": {
                    "type": "string",
                    "enum": ["propose", "question", "answer", "result", "review", "claim", "decision"],
                    "description": "Message type.",
                },
                "slug": {
                    "type": "string",
                    "description": "Short topic slug, e.g. my-feature-idea.",
                },
                "message": {
                    "type": "string",
                    "description": "Message body text.",
                },
                "refs": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Optional list of message IDs this post refers to.",
                },
            },
            "required": ["type", "slug", "message"],
        },
    },
    {
        "name": "board_read",
        "description": "Read messages from the board, newest last.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "n": {
                    "type": "integer",
                    "description": "Max number of messages to return (default 20).",
                },
                "since": {
                    "type": "string",
                    "description": "Return only messages newer than this message ID.",
                },
                "type": {
                    "type": "string",
                    "description": "Filter by message type (propose/question/answer/result/review/claim/decision).",
                },
                "author": {
                    "type": "string",
                    "description": "Filter by author agent name.",
                },
            },
            "required": [],
        },
    },
    {
        "name": "board_new",
        "description": (
            "Return messages newer than this agent's read cursor, then advance the cursor. "
            "Idempotent: a second immediate call returns nothing new."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
    {
        "name": "board_claim",
        "description": (
            "Claim a task slug. "
            "Fails (exit 5) if another agent already holds an open claim on the same slug."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "slug": {
                    "type": "string",
                    "description": "Task slug to claim, e.g. mcp-server.",
                },
                "why": {
                    "type": "string",
                    "description": "Optional reason / description for claiming.",
                },
            },
            "required": ["slug"],
        },
    },
    {
        "name": "board_result",
        "description": (
            "Post a result record for a completed task. "
            "The merge gate consumes this record."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "task": {
                    "type": "string",
                    "description": "Task slug, e.g. mcp-server.",
                },
                "branch": {
                    "type": "string",
                    "description": "Git branch name, e.g. agent/cursor.",
                },
                "sha": {
                    "type": "string",
                    "description": "Commit SHA of the deliverable.",
                },
                "evidence": {
                    "type": "string",
                    "description": "Evidence text (test output, logs). Pass '-' to read from stdin instead.",
                },
                "metric": {
                    "type": "number",
                    "description": "Optional primary metric value (Tier-3) — the number ranking reads.",
                },
                "message": {
                    "type": "string",
                    "description": "Optional human-readable summary.",
                },
            },
            "required": ["task", "branch", "sha", "evidence"],
        },
    },
    {
        "name": "board_review",
        "description": (
            "Post a review of another agent's result. "
            "Pass verdict=pass only if score >= 7 and no fatal flaw."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "result_id": {
                    "type": "string",
                    "description": "ID of the result message being reviewed.",
                },
                "score": {
                    "type": "integer",
                    "minimum": 0,
                    "maximum": 10,
                    "description": "Quality score 0–10.",
                },
                "verdict": {
                    "type": "string",
                    "enum": ["pass", "fail"],
                    "description": "pass requires score >= 7.",
                },
                "message": {
                    "type": "string",
                    "description": "Optional review commentary.",
                },
            },
            "required": ["result_id", "score", "verdict"],
        },
    },
    # ---------------------------- Tier-2 tools ----------------------------
    {
        "name": "board_task_new",
        "description": (
            "Create a new immutable task spec file under tasks/. "
            "Returns the task id and path as JSON. Auto-assigns TASK-NNN if no id given."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {
                    "type": "string",
                    "description": "Short task title.",
                },
                "type": {
                    "type": "string",
                    "enum": ["code", "research", "build", "analysis", "other"],
                    "description": "Task type.",
                },
                "verifier": {
                    "type": "string",
                    "description": "Verifier reference: verifiers/<id>.sh | checklist | llm-judge | none.",
                },
                "acceptance": {
                    "type": "string",
                    "description": "Acceptance criteria text. Passed to CLI via stdin (--acceptance -).",
                },
                "id": {
                    "type": "string",
                    "description": "Optional explicit task id, e.g. TASK-007-foo.",
                },
                "metric": {
                    "type": "string",
                    "description": "Tier-3: name of the PRIMARY metric to rank by, e.g. tps.",
                },
                "metric_dir": {
                    "type": "string",
                    "enum": ["max", "min"],
                    "description": "Tier-3: optimization direction for the metric (default max).",
                },
            },
            "required": ["title", "type"],
        },
    },
    {
        "name": "board_task_list",
        "description": (
            "List tasks with computed status (open/claimed/done/closed), "
            "folded from the append-only message log."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "status": {
                    "type": "string",
                    "enum": ["open", "claimed", "done", "closed"],
                    "description": "Optional filter by computed status.",
                },
            },
            "required": [],
        },
    },
    {
        "name": "board_task_show",
        "description": (
            "Show a task's spec plus its folded thread "
            "(claims/results/reviews/decisions). Fails (exit 4) if the task does not exist."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {
                    "type": "string",
                    "description": "Task id, e.g. TASK-001-foo.",
                },
            },
            "required": ["id"],
        },
    },
    {
        "name": "board_task_claim",
        "description": (
            "Claim an existing task. Validates the task exists (exit 4 if not), "
            "then posts a claim (conflict exit 5 if another agent holds an open claim)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {
                    "type": "string",
                    "description": "Task id to claim, e.g. TASK-001-foo.",
                },
                "why": {
                    "type": "string",
                    "description": "Optional reason for claiming.",
                },
            },
            "required": ["id"],
        },
    },
    {
        "name": "board_task_close",
        "description": (
            "Close a task by posting a decision-type message referencing it "
            "(creator/integrator). Fails (exit 4) if the task does not exist."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "id": {
                    "type": "string",
                    "description": "Task id to close.",
                },
                "reason": {
                    "type": "string",
                    "description": "Optional close reason. Passed to CLI via stdin (--reason -).",
                },
            },
            "required": ["id"],
        },
    },
    {
        "name": "board_digest",
        "description": (
            "Render a deterministic rolling summary: agents online, open/claimed tasks, "
            "recent results, active claims, recent decisions. "
            "Set write=true to also save board/digest.md."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "write": {
                    "type": "boolean",
                    "description": "If true, also write board/digest.md (atomic). Default false.",
                },
            },
            "required": [],
        },
    },
    {
        "name": "board_verify",
        "description": (
            "Run the task's verifier (verifiers/<id>.sh) and report pass/fail with captured "
            "output. Does NOT post — attach the output to a result yourself. "
            "exit 4 if task missing, exit 2 if no verifier defined."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "task": {
                    "type": "string",
                    "description": "Task id to verify, e.g. TASK-001-foo.",
                },
            },
            "required": ["task"],
        },
    },
    # ---------------------------- Tier-3 tools ----------------------------
    {
        "name": "board_task_results",
        "description": (
            "List all results for a task: result-id, author, metric_value, and review "
            "verdict (pass/fail/none). exit 4 if the task does not exist."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "task": {
                    "type": "string",
                    "description": "Task id, e.g. TASK-001-foo.",
                },
            },
            "required": ["task"],
        },
    },
    {
        "name": "board_task_rank",
        "description": (
            "Rank a task's results that have BOTH a passing review AND a numeric "
            "metric_value, ordered by the task's metric_dir (max/min). #1 is the "
            "candidate winner. Results lacking a passing review or metric are excluded."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "task": {
                    "type": "string",
                    "description": "Task id to rank.",
                },
            },
            "required": ["task"],
        },
    },
    {
        "name": "board_task_promote",
        "description": (
            "Integrator action: promote a result as the task winner. Runs the private "
            "holdout first; if the verdict is diverged or guardrail-fail the promote is "
            "REFUSED (exit 5) unless force=true. Posts a decision with winner + holdout "
            "verdict; task status becomes promoted:<result-id>. "
            "exit 4 if task/result missing, exit 2 if the result is not for this task."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "task": {
                    "type": "string",
                    "description": "Task id.",
                },
                "result_id": {
                    "type": "string",
                    "description": "Result message id to promote as winner.",
                },
                "tolerance": {
                    "type": "number",
                    "description": "Holdout tolerance fraction (default 0.05).",
                },
                "force": {
                    "type": "boolean",
                    "description": "Promote even if the holdout diverges / fails guardrails.",
                },
                "message": {
                    "type": "string",
                    "description": "Optional reason recorded in the decision.",
                },
            },
            "required": ["task", "result_id"],
        },
    },
    {
        "name": "board_task_holdout",
        "description": (
            "Run the private holdout verifier on a candidate result before promotion. "
            "Verdict = confirmed | diverged | guardrail-fail | no-holdout. confirmed = "
            "holdout exit 0 AND |holdout-claimed|/claimed <= tolerance. "
            "exit 0 iff confirmed/no-holdout. exit 4 if task/result missing."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "task": {
                    "type": "string",
                    "description": "Task id.",
                },
                "result_id": {
                    "type": "string",
                    "description": "Result message id to re-verify against the holdout.",
                },
                "tolerance": {
                    "type": "number",
                    "description": "Tolerance fraction for metric divergence (default 0.05).",
                },
            },
            "required": ["task", "result_id"],
        },
    },
]

# ---------------------------------------------------------------------------
# Tool handlers
# ---------------------------------------------------------------------------

def _require_agent() -> str | None:
    """Return OB_AGENT or None if unset."""
    agent = os.environ.get("OB_AGENT", "")
    return agent if agent else None


def handle_board_register(args: dict[str, Any]) -> dict[str, Any]:
    cmd = ["register", "--role", args["role"]]
    if "status" in args:
        cmd += ["--status", args["status"]]
    stdout, stderr, rc = _run_board(*cmd)
    return _board_result(stdout, stderr, rc)


def handle_board_who(_args: dict[str, Any]) -> dict[str, Any]:
    stdout, stderr, rc = _run_board("who", "--json")
    return _board_result(stdout, stderr, rc)


def handle_board_post(args: dict[str, Any]) -> dict[str, Any]:
    cmd = ["post", args["type"], args["slug"], "--json"]
    for ref in args.get("refs") or []:
        cmd += ["--ref", ref]
    stdout, stderr, rc = _run_board(*cmd, stdin_data=args["message"])
    return _board_result(stdout, stderr, rc)


def handle_board_read(args: dict[str, Any]) -> dict[str, Any]:
    cmd = ["read", "--json"]
    if "n" in args:
        cmd += ["-n", str(args["n"])]
    if "since" in args:
        cmd += ["--since", args["since"]]
    if "type" in args:
        cmd += ["--type", args["type"]]
    if "author" in args:
        cmd += ["--author", args["author"]]
    stdout, stderr, rc = _run_board(*cmd)
    return _board_result(stdout, stderr, rc)


def handle_board_new(_args: dict[str, Any]) -> dict[str, Any]:
    stdout, stderr, rc = _run_board("new", "--json")
    return _board_result(stdout, stderr, rc)


def handle_board_claim(args: dict[str, Any]) -> dict[str, Any]:
    cmd = ["claim", args["slug"]]
    if "why" in args:
        cmd += ["-m", args["why"]]
    stdout, stderr, rc = _run_board(*cmd)
    return _board_result(stdout, stderr, rc)


def handle_board_result(args: dict[str, Any]) -> dict[str, Any]:
    # Evidence is always streamed via stdin (--evidence -): the "evidence" arg
    # holds the literal text whether or not the caller passed the sentinel "-".
    evidence = args["evidence"]
    cmd = ["result",
           "--task", args["task"],
           "--branch", args["branch"],
           "--sha", args["sha"],
           "--evidence", "-"]
    if "metric" in args:
        cmd += ["--metric", str(args["metric"])]
    if args.get("message"):
        cmd += ["-m", args["message"]]
    stdout, stderr, rc = _run_board(*cmd, stdin_data=evidence)
    return _board_result(stdout, stderr, rc)


def handle_board_review(args: dict[str, Any]) -> dict[str, Any]:
    cmd = ["review", args["result_id"],
           "--score", str(args["score"]),
           "--verdict", args["verdict"]]
    if "message" in args:
        cmd += ["-m", args["message"]]
    stdout, stderr, rc = _run_board(*cmd)
    return _board_result(stdout, stderr, rc)


# ------------------------------ Tier-2 handlers ------------------------------

def handle_board_task_new(args: dict[str, Any]) -> dict[str, Any]:
    cmd = ["task", "new",
           "--title", args["title"],
           "--type", args["type"],
           "--json"]
    if "verifier" in args:
        cmd += ["--verifier", args["verifier"]]
    if "id" in args:
        cmd += ["--id", args["id"]]
    if "metric" in args:
        cmd += ["--metric", args["metric"]]
    if "metric_dir" in args:
        cmd += ["--metric-dir", args["metric_dir"]]
    stdin_data = None
    if "acceptance" in args:
        cmd += ["--acceptance", "-"]
        stdin_data = args["acceptance"]
    stdout, stderr, rc = _run_board(*cmd, stdin_data=stdin_data)
    return _board_result(stdout, stderr, rc)


def handle_board_task_list(args: dict[str, Any]) -> dict[str, Any]:
    cmd = ["task", "list", "--json"]
    if "status" in args:
        cmd += ["--status", args["status"]]
    stdout, stderr, rc = _run_board(*cmd)
    return _board_result(stdout, stderr, rc)


def handle_board_task_show(args: dict[str, Any]) -> dict[str, Any]:
    stdout, stderr, rc = _run_board("task", "show", args["id"], "--json")
    return _board_result(stdout, stderr, rc)


def handle_board_task_claim(args: dict[str, Any]) -> dict[str, Any]:
    cmd = ["task", "claim", args["id"]]
    if "why" in args:
        cmd += ["-m", args["why"]]
    stdout, stderr, rc = _run_board(*cmd)
    return _board_result(stdout, stderr, rc)


def handle_board_task_close(args: dict[str, Any]) -> dict[str, Any]:
    cmd = ["task", "close", args["id"]]
    stdin_data = None
    if "reason" in args:
        cmd += ["--reason", "-"]
        stdin_data = args["reason"]
    stdout, stderr, rc = _run_board(*cmd, stdin_data=stdin_data)
    return _board_result(stdout, stderr, rc)


def handle_board_digest(args: dict[str, Any]) -> dict[str, Any]:
    cmd = ["digest", "--json"]
    if args.get("write"):
        cmd += ["--write"]
    stdout, stderr, rc = _run_board(*cmd)
    return _board_result(stdout, stderr, rc)


def handle_board_verify(args: dict[str, Any]) -> dict[str, Any]:
    stdout, stderr, rc = _run_board("verify", "--task", args["task"], "--json")
    return _board_result(stdout, stderr, rc)


# ------------------------------ Tier-3 handlers ------------------------------

def handle_board_task_results(args: dict[str, Any]) -> dict[str, Any]:
    stdout, stderr, rc = _run_board("task", "results", args["task"], "--json")
    return _board_result(stdout, stderr, rc)


def handle_board_task_rank(args: dict[str, Any]) -> dict[str, Any]:
    stdout, stderr, rc = _run_board("task", "rank", args["task"], "--json")
    return _board_result(stdout, stderr, rc)


def handle_board_task_promote(args: dict[str, Any]) -> dict[str, Any]:
    # promote is an integrator action; the CLI does not emit --json.
    cmd = ["task", "promote", args["task"], args["result_id"]]
    if "tolerance" in args:
        cmd += ["--tolerance", str(args["tolerance"])]
    if args.get("force"):
        cmd += ["--force"]
    if "message" in args:
        cmd += ["-m", args["message"]]
    stdout, stderr, rc = _run_board(*cmd)
    return _board_result(stdout, stderr, rc)


def handle_board_task_holdout(args: dict[str, Any]) -> dict[str, Any]:
    cmd = ["task", "holdout", args["task"], args["result_id"]]
    if "tolerance" in args:
        cmd += ["--tolerance", str(args["tolerance"])]
    cmd += ["--json"]
    stdout, stderr, rc = _run_board(*cmd)
    return _board_result(stdout, stderr, rc)


HANDLERS: dict[str, Any] = {
    # Tier-1
    "board_register": handle_board_register,
    "board_who": handle_board_who,
    "board_post": handle_board_post,
    "board_read": handle_board_read,
    "board_new": handle_board_new,
    "board_claim": handle_board_claim,
    "board_result": handle_board_result,
    "board_review": handle_board_review,
    # Tier-2
    "board_task_new": handle_board_task_new,
    "board_task_list": handle_board_task_list,
    "board_task_show": handle_board_task_show,
    "board_task_claim": handle_board_task_claim,
    "board_task_close": handle_board_task_close,
    "board_digest": handle_board_digest,
    "board_verify": handle_board_verify,
    # Tier-3
    "board_task_results": handle_board_task_results,
    "board_task_rank": handle_board_task_rank,
    "board_task_promote": handle_board_task_promote,
    "board_task_holdout": handle_board_task_holdout,
}

# ---------------------------------------------------------------------------
# JSON-RPC 2.0 / MCP stdio loop
# ---------------------------------------------------------------------------

def _send(obj: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def _error_response(req_id: Any, code: int, message: str) -> dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {"code": code, "message": message},
    }


def _handle_request(msg: dict[str, Any]) -> dict[str, Any] | None:
    """Dispatch one JSON-RPC request; return response dict or None for notifications."""
    method = msg.get("method", "")
    req_id = msg.get("id")  # None for notifications
    params = msg.get("params") or {}

    # Notifications have no id — handle and return nothing
    if req_id is None:
        # e.g. notifications/initialized
        return None

    # initialize
    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": SERVER_NAME, "version": VERSION},
            },
        }

    # tools/list
    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": TOOLS},
        }

    # tools/call
    if method == "tools/call":
        name = params.get("name", "")
        arguments = params.get("arguments") or {}

        handler = HANDLERS.get(name)
        if handler is None:
            return _error_response(req_id, -32601, f"Unknown tool: {name}")

        # Check OB_AGENT for tools that need it
        if not _require_agent():
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": _err_content(
                    "OB_AGENT env var is not set. Set it in the MCP server config.", 3
                ),
            }

        try:
            result = handler(arguments)
        except Exception as exc:  # pylint: disable=broad-except
            return _error_response(req_id, -32603, f"Internal error: {exc}")

        return {"jsonrpc": "2.0", "id": req_id, "result": result}

    # Ping / unknown
    if method == "ping":
        return {"jsonrpc": "2.0", "id": req_id, "result": {}}

    return _error_response(req_id, -32601, f"Method not found: {method}")


def main() -> None:
    print(f"[openboard-mcp {VERSION}] ready on stdio", file=sys.stderr)

    for raw_line in sys.stdin:
        raw_line = raw_line.strip()
        if not raw_line:
            continue
        try:
            msg = json.loads(raw_line)
        except json.JSONDecodeError as exc:
            _send(_error_response(None, -32700, f"Parse error: {exc}"))
            continue

        response = _handle_request(msg)
        if response is not None:
            _send(response)


if __name__ == "__main__":
    main()
