#!/usr/bin/env python3
"""Cross-platform macOS and Linux (tmux) runtime for Agent Fleet 2.1.0."""

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
TAB_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9 _-]{0,31}$")
HEX_COLOR_RE = re.compile(r"^#[0-9A-Fa-f]{6}$")
PROFILE_NAME_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
REPO_SLUG_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
VERSION_RE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
HEX64_RE = re.compile(r"^[A-F0-9]{64}$")
COMMIT40_RE = re.compile(r"^[0-9a-f]{40}$")
DEFAULT_UPDATE_REPO = "fergeley/agent-fleet"
MAX_COPY_FILE_BYTES = 10 * 1024 * 1024
MAX_COPY_FILES = 64
MAX_INCLUDE_BYTES = 64 * 1024


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


def validate_profile_name(profile: str) -> str:
    if not profile:
        return ""
    if not PROFILE_NAME_RE.match(profile):
        raise ValueError(f"Invalid profile name (use 1-32 lowercase letters, digits, or hyphens): {profile}")
    return profile


def resolve_manifest_path(explicit_manifest: str, install_root: Path, profile: str = "") -> Path:
    validate_profile_name(profile)
    if explicit_manifest:
        return Path(explicit_manifest)
    if profile:
        return install_root / "profiles" / profile / "manifest.json"
    return default_manifest_path()


def resolve_state_dir(install_root: Path, profile: str = "") -> Path:
    validate_profile_name(profile)
    if profile:
        return install_root / "profiles" / profile / "state"
    return install_root / "state"


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


def parse_job_tab(job: dict[str, Any], job_id: str) -> str:
    raw = job.get("Tab")
    if raw is None:
        return "fleet"
    if not isinstance(raw, str) or not raw.strip():
        raise ValueError(f"The Jobs Tab field must be a non-empty string for {job_id}.")
    tab = raw.strip()
    if not TAB_NAME_RE.match(tab):
        raise ValueError(f"The Jobs Tab name is invalid for {job_id}: {tab}")
    return tab


def validate_tab_colors(manifest: dict[str, Any]) -> dict[str, str]:
    raw = manifest.get("TabColors")
    if raw is None:
        return {}
    if not isinstance(raw, dict):
        raise ValueError("TabColors must be an object mapping tab names to #RRGGBB colors.")
    colors: dict[str, str] = {}
    for k, v in raw.items():
        if not isinstance(k, str) or not TAB_NAME_RE.match(k):
            raise ValueError(f"The TabColors tab name is invalid: {k}")
        if not isinstance(v, str) or not HEX_COLOR_RE.match(v):
            raise ValueError(f"TabColors value for {k} must be a #RRGGBB hex color.")
        colors[k] = v
    return colors


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
    validate_tab_colors(manifest)
    raw_jobs = manifest.get("Jobs")
    if not isinstance(raw_jobs, list) or not (1 <= len(raw_jobs) <= 16):
        raise ValueError("Configure 1 to 16 Jobs entries.")

    seen_ids: set[str] = set()
    tab_counts: dict[str, int] = {}
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
        tab_name = parse_job_tab(entry, jid)
        tab_counts[tab_name] = tab_counts.get(tab_name, 0) + 1
        if tab_counts[tab_name] > 4:
            raise ValueError(f"Tab '{tab_name}' exceeds the limit of 4 panes per tab.")
        if len(tab_counts) > 4:
            raise ValueError("Configure at most 4 distinct tabs in SingleWindow.")
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
                "Tab": tab_name,
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


def tmux_session_name(install_root: Path, suffix: str, profile: str = "") -> str:
    validate_profile_name(profile)
    raw = str(install_root) if not profile else f"{install_root}|{profile}"
    tag = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:8]
    return f"agent-fleet-{tag}-{suffix}"


