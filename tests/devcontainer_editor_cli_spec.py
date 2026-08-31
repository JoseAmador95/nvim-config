"""Focused contracts for the Dev Container editor launcher."""

from __future__ import annotations

import argparse
import importlib.machinery
import importlib.util
import os
import pathlib
import stat
import subprocess
import tempfile
import unittest
import uuid
from unittest import mock

REPO = pathlib.Path(__file__).resolve().parent.parent
LOADER = importlib.machinery.SourceFileLoader(
    "devcontainer_editor_cli",
    str(REPO / "scripts/devcontainer-editor"),
)
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
MODULE = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(MODULE)


class DevContainerEditorCliTest(unittest.TestCase):
    """Exercise private state, lifecycle, routing, and no-network contracts."""

    def setUp(self) -> None:
        """Create one isolated Git-shaped project and private state root."""
        self.temporary = tempfile.TemporaryDirectory(prefix="devcontainer-editor-spec.")
        self.root = pathlib.Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        (self.repo / ".git").mkdir()
        (self.repo / ".devcontainer").mkdir()
        self.config = self.repo / ".devcontainer/devcontainer.json"
        self.config.write_text('{"image":"ubuntu:24.04"}\n', encoding="utf-8")
        self.file = self.repo / "file.txt"
        self.file.write_text("hello\n", encoding="utf-8")
        self.repo = self.repo.resolve(strict=True)
        self.config = self.repo / ".devcontainer/devcontainer.json"
        self.file = self.repo / "file.txt"
        self.state = self.root / "state"
        self.environment = mock.patch.dict(
            os.environ,
            {"NVIM_DEVCONTAINER_STATE_HOME": str(self.state)},
        )
        self.environment.start()
        self.paths = MODULE.prepare_state()

    def tearDown(self) -> None:
        """Restore process environment and remove the isolated fixture."""
        self.environment.stop()
        self.temporary.cleanup()

    def record(self, status: str = "running", pid: int | None = None) -> dict[str, object]:
        """Build and persist one exact lifecycle fixture."""
        token = "t" * 43
        value = MODULE.base_record(
            self.repo,
            self.config,
            MODULE.log_path(self.paths, self.repo),
            token,
            False,
            None,
        )
        value.update(
            {
                "status": status,
                "pid": os.getpid() if pid is None else pid,
                "container_root": "/workspaces/repo",
                "container_id": "abc",
                "workspace_key": {
                    "runtime": "container",
                    "root": "/workspaces/repo",
                    "repo_identity": str(self.repo),
                },
            }
        )
        MODULE.atomic_json(MODULE.record_path(self.paths, self.repo), value)
        return value

    def test_state_and_spool_are_owner_only(self) -> None:
        """Private directories and JSON files remain 0700/0600."""
        for path in self.paths.values():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
        spool = MODULE.prepare_spool(MODULE.spool_path(self.paths, self.repo))
        for path in (spool, spool / "inbox", spool / "outbox", spool / "acks"):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
        target = spool / "inbox/request.json"
        MODULE.atomic_json(target, {"ok": True})
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)

    def test_state_root_symlink_and_record_symlink_are_rejected(self) -> None:
        """State and records are never accepted through symlinks."""
        alternate = self.root / "alternate"
        alternate.mkdir()
        linked = self.root / "linked"
        linked.symlink_to(alternate, target_is_directory=True)
        with mock.patch.dict(
            os.environ,
            {"NVIM_DEVCONTAINER_STATE_HOME": str(linked)},
        ), self.assertRaisesRegex(MODULE.EditorError, "not a real directory"):
            MODULE.prepare_state()
        path = MODULE.record_path(self.paths, self.repo)
        path.symlink_to(self.file)
        with self.assertRaisesRegex(MODULE.EditorError, "unsafe"):
            MODULE.selected_record(self.paths, self.repo)

    def test_explicit_config_is_contained_regular_and_has_no_fallback(self) -> None:
        """Explicit invalid config never falls back to a conventional file."""
        self.assertEqual(MODULE.discover_config(self.repo, None), self.config)
        outside = self.root / "outside.json"
        outside.write_text("{}", encoding="utf-8")
        with self.assertRaisesRegex(MODULE.EditorError, "contained"):
            MODULE.discover_config(self.repo, str(outside))
        link = self.repo / "linked.json"
        link.symlink_to(outside)
        with self.assertRaisesRegex(MODULE.EditorError, "non-symlink"):
            MODULE.discover_config(self.repo, str(link))

    def test_up_argv_uses_only_devcontainers_cli_and_explicit_mounts(self) -> None:
        """Lifecycle argv uses only the explicit CLI and carries SSH parity."""
        spool = MODULE.prepare_spool(MODULE.spool_path(self.paths, self.repo))
        agent = self.root / "agent.sock"
        argv, remote = MODULE.up_argv(
            "/managed/devcontainer",
            self.repo,
            self.config,
            spool,
            True,
            agent,
        )
        self.assertEqual(argv[:2], ["/managed/devcontainer", "up"])
        self.assertIn("--remove-existing-container", argv)
        self.assertIn("SSH_AUTH_SOCK=/tmp/nvim-config-ssh-agent.sock", argv)
        self.assertIn(str(spool), "\n".join(argv))
        self.assertTrue(remote.startswith("/tmp/nvim-devcontainer-"))

    def test_up_projection_requires_exact_json_fields(self) -> None:
        """Container identity and remote root are schema checked."""
        result = subprocess.CompletedProcess(
            ["devcontainer", "up"],
            0,
            b'{"containerId":"abc","remoteWorkspaceFolder":"/workspaces/repo"}',
            b"",
        )
        self.assertEqual(MODULE.decode_up(result), ("abc", "/workspaces/repo"))
        result.stdout = b'{"containerId":"abc","remoteWorkspaceFolder":"relative"}'
        with self.assertRaisesRegex(MODULE.EditorError, "remote workspace"):
            MODULE.decode_up(result)

    def test_offline_environment_reaches_verified_tools_without_a_claim(self) -> None:
        """Denied network becomes NVIM_CONFIG_OFFLINE=1 in the container."""
        record = self.record()
        values = MODULE.remote_environment(record, "/tmp/spool")
        self.assertIn("NVIM_CONFIG_OFFLINE=1", values)
        record["network_authorized"] = True
        self.assertIn("NVIM_CONFIG_OFFLINE=0", MODULE.remote_environment(record, "/tmp/spool"))

    def test_cli_missing_never_downloads_or_falls_back(self) -> None:
        """The launcher only accepts an already installed Dev Containers CLI."""
        with mock.patch.dict(os.environ, {}, clear=True), mock.patch.object(
            MODULE.shutil,
            "which",
            return_value=None,
        ), self.assertRaisesRegex(MODULE.EditorError, "no implicit download"):
            MODULE.cli_path()

    def test_lock_recovers_only_a_dead_owner(self) -> None:
        """Dead owner locks are recovered; live/corrupt locks fail closed."""
        lock = self.paths["locks"] / f"{MODULE.workspace_id(self.repo)}.json"
        MODULE.atomic_json(lock, {"version": 1, "pid": 99_999_999, "created_at": MODULE.utc_now()})
        with mock.patch.object(MODULE, "pid_alive", return_value=False), MODULE.workspace_lock(
            self.paths,
            self.repo,
        ):
            self.assertTrue(lock.exists())
        self.assertFalse(lock.exists())
        MODULE.atomic_json(lock, {"version": 1, "pid": os.getpid(), "created_at": MODULE.utc_now()})
        with self.assertRaisesRegex(MODULE.EditorError, "busy"), MODULE.workspace_lock(
            self.paths,
            self.repo,
        ):
            pass

    def test_fallback_is_allowed_only_for_absent_or_explicitly_stopped(self) -> None:
        """Starting/error/dead records disable host fallback."""
        with self.assertRaises(MODULE.NoActiveEditor):
            MODULE.selected_record(self.paths, self.repo)
        self.record("stopped")
        with self.assertRaises(MODULE.NoActiveEditor):
            MODULE.selected_record(self.paths, self.repo)
        self.record("starting")
        with self.assertRaisesRegex(MODULE.EditorError, "fallback is disabled"):
            MODULE.selected_record(self.paths, self.repo)
        self.record("error")
        with self.assertRaisesRegex(MODULE.EditorError, "fallback is disabled"):
            MODULE.selected_record(self.paths, self.repo)
        self.record("running", pid=99_999_999)
        with self.assertRaisesRegex(MODULE.EditorError, "unreachable"):
            MODULE.selected_record(self.paths, self.repo)

    def test_lifecycle_failure_after_start_never_falls_back(self) -> None:
        """The starting record precedes CLI resolution and becomes fail-closed error state."""
        arguments = argparse.Namespace(
            repo=str(self.repo),
            config=None,
            recreate=False,
            allow_network=False,
            timeout=1.0,
        )
        with mock.patch.object(MODULE, "repo_root", return_value=self.repo), mock.patch.object(
            MODULE,
            "require_editor_pane",
            return_value="%1",
        ), mock.patch.object(
            MODULE,
            "cli_path",
            side_effect=MODULE.EditorError("CLI is broken"),
        ), self.assertRaisesRegex(MODULE.EditorError, "CLI is broken"):
            MODULE.cmd_up(arguments)
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "error")
        with self.assertRaisesRegex(MODULE.EditorError, "fallback is disabled"):
            MODULE.selected_record(self.paths, self.repo)

    def test_open_location_writes_authenticated_request_and_waits_for_ack(self) -> None:
        """Host-to-container routing uses one authenticated relative request."""
        record = self.record()
        captured: dict[str, object] = {}

        def acknowledge(spool: pathlib.Path, request: dict[str, object], _timeout: float) -> None:
            captured.update(request)
            request_path = spool / "inbox" / f"{request['request_id']}.json"
            persisted = MODULE.read_private_json(request_path, "request")
            self.assertEqual(persisted, request)

        with mock.patch.object(MODULE, "wait_ack", side_effect=acknowledge):
            MODULE.open_location(self.paths, self.repo, str(self.file), 4, 2, 1.0)
        self.assertEqual(captured["token"], record["token"])
        self.assertEqual(captured["path"], "file.txt")
        self.assertEqual(captured["action"], "open_location")
        with self.assertRaisesRegex(MODULE.EditorError, "contained"):
            MODULE.open_location(self.paths, self.repo, "/etc/passwd", 1, 1, 1.0)

    def test_wait_ack_rejects_mismatched_token_and_timeout(self) -> None:
        """Spool acknowledgements authenticate and fail closed when absent."""
        spool = MODULE.prepare_spool(MODULE.spool_path(self.paths, self.repo))
        request = {
            "version": 1,
            "token": "t" * 43,
            "request_id": str(uuid.uuid4()),
            "action": "open_location",
        }
        path = spool / "acks" / f"{request['request_id']}.json"
        MODULE.atomic_json(
            path,
            {
                "version": 1,
                "token": "wrong",
                "request_id": request["request_id"],
                "ok": True,
                "action": "open_location",
                "error": None,
            },
        )
        with self.assertRaises(MODULE.EditorError):
            MODULE.wait_ack(spool, request, 0.1)
        with self.assertRaisesRegex(MODULE.EditorError, "timed out"):
            MODULE.wait_ack(spool, request, 0.01)

    def test_outbox_authentication_and_replay_cleanup(self) -> None:
        """Container-to-host actions require token/allowlist and are consumed once."""
        record = self.record()
        spool = MODULE.prepare_spool(MODULE.spool_path(self.paths, self.repo))
        request_id = str(uuid.uuid4())
        request = {
            "version": 1,
            "token": record["token"],
            "request_id": request_id,
            "action": "lazygit",
            "created_at": MODULE.utc_now(),
        }
        path = spool / "outbox" / f"{request_id}.json"
        MODULE.atomic_json(path, request)
        with mock.patch.object(MODULE, "tmux_action") as action:
            self.assertEqual(MODULE.consume_outbox(spool, record), 1)
            action.assert_called_once_with(record, "lazygit")
        self.assertFalse(path.exists())
        ack = MODULE.read_private_json(spool / "acks" / f"{request_id}.json", "ack")
        self.assertTrue(ack["ok"])
        self.assertEqual(MODULE.consume_outbox(spool, record), 0)

    def test_host_action_failure_is_acknowledged_without_execution_retry(self) -> None:
        """Failed host actions produce one negative ACK and no replay."""
        record = self.record()
        spool = MODULE.prepare_spool(MODULE.spool_path(self.paths, self.repo))
        request_id = str(uuid.uuid4())
        request = {
            "version": 1,
            "token": record["token"],
            "request_id": request_id,
            "action": "lazygit",
            "created_at": MODULE.utc_now(),
        }
        MODULE.atomic_json(spool / "outbox" / f"{request_id}.json", request)
        with mock.patch.object(MODULE, "tmux_action", side_effect=MODULE.EditorError("rejected")):
            MODULE.consume_outbox(spool, record)
        ack = MODULE.read_private_json(spool / "acks" / f"{request_id}.json", "ack")
        self.assertFalse(ack["ok"])
        self.assertEqual(ack["error"], "rejected")

    def test_explicit_host_action_marks_stopped_before_respawn(self) -> None:
        """The sole explicit fallback state is durable before tmux replacement."""
        record = self.record()
        spool = MODULE.prepare_spool(MODULE.spool_path(self.paths, self.repo))
        request_id = str(uuid.uuid4())
        request = {
            "version": 1,
            "token": record["token"],
            "request_id": request_id,
            "action": "host_editor",
            "created_at": MODULE.utc_now(),
        }
        MODULE.atomic_json(spool / "outbox" / f"{request_id}.json", request)
        with mock.patch.object(MODULE, "tmux_action") as action:
            MODULE.consume_outbox(spool, record)
        action.assert_called_once_with(record, "host_editor")
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "stopped")
        ack = MODULE.read_private_json(spool / "acks" / f"{request_id}.json", "ack")
        self.assertTrue(ack["ok"])

    def test_run_editor_services_spool_until_quick_exit(self) -> None:
        """Quick editor exit still performs final authenticated reconciliation."""
        process = mock.Mock()
        process.poll.side_effect = [None, 0]
        process.returncode = 0
        record = self.record()
        spool = MODULE.prepare_spool(MODULE.spool_path(self.paths, self.repo))
        with mock.patch.object(MODULE.subprocess, "Popen", return_value=process), mock.patch.object(
            MODULE,
            "consume_outbox",
            return_value=0,
        ) as consume, mock.patch.object(MODULE.time, "sleep"):
            self.assertEqual(MODULE.run_editor(["devcontainer", "exec"], spool, record), 0)
        self.assertEqual(consume.call_count, 2)

    def test_run_editor_cancellation_terminates_and_stays_fail_closed(self) -> None:
        """Explicit cancellation terminates the child and reports lifecycle error."""
        process = mock.Mock()
        process.poll.return_value = None
        process.wait.return_value = 0
        record = self.record()
        spool = MODULE.prepare_spool(MODULE.spool_path(self.paths, self.repo))
        with mock.patch.object(MODULE.subprocess, "Popen", return_value=process), mock.patch.object(
            MODULE,
            "consume_outbox",
            return_value=0,
        ), mock.patch.object(
            MODULE.time,
            "sleep",
            side_effect=KeyboardInterrupt,
        ), self.assertRaisesRegex(MODULE.EditorError, "cancelled"):
            MODULE.run_editor(["devcontainer", "exec"], spool, record)
        process.terminate.assert_called_once_with()
        process.wait.assert_called_once_with(timeout=5.0)

    def test_module_imports_are_at_module_scope_and_cli_help_is_offline(self) -> None:
        """The Python entrypoint imports cleanly and help starts no lifecycle."""
        result = subprocess.run(
            [str(REPO / "scripts/devcontainer-editor"), "up", "--help"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--allow-network", result.stdout)


if __name__ == "__main__":
    unittest.main()
