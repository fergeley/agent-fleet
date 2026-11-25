#!/usr/bin/env python3
"""Unit tests for the macOS/Linux (tmux) Agent Fleet backend."""

from __future__ import annotations

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
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        subprocess.run(["git", "-C", str(self.repo), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-q", "--allow-empty", "-m", "init"], check=True)
        for wt in (self.wt1, self.wt2, self.wt3, self.wt4):
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

    def test_git_status_and_new_worktree(self) -> None:
        (self.wt1 / "dirty.txt").write_text("x", encoding="utf-8")
        st = af.git_status(str(self.wt1))
        self.assertEqual(st["State"], "observed")
        self.assertEqual(st["DirtyCount"], 1)
        wt5 = self.root / "wt5"
        created = af.new_worktree(str(self.repo), str(wt5), base_ref="HEAD", branch="feat/test-wt", lock=True)
        self.assertEqual(created["Result"], "created")
        self.assertTrue(created["Locked"])
        self.assertTrue(wt5.is_dir())

    def test_dispatch_and_queue_commands(self) -> None:
        m = self.base_manifest()
        with mock.patch("subprocess.run") as mock_run:
            mock_run.return_value = mock.Mock(returncode=0, stdout="bg-123\n", stderr="")
            res = af.dispatch_task(m, self.root / "install", "Claude", str(self.wt2), "fix bug", model="sonnet", name="bugfix")
            self.assertEqual(res["Result"], "dispatched")
            called_cmd = mock_run.call_args[0][0]
            self.assertEqual(called_cmd, [str(self.cli), "--bg", "--model", "sonnet", "--name", "bugfix", "fix bug"])

            qres = af.queue_message(m, "bugfix", "run tests", resume=True)
            self.assertEqual(qres["Result"], "queued")
            self.assertEqual(mock_run.call_args[0][0], [str(self.cli), "queue", "--thread", "bugfix", "--message", "run tests", "--resume"])

    def test_update_source_routing(self) -> None:
        repo, transport, prefix = af.update_source({})
        self.assertEqual((repo, transport, prefix), ("fergeley/agent-fleet", "https", ""))


if __name__ == "__main__":
    unittest.main()