def _build_tab_split_commands(session: str, win_idx: int, tab_name: str, jobs: list[dict[str, Any]], create_session: bool) -> list[list[str]]:
    steps: list[list[str]] = []
    first = jobs[0]
    if create_session:
        steps.append(["new-session", "-d", "-s", session, "-n", tab_name, "-c", first["Directory"], *build_pane_command(first)])
    else:
        steps.append(["new-window", "-t", session, "-n", tab_name, "-c", first["Directory"], *build_pane_command(first)])

    target_base = f"{session}:{win_idx}"
    if len(jobs) == 2:
        steps.append(["split-window", "-h", "-t", f"{target_base}.0", "-c", jobs[1]["Directory"], *build_pane_command(jobs[1])])
        steps.append(["select-layout", "-t", target_base, "even-horizontal"])
    elif len(jobs) == 3:
        steps.append(["split-window", "-h", "-t", f"{target_base}.0", "-c", jobs[1]["Directory"], *build_pane_command(jobs[1])])
        steps.append(["split-window", "-v", "-t", f"{target_base}.0", "-c", jobs[2]["Directory"], *build_pane_command(jobs[2])])
        steps.append(["select-layout", "-t", target_base, "tiled"])
    elif len(jobs) == 4:
        steps.append(["split-window", "-h", "-t", f"{target_base}.0", "-c", jobs[1]["Directory"], *build_pane_command(jobs[1])])
        steps.append(["split-window", "-v", "-t", f"{target_base}.1", "-c", jobs[3]["Directory"], *build_pane_command(jobs[3])])
        steps.append(["split-window", "-v", "-t", f"{target_base}.0", "-c", jobs[2]["Directory"], *build_pane_command(jobs[2])])
        steps.append(["select-layout", "-t", target_base, "tiled"])
    return steps


def build_launch_plan(
    manifest: dict[str, Any],
    install_root: Path,
    job_id: str = "",
    profile: str = "",
) -> dict[str, Any]:
    layout, jobs = validate_manifest(manifest, job_id=job_id)
    if layout == "SingleWindow":
        session = tmux_session_name(install_root, "single", profile=profile)
        tab_groups: dict[str, list[dict[str, Any]]] = {}
        for job in jobs:
            tab_groups.setdefault(job["Tab"], []).append(job)
        steps: list[list[str]] = []
        tabs_meta = []
        for idx, (tab_name, tab_jobs) in enumerate(tab_groups.items()):
            steps.extend(_build_tab_split_commands(session, idx, tab_name, tab_jobs, create_session=(idx == 0)))
            tabs_meta.append({"Tab": tab_name, "JobIds": [j["Id"] for j in tab_jobs]})
        return {
            "Mode": "Jobs",
            "Layout": "SingleWindow",
            "Profile": profile or None,
            "Tabs": tabs_meta,
            "Sessions": [{"SessionName": session, "TmuxCommands": steps, "Jobs": jobs}],
        }

    sessions = []
    for job in jobs:
        session = tmux_session_name(install_root, job["Id"], profile=profile)
        sessions.append(
            {
                "SessionName": session,
                "TmuxCommands": [
                    ["new-session", "-d", "-s", session, "-n", job["Id"], "-c", job["Directory"], *build_pane_command(job)]
                ],
                "Jobs": [job],
            }
        )
    return {"Mode": "Jobs", "Layout": "JobWindows", "Profile": profile or None, "Sessions": sessions}


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


def status_snapshot(manifest: dict[str, Any], install_root: Path, job_id: str = "", profile: str = "") -> dict[str, Any]:
    layout = manifest.get("JobsLayout", "SingleWindow")
    rows = []
    for entry in manifest.get("Jobs", []):
        jid = entry.get("Id", "")
        if job_id and jid != job_id:
            continue
        session = tmux_session_name(install_root, "single" if layout == "SingleWindow" else jid, profile=profile)
        tmux_state = "observed" if (shutil.which("tmux") and tmux_has_session(session)) else "absent"
        rows.append(
            {
                "Id": jid,
                "Configured": {
                    "Client": entry.get("Client"),
                    "Tab": entry.get("Tab") or "fleet",
                    "Directory": entry.get("Directory"),
                },
                "Session": {"Name": session, "State": tmux_state},
                "Git": git_status(str(entry.get("Directory", ""))),
            }
        )
    return {
        "SchemaVersion": 2,
        "Result": "observed",
        "Profile": profile or None,
        "Jobs": rows,
        "ProviderSessions": {"Claude": claude_sessions(str(manifest.get("Claude", "")))},
    }


