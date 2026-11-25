#!/usr/bin/env python3
"""Cross-platform macOS and Linux (tmux) runtime for Agent Fleet 2.0.0."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

SUPPORTED_CLIENTS = ("Codex", "Claude", "Antigravity", "OpenCode")
DEFAULT_CLIENT_ARGS = {
    "Codex": ["agents"],
    "Claude": ["agents"],
    "Antigravity": [],
    "OpenCode": [],
}
GIT_OVERRIDE_ENV = {
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_COMMON_DIR",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
}
JOB_ID_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
REPO_SLUG_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
VERSION_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
HEX64_RE = re.compile(r"^[A-F0-9]{64}$")
COMMIT40_RE = re.compile(r"^[0-9a-f]{40}$")
DEFAULT_UPDATE_REPO = "fergeley/agent-fleet"


def default_install_root() -> Path:
    xdg_data = os.environ.get("XDG_DATA_HOME", "").strip()
    base = Path(xdg_data) if xdg_data else Path.home() / ".local" / "share"
    return base / "agent-fleet"


def default_manifest_path() -> Path:
    xdg_cfg = os.environ.get("XDG_CONFIG_HOME", "").strip()
    base = Path(xdg_cfg) if xdg_cfg else Path.home() / ".config"
    return base / "agent-fleet" / "manifest.json"


def default_bin_dir() -> Path:
    return Path.home() / ".local" / "bin"


def ensure_absolute_path(value: str, label: str = "Path") -> str:
    if not isinstance(value, str) or not value.strip() or not os.path.isabs(value):
        raise ValueError(f"{label} must be an absolute path.")
    return os.path.normpath(value)


def resolve_final_dir(path: str | Path) -> str:
    return os.path.realpath(str(path))


def assert_no_git_overrides() -> None:
    for name in sorted(GIT_OVERRIDE_ENV):
        if name in os.environ:
            raise RuntimeError(f"Remove the inherited Git source override before launching: {name}")


def parse_job_args(job: dict[str, Any], job_id: str) -> list[str] | None:
    if "Args" not in job:
        return None
    raw = job["Args"]
    if not isinstance(raw, list) or any(not isinstance(item, str) for item in raw):
        raise ValueError(f"The Jobs Args field must be a string array for {job_id}.")
    return list(raw)


def parse_job_env(job: dict[str, Any], job_id: str) -> dict[str, str] | None:
    if "Env" not in job:
        return None
    raw = job["Env"]
    if not isinstance(raw, dict):
        raise ValueError(f"The Jobs Env field must be an object for {job_id}.")
    parsed: dict[str, str] = {}
    for k, v in raw.items():
        if not isinstance(k, str) or not k.strip() or not isinstance(v, str):
            raise ValueError(f"The Jobs Env entries must map non-empty keys to strings for {job_id}.")
        if k.upper() in GIT_OVERRIDE_ENV:
            raise ValueError(f"The Jobs Env cannot override Git source variables: {k}")
        parsed[k] = v
    return parsed


def client_arguments(client: str, custom_args: list[str] | None = None) -> list[str]:
    if custom_args is not None:
        return list(custom_args)
    if client not in DEFAULT_CLIENT_ARGS:
        raise ValueError(f"The Jobs client is unsupported: {client}")
    return list(DEFAULT_CLIENT_ARGS[client])


def validate_manifest(manifest: dict[str, Any], job_id: str = "") -> tuple[str, list[dict[str, Any]]]:
    assert_no_git_overrides()
    default_mode = manifest.get("DefaultMode", "Jobs")
    if default_mode != "Jobs":
        raise ValueError("Unix Agent Fleet supports DefaultMode 'Jobs' only.")
    layout = manifest.get("JobsLayout", "SingleWindow")
    if layout not in ("SingleWindow", "JobWindows"):
        raise ValueError("The Jobs layout is invalid.")
    raw_jobs = manifest.get("Jobs")
    if not isinstance(raw_jobs, list) or not (1 <= len(raw_jobs) <= 4):
        raise ValueError("Configure one to four Jobs entries.")

    seen_ids: set[str] = set()
    definitions: list[dict[str, Any]] = []
    for entry in raw_jobs:
        if not isinstance(entry, dict):
            raise ValueError("Each Jobs entry must be an object.")
        jid = entry.get("Id")
        if not isinstance(jid, str) or not JOB_ID_RE.match(jid):
            raise ValueError("Every Jobs entry needs an explicit lowercase ASCII ID of 1 to 32 filename-safe characters.")
        if jid in seen_ids:
            raise ValueError(f"The Jobs ID is duplicated: {jid}")
        seen_ids.add(jid)
        if job_id and jid != job_id:
            continue
        client = entry.get("Client")
        if client not in SUPPORTED_CLIENTS:
            raise ValueError(f"The Jobs client is unsupported: {client}")
        directory = ensure_absolute_path(str(entry.get("Directory", "")), "Job Directory")
        if not os.path.isdir(directory):
            raise ValueError(f"The configured directory is unavailable: {directory}")
        exe = ensure_absolute_path(str(manifest.get(client, "")), client)
        if not (os.path.isfile(exe) and os.access(exe, os.X_OK)):
            raise ValueError(f"The configured executable is unavailable: {client}")
        custom_args = parse_job_args(entry, jid)
        custom_env = parse_job_env(entry, jid)
        definitions.append(
            {
                "Id": jid,
                "Client": client,
                "Directory": directory,
                "Executable": exe,
                "NativeArguments": client_arguments(client, custom_args),
                "NativeEnv": custom_env,
            }
        )

    if job_id and len(definitions) != 1:
        raise ValueError(f"The Jobs ID is not configured: {job_id}")

    seen_git_dirs: set[str] = set()
    for job in definitions:
        git_proc = subprocess.run(
            ["git", "-C", job["Directory"], "rev-parse", "--absolute-git-dir"],
            capture_output=True,
            text=True,
        )
        if git_proc.returncode != 0 or not git_proc.stdout.strip():
            raise ValueError(f"The configured worker is not a Git worktree: {job['Directory']}")
        canonical_git = resolve_final_dir(git_proc.stdout.strip())
        if canonical_git in seen_git_dirs:
            raise ValueError("Jobs must identify distinct Git worktrees.")
        seen_git_dirs.add(canonical_git)
        head_proc = subprocess.run(
            ["git", "-C", job["Directory"], "rev-parse", "HEAD"],
            capture_output=True,
            text=True,
        )
        if head_proc.returncode != 0 or not head_proc.stdout.strip():
            raise ValueError(f"The Jobs Git HEAD is unavailable: {job['Directory']}")
        job["GitDirectory"] = canonical_git
        job["ObservedHead"] = head_proc.stdout.strip()

    return layout, definitions


def build_pane_command(job: dict[str, Any]) -> list[str]:
    cmd: list[str] = []
    if job.get("NativeEnv"):
        env_pairs = [f"{k}={v}" for k, v in job["NativeEnv"].items()]
        cmd.extend(["env", *env_pairs])
    cmd.append(job["Executable"])
    cmd.extend(job["NativeArguments"])
    return cmd


def tmux_session_name(install_root: Path, suffix: str) -> str:
    tag = hashlib.sha256(str(install_root).encode("utf-8")).hexdigest()[:8]
    return f"agent-fleet-{tag}-{suffix}"


def build_launch_plan(
    manifest: dict[str, Any],
    install_root: Path,
    job_id: str = "",
) -> dict[str, Any]:
    layout, jobs = validate_manifest(manifest, job_id=job_id)
    if layout == "SingleWindow":
        session = tmux_session_name(install_root, "single")
        steps: list[list[str]] = []
        first = jobs[0]
        steps.append(
            [
                "new-session",
                "-d",
                "-s",
                session,
                "-n",
                "fleet",
                "-c",
                first["Directory"],
                *build_pane_command(first),
            ]
        )
        if len(jobs) == 2:
            steps.append(["split-window", "-h", "-t", f"{session}:0.0", "-c", jobs[1]["Directory"], *build_pane_command(jobs[1])])
            steps.append(["select-layout", "-t", f"{session}:0", "even-horizontal"])
        elif len(jobs) == 3:
            steps.append(["split-window", "-h", "-t", f"{session}:0.0", "-c", jobs[1]["Directory"], *build_pane_command(jobs[1])])
            steps.append(["split-window", "-v", "-t", f"{session}:0.0", "-c", jobs[2]["Directory"], *build_pane_command(jobs[2])])
            steps.append(["select-layout", "-t", f"{session}:0", "tiled"])
        elif len(jobs) == 4:
            steps.append(["split-window", "-h", "-t", f"{session}:0.0", "-c", jobs[1]["Directory"], *build_pane_command(jobs[1])])
            steps.append(["split-window", "-v", "-t", f"{session}:0.1", "-c", jobs[3]["Directory"], *build_pane_command(jobs[3])])
            steps.append(["split-window", "-v", "-t", f"{session}:0.0", "-c", jobs[2]["Directory"], *build_pane_command(jobs[2])])
            steps.append(["select-layout", "-t", f"{session}:0", "tiled"])
        return {
            "Mode": "Jobs",
            "Layout": "SingleWindow",
            "Sessions": [{"SessionName": session, "TmuxCommands": steps, "Jobs": jobs}],
        }

    sessions = []
    for job in jobs:
        session = tmux_session_name(install_root, job["Id"])
        sessions.append(
            {
                "SessionName": session,
                "TmuxCommands": [
                    [
                        "new-session",
                        "-d",
                        "-s",
                        session,
                        "-n",
                        job["Id"],
                        "-c",
                        job["Directory"],
                        *build_pane_command(job),
                    ]
                ],
                "Jobs": [job],
            }
        )
    return {"Mode": "Jobs", "Layout": "JobWindows", "Sessions": sessions}


def git_status(directory: str) -> dict[str, Any]:
    empty = {"State": "unavailable", "Branch": None, "Head": None, "DirtyCount": None, "Ahead": None, "Behind": None}
    if not directory or not os.path.isdir(directory):
        return empty
    proc = subprocess.run(
        ["git", "-C", directory, "status", "--porcelain=v2", "--branch"],
        capture_output=True,
        text=True,
        timeout=3,
    )
    if proc.returncode != 0:
        return empty
    branch = None
    head = None
    ahead = None
    behind = None
    dirty = 0
    for line in proc.stdout.splitlines():
        if line.startswith("# branch.oid "):
            oid = line[13:].strip()
            if oid and oid != "(initial)":
                head = oid
        elif line.startswith("# branch.head "):
            branch = line[14:].strip()
        elif line.startswith("# branch.ab "):
            m = re.match(r"^# branch\.ab \+(\d+) -(\d+)$", line)
            if m:
                ahead = int(m.group(1))
                behind = int(m.group(2))
        elif line and not line.startswith("#"):
            dirty += 1
    return {"State": "observed", "Branch": branch, "Head": head, "DirtyCount": dirty, "Ahead": ahead, "Behind": behind}


def claude_sessions(claude_exe: str) -> dict[str, Any]:
    empty = {"State": "unavailable", "Sessions": []}
    if not claude_exe or not os.path.isfile(claude_exe):
        return empty
    try:
        if os.path.getsize(claude_exe) == 0:
            return empty
        proc = subprocess.run([claude_exe, "agents", "--json", "--all"], capture_output=True, text=True, timeout=5)
        if proc.returncode != 0 or not proc.stdout.strip():
            return empty
        parsed = json.loads(proc.stdout)
        return {"State": "observed", "Sessions": parsed if isinstance(parsed, list) else [parsed]}
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
        return empty


def tmux_has_session(session: str) -> bool:
    proc = subprocess.run(["tmux", "has-session", "-t", session], capture_output=True, text=True)
    return proc.returncode == 0


def status_snapshot(manifest: dict[str, Any], install_root: Path, job_id: str = "") -> dict[str, Any]:
    layout = manifest.get("JobsLayout", "SingleWindow")
    rows = []
    for entry in manifest.get("Jobs", []):
        jid = entry.get("Id", "")
        if job_id and jid != job_id:
            continue
        session = tmux_session_name(install_root, "single" if layout == "SingleWindow" else jid)
        tmux_state = "observed" if (shutil.which("tmux") and tmux_has_session(session)) else "absent"
        rows.append(
            {
                "Id": jid,
                "Configured": {"Client": entry.get("Client"), "Directory": entry.get("Directory")},
                "Session": {"Name": session, "State": tmux_state},
                "Git": git_status(str(entry.get("Directory", ""))),
            }
        )
    return {
        "SchemaVersion": 2,
        "Result": "observed",
        "Jobs": rows,
        "ProviderSessions": {"Claude": claude_sessions(str(manifest.get("Claude", "")))},
    }


def new_worktree(repo: str, path: str, base_ref: str = "main", branch: str = "", lock: bool = False) -> dict[str, Any]:
    repo_abs = ensure_absolute_path(repo, "Repository")
    target_abs = ensure_absolute_path(path, "Worktree path")
    if os.path.exists(target_abs):
        raise ValueError(f"The target worktree path already exists: {target_abs}")
    top_proc = subprocess.run(["git", "-C", repo_abs, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if top_proc.returncode != 0 or not top_proc.stdout.strip():
        raise ValueError(f"The path is not a Git repository: {repo_abs}")
    top_real = resolve_final_dir(top_proc.stdout.strip())
    target_real = resolve_final_dir(target_abs)
    if target_real == top_real or target_real.startswith(top_real + os.sep):
        raise ValueError(f"Worktree path must be outside the repository: {target_abs}")
    os.makedirs(os.path.dirname(target_abs), exist_ok=True)
    cmd = ["git", "-C", repo_abs, "worktree", "add"]
    cmd.extend(["-b", branch, target_abs, base_ref] if branch else ["--detach", target_abs, base_ref])
    add_proc = subprocess.run(cmd, capture_output=True, text=True)
    if add_proc.returncode != 0:
        raise RuntimeError(f"git worktree add failed: {add_proc.stderr.strip()}")
    if lock:
        lock_proc = subprocess.run(["git", "-C", repo_abs, "worktree", "lock", target_abs, "--reason", "Agent Fleet job slot"], capture_output=True, text=True)
        if lock_proc.returncode != 0:
            raise RuntimeError(f"Worktree created, but lock failed: {lock_proc.stderr.strip()}")
    return {"Result": "created", "Path": target_abs, "Branch": branch or "(detached)", "BaseRef": base_ref, "Locked": lock}


def dispatch_task(manifest: dict[str, Any], install_root: Path, client: str, directory: str, prompt: str, model: str = "", name: str = "") -> dict[str, Any]:
    if client not in ("Claude", "Codex"):
        raise ValueError(f"Dispatch supports Claude or Codex only: {client}")
    if not prompt.strip():
        raise ValueError("Dispatch requires a non-empty --prompt.")
    dir_abs = ensure_absolute_path(directory, "Directory")
    if not os.path.isdir(dir_abs):
        raise ValueError(f"The dispatch directory is unavailable: {dir_abs}")
    exe = ensure_absolute_path(str(manifest.get(client, "")), client)
    if client == "Claude":
        cmd = [exe, "--bg"]
        if model:
            cmd.extend(["--model", model])
        if name:
            cmd.extend(["--name", name])
        cmd.append(prompt)
        proc = subprocess.run(cmd, cwd=dir_abs, capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(f"Claude background dispatch failed: {proc.stderr.strip()} {proc.stdout.strip()}".strip())
        return {"Result": "dispatched", "Client": "Claude", "Directory": dir_abs, "Output": proc.stdout.strip()}

    state_dir = install_root / "state"
    state_dir.mkdir(parents=True, exist_ok=True)
    log_path = state_dir / f"dispatch-codex-{int(time.time() * 1000)}.jsonl"
    cmd = [exe, "exec", "-C", dir_abs, "--json"]
    if model:
        cmd.extend(["-m", model])
    cmd.append(prompt)
    with log_path.open("w", encoding="utf-8") as log_handle:
        proc = subprocess.Popen(cmd, cwd=dir_abs, stdout=log_handle, stderr=subprocess.STDOUT, start_new_session=True)
    return {"Result": "dispatched", "Client": "Codex", "Directory": dir_abs, "Pid": proc.pid, "LogPath": str(log_path)}


def queue_message(manifest: dict[str, Any], thread: str, message: str, resume: bool = False) -> dict[str, Any]:
    if not thread.strip() or not message.strip():
        raise ValueError("Queue requires --thread and --message.")
    exe = ensure_absolute_path(str(manifest.get("Codex", "")), "Codex")
    cmd = [exe, "queue", "--thread", thread, "--message", message]
    if resume:
        cmd.append("--resume")
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"Codex queue failed: {proc.stderr.strip()} {proc.stdout.strip()}".strip())
    return {"Result": "queued", "Client": "Codex", "Thread": thread, "Output": proc.stdout.strip()}


def discover_clients() -> dict[str, str]:
    bins = {"Codex": "codex", "Claude": "claude", "Antigravity": "agy", "OpenCode": "opencode"}
    found: dict[str, str] = {}
    for client, binary in bins.items():
        resolved = shutil.which(binary)
        if resolved:
            found[client] = resolve_final_dir(resolved)
    return found


def init_manifest(manifest_path: Path, worktrees: list[str], layout: str = "SingleWindow", update_repo: str = "") -> dict[str, Any]:
    if manifest_path.exists():
        raise FileExistsError(f"The manifest already exists: {manifest_path}")
    clients = discover_clients()
    if not clients:
        raise RuntimeError("No supported agent CLI (codex, claude, agy, opencode) was found on PATH.")
    if not (1 <= len(worktrees) <= 4):
        raise ValueError("Pass 1 to 4 distinct Git worktrees via --worktree.")
    client_names = list(clients.keys())
    jobs = [
        {"Id": f"job-{i + 1}", "Client": client_names[i % len(client_names)], "Directory": ensure_absolute_path(wt, "Worktree")}
        for i, wt in enumerate(worktrees)
    ]
    manifest: dict[str, Any] = {"DefaultMode": "Jobs", "JobsLayout": layout}
    if update_repo:
        if not REPO_SLUG_RE.match(update_repo):
            raise ValueError("The UpdateRepo value is invalid.")
        manifest["UpdateRepo"] = update_repo
    else:
        manifest["UpdateRepo"] = DEFAULT_UPDATE_REPO
    manifest.update(clients)
    manifest["Jobs"] = jobs
    validate_manifest(manifest)
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def update_source(manifest: dict[str, Any]) -> tuple[str, str, str]:
    repo = str(manifest.get("UpdateRepo", DEFAULT_UPDATE_REPO)).strip() or DEFAULT_UPDATE_REPO
    if not REPO_SLUG_RE.match(repo):
        raise ValueError("The UpdateRepo manifest field is invalid.")
    transport = manifest.get("UpdateTransport") or "https"
    if str(transport) not in ("https", "gh"):
        raise ValueError("The UpdateTransport manifest field is invalid.")
    prefix = str(manifest.get("UpdatePathPrefix", ""))
    return repo, str(transport), prefix


def fetch_text(url: str, accept: str = "application/vnd.github+json") -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "AgentFleet/2.0", "Accept": accept})
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = resp.read(2 * 1024 * 1024 + 1)
        if len(data) > 2 * 1024 * 1024:
            raise RuntimeError("The Fleet update response is too large.")
        return data.decode("utf-8")


def run_self_update(install_root: Path, manifest: dict[str, Any]) -> dict[str, Any]:
    receipt_path = install_root / "installation.json"
    receipt = json.loads(receipt_path.read_text(encoding="utf-8")) if receipt_path.exists() else {"ReleaseVersion": "0.0.0"}
    repo, transport, prefix = update_source(manifest)
    if transport == "gh":
        head = subprocess.check_output(["gh", "api", "--hostname", "github.com", f"repos/{repo}/commits/main", "--jq", ".sha"], text=True, timeout=20).strip()
        rel_text = subprocess.check_output(["gh", "api", "--hostname", "github.com", f"repos/{repo}/contents/{prefix}release.json?ref={head}", "-H", "Accept:application/vnd.github.raw+json"], text=True, timeout=20)
    else:
        head = str(json.loads(fetch_text(f"https://api.github.com/repos/{repo}/commits/main")).get("sha", "")).strip()
        rel_text = fetch_text(f"https://api.github.com/repos/{repo}/contents/{prefix}release.json?ref={head}", "application/vnd.github.raw+json")
    if not COMMIT40_RE.match(head):
        raise RuntimeError("The Fleet source commit is invalid.")
    rel = json.loads(rel_text)
    if rel.get("Protocol") != 2 or not VERSION_RE.match(str(rel.get("Version", ""))):
        raise RuntimeError("The Fleet release metadata is invalid.")
    cur_tuple = tuple(int(x) for x in str(receipt.get("ReleaseVersion", "0.0.0")).split("."))
    cand_tuple = tuple(int(x) for x in rel["Version"].split("."))
    if cand_tuple <= cur_tuple:
        return {"Result": "current", "Version": receipt.get("ReleaseVersion")}
    script_url = f"https://api.github.com/repos/{repo}/contents/{prefix}unix/agent_fleet.py?ref={head}"
    new_script = subprocess.check_output(["gh", "api", "--hostname", "github.com", f"repos/{repo}/contents/{prefix}unix/agent_fleet.py?ref={head}", "-H", "Accept:application/vnd.github.raw+json"], text=True, timeout=20) if transport == "gh" else fetch_text(script_url, "application/vnd.github.raw+json")
    target = install_root / "agent_fleet.py"
    backup = install_root / "agent_fleet.py.prev"
    if target.exists():
        backup.write_text(target.read_text(encoding="utf-8"), encoding="utf-8")
    fd, tmp_name = tempfile.mkstemp(dir=str(install_root), prefix=".agent_fleet.", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(new_script)
    os.replace(tmp_name, target)
    receipt["PreviousVersion"] = receipt.get("ReleaseVersion")
    receipt["ReleaseVersion"] = rel["Version"]
    receipt["SourceCommit"] = head
    receipt_path.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    return {"Result": "updated", "Version": rel["Version"], "SourceCommit": head}


def launch_tmux(manifest: dict[str, Any], install_root: Path, job_id: str = "") -> int:
    if not shutil.which("tmux"):
        raise RuntimeError("Agent Fleet on macOS/Linux requires tmux on PATH.")
    plan = build_launch_plan(manifest, install_root, job_id=job_id)
    for session_plan in plan["Sessions"]:
        session = session_plan["SessionName"]
        if not tmux_has_session(session):
            for cmd in session_plan["TmuxCommands"]:
                subprocess.run(["tmux", *cmd], check=True)
    if len(plan["Sessions"]) == 1:
        session = plan["Sessions"][0]["SessionName"]
        if sys.stdout.isatty():
            if os.environ.get("TMUX"):
                subprocess.run(["tmux", "switch-client", "-t", session], check=True)
            else:
                subprocess.run(["tmux", "attach-session", "-t", session], check=True)
        else:
            print(f"tmux session ready: {session} (attach with: tmux attach -t {session})")
    else:
        names = ", ".join(s["SessionName"] for s in plan["Sessions"])
        print(f"tmux sessions ready: {names}")
    return 0


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Agent Fleet cross-platform launcher (macOS/Linux tmux backend)")
    p.add_argument("--manifest", default=str(default_manifest_path()))
    p.add_argument("--install-root", default=str(default_install_root()))
    p.add_argument("--job", default="")
    p.add_argument("--print-plan", action="store_true")
    p.add_argument("--status", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("--init", action="store_true")
    p.add_argument("--worktree", action="append", default=[])
    p.add_argument("--layout", choices=("SingleWindow", "JobWindows"), default="SingleWindow")
    p.add_argument("--update-repo", default="")
    p.add_argument("--new-worktree", default="")
    p.add_argument("--repository", default="")
    p.add_argument("--base-ref", default="main")
    p.add_argument("--branch", default="")
    p.add_argument("--lock", action="store_true")
    p.add_argument("--dispatch", action="store_true")
    p.add_argument("--queue", action="store_true")
    p.add_argument("--client", default="")
    p.add_argument("--directory", default="")
    p.add_argument("--prompt", default="")
    p.add_argument("--model", default="")
    p.add_argument("--name", default="")
    p.add_argument("--thread", default="")
    p.add_argument("--message", default="")
    p.add_argument("--resume", action="store_true")
    p.add_argument("--update", action="store_true")
    p.add_argument("--rollback", action="store_true")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    manifest_path = Path(args.manifest)
    install_root = Path(args.install_root)

    if args.init:
        manifest = init_manifest(manifest_path, args.worktree, layout=args.layout, update_repo=args.update_repo)
        print(json.dumps({"Result": "initialized", "Manifest": str(manifest_path), "Jobs": len(manifest["Jobs"])}, indent=2))
        return 0
    if args.new_worktree:
        repo = args.repository or os.getcwd()
        print(json.dumps(new_worktree(repo, args.new_worktree, base_ref=args.base_ref, branch=args.branch, lock=args.lock), indent=2))
        return 0
    if args.rollback:
        target = install_root / "agent_fleet.py"
        backup = install_root / "agent_fleet.py.prev"
        if not backup.exists():
            raise RuntimeError("No previous Unix Agent Fleet runtime is available for rollback.")
        target.write_text(backup.read_text(encoding="utf-8"), encoding="utf-8")
        print("Rolled back Unix Agent Fleet runtime.")
        return 0

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if args.update:
        print(json.dumps(run_self_update(install_root, manifest), indent=2))
        return 0
    if args.dispatch:
        print(json.dumps(dispatch_task(manifest, install_root, args.client, args.directory, args.prompt, args.model, args.name), indent=2))
        return 0
    if args.queue:
        print(json.dumps(queue_message(manifest, args.thread, args.message, resume=args.resume), indent=2))
        return 0
    if args.print_plan:
        print(json.dumps(build_launch_plan(manifest, install_root, job_id=args.job), indent=2))
        return 0
    if args.status:
        snap = status_snapshot(manifest, install_root, job_id=args.job)
        if args.json:
            print(json.dumps(snap, indent=2))
        else:
            for row in snap["Jobs"]:
                git = row["Git"]
                git_txt = f"{git['Branch']} ({git['DirtyCount']} dirty)" if git["State"] == "observed" else "unavailable"
                print(f"{row['Id']}: {row['Configured']['Client']} | tmux {row['Session']['State']} | git {git_txt}")
        return 0
    return launch_tmux(manifest, install_root, job_id=args.job)


if __name__ == "__main__":
    raise SystemExit(main())
