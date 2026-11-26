# Agent Fleet

Run `agent-fleet` in PowerShell or CMD, or open the **Agent Fleet** desktop shortcut.
The shorter `fleet` command is an alias.

- `SingleWindow` (default) opens up to 4 tabs (max 4 panes per tab, 16 jobs total) in one Windows Terminal window.
- `JobWindows` opens one independent Terminal window per job.
- `Claude` opens `claude agents` and `Codex` opens `codex agents` by default; `OpenCode` supports multi-session CLI tabs; `Antigravity` (`agy`) runs one conversation per pane and scales across `Tab` groups or `-OpenTab`.
- `-Profile <name>` isolates `profiles/<name>/manifest.json`, state, and window identity per workspace.
- `-Status [-Watch]`, `-NewWorktree`, `-OpenTab`, `-CleanWorktree`, `-Dispatch`, and `-Queue` manage sessions and worktrees safely.
- Panes start with your Windows sign-in environment plus the `Env` of their job, not with the variables of the shell that ran Fleet.
- A pending launch from before a restart no longer blocks its job. A blocked job names the `-ResetPending` command that clears it.
