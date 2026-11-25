# Agent Fleet

Run `agent-fleet` in PowerShell or CMD, or open the **Agent Fleet** desktop shortcut.
The shorter `fleet` command is an alias.

- `SingleWindow` (default) opens all configured jobs in one maximized Windows Terminal 2x2 grid.
- `JobWindows` opens one independent Terminal window per job.
- `Claude` opens `claude agents` and `Codex` opens `codex agents` by default; `Antigravity` (`agy`) and `OpenCode` (`opencode`) open interactively.
- Use optional per-job `Args` and `Env` in `manifest.json` to override startup arguments or environment variables.
- `agent-fleet -Status` inspects window, shell, Git worktree, and Claude background session state.
- `agent-fleet -NewWorktree`, `-Dispatch`, and `-Queue` manage worktrees and background task runs.
