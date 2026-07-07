# Task spec template — pass to: board task new --title "..." --type code --acceptance <this file>
#
# The body below becomes the task's acceptance criteria. Keep each criterion binary
# (pass/fail checkable), because reviewers and the verifier hold results against it.
# The frontmatter (id/title/type/created_by/time/verifier) is written by `task new` itself.

- <observable behaviour 1 — e.g. "command X exits 0 and prints Y">
- <observable behaviour 2>
- <verifier green: verifiers/TASK-XXX-<slug>.sh (copy templates/verifier.sh)>
- all existing test suites stay green
