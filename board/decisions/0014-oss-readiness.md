---
id: 0014-oss-readiness
author: claude
type: decision
time: 20260704T230500Z
refs: [0012-cold-start-portability, 0013-brief-join-doctor]
task: TASK-002-coldstart
status: resolved
---
OSS-readiness slice — integrate TASK-002 (cold-start, per human-owner directive: peer agents were
offline test sessions, owner authorized direct integration) and close the gaps between "a working
toolkit" and "an open-source project someone can adopt cold".

## Integrated
- TASK-002-coldstart (agent/claude 981a6fd) fast-forwarded into main: root discovery +
  init/brief/join/doctor (decisions 0012+0013), 14-test cold-start suite.

## New in this slice (built on main by integrator, owner-directed)
1. **Broken-reference fix**: hook sync told agents to run `board cat <id>` — the command did not
   exist. Added `board cat` (human + --json, exit 4 unknown) and `board search <pattern>` (case-
   insensitive ERE, -n cap, --json). Tier-1 tests 10-12.
2. **`board version`** + VERSION file (0.1.0); works outside any root (init/help/version skip
   root resolution).
3. **Last hardcoded paths removed from code**: bin/board-view now resolves via ob-common;
   mcp/server.py + smoke_test.py default BOARD_BIN is script-relative. `grep liaix` over
   bin/ mcp/ docs/ = zero hits.
4. **Symlink-safe entry points**: install.sh symlinks broke every `dirname BASH_SOURCE` lookup;
   all five entry points (board wrapper, join, view, watch, hook) now resolve their real location
   through symlink chains first. Verified end-to-end via a fake prefix install.
5. **install.sh**: --prefix (default ~/.local), PATH advice, --uninstall; `git pull` upgrades in
   place because links point into the checkout.
6. **OSS scaffolding**: LICENSE (MIT), CHANGELOG.md (Keep-a-Changelog, 0.1.0), CONTRIBUTING.md
   (the merge gate applies to humans too), .github/workflows/ci.yml (all 7 suites + MCP schema
   as blocking; shellcheck informational until the burn-down).
7. **Docs de-localized**: CONTRACT/USAGE/hooks/onboarding/board-view.md/mcp-README/DESIGN sweep;
   README rewritten as the project front door (why > install > quickstart > loop > components).
   docs/board-cli-spec.md gained a "v0.1 additions" section covering init/brief/doctor/cat/
   search/version.

## Verification
All suites green post-change: Tier-1 12/12 (3 new), Tier-2 15/15, Tier-3 12/12, cold-start 14/14,
view 7/7, watch 24/24, hook 7/7, MCP schema 82/82. Symlink-install verified: version/init/register/
join/view all correct through ~/.local-style links; uninstall removes only our links.

## Known remaining (ordered; from decision 0012 + this assessment)
`git` transport (multi-host boards) -> MCP onboarding resource wired to `brief --json` + uvx
packaging -> Claude Code plugin -> templates/ + example verifiers -> issue templates.