def _assert_safe_rel_copy_path(raw: str) -> str:
    if not isinstance(raw, str) or not raw.strip():
        raise ValueError("Worktree copy path cannot be empty.")
    cleaned = raw.strip()
    if os.path.isabs(cleaned) or cleaned.startswith(("/", "\\")) or ":" in cleaned:
        raise ValueError(f"Worktree copy path must be relative: {cleaned}")
    if "*" in cleaned or "?" in cleaned:
        raise ValueError(f"Worktree copy path cannot contain wildcards: {cleaned}")
    parts = [p for p in re.split(r"[/\\]", cleaned) if True]
    for seg in parts:
        if not seg or seg in (".", "..") or seg.lower() == ".git":
            raise ValueError(f"Worktree copy path contains a blocked segment: {cleaned}")
    return os.path.join(*parts)


def get_relative_copy_paths(repo_root: Path, manifest: dict[str, Any] | None = None, allow_include: bool = False) -> list[str]:
    raw_entries: list[str] = []
    if manifest and manifest.get("WorktreeCopyFiles") is not None:
        wcf = manifest["WorktreeCopyFiles"]
        if not isinstance(wcf, list) or any(not isinstance(x, str) for x in wcf):
            raise ValueError("WorktreeCopyFiles must be an array of relative file paths.")
        raw_entries.extend(wcf)
    if allow_include:
        inc_path = repo_root / ".worktreeinclude"
        if inc_path.exists() or inc_path.is_symlink():
            if inc_path.is_symlink():
                raise ValueError(".worktreeinclude cannot be a symlink.")
            if not inc_path.is_file() or inc_path.stat().st_size > MAX_INCLUDE_BYTES:
                raise ValueError(".worktreeinclude is invalid or exceeds 64 KiB.")
            for line in inc_path.read_text(encoding="utf-8").splitlines():
                trimmed = line.strip()
                if not trimmed or trimmed.startswith("#"):
                    continue
                raw_entries.append(trimmed)
    seen: set[str] = set()
    result: list[str] = []
    for entry in raw_entries:
        rel = _assert_safe_rel_copy_path(entry)
        key = rel.lower()
        if key not in seen:
            seen.add(key)
            result.append(rel)
    if len(result) > MAX_COPY_FILES:
        raise ValueError(f"Worktree copy list exceeds {MAX_COPY_FILES} files.")
    return result


def _assert_no_symlink_between(path: Path, root: Path) -> None:
    cur = path
    root_real = os.path.realpath(str(root))
    while True:
        if cur.is_symlink():
            raise ValueError(f"Path contains a symlink: {cur}")
        if os.path.realpath(str(cur)) == root_real or cur == cur.parent:
            break
        cur = cur.parent


def copy_worktree_files(repo_root: Path, target_worktree: Path, rel_paths: list[str]) -> tuple[list[str], list[dict[str, str]]]:
    copied: list[str] = []
    skipped: list[dict[str, str]] = []
    if not rel_paths:
        return copied, skipped
    canon_repo = Path(resolve_final_dir(repo_root))
    canon_target = Path(resolve_final_dir(target_worktree))
    for rel in rel_paths:
        src = canon_repo / rel
        if not src.exists() and not src.is_symlink():
            skipped.append({"Path": rel, "Reason": "missing"})
            continue
        if src.is_symlink():
            raise ValueError(f"Worktree copy source cannot be a symlink: {rel}")
        _assert_no_symlink_between(src, canon_repo)
        if src.is_dir():
            raise ValueError(f"Worktree copy entry must be a regular file: {rel}")
        if src.stat().st_size > MAX_COPY_FILE_BYTES:
            raise ValueError(f"Worktree copy file exceeds 10 MiB limit: {rel}")
        src_parent_real = resolve_final_dir(src.parent)
        canon_repo_str = str(canon_repo)
        if not (src_parent_real == canon_repo_str or src_parent_real.startswith(canon_repo_str + os.sep)):
            raise ValueError(f"Worktree copy source escapes repository root: {rel}")
        dst = canon_target / rel
        dst_parent = dst.parent
        # Ensure existing destination ancestors contain no symlinks
        probe = dst
        while True:
            if probe.exists() or probe.is_symlink():
                _assert_no_symlink_between(probe, canon_target)
                break
            if probe == canon_target or probe == probe.parent:
                break
            probe = probe.parent
        if dst.exists() or dst.is_symlink():
            skipped.append({"Path": rel, "Reason": "exists"})
            continue
        dst_parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst, follow_symlinks=False)
        copied.append(rel)
    return copied, skipped


