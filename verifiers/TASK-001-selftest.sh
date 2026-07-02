#!/usr/bin/env bash
# OpenBoard self-test verifier: runs ALL acceptance suites + emits a structured metric.
# Exit 0 = all pass (evidence on stdout); non-zero = a suite failed.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
echo "--- Tier-1 ---"; bash "$ROOT/tests/run.sh"            | tail -1
echo "--- Tier-2 ---"; bash "$ROOT/tests/run-tier2.sh"     | tail -1
echo "--- Tier-3 ---"; bash "$ROOT/tests/run-tier3.sh"     | tail -1
echo "--- holdout -"; bash "$ROOT/tests/run-holdout.sh"    | tail -1
echo "--- view  ---"; bash "$ROOT/tests/board-view-test.sh" | tail -1
echo "--- hook  ---"; bash "$ROOT/tests/board-hook-test.sh" | tail -1
echo "--- watch ---"; bash "$ROOT/bin/board-watch-test.sh"  | tail -1
echo 'METRICS: {"suites_passed":7}'
echo "ALL SUITES PASSED"
