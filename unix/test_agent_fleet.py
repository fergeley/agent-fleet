#!/usr/bin/env python3
"""Unit tests for the macOS/Linux (tmux) Agent Fleet 2.1.0 backend."""

from __future__ import annotations

import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import agent_fleet as af


class AgentFleetUnixTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.wt1 = self.root / "wt1"
        self.wt2 = self.root / "wt2"
        self.wt3 = self.root / "wt3"
        self.wt4 = self.root / "wt4"
        self.wt5 = self.root / "wt5"
        self.wt6 = self.root / "wt6"
        subprocess.run(["git", "init", "-q", "-b", "main", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-q", "--allow-empty", "-m", "init"], check=True)
        for wt in (self.wt1, self.wt2, self.wt3, self.wt4, self.wt5, self.wt6):
            subprocess.run(["git", "-C", str(self.repo), "worktree", "add", "-q", "--detach", str(wt)], check=True)
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.cli = self.bin_dir / "tool"
        self.cli.write_text("#!/usr/bin/env sh\nexit 0\n", encoding="utf-8")
        self.cli.chmod(self.cli.stat().st_mode | stat.S_IXUSR)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def base_manifest(self) -> dict:
        return {
            "DefaultMode": "Jobs",
            "JobsLayout": "SingleWindow",
            "Codex": str(self.cli),
            "Claude": str(self.cli),
            "Antigravity": str(self.cli),
            "OpenCode": str(self.cli),
            "Jobs": [
                {"Id": "job-1", "Client": "Codex", "Directory": str(self.wt1)},
                {"Id": "job-2", "Client": "Claude", "Directory": str(self.wt2), "Args": ["agents", "--cwd", str(self.wt2)], "Env": {"FOO": "bar"}},
                {"Id": "job-3", "Client": "Antigravity", "Directory": str(self.wt3)},
                {"Id": "job-4", "Client": "OpenCode", "Directory": str(self.wt4)},
            ],
        }

    def test_single_window_and_custom_args_env(self) -> None:
        plan = af.build_launch_plan(self.base_manifest(), self.root / "install")
        self.assertEqual(plan["Layout"], "SingleWindow")
        self.assertEqual(len(plan["Sessions"]), 1)
        cmds = plan["Sessions"][0]["TmuxCommands"]
        self.assertEqual(cmds[0][0], "new-session")
        self.assertEqual(cmds[-1][0], "select-layout")
        jobs = plan["Sessions"][0]["Jobs"]
        self.assertEqual(jobs[0]["NativeArguments"], ["agents"])
        self.assertEqual(jobs[1]["NativeArguments"], ["agents", "--cwd", str(self.wt2)])
        self.assertEqual(jobs[2]["NativeArguments"], [])
        pane2_cmd = af.build_pane_command(jobs[1])
        self.assertEqual(pane2_cmd[:3], ["env", "FOO=bar", str(self.cli)])

    def test_multi_tab_single_window_and_limits(self) -> None:
        m = self.base_manifest()
        m["TabColors"] = {"hub": "#1e66f5", "agy": "#40a02b"}
        for j in m["Jobs"]:
            j["Tab"] = "hub"
        m["Jobs"].append({"Id": "job-5", "Tab": "agy", "Client": "Antigravity", "Directory": str(self.wt5)})
        m["Jobs"].append({"Id": "job-6", "Tab": "agy", "Client": "Antigravity", "Directory": str(self.wt6)})
        plan = af.build_launch_plan(m, self.root / "install")
        self.assertEqual(len(plan["Tabs"]), 2)
        cmds = plan["Sessions"][0]["TmuxCommands"]
        self.assertTrue(any(c[0] == "new-window" and "-n" in c and "agy" in c for c in cmds))

        bad_hex = self.base_manifest()
        bad_hex["TabColors"] = {"fleet": "blue"}
        with self.assertRaisesRegex(ValueError, "RRGGBB"):
            af.validate_manifest(bad_hex)

        over_tab = self.base_manifest()
        over_tab["Jobs"].append({"Id": "job-5", "Client": "Antigravity", "Directory": str(self.wt5)})
        with self.assertRaisesRegex(ValueError, "4 panes per tab"):
            af.validate_manifest(over_tab)

    def test_rejects_git_dir_in_job_env(self) -> None:
        bad = self.base_manifest()
        bad["Jobs"][0]["Env"] = {"GIT_DIR": "/tmp/other"}
        with self.assertRaisesRegex(ValueError, "Git source"):
            af.validate_manifest(bad)

    def test_job_windows_layout(self) -> None:
        m = self.base_manifest()
        m["JobsLayout"] = "JobWindows"
        plan = af.build_launch_plan(m, self.root / "install")
        self.assertEqual(len(plan["Sessions"]), 4)

    def test_worktree_copy_files_and_guards(self) -> None:
        (self.repo / ".env").write_text("SECRET=ok\n", encoding="utf-8")
        (self.repo / ".worktreeinclude").write_text(".env\n", encoding="utf-8")

        # Ignored without opt-in
        wt_no_opt = self.root / "wt-no-opt"
        res_no = af.new_worktree(str(self.repo), str(wt_no_opt), base_ref="HEAD", branch="feat/noopt")
        self.assertEqual(res_no["CopiedFiles"], [])
        self.assertFalse((wt_no_opt / ".env").exists())

        # Copied with manifest WorktreeCopyFiles or AllowWorktreeInclude
        wt_opt = self.root / "wt-opt"
        res_opt = af.new_worktree(str(self.repo), str(wt_opt), base_ref="HEAD", branch="feat/opt", manifest={"AllowWorktreeInclude": True})
        self.assertEqual(res_opt["CopiedFiles"], [".env"])
        self.assertEqual((wt_opt / ".env").read_text(encoding="utf-8"), "SECRET=ok\n")

        # Reject traversal, absolute path, .git/, wildcards
        for bad_rel in ("../outside", "/etc/passwd", ".git/config", "*.env"):
            with self.assertRaises(ValueError):
                af.get_relative_copy_paths(self.repo, manifest={"WorktreeCopyFiles": [bad_rel]})

    def test_worktree_is_locked_at_checkout_only_when_requested(self) -> None:
        hooks = self.root / "checkout-hooks"
        hooks.mkdir()
        checkout_hook = hooks / "post-checkout"
        checkout_hook.write_text(
            '#!/bin/sh\nif test -f "$(git rev-parse --git-path locked)"; then\n'
            '    printf locked >lock-at-checkout\nelse\n    printf unlocked >lock-at-checkout\nfi\n',
            encoding="utf-8",
        )
        checkout_hook.chmod(0o755)
        subprocess.run(["git", "-C", str(self.repo), "config", "core.hooksPath", str(hooks)], check=True)

        for lock, expected in [(True, "locked"), (False, "unlocked")]:
            wt = self.root / expected
            result = af.new_worktree(str(self.repo), str(wt), base_ref="HEAD", lock=lock)
            self.assertEqual(result["Locked"], lock)
            self.assertEqual((wt / "lock-at-checkout").read_text(encoding="utf-8"), expected)

    def test_clean_worktree_guards_and_removal(self) -> None:
        install = self.root / "install"
        install.mkdir(parents=True, exist_ok=True)
        mp = self.root / "manifest.json"
        mp.write_text(json.dumps(self.base_manifest()), encoding="utf-8")

        # Main repo rejected
        with self.assertRaisesRegex(ValueError, "main Git repository"):
            af.clean_worktree(str(self.repo), install, manifest_path=mp)

        # Configured job rejected
        with self.assertRaisesRegex(ValueError, "configured in Agent Fleet"):
            af.clean_worktree(str(self.wt1), install, manifest_path=mp)

        # Ad-hoc worktree: dirty rejected unless force; dry-run preserves; merged removes
        wt_adhoc = self.root / "wt-adhoc"
        af.new_worktree(str(self.repo), str(wt_adhoc), base_ref="HEAD", branch="feat/adhoc", lock=True)
        (wt_adhoc / "untracked.txt").write_text("x", encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "uncommitted changes"):
            af.clean_worktree(str(wt_adhoc), install, manifest_path=mp)
        (wt_adhoc / "untracked.txt").unlink()

        # Dry run succeeds without removing
        dry = af.clean_worktree(str(wt_adhoc), install, dry_run=True, manifest_path=mp)
        self.assertEqual(dry["Result"], "dry-run")
        self.assertTrue(dry["Locked"])
        self.assertTrue(wt_adhoc.is_dir())

        # Real removal unlocks and deletes cleanly
        rem = af.clean_worktree(str(wt_adhoc), install, manifest_path=mp)
        self.assertEqual(rem["Result"], "removed")
        self.assertTrue(rem["WasLocked"])
        self.assertFalse(wt_adhoc.exists())

    def test_open_tab_and_profile_isolation(self) -> None:
        install = self.root / "install"
        mp = self.root / "manifest.json"
        m = self.base_manifest()
        mp.write_text(json.dumps(m), encoding="utf-8")

        # Collision with configured job rejected
        with self.assertRaisesRegex(ValueError, "already owned"):
            af.open_tab(m, install, "Antigravity", directory=str(self.wt1), manifest_path=mp, plan_only=True)

        # Plan-only on unused worktree succeeds
        wt_free = self.root / "wt-free"
        af.new_worktree(str(self.repo), str(wt_free), base_ref="HEAD", branch="feat/free")
        plan = af.open_tab(m, install, "Antigravity", directory=str(wt_free), manifest_path=mp, plan_only=True)
        self.assertEqual(plan["Result"], "planned")
        self.assertNotEqual(af.tmux_session_name(install, "single"), af.tmux_session_name(install, "single", profile="work"))

    def test_git_status_and_dispatch_queue_watch(self) -> None:
        (self.wt1 / "dirty.txt").write_text("x", encoding="utf-8")
        st = af.git_status(str(self.wt1))
        self.assertEqual(st["State"], "observed")
        self.assertEqual(st["DirtyCount"], 1)
        m = self.base_manifest()
        with mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="bg-123\n", stderr="")
            res = af.dispatch_task(m, self.root / "install", "Claude", str(self.wt2), "fix bug", model="sonnet", name="bugfix")
            self.assertEqual(res["Result"], "dispatched")
            qres = af.queue_message(m, "bugfix", "run tests", resume=True)
            self.assertEqual(qres["Result"], "queued")

        watch_out = af.format_status_watch(af.status_snapshot(m, self.root / "install", profile="work"))
        self.assertIn("profile: work", watch_out)
        self.assertIn("job-1", watch_out)

    def test_update_source_routing(self) -> None:
        repo, transport, prefix = af.update_source({})
        self.assertEqual((repo, transport, prefix), ("fergeley/agent-fleet", "https", ""))


import json  # noqa: E402

if __name__ == "__main__":
    unittest.main()