def known_worktrees(install_root: Path, default_manifest: Path | None = None) -> tuple[set[str], set[str]]:
    dirs: set[str] = set()
    git_dirs: set[str] = set()
    manifest_files: list[Path] = []
    root_manifest = default_manifest if default_manifest is not None else default_manifest_path()
    if root_manifest.is_file():
        manifest_files.append(root_manifest)
    profiles_dir = install_root / "profiles"
    if profiles_dir.is_dir():
        for p in profiles_dir.iterdir():
            pm = p / "manifest.json"
            if pm.is_file():
                manifest_files.append(pm)
    for mp in manifest_files:
        try:
            data = json.loads(mp.read_text(encoding="utf-8"))
            for job in data.get("Jobs", []):
                d = str(job.get("Directory", ""))
                if d and os.path.isdir(d):
                    dirs.add(resolve_final_dir(d))
                    gd = subprocess.run(["git", "-C", d, "rev-parse", "--absolute-git-dir"], capture_output=True, text=True)
                    if gd.returncode == 0 and gd.stdout.strip():
                        git_dirs.add(resolve_final_dir(gd.stdout.strip()))
        except (OSError, json.JSONDecodeError, ValueError):
            pass
    return dirs, git_dirs


def new_worktree(
    repo: str,
    path: str,
    base_ref: str = "main",
    branch: str = "",
    lock: bool = False,
    manifest: dict[str, Any] | None = None,
    allow_worktree_include: bool = False,
) -> dict[str, Any]:
    repo_abs = ensure_absolute_path(repo, "Repository")
    target_abs = ensure_absolute_path(path, "Worktree path")
    if not base_ref.strip() or base_ref.strip().startswith("-"):
        raise ValueError(f"Invalid base ref: {base_ref}")
    if branch and branch.strip().startswith("-"):
        raise ValueError(f"Invalid branch name: {branch}")
    if os.path.exists(target_abs):
        raise ValueError(f"The target worktree path already exists: {target_abs}")
    top_proc = subprocess.run(["git", "-C", repo_abs, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if top_proc.returncode != 0 or not top_proc.stdout.strip():
        raise ValueError(f"The path is not a Git repository: {repo_abs}")
    top_real = resolve_final_dir(top_proc.stdout.strip())
    target_real = resolve_final_dir(target_abs)
    if target_real == top_real or target_real.startswith(top_real + os.sep):
        raise ValueError(f"Worktree path must be outside the repository: {target_abs}")

    copy_root = Path(top_real)
    common_proc = subprocess.run(["git", "-C", repo_abs, "rev-parse", "--git-common-dir"], capture_output=True, text=True)
    if common_proc.returncode == 0 and common_proc.stdout.strip():
        cdir = common_proc.stdout.strip()
        if not os.path.isabs(cdir):
            cdir = os.path.abspath(os.path.join(repo_abs, cdir))
        cparent = os.path.dirname(os.path.normpath(cdir))
        if os.path.isdir(cparent):
            copy_root = Path(resolve_final_dir(cparent))

    use_include = bool(allow_worktree_include or (manifest and manifest.get("AllowWorktreeInclude")))
    rel_copy_paths = get_relative_copy_paths(copy_root, manifest=manifest, allow_include=use_include)

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
    copied, skipped = copy_worktree_files(copy_root, Path(target_abs), rel_copy_paths)
    return {
        "Result": "created",
        "Path": target_abs,
        "Branch": branch or "(detached)",
        "BaseRef": base_ref,
        "Locked": lock,
        "CopiedFiles": copied,
        "SkippedFiles": skipped,
    }


def clean_worktree(
    path: str,
    install_root: Path,
    base_ref: str = "",
    dry_run: bool = False,
    force: bool = False,
    manifest_path: Path | None = None,
) -> dict[str, Any]:
    abs_path = ensure_absolute_path(path, "Worktree path")
    p = Path(abs_path)
    if p.is_symlink():
        raise ValueError(f"Refusing to remove symlinked worktree path: {abs_path}")
    if not p.is_dir():
        raise ValueError(f"The worktree directory does not exist: {abs_path}")
    canon_target = resolve_final_dir(abs_path)

    gd_proc = subprocess.run(["git", "-C", canon_target, "rev-parse", "--absolute-git-dir"], capture_output=True, text=True)
    cd_proc = subprocess.run(["git", "-C", canon_target, "rev-parse", "--git-common-dir"], capture_output=True, text=True)
    if gd_proc.returncode != 0 or cd_proc.returncode != 0 or not gd_proc.stdout.strip():
        raise ValueError(f"The path is not a Git worktree: {canon_target}")
    canon_git = resolve_final_dir(gd_proc.stdout.strip())
    raw_common = cd_proc.stdout.strip()
    if not os.path.isabs(raw_common):
        raw_common = os.path.join(canon_target, raw_common)
    canon_common = resolve_final_dir(raw_common)
    if canon_git == canon_common:
        raise ValueError(f"Refusing to remove the main Git repository checkout: {canon_target}")

    common_parent = os.path.dirname(canon_common)
    wt_list_proc = subprocess.run(["git", "-C", common_parent, "worktree", "list", "--porcelain"], capture_output=True, text=True)
    if wt_list_proc.returncode != 0:
        raise RuntimeError("Could not inspect repository worktree list.")
    found = False
    is_locked = False
    matched = False
    for line in wt_list_proc.stdout.splitlines():
        if line.startswith("worktree "):
            wt_real = resolve_final_dir(line[9:].strip())
            matched = wt_real == canon_target
            if matched:
                found = True
        elif matched and (line == "locked" or line.startswith("locked ")):
            is_locked = True
    if not found:
        raise ValueError(f"Directory is not a registered linked worktree: {canon_target}")

    dirs, git_dirs = known_worktrees(install_root, manifest_path)
    if canon_git in git_dirs or canon_target in dirs:
        raise ValueError(f"Refusing to remove a worktree configured in Agent Fleet: {canon_target}")

    cwd_real = resolve_final_dir(os.getcwd())
    if cwd_real == canon_target or cwd_real.startswith(canon_target + os.sep):
        raise ValueError(f"Refusing to remove the current working directory or its ancestor: {canon_target}")

    porcelain = subprocess.run(["git", "-C", canon_target, "status", "--porcelain"], capture_output=True, text=True)
    if porcelain.returncode != 0:
        raise RuntimeError(f"Could not inspect Git status for {canon_target}")
    dirty = bool(porcelain.stdout.strip())
    if dirty and not force:
        raise ValueError("Worktree has uncommitted changes. Commit/discard or pass --force.")

    head_proc = subprocess.run(["git", "-C", canon_target, "rev-parse", "HEAD"], capture_output=True, text=True)
    wt_head = head_proc.stdout.strip()
    up_proc = subprocess.run(["git", "-C", canon_target, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], capture_output=True, text=True)
    unpushed = 0
    if up_proc.returncode == 0 and up_proc.stdout.strip():
        cnt_proc = subprocess.run(["git", "-C", canon_target, "rev-list", "--count", "@{u}..HEAD"], capture_output=True, text=True)
        if cnt_proc.returncode == 0 and cnt_proc.stdout.strip().isdigit():
            unpushed = int(cnt_proc.stdout.strip())
        if unpushed > 0 and not force:
            raise ValueError(f"Worktree has {unpushed} unpushed commit(s) ahead of {up_proc.stdout.strip()}.")

    merge_target = ""
    if base_ref:
        if base_ref.strip().startswith("-"):
            raise ValueError(f"Invalid base_ref: {base_ref}")
        chk = subprocess.run(["git", "-C", common_parent, "rev-parse", "--verify", f"{base_ref.strip()}^{{commit}}"], capture_output=True, text=True)
        if chk.returncode != 0:
            raise ValueError(f"Base ref not found: {base_ref}")
        merge_target = base_ref.strip()
    else:
        for cand in ("origin/HEAD", "refs/heads/main", "refs/heads/master", "refs/heads/develop", "HEAD"):
            chk = subprocess.run(["git", "-C", common_parent, "rev-parse", "--verify", f"{cand}^{{commit}}"], capture_output=True, text=True)
            if chk.returncode == 0:
                merge_target = cand
                break
    merged = False
    if merge_target:
        anc = subprocess.run(["git", "-C", common_parent, "merge-base", "--is-ancestor", wt_head, merge_target], capture_output=True, text=True)
        merged = anc.returncode == 0
    if not merged and not force:
        raise ValueError(f"Worktree HEAD ({wt_head[:8]}) is not merged into {merge_target}. Pass --force to override.")

    commands = []
    if is_locked:
        commands.append(["git", "-C", common_parent, "worktree", "unlock", canon_target])
    rm_cmd = ["git", "-C", common_parent, "worktree", "remove", *(["--force"] if force else []), canon_target]
    commands.append(rm_cmd)

    if dry_run:
        return {
            "Result": "dry-run",
            "Path": canon_target,
            "Locked": is_locked,
            "Dirty": dirty,
            "UnpushedCommits": unpushed,
            "MergedInto": merge_target if merged else None,
            "Commands": commands,
        }

    for cmd in commands:
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode != 0:
            raise RuntimeError(f"Worktree cleanup failed: {res.stderr.strip()}")
    return {"Result": "removed", "Path": canon_target, "WasLocked": is_locked, "Forced": force, "MergedInto": merge_target if merged else None}


def open_tab(
    manifest: dict[str, Any],
    install_root: Path,
    client: str,
    directory: str = "",
    repository: str = "",
    branch: str = "",
    base_ref: str = "main",
    tab_title: str = "",
    client_args: list[str] | None = None,
    lock: bool = False,
    allow_worktree_include: bool = False,
    profile: str = "",
    manifest_path: Path | None = None,
    plan_only: bool = False,
) -> dict[str, Any]:
    if client not in SUPPORTED_CLIENTS:
        raise ValueError(f"OpenTab client is unsupported: {client}")
    exe = ensure_absolute_path(str(manifest.get(client, "")), client)
    if not (os.path.isfile(exe) and os.access(exe, os.X_OK)):
        raise ValueError(f"The configured executable is unavailable: {client}")
    if branch and branch.strip().startswith("-"):
        raise ValueError(f"Invalid branch name: {branch}")
    if not base_ref.strip() or base_ref.strip().startswith("-"):
        raise ValueError(f"Invalid base ref: {base_ref}")
    resolved_args = client_arguments(client, client_args)
    created_wt = None
    target_dir = directory
    if not target_dir:
        if not branch or not repository:
            raise ValueError("--open-tab requires either --directory or both --repository and --branch.")
        repo_abs = ensure_absolute_path(repository, "Repository")
        top_proc = subprocess.run(["git", "-C", repo_abs, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
        if top_proc.returncode != 0 or not top_proc.stdout.strip():
            raise ValueError(f"The path is not a Git repository: {repo_abs}")
        repo_top = top_proc.stdout.strip()
        slug = re.sub(r"[^A-Za-z0-9._-]+", "-", branch).strip("-")
        if not slug:
            raise ValueError(f"Could not derive folder name from branch: {branch}")
        candidate = os.path.join(os.path.dirname(repo_top), f"{os.path.basename(repo_top)}-{slug}")
        if not plan_only:
            created_wt = new_worktree(repo_top, candidate, base_ref=base_ref, branch=branch, lock=lock, manifest=manifest, allow_worktree_include=allow_worktree_include)
            target_dir = created_wt["Path"]
        else:
            target_dir = candidate
    else:
        target_dir = ensure_absolute_path(target_dir, "Directory")
        if not os.path.isdir(target_dir):
            raise ValueError(f"The directory is unavailable: {target_dir}")

    if os.path.isdir(target_dir):
        gd = subprocess.run(["git", "-C", target_dir, "rev-parse", "--absolute-git-dir"], capture_output=True, text=True)
        if gd.returncode != 0 or not gd.stdout.strip():
            raise ValueError(f"Directory is not a Git worktree: {target_dir}")
        _, known_gits = known_worktrees(install_root, manifest_path)
        if resolve_final_dir(gd.stdout.strip()) in known_gits:
            raise ValueError(f"The worktree is already owned by a configured Agent Fleet job: {target_dir}")

    win_name = tab_title.strip() if tab_title.strip() else (f"{client}:{branch}" if branch else f"{client}:{os.path.basename(target_dir)}")
    session = tmux_session_name(install_root, "single", profile=profile)
    if shutil.which("tmux") and tmux_has_session(session):
        tmux_cmd = ["new-window", "-t", session, "-n", win_name, "-c", target_dir, exe, *resolved_args]
        target = "existing"
    else:
        tmux_cmd = ["new-session", "-d", "-s", session, "-n", win_name, "-c", target_dir, exe, *resolved_args]
        target = "new"
    if not plan_only:
        if not shutil.which("tmux"):
            raise RuntimeError("Agent Fleet on macOS/Linux requires tmux on PATH.")
        subprocess.run(["tmux", *tmux_cmd], check=True)
    return {
        "Result": "planned" if plan_only else "opened",
        "WindowTarget": target,
        "SessionName": session,
        "TmuxCommand": tmux_cmd,
        "Client": client,
        "Directory": target_dir,
        "Worktree": created_wt,
    }


def dispatch_task(manifest: dict[str, Any], install_root: Path, client: str, directory: str, prompt: str, model: str = "", name: str = "", profile: str = "") -> dict[str, Any]:
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

    state_dir = resolve_state_dir(install_root, profile)
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
    if not (1 <= len(worktrees) <= 16):
        raise ValueError("Pass 1 to 16 distinct Git worktrees via --worktree.")
    client_names = list(clients.keys())
    jobs = [
        {
            "Id": f"job-{i + 1}",
            "Client": client_names[i % len(client_names)],
            "Tab": "fleet" if i < 4 else f"tab-{(i // 4) + 1}",
            "Directory": ensure_absolute_path(wt, "Worktree"),
        }
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
    req = urllib.request.Request(url, headers={"User-Agent": "AgentFleet/2.1", "Accept": accept})
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


def launch_tmux(manifest: dict[str, Any], install_root: Path, job_id: str = "", profile: str = "") -> int:
    if not shutil.which("tmux"):
        raise RuntimeError("Agent Fleet on macOS/Linux requires tmux on PATH.")
    plan = build_launch_plan(manifest, install_root, job_id=job_id, profile=profile)
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


def format_status_watch(snap: dict[str, Any]) -> str:
    prof = f" [profile: {snap['Profile']}]" if snap.get("Profile") else ""
    lines = [
        f"Agent Fleet status{prof} | {snap['Result']} | {time.strftime('%H:%M:%S')}",
        f"{'TAB':<10} {'JOB':<10} {'CLIENT':<12} {'TMUX':<10} {'BRANCH':<24} {'DIRTY'}",
    ]
    for row in snap["Jobs"]:
        git = row["Git"]
        branch = git.get("Branch") or "-" if git.get("State") == "observed" else "-"
        if len(branch) > 23:
            branch = branch[:20] + "..."
        dirty = f"{git.get('DirtyCount', '-')}" if git.get("State") == "observed" else "-"
        lines.append(f"{row['Configured'].get('Tab', 'fleet'):<10} {row['Id']:<10} {row['Configured']['Client']:<12} {row['Session']['State']:<10} {branch:<24} {dirty}")
    cs = snap.get("ProviderSessions", {}).get("Claude", {})
    if cs.get("State") == "observed":
        lines.append(f"Claude sessions: {len(cs.get('Sessions', []))}")
    return "\n".join(lines)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Agent Fleet cross-platform launcher (macOS/Linux tmux backend)")
    p.add_argument("--manifest", default="")
    p.add_argument("--install-root", default=str(default_install_root()))
    p.add_argument("--profile", default="")
    p.add_argument("--job", default="")
    p.add_argument("--print-plan", action="store_true")
    p.add_argument("--status", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("--watch", action="store_true")
    p.add_argument("--interval", type=int, default=3)
    p.add_argument("--max-iterations", type=int, default=0)
    p.add_argument("--init", action="store_true")
    p.add_argument("--worktree", action="append", default=[])
    p.add_argument("--layout", choices=("SingleWindow", "JobWindows"), default="SingleWindow")
    p.add_argument("--update-repo", default="")
    p.add_argument("--new-worktree", default="")
    p.add_argument("--clean-worktree", default="")
    p.add_argument("--open-tab", action="store_true")
    p.add_argument("--tab-title", default="")
    p.add_argument("--allow-worktree-include", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--force", action="store_true")
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
    if args.watch and not args.status:
        raise SystemExit("--watch requires --status.")
    if args.watch and args.json:
        raise SystemExit("--watch cannot be combined with --json.")
    install_root = Path(args.install_root)
    profile = validate_profile_name(args.profile)
    manifest_path = resolve_manifest_path(args.manifest, install_root, profile)

    if args.init:
        manifest = init_manifest(manifest_path, args.worktree, layout=args.layout, update_repo=args.update_repo)
        print(json.dumps({"Result": "initialized", "Manifest": str(manifest_path), "Jobs": len(manifest["Jobs"])}, indent=2))
        return 0
    manifest_ops = json.loads(manifest_path.read_text(encoding="utf-8")) if manifest_path.exists() else None
    if args.new_worktree:
        repo = args.repository or os.getcwd()
        print(json.dumps(new_worktree(repo, args.new_worktree, base_ref=args.base_ref, branch=args.branch, lock=args.lock, manifest=manifest_ops, allow_worktree_include=args.allow_worktree_include), indent=2))
        return 0
    if args.clean_worktree:
        base = args.base_ref if "--base-ref" in (argv or sys.argv[1:]) else ""
        print(json.dumps(clean_worktree(args.clean_worktree, install_root, base_ref=base, dry_run=args.dry_run, force=args.force, manifest_path=manifest_path), indent=2))
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
    if args.open_tab:
        print(json.dumps(open_tab(manifest, install_root, args.client, directory=args.directory, repository=args.repository, branch=args.branch, base_ref=args.base_ref, tab_title=args.tab_title, lock=args.lock, allow_worktree_include=args.allow_worktree_include, profile=profile, manifest_path=manifest_path), indent=2))
        return 0
    if args.update:
        print(json.dumps(run_self_update(install_root, manifest), indent=2))
        return 0
    if args.dispatch:
        print(json.dumps(dispatch_task(manifest, install_root, args.client, args.directory, args.prompt, args.model, args.name, profile=profile), indent=2))
        return 0
    if args.queue:
        print(json.dumps(queue_message(manifest, args.thread, args.message, resume=args.resume), indent=2))
        return 0
    if args.print_plan:
        print(json.dumps(build_launch_plan(manifest, install_root, job_id=args.job, profile=profile), indent=2))
        return 0
    if args.status:
        if args.watch:
            count = 0
            while True:
                count += 1
                snap = status_snapshot(manifest, install_root, job_id=args.job, profile=profile)
                print(format_status_watch(snap))
                if args.max_iterations > 0 and count >= args.max_iterations:
                    break
                time.sleep(max(1, min(60, args.interval)))
            return 0
        snap = status_snapshot(manifest, install_root, job_id=args.job, profile=profile)
        if args.json:
            print(json.dumps(snap, indent=2))
        else:
            for row in snap["Jobs"]:
                git = row["Git"]
                git_txt = f"{git['Branch']} ({git['DirtyCount']} dirty)" if git["State"] == "observed" else "unavailable"
                print(f"{row['Configured'].get('Tab', 'fleet')} / {row['Id']}: {row['Configured']['Client']} | tmux {row['Session']['State']} | git {git_txt}")
        return 0
    return launch_tmux(manifest, install_root, job_id=args.job, profile=profile)


if __name__ == "__main__":
    raise SystemExit(main())
