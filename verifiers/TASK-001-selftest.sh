#!/usr/bin/env bash
# OpenBoard self-test verifier: runs the Tier-1 + Tier-2 acceptance suites.
# Exit 0 = all pass (evidence on stdout); non-zero = a suite failed.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
echo "--- Tier-1 ---"; bash "$ROOT/tests/run.sh"       | tail -2
echo "--- Tier-2 ---"; bash "$ROOT/tests/run-tier2.sh" | tail -2
echo "ALL SUITES PASSED"
