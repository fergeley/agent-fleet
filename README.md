# Agent Fleet

Agent Fleet is a thin, native multi-agent workspace launcher and coordinator for **Windows** (Windows Terminal + PowerShell 7), **macOS**, and **Linux** (`tmux`).

Unlike heavy Electron or custom-TUI wrappers, Agent Fleet stays out of your way:
- **Zero Electron, zero background daemon, zero custom PTY replacement.**
- Opens **Claude Code** (`claude agents`) and **Codex CLI** (`codex agents`) directly into their native multi-session dashboards.
- Opens **OpenCode** (`opencode`, which supports multi-session CLI tabs) and **Google Antigravity** (`agy`) side-by-side in isolated Git worktrees, with multi-tab `SingleWindow` support so extra Antigravity worktrees fit cleanly in one window.

## Quick start (Windows)

Requirements: Windows 10/11, PowerShell 7 (`pwsh`), Windows Terminal (`wt`), Git, and one or more supported CLIs.

One-line verified bootstrapper (fetches pinned commit, verifies SHA-256 digests against `release.json` before execution):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/fergeley/agent-fleet/main/install.ps1))) -Init -AddToPath -EnableStartup
```

Or install from a local clone:

```powershell
git clone https://github.com/fergeley/agent-fleet.git
cd agent-fleet
.\Install-AgentFleet.ps1 -Init -AddToPath -EnableStartup
```

To migrate an existing `manifest.json` and replace earlier launchers/shortcuts:

```powershell
.\Install-AgentFleet.ps1 -ImportManifest "C:\path\to\existing\manifest.json" -ForceTakeover -AddToPath -EnableStartup
```

## Quick start (macOS and Linux)

Requirements: `python3` (3.9+), `git`, and `tmux`.

```sh
git clone https://github.com/fergeley/agent-fleet.git
cd agent-fleet
./unix/install.sh --init --worktree /path/to/wt1 --worktree /path/to/wt2
```

Add `~/.local/bin` to your `PATH`, then run `agent-fleet` (or `fleet`).

## Manifest configuration (`manifest.json`)

```json
{
  "DefaultMode": "Jobs",
  "JobsLayout": "SingleWindow",
  "UpdateRepo": "fergeley/agent-fleet",
  "WorktreeCopyFiles": [".env"],
  "AllowWorktreeInclude": false,
  "TabColors": { "hub": "#1e66f5", "agy": "#40a02b" },
  "PowerShell": "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
  "Terminal": "C:\\Users\\you\\AppData\\Local\\Microsoft\\WindowsApps\\wt.exe",
  "Codex": "C:\\Users\\you\\AppData\\Local\\Programs\\OpenAI\\Codex\\bin\\codex.exe",
  "Claude": "C:\\Users\\you\\.local\\bin\\claude.exe",
  "Antigravity": "C:\\Users\\you\\AppData\\Local\\agy\\bin\\agy.exe",
  "Jobs": [
    { "Id": "job-1", "Tab": "hub", "Client": "Codex", "Directory": "C:\\worktrees\\wt-1" },
    { "Id": "job-2", "Tab": "hub", "Client": "Claude", "Directory": "C:\\worktrees\\wt-2", "Args": ["agents"], "Env": { "CLAUDE_CODE_EFFORT": "high" } },
    { "Id": "job-3", "Tab": "agy", "Client": "Antigravity", "Directory": "C:\\worktrees\\wt-3" },
    { "Id": "job-4", "Tab": "agy", "Client": "Antigravity", "Directory": "C:\\worktrees\\wt-4" }
  ]
}
```

- `Tab` groups jobs into up to 4 tabs (max 4 panes per tab, 16 jobs total) inside one `SingleWindow` Windows Terminal window or `tmux` session. Omitting `Tab` uses the default `"fleet"` tab.
- `TabColors` optionally assigns `#RRGGBB` tab colors in Windows Terminal.
- `WorktreeCopyFiles` copies listed gitignored regular files (for example `.env`) from the main repository root into new worktrees created by `-NewWorktree` or `-OpenTab`. Never overwrites existing files, rejects traversal/symlinks/`.git/`, and enforces a 10 MiB / 64-file limit.
- Set `"AllowWorktreeInclude": true` (or pass `-AllowWorktreeInclude`) to also read relative file paths from a repository `.worktreeinclude` file.

## Commands

