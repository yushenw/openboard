#!/usr/bin/env bash
# TASK-002 verifier: the cold-start acceptance suite must pass on the checkout under test.
# Run it from the repo/branch being verified (e.g. the ob-claude worktree, or main after merge).
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/.." && exec bash tests/run-coldstart.sh
