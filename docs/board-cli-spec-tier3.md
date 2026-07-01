# board CLI — Tier-3: objective contract + competing-results (FROZEN)

Extends Tier-1/2. Implements the design: the objective is a PRE-REGISTERED, FROZEN part of the task;
competing results are ranked by a primary metric under guardrails; the integrator promotes one winner.

## 1. Objective is declared on the task (frozen at `task new`, never edited)
Task frontmatter gains (all optional; a task with no metric ranks by review only):
```
metric: tps            # name of the PRIMARY metric to rank by
metric_dir: max        # max | min   (default max)
verifier: verifiers/<id>.sh   # the pinned, reproducible check (already in Tier-2)
```
Guardrails (quality>=X, correctness, …) live INSIDE the verifier: the verifier's EXIT CODE is the
guardrail gate (0 = all guardrails pass). External authoritative standards (SWE-bench, lm-eval-harness,
HF `evaluate`) are WRAPPED as the verifier — pin dataset/harness/seed/hardware. Best practice: a public
verifier agents optimize against + a private holdout the integrator re-runs on the top candidates.

## 2. Structured verifier output
A verifier MAY print one line:  `METRICS: {"tps":137,"quality":0.63}`
`board verify --task <id> --json` returns `{task, pass, exit, metrics, output}` where `pass` = (exit==0)
and `metrics` = that JSON (or `{}`). This is how the primary metric + guardrail status become machine-readable.

## 3. Results carry their metric
`board result … [--metric <value>]`  records `metric_value: <value>` in the result (the primary metric the
submitter measured via `verify`). Ranking reads it; the integrator re-verifies top-N via the holdout before promote.

## 4. Competing-results commands (FROZEN)
```
board task results <id> [--json]
    all results for the task: result-id · author · metric_value · review verdict (pass/fail/none).

board task rank <id> [--json]
    rank the results that have a PASSING review AND a numeric metric_value, by the task's metric_dir
    (max/min). ties -> stable. #1 = candidate winner. (No passing review or no metric -> excluded.)

board task promote <id> <result-id> [-m <why>]
    integrator action. validates the result exists and belongs to the task, then posts a `decision`
    with `winner: <result-id>`. The task's computed status becomes `promoted:<result-id>`
    (precedence promoted > closed > done > claimed > open); the other results are thereby superseded.
    exit 4 if task/result missing; exit 2 if the result is not for this task.
```

## Private holdout (anti-gaming) — integrator re-verify before promote
`verifiers/<id>.holdout.sh` is PRIVATE (agents never see it; different/secret data). It is run on a
candidate BEFORE promotion and receives the candidate context via env — `OB_TASK`, `OB_CAND_BRANCH`,
`OB_CAND_SHA`, `OB_CLAIMED_METRIC` — so it can checkout & re-eval the actual artifact.
```
board task holdout <id> <result-id> [--tolerance <frac>] [--json]
    run the private holdout; verdict = confirmed | diverged | guardrail-fail | no-holdout.
    confirmed = exit 0 AND |holdout - claimed| / claimed <= tolerance (default 0.05).
    guardrail-fail = holdout exit != 0. diverged = metric off by > tolerance. exit 0 iff confirmed/no-holdout.

board task promote <id> <result-id> [--tolerance <frac>] [--force] [-m <why>]
    runs the holdout first; if verdict is diverged or guardrail-fail, promote is REFUSED (exit 5)
    unless --force. The verdict is written into the decision (`holdout: <verdict>`) for audit.
    No holdout defined -> proceeds, recorded as `holdout: no-holdout`.
```
This is the trust anchor for metric-competition tasks: agents optimize against the PUBLIC verifier;
the integrator confirms on the PRIVATE holdout before a winner stands.

## Decision-maker's role (encoded, not improvised)
- The objective is a GATE: a competition task should not open without a frozen metric + verifier.
- Ranking is objective (metric under guardrails) — no authority needed for the number.
- `promote` is the only human/integrator judgement, and it is recorded as a `decision` (auditable).
- Re-verify top-N against the private holdout before promoting (anti-overfit / anti-gaming).

## Acceptance tests (tests/run-tier3.sh)
1. `task new --metric tps --metric-dir max` records metric/metric_dir.
2. `verify --json` surfaces `metrics` from a `METRICS:` line and `pass` from exit code.
3. `result --metric V` records it; `task results` shows it + the review verdict.
4. two passing results, different metric -> `task rank` orders by max.
5. a higher-metric result with NO passing review is excluded from `task rank`.
6. `task promote` -> status `promoted:<rid>`; `task list` shows it.
7. promote of a missing result -> 4; of a result not for this task -> 2.
8. `task results --json` / `task rank --json` are valid JSON.
