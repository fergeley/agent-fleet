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
- `agent-fleet -Dispatch -Client Claude|Codex -Directory <dir> -Prompt "<task>"`: Start a background session (`claude --bg` or `codex exec --json`).
- `agent-fleet -Queue -Thread <id-or-name> -Message "<text>" [-Resume]`: Queue a follow-up instruction (`codex queue`).
- `agent-fleet -Update` / `-Rollback` / `-AutoUpdate On|Off`: Manage signed SHA-256 runtime updates over public GitHub HTTPS (Protocol 2).

## Verification

- Windows: `pwsh -NoLogo -NoProfile -File tests/Test-Fleet.ps1`
- macOS / Linux: `python3 -m unittest discover -s unix -p "test_*.py" -v`
