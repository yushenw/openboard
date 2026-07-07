#!/usr/bin/env bash
# Verifier template — copy to verifiers/TASK-XXX-<slug>.sh (chmod +x) and reference it in
# `board task new --verifier verifiers/TASK-XXX-<slug>.sh`.
#
# Contract: exit 0 = pass, non-zero = fail. Print evidence to stdout — `board verify` embeds
# it into the verification record. Run against the checkout being verified (results carry a
# branch + sha; reviewers run this INSIDE that checkout).
#
# For metric competitions, print a `metric: <number>` line — `task rank` parses it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # repo root of the checkout under test

# --- replace with real checks ---------------------------------------------
echo "verifier: replace me with real checks (tests, lint, benchmark ...)"
# bash tests/run.sh
# echo "metric: $(...)"
exit 1   # template must fail until you implement it
