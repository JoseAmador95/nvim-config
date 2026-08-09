#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import json
import os
import pathlib
import stat
import subprocess
import tempfile
import unittest
from unittest import mock


REPO = pathlib.Path(__file__).resolve().parent.parent
LOADER = importlib.machinery.SourceFileLoader("devpod_nvim", str(REPO / "scripts/devpod-nvim"))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
MODULE = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(MODULE)


class DevPodLauncherTest(unittest.TestCase):
    @staticmethod
    def provider(name="podman"):
        return {
            "name": name,
            "config": {
                "source": {"internal": True, "raw": "docker"},
                "agent": {"local": "true", "docker": {"install": "false"}},
            },
            "state": {"options": {"DOCKER_PATH": {"value": f"/usr/bin/{name}"}}},
        }

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="devpod-nvim-spec.")
        self.root = pathlib.Path(self.temp.name)
        subprocess.run(["git", "init", "-q", self.root], check=True)
        (self.root / "tracked.txt").write_text("base\n", encoding="utf-8")
        subprocess.run(["git", "-C", self.root, "add", "tracked.txt"], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                self.root,
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "commit",
                "-qm",
                "fixture",
            ],
            check=True,
        )

    def tearDown(self):
        self.temp.cleanup()

    def test_workspace_identity_includes_repo_provider_and_config(self):
        _, first = MODULE.identities(self.root.resolve(), "podman", ".devcontainer/devcontainer.json")
        _, second = MODULE.identities(self.root.resolve(), "docker", ".devcontainer/devcontainer.json")
        _, third = MODULE.identities(self.root.resolve(), "podman", ".devcontainer/alt/devcontainer.json")
        self.assertEqual(len({first, second, third}), 3)
        self.assertRegex(first, r"^nvim-[a-z0-9-]+-[0-9a-f]{12}$")

    def test_config_discovery_fails_closed_on_ambiguity_and_escape(self):
        default = self.root / ".devcontainer/devcontainer.json"
        default.parent.mkdir()
        default.write_text("{}", encoding="utf-8")
        self.assertEqual(MODULE.discover_config(self.root, None), ".devcontainer/devcontainer.json")
        alternate = self.root / ".devcontainer/alt/devcontainer.json"
        alternate.parent.mkdir()
        alternate.write_text("{}", encoding="utf-8")
        with self.assertRaisesRegex(MODULE.DevPodError, "more than one"):
            MODULE.discover_config(self.root, None)
        with self.assertRaisesRegex(MODULE.DevPodError, "outside"):
            MODULE.discover_config(self.root, "../devcontainer.json")

    def test_git_fingerprint_reports_lifecycle_mutation(self):
        before = MODULE.project_fingerprint(self.root)
        (self.root / "tracked.txt").write_text("changed\n", encoding="utf-8")
        after = MODULE.project_fingerprint(self.root)
        self.assertNotEqual(before, after)
        (self.root / "untracked.bin").write_bytes(b"\0\xff")
        self.assertNotEqual(after, MODULE.project_fingerprint(self.root))

    def test_private_state_is_owner_only_and_atomic(self):
        old = os.environ.get("NVIM_DEVPOD_STATE_HOME")
        os.environ["NVIM_DEVPOD_STATE_HOME"] = str(self.root / "state")
        try:
            private = MODULE.prepare_state()
            record = private / "workspaces/test.json"
            MODULE.atomic_json(record, {"version": 1, "value": "ok"})
            self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(record.stat().st_mode), 0o600)
            self.assertEqual(MODULE.read_json(record)["value"], "ok")
        finally:
            if old is None:
                os.environ.pop("NVIM_DEVPOD_STATE_HOME", None)
            else:
                os.environ["NVIM_DEVPOD_STATE_HOME"] = old

    def test_git_archive_rejects_links_and_traversal(self):
        import io
        import tarfile

        payload = io.BytesIO()
        with tarfile.open(fileobj=payload, mode="w") as archive:
            info = tarfile.TarInfo("link")
            info.type = tarfile.SYMTYPE
            info.linkname = "/etc/passwd"
            archive.addfile(info)
        with self.assertRaisesRegex(MODULE.DevPodError, "non-regular"):
            MODULE.safe_extract_git_archive(payload.getvalue(), self.root / "extract")

    def test_cli_exposes_only_structured_exec(self):
        help_result = subprocess.run(
            [str(REPO / "scripts/devpod-nvim"), "exec", "--help"],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        )
        self.assertIn("argv", help_result.stdout)
        self.assertNotIn("shell-command", help_result.stdout)
        self.assertEqual(MODULE.parser().parse_args(["exec", "--", "printf", "a b"]).argv, ["--", "printf", "a b"])

    def test_state_root_rejects_symlink(self):
        destination = self.root / "real-state"
        destination.mkdir()
        link = self.root / "linked-state"
        link.symlink_to(destination, target_is_directory=True)
        old = os.environ.get("NVIM_DEVPOD_STATE_HOME")
        os.environ["NVIM_DEVPOD_STATE_HOME"] = str(link)
        try:
            with self.assertRaisesRegex(MODULE.DevPodError, "not a real directory"):
                MODULE.prepare_state()
        finally:
            if old is None:
                os.environ.pop("NVIM_DEVPOD_STATE_HOME", None)
            else:
                os.environ["NVIM_DEVPOD_STATE_HOME"] = old

    def test_context_creation_restores_implicit_default(self):
        completed = subprocess.CompletedProcess([], 0, b"", b"")
        with mock.patch.object(
            MODULE,
            "json_command",
            side_effect=[
                [{"name": "default"}],
                [self.provider()],
            ],
        ), mock.patch.object(MODULE, "run", return_value=completed) as runner, mock.patch.object(
            MODULE.shutil, "which", return_value="/bin/sh"
        ):
            MODULE.ensure_context_provider(pathlib.Path("/tmp/devpod"), "podman")
        calls = [[str(value) for value in call.args[0]] for call in runner.call_args_list]
        self.assertIn(["/tmp/devpod", "context", "create", "nvim-devpod"], calls)
        self.assertIn(["/tmp/devpod", "context", "use", "default"], calls)

    def test_existing_context_is_selected_only_during_management(self):
        completed = subprocess.CompletedProcess([], 0, b"", b"")
        with mock.patch.object(
            MODULE,
            "json_command",
            side_effect=[
                [{"name": "default", "default": True}, {"name": "nvim-devpod"}],
                [self.provider()],
            ],
        ), mock.patch.object(MODULE, "run", return_value=completed) as runner, mock.patch.object(
            MODULE.shutil, "which", return_value="/bin/sh"
        ):
            MODULE.ensure_context_provider(pathlib.Path("/tmp/devpod"), "podman")
        calls = [[str(value) for value in call.args[0]] for call in runner.call_args_list]
        selected = calls.index(["/tmp/devpod", "context", "use", "nvim-devpod"])
        restored = calls.index(["/tmp/devpod", "context", "use", "default"])
        self.assertLess(selected, restored)

    def test_remote_provider_with_local_name_is_rejected(self):
        remote = self.provider()
        remote["config"]["source"] = {"internal": False, "raw": "remote"}
        completed = subprocess.CompletedProcess([], 0, b"", b"")
        with mock.patch.object(
            MODULE,
            "json_command",
            side_effect=[
                [{"name": "nvim-devpod", "default": True}],
                [remote],
            ],
        ), mock.patch.object(MODULE, "run", return_value=completed), mock.patch.object(
            MODULE.shutil, "which", return_value="/bin/sh"
        ):
            with self.assertRaisesRegex(MODULE.DevPodError, "local built-in Docker provider"):
                MODULE.ensure_context_provider(pathlib.Path("/tmp/devpod"), "podman")

    def test_live_editor_requires_the_single_editor_pane(self):
        completed = subprocess.CompletedProcess([], 0, b"editor\t1\n", b"")
        with mock.patch.dict(os.environ, {"TMUX_PANE": "%7"}), mock.patch.object(
            MODULE.shutil, "which", return_value="/usr/bin/tmux"
        ), mock.patch.object(MODULE, "run", return_value=completed):
            MODULE.require_editor_pane(False)
        wrong = subprocess.CompletedProcess([], 0, b"agent\t1\n", b"")
        with mock.patch.dict(os.environ, {"TMUX_PANE": "%7"}), mock.patch.object(
            MODULE.shutil, "which", return_value="/usr/bin/tmux"
        ), mock.patch.object(MODULE, "run", return_value=wrong), self.assertRaisesRegex(
            MODULE.DevPodError, "single-pane editor window"
        ):
            MODULE.require_editor_pane(False)
        with mock.patch.dict(os.environ, {}, clear=True):
            MODULE.require_editor_pane(True)

    def test_socket_paths_are_private_and_below_macos_limit(self):
        nvim, controller = MODULE.socket_paths("nvim-project-" + "x" * 200)
        self.assertLess(len(os.fsencode(str(nvim))), 100)
        self.assertLess(len(os.fsencode(str(controller))), 100)
        self.assertEqual(stat.S_IMODE(nvim.parent.stat().st_mode), 0o700)

    def test_verified_download_requires_explicit_network_permission(self):
        with self.assertRaisesRegex(MODULE.DevPodError, "rerun with --allow-network"):
            MODULE.download(
                "https://example.invalid/asset",
                self.root / "missing-asset",
                "0" * 64,
                False,
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
