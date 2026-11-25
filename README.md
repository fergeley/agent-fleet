# Agent Fleet

Agent Fleet is a lightweight multi-agent workspace launcher and coordinator for **Windows** (Windows Terminal + PowerShell 7), **macOS**, and **Linux** (`tmux`).

It starts your configured AI coding CLIs (**Claude Code**, **OpenAI Codex**, **Google Antigravity**, and **OpenCode**) inside isolated Git worktrees, opens Claude and Codex directly into their native multi-session dashboards (`claude agents` and `codex agents`), and adds unified status, worktree creation, background dispatch, and cross-terminal steering.

## Quick start (Windows)

Requirements: Windows 10/11, PowerShell 7 (`pwsh`), Windows Terminal (`wt`), Git, and one or more supported CLIs.

```powershell
git clone https://github.com/fergeley/agent-fleet.git
cd agent-fleet
.\Install-AgentFleet.ps1 -Init -AddToPath -EnableStartup
```

To upgrade later from a local checkout using your saved manifest:

```powershell
.\Install-AgentFleet.ps1
```

To import an existing `manifest.json` from an earlier install:

```powershell
.\Install-AgentFleet.ps1 -ImportManifest "C:\path\to\existing\manifest.json"
```

## Quick start (macOS and Linux)

Requirements: `python3` (3.9+), `git`, and `tmux`.

```sh
git clone https://github.com/fergeley/agent-fleet.git
cd agent-fleet
./unix/install.sh --init --worktree /path/to/wt1 --worktree /path/to/wt2
```

Add `~/.local/bin` to your `PATH`, then run `agent-fleet` (or `fleet`).

## Client startup behavior

| Client | Default startup | Notes |
| --- | --- | --- |
| **Claude Code** | `claude agents` | Opens the native interactive Agent View dashboard. |
| **Codex CLI** | `codex agents` | Opens the native agent command center. |
| **Antigravity** | `agy` | Starts interactive CLI (use `/agents` or `Alt+S` in-session). |
| **OpenCode** | `opencode` | Starts interactive CLI. |

Override defaults per job with optional `Args` and `Env` fields in `manifest.json`:

```json
{
  "DefaultMode": "Jobs",
  "JobsLayout": "SingleWindow",
  "UpdateRepo": "fergeley/agent-fleet",
  "PowerShell": "C:\\Program Files\\PowerShell\\7\\pwsh.exe",
  "Terminal": "C:\\Users\\you\\AppData\\Local\\Microsoft\\WindowsApps\\wt.exe",
  "Codex": "C:\\Users\\you\\AppData\\Local\\Programs\\OpenAI\\Codex\\bin\\codex.exe",
  "Claude": "C:\\Users\\you\\.local\\bin\\claude.exe",
  "Jobs": [
    { "Id": "job-1", "Client": "Codex", "Directory": "C:\\worktrees\\wt-1" },
    { "Id": "job-2", "Client": "Claude", "Directory": "C:\\worktrees\\wt-2", "Args": ["agents"], "Env": { "CLAUDE_CODE_EFFORT": "high" } }
  ]
}
```

Set `JobsLayout` to `"SingleWindow"` (default) for a maximized 2x2 split-pane grid, or `"JobWindows"` for separate tiled windows.

## Commands

- `agent-fleet` (or `fleet`): Open or focus your configured job window(s).
- `agent-fleet -PrintPlan` (`--print-plan` on Unix): Inspect resolved worktrees, client arguments, and commit SHAs without launching.
- `agent-fleet -Status [-Json]` (`--status [--json]`): Inspect window/tmux state, Git worktree branch/dirty counts, and live `claude agents --json --all` sessions.
- `agent-fleet -NewWorktree <path> -Repository <repo> -Branch <name> [-Lock]`: Create an isolated Git worktree outside the repository.
- `agent-fleet -Dispatch -Client Claude|Codex -Directory <dir> -Prompt "<task>"`: Start a background session (`claude --bg` or `codex exec --json`).
- `agent-fleet -Queue -Thread <id-or-name> -Message "<text>" [-Resume]`: Queue a follow-up instruction for Codex (`codex queue`).
- `agent-fleet -Update` / `-Rollback` / `-AutoUpdate On|Off`: Manage signed SHA-256 runtime updates over public GitHub HTTPS (Protocol 2).

## Verification

- Windows: `pwsh -NoLogo -NoProfile -File tests/Test-Fleet.ps1`
- macOS / Linux: `python3 -m unittest discover -s unix -p "test_*.py" -v`