- `agent-fleet` (`fleet`): Open or focus your configured workspace window(s).
- `agent-fleet -Profile <name>`: Launch or manage an isolated workspace profile (`profiles/<name>/manifest.json`).
- `agent-fleet -PrintPlan`: Inspect resolved tabs, worktrees, client args, and commit SHAs without launching.
- `agent-fleet -Status [-Json | -Watch [-IntervalSeconds 3]]`: Inspect window/`tmux` state, Git branch/dirty counts, and live `claude agents --json --all` sessions.
- `agent-fleet -NewWorktree <path> -Repository <repo> -Branch <name> [-Lock]`: Create an isolated Git worktree and copy configured untracked env files.
- `agent-fleet -OpenTab -Client Antigravity -Repository <repo> -Branch <name> [-TabColor #40a02b]`: Create a worktree if needed and open an ad-hoc tab inside the live Agent Fleet window.
- `agent-fleet -CleanWorktree <path> [-DryRun] [-Force]`: Safely unlock and remove an unused linked worktree after verifying it is not the main repo, not configured in Agent Fleet, not CWD, clean, and merged/pushed.
- `agent-fleet -Dispatch -Client Claude|Codex -Directory <dir> -Prompt "<task>"`: Start a background session (`claude --bg` or `codex exec --json`). Codex reads the prompt from standard input. A Claude prompt cannot start with `-`. The manifest must name the client program file (`.exe`), not a `.cmd` shim, because `cmd.exe` would parse the prompt again.
- `agent-fleet -Queue -Thread <id-or-name> -Message "<text>" [-Resume]`: Queue a follow-up instruction (`codex queue`).
- `agent-fleet -Update` / `-Rollback` / `-AutoUpdate On|Off`: Manage signed SHA-256 runtime updates over public GitHub HTTPS (Protocol 2).
- `agent-fleet -Arrange`: Move the open job windows back to their tiles, or the shared window back to the monitor under the pointer.
- `agent-fleet -Job <id> -ResetPending`: Clear the pending launch of one job. Run it only when no window or client of that launch is still running.

## How a Windows launch behaves

- **Environment.** Terminal panes, the clients in them and `-OpenTab` tabs start with your Windows sign-in environment, plus the `Env` of their job. Variables of the shell that ran `agent-fleet` do not reach them. For example, `NO_COLOR=1` from an agent or editor terminal does not turn off color in your clients. To give a variable to a client, put it in the job's `Env` or in your Windows user environment. `-Dispatch` and `-Queue` start no pane, so their clients run with the environment of the shell that calls them.
- **Window size.** Fleet moves or maximizes a window only after every pane in it has started. Windows Terminal 1.25 often stopped responding when its window changed size while it was still creating panes. The shared `SingleWindow` window then fills the monitor under the pointer. When a pane has not started after 20 seconds in a window that responds, the job still counts as open, Fleet leaves the window where Terminal opened it, and `agent-fleet -Arrange` places it later. A Terminal setting that opens every window maximized or full screen (`launchMode`) was not tested and can cause the same hang.
- **Pending launches.** Fleet records a pending launch before it opens a window, and a pending launch blocks its job until Fleet finds that window. At the next launch after a restart, Fleet moves a pending launch of an earlier boot to `state\retired`, because a restart closes every window. A pending launch of the current boot keeps blocking its job, and the message names the `-ResetPending` command.
- **A frozen Terminal.** When Windows Terminal does not answer within 5 seconds, Fleet reports every job of that window as blocked instead of focusing or moving it. If it does not recover within a minute, end it. Closing a frozen window or ending `WindowsTerminal.exe` in Task Manager ends every Terminal window and its sessions, so save what you need from the other Terminal windows first.
- **Result.** `agent-fleet` exits with 0 when every job opened or was open, and with 1 when a job is blocked. A launch from the desktop or Startup shortcut shows a notice that lists the blocked jobs. The daily update check runs after either result.

### Known limits

- The `agent-fleet` command is a `.cmd` file, so `cmd.exe` reads its arguments first. A `%NAME%` in an argument expands, and a double quote or a line break inside a `-Prompt`, `-Message` or `-TabTitle` value can change or cut the value. Keep such text plain, or run `Start-Fleet.ps1` in the installation folder from PowerShell.
- Windows Terminal joins the client arguments of `-OpenTab` into one command line and expands `%NAME%` in it. An argument that ends with `\` or is empty can reach the client changed.
- Tiles are computed for the monitor under the pointer. On monitors with different scaling, a tile on the other monitor can come out larger after Windows rescales the window. Run `agent-fleet -Arrange` again from that monitor.

### Upgrading from 2.1.0

Version 2.1.0 could not open its window, so its daily update check never ran, and every launch left pending launches behind. An update waits while any pending launch exists, so `agent-fleet -Update` alone reports `deferred` on such an installation. Install again instead, with the bootstrapper or `Install-AgentFleet.ps1`, which also replaces `Start-Fleet.ps1`. Or clear the pending launches first:

1. Close every Agent Fleet window and any window titled `Agent`.
2. For each job, run `agent-fleet -Job <id> -ResetPending`.
3. Run `agent-fleet -Update`.

`-Update` replaces the runtime but not `Start-Fleet.ps1`. A `Start-Fleet.ps1` from before 2.1.1 skips its daily update check after a launch with a blocked job, so installing again is the more complete way.

## Verification

- Windows: `pwsh -NoLogo -NoProfile -File tests/Test-Fleet.ps1`
- Windows desktop with Windows Terminal: `pwsh -NoLogo -NoProfile -File tests/Test-NativeLaunch.ps1`. It opens and closes Terminal windows of a temporary installation and runs a small PowerShell probe in place of each client. GitHub Actions cannot run it, because its runners have no desktop session with Windows Terminal.
- macOS / Linux: `python3 -m unittest discover -s unix -p "test_*.py" -v`
