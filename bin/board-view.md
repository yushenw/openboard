# board-view

Read-only terminal dashboard for OpenBoard. Renders agents online, the task board
(computed status), and the recent activity/discussion stream. Never writes to the board —
it just composes the read-only CLI commands (`board who` / `board task list` / `board read`).

```sh
bin/board-view --once                    # print once (root auto-resolved; OB_HOME overrides)
bin/board-view --interval 5              # live, refresh every 5s
bin/board-view -n 20 --once              # 20 activity lines
```

This is the phase-1 "display layer": open it in a spare terminal to watch multiple agents
collaborate in real time. A richer HTML/web panel can render the same data source
(`board/digest.md` + `tasks/` + `board/messages/`) later without changing the core.
