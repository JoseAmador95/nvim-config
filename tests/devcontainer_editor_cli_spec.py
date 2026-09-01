"""Focused contracts for the Dev Container editor launcher."""

from __future__ import annotations

import argparse
import contextlib
import importlib.machinery
import importlib.util
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import unittest
import uuid
from collections.abc import Iterator
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
        self.spool_context = MODULE.workspace_spool(MODULE.spool_path(self.paths, self.repo))
        self.spool = self.spool_context.__enter__()

    def tearDown(self) -> None:
        """Restore process environment and remove the isolated fixture."""
        self.spool_context.__exit__(None, None, None)
        self.environment.stop()
        self.temporary.cleanup()

    def record(self, status: str = "running", pid: int | None = None) -> dict[str, object]:
        """Build and persist one exact lifecycle fixture."""
        self.token = "t" * 43
        value = MODULE.base_record(
            self.repo,
            self.config,
            MODULE.log_path(self.paths, self.repo),
            False,
            None,
            "%7",
            7007,
            "00000000-0000-4000-8000-000000000009",
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
        MODULE.unlink_regular_at(self.spool.root_fd, "auth.json")
        MODULE.create_auth(self.spool, self.token)
        return value

    def test_state_and_spool_are_owner_only(self) -> None:
        """Private directories and JSON files remain 0700/0600."""
        for path in self.paths.values():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
        spool = self.spool
        for path in (spool.root, spool.root / "inbox", spool.root / "outbox", spool.root / "acks"):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
        target = spool.root / "inbox/request.json"
        MODULE.atomic_json(target, {"ok": True})
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        MODULE.create_auth(spool, "a" * 32)
        self.assertEqual(stat.S_IMODE(MODULE.auth_path(spool).stat().st_mode), 0o600)

    def test_spool_descriptors_survive_child_path_replacement(self) -> None:
        """Pinned outbox operations never follow a later child-path replacement."""
        record = self.record()
        outside = self.root / "outside"
        outside.mkdir()
        victim = outside / "must-remain.json"
        victim.write_text('{"must_remain":true}\n', encoding="utf-8")
        outbox = self.spool.root / "outbox"
        outbox.rmdir()
        outbox.symlink_to(outside, target_is_directory=True)

        self.assertEqual(MODULE.consume_outbox(self.paths, self.spool, record, self.token), (0, False))
        self.assertEqual(victim.read_text(encoding="utf-8"), '{"must_remain":true}\n')

    def test_spool_descriptor_helpers_reject_non_basename_entries(self) -> None:
        """Descriptor-relative state helpers never traverse outside their pinned directory."""
        with self.assertRaisesRegex(MODULE.EditorError, "not a basename"):
            MODULE.atomic_create_json_at(self.spool.outbox_fd, "../outside.json", {"ok": True})
        self.assertFalse((self.spool.root / "outside.json").exists())

    def test_state_children_stay_pinned_across_lexical_parent_replacement(self) -> None:
        """Record and lock mutations cannot escape after state-child replacement."""
        record = self.record()
        workspaces = self.paths["workspaces"]
        pinned_workspaces = self.state / "pinned-workspaces"
        workspaces.rename(pinned_workspaces)
        outside_workspaces = self.root / "outside-workspaces"
        outside_workspaces.mkdir(mode=0o700)
        workspaces.symlink_to(outside_workspaces, target_is_directory=True)

        MODULE.update_workspace_record(self.paths, self.repo, record, status="error", error="anchored")
        pinned_record = pinned_workspaces / MODULE.record_name(self.repo)
        self.assertEqual(MODULE.read_private_json(pinned_record, "record")["error"], "anchored")
        self.assertEqual(list(outside_workspaces.iterdir()), [])

        locks = self.paths["locks"]
        pinned_locks = self.state / "pinned-locks"
        locks.rename(pinned_locks)
        outside_locks = self.root / "outside-locks"
        outside_locks.mkdir(mode=0o700)
        locks.symlink_to(outside_locks, target_is_directory=True)
        with MODULE.workspace_lock(self.paths, self.repo):
            self.assertTrue((pinned_locks / MODULE.record_name(self.repo)).exists())
            with self.assertRaisesRegex(MODULE.EditorError, "busy"), MODULE.workspace_lock(
                self.paths,
                self.repo,
            ):
                pass
        self.assertEqual(list(outside_locks.iterdir()), [])

    def test_auth_is_created_once_and_parent_directory_is_synced(self) -> None:
        """Authentication uses its final name, one link, and a durable directory entry."""
        token = "a" * 43
        real_fsync = MODULE.os.fsync
        synced: list[int] = []

        def capture_fsync(descriptor: int) -> None:
            synced.append(descriptor)
            real_fsync(descriptor)

        with mock.patch.object(MODULE.os, "link", side_effect=AssertionError("auth hardlink")), mock.patch.object(
            MODULE.os,
            "fsync",
            side_effect=capture_fsync,
        ):
            MODULE.create_auth(self.spool, token)

        auth = MODULE.auth_path(self.spool)
        self.assertEqual(auth.stat().st_nlink, 1)
        self.assertIn(self.spool.root_fd, synced)
        self.assertEqual([path.name for path in self.spool.root.iterdir() if "auth.json." in path.name], [])

    def test_auth_hardlink_is_rejected_and_not_retired(self) -> None:
        """A second authentication link blocks reads and lifecycle cleanup."""
        MODULE.create_auth(self.spool, "a" * 43)
        auth = MODULE.auth_path(self.spool)
        duplicate = self.spool.root / "duplicate-auth.json"
        os.link(auth, duplicate)

        with self.assertRaisesRegex(MODULE.EditorError, "unsafe"):
            MODULE.read_auth(self.spool)
        with self.assertRaisesRegex(MODULE.EditorError, "single-link"):
            MODULE.remove_auth(self.spool)
        self.assertTrue(auth.exists())
        duplicate.unlink()
        MODULE.remove_auth(self.spool)
        self.assertFalse(auth.exists())

    def test_auth_hardlink_created_between_stat_and_open_is_rejected(self) -> None:
        """Descriptor validation repeats single-link ownership after opening."""
        MODULE.create_auth(self.spool, "a" * 43)
        auth = MODULE.auth_path(self.spool)
        duplicate = self.spool.root / "raced-auth-link.json"
        real_open = MODULE.os.open
        raced = False

        def race_open(path: object, flags: int, *args: object, **kwargs: object) -> int:
            nonlocal raced
            if path == "auth.json" and kwargs.get("dir_fd") == self.spool.root_fd and not raced:
                raced = True
                os.link(auth, duplicate)
            return real_open(path, flags, *args, **kwargs)

        with mock.patch.object(MODULE.os, "open", side_effect=race_open), self.assertRaisesRegex(
            MODULE.EditorError,
            "changed while opening",
        ):
            MODULE.read_auth(self.spool)

        self.assertTrue(raced)
        self.assertEqual(auth.stat().st_nlink, 2)
        duplicate.unlink()
        MODULE.remove_auth(self.spool)

    def test_auth_cleanup_never_deletes_a_replacement(self) -> None:
        """A failed direct create preserves any final-name replacement installed mid-write."""
        auth = MODULE.auth_path(self.spool)
        displaced = self.spool.root / "displaced-auth.json"
        real_write = MODULE.write_descriptor

        def replace_after_write(descriptor: int, payload: bytes) -> None:
            real_write(descriptor, payload)
            auth.rename(displaced)
            auth.write_text('{"replacement":true}\n', encoding="utf-8")
            auth.chmod(0o600)
            raise MODULE.EditorError("injected write boundary failure")

        with mock.patch.object(MODULE, "write_descriptor", side_effect=replace_after_write), self.assertRaisesRegex(
            MODULE.EditorError,
            "injected write boundary failure",
        ):
            MODULE.create_auth(self.spool, "a" * 43)

        self.assertEqual(auth.read_text(encoding="utf-8"), '{"replacement":true}\n')
        self.assertTrue(displaced.exists())

    def test_auth_cleanup_warning_sink_preserves_primary_and_cause(self) -> None:
        """Cleanup warning I/O never masks the active authentication write error."""
        auth = MODULE.auth_path(self.spool)

        def fail_write(descriptor: int, _payload: bytes) -> None:
            os.close(descriptor)
            try:
                raise OSError("injected auth disk failure")
            except OSError as cause:
                raise MODULE.EditorError("primary authentication write failure") from cause

        with mock.patch.object(MODULE, "write_descriptor", side_effect=fail_write), mock.patch.object(
            MODULE,
            "unlink_regular_at",
            side_effect=MODULE.EditorError("authentication cleanup failed"),
        ), mock.patch.object(
            MODULE,
            "progress",
            side_effect=ValueError("stderr is closed"),
        ) as reported, self.assertRaises(MODULE.EditorError) as caught:
            MODULE.create_auth(self.spool, "a" * 43)

        self.assertEqual(str(caught.exception), "primary authentication write failure")
        self.assertIsInstance(caught.exception.__cause__, OSError)
        assert caught.exception.__cause__ is not None
        self.assertEqual(str(caught.exception.__cause__), "injected auth disk failure")
        reported.assert_called_once()
        self.assertIn("authentication cleanup failed", reported.call_args.args[0])
        self.assertTrue(auth.exists())

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
        spool = self.spool
        agent = self.root / "agent.sock"
        argv, remote = MODULE.up_argv(
            "/managed/devcontainer",
            self.repo,
            self.config,
            spool.root,
            True,
            agent,
            "--no-lockfile",
        )
        self.assertEqual(argv[:2], ["/managed/devcontainer", "up"])
        self.assertIn("--remove-existing-container", argv)
        self.assertIn("SSH_AUTH_SOCK=/tmp/nvim-config-ssh-agent.sock", argv)
        self.assertIn("--no-lockfile", argv)
        self.assertIn(str(spool.root), "\n".join(argv))
        self.assertTrue(remote.startswith("/tmp/nvim-devcontainer-"))

    def test_external_up_detects_a_spool_root_swap_after_the_call(self) -> None:
        """The lifecycle fails closed when the lexical mount source changes during up."""
        command, _ = MODULE.up_argv(
            "/managed/devcontainer",
            self.repo,
            self.config,
            self.spool.root,
            False,
            None,
            "--no-lockfile",
        )
        pinned = self.spool.root.with_name("pinned-spool")
        outside = self.root / "outside-spool"
        outside.mkdir(mode=0o700)

        def swap_root(*_args: object, **_kwargs: object) -> subprocess.CompletedProcess[bytes]:
            self.spool.root.rename(pinned)
            self.spool.root.symlink_to(outside, target_is_directory=True)
            return subprocess.CompletedProcess(command, 0, b"{}", b"")

        with mock.patch.object(MODULE, "run", side_effect=swap_root), self.assertRaisesRegex(
            MODULE.EditorError,
            "no longer names its pinned directory",
        ):
            MODULE.run_up_with_pinned_spool(command, self.spool, 1.0)

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
        for container_root in (
            "//workspaces/repo",
            "/workspaces//repo",
            "/workspaces/./repo",
            "/workspaces/repo/../escape",
            "/workspaces/repo/",
        ):
            result.stdout = (
                '{"containerId":"abc","remoteWorkspaceFolder":"' + container_root + '"}'
            ).encode()
            with self.subTest(container_root=container_root), self.assertRaisesRegex(
                MODULE.EditorError,
                "remote workspace",
            ):
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

    def test_preserve_lockfile_selects_flags_at_each_invocation(self) -> None:
        """Preserve chooses absent and present lock modes after an on-demand probe."""
        supported = subprocess.CompletedProcess(
            ["devcontainer", "up", "--help"],
            0,
            b"--frozen-lockfile\n--no-lockfile\n",
            b"",
        )
        with mock.patch.object(MODULE, "run", return_value=supported) as execute:
            self.assertEqual(
                MODULE.preserve_lockfile_flag("/managed/devcontainer", self.config),
                "--no-lockfile",
            )
            lockfile = MODULE.lockfile_path(self.config)
            self.assertEqual(lockfile, self.config.with_name("devcontainer-lock.json"))
            lockfile.write_text('{"lockfileVersion":1}\n', encoding="utf-8")
            self.assertEqual(
                MODULE.preserve_lockfile_flag("/managed/devcontainer", self.config),
                "--frozen-lockfile",
            )
        self.assertEqual(execute.call_count, 2, "capability was cached instead of probed per invocation")
        execute.assert_called_with(
            ["/managed/devcontainer", "up", "--help"],
            timeout=5.0,
            check=False,
        )

    def test_preserve_lockfile_fails_closed_when_cli_is_unsupported(self) -> None:
        """An old or ambiguous CLI cannot silently mutate lockfile state."""
        unsupported = subprocess.CompletedProcess(
            ["devcontainer", "up", "--help"],
            0,
            b"--no-lockfile\n",
            b"",
        )
        with mock.patch.object(MODULE, "run", return_value=unsupported), self.assertRaisesRegex(
            MODULE.EditorError,
            "required lockfile preservation flags",
        ):
            MODULE.preserve_lockfile_flag("/managed/devcontainer", self.config)

    def test_workspace_lock_rejects_hard_link_without_modifying_peer(self) -> None:
        """A hard-linked lock never truncates the other pathname's contents."""
        lock = self.paths["locks"] / f"{MODULE.workspace_id(self.repo)}.json"
        victim = self.root / "private-peer.json"
        victim.write_bytes(b"earlier private contents\n")
        victim.chmod(0o600)
        os.link(victim, lock)

        with self.assertRaisesRegex(MODULE.EditorError, "unsafe"), MODULE.workspace_lock(
            self.paths,
            self.repo,
        ):
            pass

        self.assertEqual(victim.read_bytes(), b"earlier private contents\n")

    def test_flock_serializes_real_contenders_and_reuses_stale_file(self) -> None:
        """An unlocked stale inode is reused while a live flock excludes contenders."""
        lock = self.paths["locks"] / f"{MODULE.workspace_id(self.repo)}.json"
        MODULE.atomic_json(lock, {"stale": True})
        inode = lock.stat().st_ino
        with MODULE.workspace_lock(self.paths, self.repo):
            self.assertTrue(lock.exists())
            self.assertEqual(lock.stat().st_ino, inode)
            with self.assertRaisesRegex(MODULE.EditorError, "busy"), MODULE.workspace_lock(
                self.paths,
                self.repo,
            ):
                pass
        with MODULE.workspace_lock(self.paths, self.repo):
            self.assertEqual(MODULE.read_private_json(lock, "lock")["pid"], os.getpid())

        contender = subprocess.Popen(
            [
                sys.executable,
                "-c",
                (
                    "import fcntl,os,sys;"
                    "fd=os.open(sys.argv[1],os.O_RDWR);"
                    "fcntl.flock(fd,fcntl.LOCK_EX);"
                    "print('locked',flush=True);"
                    "sys.stdin.read(1)"
                ),
                str(lock),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            assert contender.stdout is not None
            self.assertEqual(contender.stdout.readline(), b"locked\n")
            with self.assertRaisesRegex(MODULE.EditorError, "busy"), MODULE.workspace_lock(
                self.paths,
                self.repo,
            ):
                pass
        finally:
            contender.communicate(b"x", timeout=5)
        self.assertEqual(contender.returncode, 0)

    def test_fallback_is_allowed_only_when_the_record_is_absent(self) -> None:
        """Every extant lifecycle state disables host fallback."""
        with self.assertRaises(MODULE.NoActiveEditor):
            MODULE.selected_record(self.paths, self.repo)
        for status in ("starting", "stopped", "error", "dead"):
            self.record(status)
            with self.assertRaisesRegex(MODULE.EditorError, "fallback is disabled"):
                MODULE.selected_record(self.paths, self.repo)
        self.record("running", pid=99_999_999)
        with self.assertRaisesRegex(MODULE.EditorError, "unreachable"):
            MODULE.selected_record(self.paths, self.repo)

    def test_exact_fallback_retains_the_lifecycle_lock_across_exec(self) -> None:
        """The host router inherits the flock while its own subprocesses close it."""
        arguments = argparse.Namespace(
            wait_editor=False,
            cwd=str(self.repo),
            file=str(self.file),
            line=1,
            column=1,
        )
        original_lock = MODULE.workspace_lock
        observed: dict[str, int] = {}

        @contextlib.contextmanager
        def capture_lock(
            paths: MODULE.StateDirectories,
            root: pathlib.Path,
        ) -> Iterator[int]:
            with original_lock(paths, root) as descriptor:
                observed["descriptor"] = descriptor
                yield descriptor

        def reject_exec(path: pathlib.Path, argv: list[str]) -> None:
            descriptor = observed["descriptor"]
            self.assertTrue(os.get_inheritable(descriptor))
            self.assertEqual(path, REPO / "scripts/exact-editor-open")
            self.assertEqual(argv[1:3], ["--cwd", str(self.repo)])
            with self.assertRaisesRegex(MODULE.EditorError, "busy"), original_lock(
                self.paths,
                self.repo,
            ):
                pass
            child = subprocess.run(
                [
                    sys.executable,
                    "-c",
                    (
                        "import os,sys; fd=int(sys.argv[1]); "
                        "\ntry: os.fstat(fd)"
                        "\nexcept OSError: raise SystemExit(0)"
                        "\nraise SystemExit(1)"
                    ),
                    str(descriptor),
                ],
                check=False,
                capture_output=True,
            )
            self.assertEqual(child.returncode, 0, child.stderr)
            raise OSError("injected exec failure")

        with mock.patch.object(MODULE, "workspace_lock", side_effect=capture_lock), mock.patch.object(
            MODULE.os,
            "execv",
            side_effect=reject_exec,
        ), self.assertRaisesRegex(MODULE.EditorError, "could not hand off"):
            MODULE.exact_fallback_if_absent(self.paths, self.repo, arguments)

        with original_lock(self.paths, self.repo):
            pass

    def test_concurrent_starting_publication_blocks_host_fallback(self) -> None:
        """A lifecycle winning the lock after absence prevents the host exec handoff."""
        arguments = argparse.Namespace(
            wait_editor=False,
            cwd=str(self.repo),
            file=str(self.file),
            line=1,
            column=1,
            wait_timeout=1.0,
            fallback_exact=True,
        )
        lifecycle: contextlib.AbstractContextManager[int] | None = None

        def publish_starting(*_args: object) -> None:
            nonlocal lifecycle
            lifecycle = MODULE.workspace_lock(self.paths, self.repo)
            lifecycle.__enter__()
            record = MODULE.base_record(
                self.repo,
                self.config,
                MODULE.log_path(self.paths, self.repo),
                False,
                None,
                "%7",
                7007,
                "00000000-0000-4000-8000-000000000013",
            )
            MODULE.update_workspace_record(self.paths, self.repo, record)
            raise MODULE.NoActiveEditor("absence observed before starting publication")

        try:
            with mock.patch.object(MODULE, "repo_root", return_value=self.repo), mock.patch.object(
                MODULE,
                "open_location",
                side_effect=publish_starting,
            ), mock.patch.object(MODULE.os, "execv") as execute, self.assertRaisesRegex(
                MODULE.EditorError,
                "busy",
            ):
                MODULE.cmd_open_location(arguments)
            execute.assert_not_called()
            self.assertEqual(MODULE.load_record(self.paths, self.repo)["status"], "starting")
        finally:
            if lifecycle is not None:
                lifecycle.__exit__(None, None, None)

    def test_lifecycle_failure_after_start_never_falls_back(self) -> None:
        """The starting record precedes CLI resolution and becomes fail-closed error state."""
        arguments = argparse.Namespace(
            repo=str(self.repo),
            config=None,
            recreate=False,
            allow_network=False,
            tmux_pane="%7",
            claim_id="00000000-0000-4000-8000-000000000010",
            timeout=1.0,
        )
        with mock.patch.object(MODULE, "repo_root", return_value=self.repo), mock.patch.object(
            MODULE,
            "require_editor_pane",
            return_value=("%7", 7007),
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

    def test_lifecycle_reconciliation_attempts_every_cleanup_and_keeps_primary_first(self) -> None:
        """Record, auth, and log failures aggregate only after every cleanup attempt."""
        arguments = argparse.Namespace(
            repo=str(self.repo),
            config=None,
            recreate=False,
            allow_network=False,
            tmux_pane="%7",
            claim_id="00000000-0000-4000-8000-000000000014",
            timeout=1.0,
        )
        original_update = MODULE.update_workspace_record
        original_append = MODULE.append_log
        attempts: list[str] = []

        def fail_error_record(
            paths: MODULE.StateDirectories,
            root: pathlib.Path,
            record: dict[str, object],
            **changes: object,
        ) -> MODULE.FileIdentity:
            if changes.get("status") == "error":
                attempts.append("record")
                raise MODULE.EditorError("record cleanup failed")
            return original_update(paths, root, record, **changes)

        def fail_auth_cleanup(_spool: MODULE.SpoolDirectories) -> None:
            attempts.append("authentication")
            raise MODULE.EditorError("auth cleanup failed")

        def fail_error_log(path: pathlib.Path, message: str) -> None:
            if "lifecycle error:" in message:
                attempts.append("log")
                raise OSError("log cleanup failed")
            original_append(path, message)

        with mock.patch.object(MODULE, "repo_root", return_value=self.repo), mock.patch.object(
            MODULE,
            "require_editor_pane",
            return_value=("%7", 7007),
        ), mock.patch.object(
            MODULE,
            "cli_path",
            side_effect=MODULE.EditorError("primary lifecycle failure"),
        ), mock.patch.object(
            MODULE,
            "update_workspace_record",
            side_effect=fail_error_record,
        ), mock.patch.object(MODULE, "remove_auth", side_effect=fail_auth_cleanup), mock.patch.object(
            MODULE,
            "append_log",
            side_effect=fail_error_log,
        ), mock.patch.object(MODULE, "progress") as reported, self.assertRaisesRegex(
            MODULE.EditorError,
            "^primary lifecycle failure; lifecycle reconciliation failures:",
        ):
            MODULE.cmd_up(arguments)

        self.assertEqual(attempts, ["record", "authentication", "log"])
        self.assertEqual(reported.call_count, 3)
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "starting")
        self.assertIsNone(persisted["error"])
        self.assertTrue(MODULE.auth_path(self.spool).exists())

    def test_open_location_writes_authenticated_request_and_waits_for_ack(self) -> None:
        """Host-to-container routing uses one authenticated relative request."""
        self.record()
        captured: dict[str, object] = {}

        def acknowledge(
            spool: MODULE.SpoolDirectories,
            token: str,
            request: dict[str, object],
            _timeout: float,
        ) -> None:
            captured.update(request)
            request_path = spool.root / "inbox" / f"{request['request_id']}.json"
            persisted = MODULE.read_private_json(request_path, "request")
            self.assertEqual(persisted, request)
            self.assertTrue(MODULE.valid_message_auth(token, "open_location", request))

        with mock.patch.object(MODULE, "wait_ack", side_effect=acknowledge):
            MODULE.open_location(self.paths, self.repo, str(self.file), 4, 2, 1.0)
        self.assertNotIn("token", captured)
        self.assertNotEqual(captured["auth"], self.token)
        self.assertEqual(captured["path"], "file.txt")
        self.assertEqual(captured["action"], "open_location")
        with self.assertRaisesRegex(MODULE.EditorError, "contained"):
            MODULE.open_location(self.paths, self.repo, "/etc/passwd", 1, 1, 1.0)

    def test_wait_ack_rejects_mismatched_auth_and_timeout(self) -> None:
        """Spool acknowledgements authenticate and fail closed when absent."""
        spool = self.spool
        token = "t" * 43
        request = MODULE.signed_message(token, "open_location", {
            "version": MODULE.VERSION,
            "request_id": str(uuid.uuid4()),
            "action": "open_location",
            "path": "file.txt",
            "line": 1,
            "column": 1,
            "created_at": MODULE.utc_now(),
        })
        path = spool.root / "acks" / f"{request['request_id']}.json"
        MODULE.atomic_create_json_at(
            spool.acks_fd,
            path.name,
            MODULE.signed_message("wrong" * 10, "ack", {
                "version": MODULE.VERSION,
                "request_id": request["request_id"],
                "ok": True,
                "action": "open_location",
                "error": None,
            }),
        )
        with self.assertRaises(MODULE.EditorError):
            MODULE.wait_ack(spool, token, request, 0.1)
        with self.assertRaisesRegex(MODULE.EditorError, "timed out"):
            MODULE.wait_ack(spool, token, request, 0.01)

    def test_malformed_ack_snapshots_are_durably_retired(self) -> None:
        """Truncated and non-UTF-8 acknowledgements cannot poison later waits."""
        self.record()
        request = MODULE.signed_message(
            self.token,
            "open_location",
            {
                "version": MODULE.VERSION,
                "request_id": str(uuid.uuid4()),
                "action": "open_location",
                "path": "file.txt",
                "line": 1,
                "column": 1,
                "created_at": MODULE.utc_now(),
            },
        )
        name = f"{request['request_id']}.json"
        real_fsync = MODULE.os.fsync
        synced: list[int] = []

        def capture_fsync(descriptor: int) -> None:
            synced.append(descriptor)
            real_fsync(descriptor)

        for payload in (b'{"version":', b"\xff"):
            synced.clear()
            MODULE.atomic_create_bytes_at(self.spool.acks_fd, name, payload)
            with self.subTest(payload=payload), mock.patch.object(
                MODULE.os,
                "fsync",
                side_effect=capture_fsync,
            ), self.assertRaisesRegex(MODULE.EditorError, "not valid JSON"):
                MODULE.wait_ack(self.spool, self.token, request, 0.1)

            self.assertFalse((self.spool.root / "acks" / name).exists())
            self.assertIn(self.spool.acks_fd, synced)

    def test_corrupt_ack_replacement_is_preserved_with_primary_first(self) -> None:
        """ACK poison cleanup cannot delete a replacement or mask its decode error."""
        self.record()
        request = MODULE.signed_message(
            self.token,
            "open_location",
            {
                "version": MODULE.VERSION,
                "request_id": str(uuid.uuid4()),
                "action": "open_location",
                "path": "file.txt",
                "line": 1,
                "column": 1,
                "created_at": MODULE.utc_now(),
            },
        )
        name = f"{request['request_id']}.json"
        path = self.spool.root / "acks" / name
        displaced = path.with_suffix(".original")
        MODULE.atomic_create_bytes_at(self.spool.acks_fd, name, b'{"version":')
        original_decode = MODULE.decode_json_object

        def replace_then_decode(payload: bytes, label: str) -> dict[str, object]:
            path.rename(displaced)
            path.write_text('{"replacement":true}\n', encoding="utf-8")
            path.chmod(0o600)
            return original_decode(payload, label)

        with mock.patch.object(
            MODULE,
            "decode_json_object",
            side_effect=replace_then_decode,
        ), mock.patch.object(MODULE, "progress") as reported, self.assertRaisesRegex(
            MODULE.EditorError,
            "^spool acknowledgement is not valid JSON.*; acknowledgement retirement failed:",
        ) as caught:
            MODULE.wait_ack(self.spool, self.token, request, 0.1)

        self.assertEqual(path.read_text(encoding="utf-8"), '{"replacement":true}\n')
        self.assertTrue(displaced.exists())
        self.assertIsInstance(caught.exception.__cause__, MODULE.EditorError)
        self.assertIn("not valid JSON", str(caught.exception.__cause__))
        reported.assert_called_once()
        self.assertIn("changed during conditional retirement", reported.call_args.args[0])

    def test_ack_cleanup_failure_preserves_decode_primary_and_warning_failure(self) -> None:
        """A failed ACK retirement and stderr sink remain secondary to decode failure."""
        self.record()
        request = MODULE.signed_message(
            self.token,
            "open_location",
            {
                "version": MODULE.VERSION,
                "request_id": str(uuid.uuid4()),
                "action": "open_location",
                "path": "file.txt",
                "line": 1,
                "column": 1,
                "created_at": MODULE.utc_now(),
            },
        )
        name = f"{request['request_id']}.json"
        path = self.spool.root / "acks" / name
        MODULE.atomic_create_bytes_at(self.spool.acks_fd, name, b'{"version":')

        with mock.patch.object(
            MODULE,
            "unlink_regular_at",
            side_effect=MODULE.EditorError("ack cleanup failed"),
        ), mock.patch.object(
            MODULE,
            "progress",
            side_effect=OSError("stderr sink failed"),
        ) as reported, self.assertRaisesRegex(
            MODULE.EditorError,
            "^spool acknowledgement is not valid JSON.*; "
            "acknowledgement retirement failed: ack cleanup failed$",
        ) as caught:
            MODULE.wait_ack(self.spool, self.token, request, 0.1)

        self.assertTrue(path.exists())
        self.assertIsInstance(caught.exception.__cause__, MODULE.EditorError)
        self.assertIn("not valid JSON", str(caught.exception.__cause__))
        reported.assert_called_once()

    def test_outbox_authentication_and_replay_cleanup(self) -> None:
        """Container-to-host actions require a MAC and are consumed once."""
        record = self.record()
        spool = self.spool
        request_id = str(uuid.uuid4())
        request = MODULE.signed_message(self.token, "host_request", {
            "version": MODULE.VERSION,
            "request_id": request_id,
            "action": "lazygit",
            "created_at": MODULE.utc_now(),
        })
        path = spool.root / "outbox" / f"{request_id}.json"
        MODULE.atomic_create_json_at(spool.outbox_fd, path.name, request)
        with mock.patch.object(MODULE, "tmux_action") as action:
            self.assertEqual(MODULE.consume_outbox(self.paths, spool, record, self.token), (1, False))
            action.assert_called_once_with(record, "lazygit")
        self.assertFalse(path.exists())
        ack = MODULE.read_private_json(spool.root / "acks" / f"{request_id}.json", "ack")
        self.assertTrue(ack["ok"])
        self.assertTrue(MODULE.valid_message_auth(self.token, "ack", ack))
        self.assertNotIn("token", ack)
        self.assertEqual(MODULE.consume_outbox(self.paths, spool, record, self.token), (0, False))

    def test_request_retirement_is_durable_before_every_host_side_effect(self) -> None:
        """Outbox absence is synced before normal actions or host restoration begin."""
        record = self.record()
        real_fsync = MODULE.os.fsync
        events: list[str] = []

        def fail_outbox_sync(descriptor: int) -> None:
            if descriptor == self.spool.outbox_fd:
                events.append("outbox-fsync")
                raise OSError("injected outbox directory fsync failure")
            real_fsync(descriptor)

        first_id = str(uuid.uuid4())
        first_name = f"{first_id}.json"
        first = MODULE.signed_message(
            self.token,
            "host_request",
            {
                "version": MODULE.VERSION,
                "request_id": first_id,
                "action": "lazygit",
                "created_at": MODULE.utc_now(),
            },
        )
        MODULE.atomic_create_json_at(self.spool.outbox_fd, first_name, first)

        def normal_action(*_args: object) -> None:
            events.append("tmux-action")

        with mock.patch.object(MODULE.os, "fsync", side_effect=fail_outbox_sync), mock.patch.object(
            MODULE,
            "progress",
            side_effect=OSError("stderr sink failed"),
        ), mock.patch.object(MODULE, "tmux_action", side_effect=normal_action):
            self.assertEqual(
                MODULE.consume_outbox(self.paths, self.spool, record, self.token),
                (1, False),
            )

        self.assertEqual(events, ["outbox-fsync", "tmux-action"])
        self.assertFalse((self.spool.root / "outbox" / first_name).exists())

        second_id = str(uuid.uuid4())
        second_name = f"{second_id}.json"
        second = MODULE.signed_message(
            self.token,
            "host_request",
            {
                "version": MODULE.VERSION,
                "request_id": second_id,
                "action": "host_editor",
                "created_at": MODULE.utc_now(),
            },
        )
        MODULE.atomic_create_json_at(self.spool.outbox_fd, second_name, second)
        events.clear()

        def capture_fsync(descriptor: int) -> None:
            if descriptor == self.spool.outbox_fd:
                events.append("outbox-fsync")
            real_fsync(descriptor)

        def restore_host(*_args: object) -> MODULE.PaneObservation:
            events.append("host-restore")
            return MODULE.PaneObservation(False, 8008, None, "")

        with mock.patch.object(MODULE.os, "fsync", side_effect=capture_fsync), mock.patch.object(
            MODULE,
            "respawn_host_editor",
            side_effect=restore_host,
        ):
            self.assertEqual(
                MODULE.consume_outbox(self.paths, self.spool, record, self.token),
                (1, True),
            )

        self.assertEqual(events[:2], ["outbox-fsync", "host-restore"])
        self.assertFalse((self.spool.root / "outbox" / second_name).exists())

    def test_malformed_outbox_json_snapshots_are_retired_with_primary_error(self) -> None:
        """Truncated, non-object, and non-UTF-8 snapshots are consumed exactly once."""
        record = self.record()
        real_fsync = MODULE.os.fsync
        synced: list[int] = []
        cases = (
            (b'{"version":', "not valid JSON"),
            (b"[]", "must contain one JSON object"),
            (b"\xff", "not valid JSON"),
        )

        def capture_fsync(descriptor: int) -> None:
            synced.append(descriptor)
            real_fsync(descriptor)

        for payload, expected in cases:
            synced.clear()
            name = f"{uuid.uuid4()}.json"
            path = self.spool.root / "outbox" / name
            MODULE.atomic_create_bytes_at(self.spool.outbox_fd, name, payload)
            with self.subTest(payload=payload), mock.patch.object(
                MODULE,
                "tmux_action",
            ) as action, mock.patch.object(
                MODULE.os,
                "fsync",
                side_effect=capture_fsync,
            ), self.assertRaisesRegex(MODULE.EditorError, expected):
                MODULE.consume_outbox(self.paths, self.spool, record, self.token)
            action.assert_not_called()
            self.assertFalse(path.exists())
            self.assertIn(self.spool.outbox_fd, synced)
            persisted = MODULE.load_record(self.paths, self.repo)
            self.assertEqual(persisted["status"], "error")
            self.assertIn(expected, persisted["error"])

    def test_unknown_outbox_fields_are_retired_before_schema_failure(self) -> None:
        """A decoded object with unknown fields cannot poison later outbox scans."""
        record = self.record()
        request_id = str(uuid.uuid4())
        name = f"{request_id}.json"
        path = self.spool.root / "outbox" / name
        request = MODULE.signed_message(
            self.token,
            "host_request",
            {
                "version": MODULE.VERSION,
                "request_id": request_id,
                "action": "lazygit",
                "created_at": MODULE.utc_now(),
            },
        )
        request["unknown"] = True
        MODULE.atomic_create_json_at(self.spool.outbox_fd, name, request)

        with mock.patch.object(MODULE, "tmux_action") as action, self.assertRaisesRegex(
            MODULE.EditorError,
            "host spool request schema is invalid",
        ):
            MODULE.consume_outbox(self.paths, self.spool, record, self.token)

        action.assert_not_called()
        self.assertFalse(path.exists())
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "error")
        self.assertEqual(persisted["error"], "host spool request schema is invalid")

    def test_corrupt_outbox_replacement_is_preserved_without_masking_decode_error(self) -> None:
        """Conditional poison cleanup retains a replacement and the JSON primary."""
        record = self.record()
        name = f"{uuid.uuid4()}.json"
        path = self.spool.root / "outbox" / name
        displaced = path.with_suffix(".original")
        MODULE.atomic_create_bytes_at(self.spool.outbox_fd, name, b'{"version":')
        original_decode = MODULE.decode_json_object

        def replace_then_decode(payload: bytes, label: str) -> dict[str, object]:
            path.rename(displaced)
            path.write_text('{"replacement":true}\n', encoding="utf-8")
            path.chmod(0o600)
            return original_decode(payload, label)

        with mock.patch.object(
            MODULE,
            "decode_json_object",
            side_effect=replace_then_decode,
        ), mock.patch.object(MODULE, "progress") as reported, mock.patch.object(
            MODULE,
            "tmux_action",
        ) as action, self.assertRaisesRegex(MODULE.EditorError, "not valid JSON"):
            MODULE.consume_outbox(self.paths, self.spool, record, self.token)

        action.assert_not_called()
        self.assertEqual(path.read_text(encoding="utf-8"), '{"replacement":true}\n')
        self.assertTrue(displaced.exists())
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "error")
        self.assertIn("not valid JSON", persisted["error"])
        reported.assert_called_once()
        self.assertIn("changed during conditional retirement", reported.call_args.args[0])

    def test_consumed_request_replacement_is_preserved(self) -> None:
        """A replacement at the retirement boundary blocks action and remains preserved."""
        record = self.record()
        request_id = str(uuid.uuid4())
        request = MODULE.signed_message(
            self.token,
            "host_request",
            {
                "version": MODULE.VERSION,
                "request_id": request_id,
                "action": "lazygit",
                "created_at": MODULE.utc_now(),
            },
        )
        name = f"{request_id}.json"
        path = self.spool.root / "outbox" / name
        displaced = path.with_suffix(".original")
        MODULE.atomic_create_json_at(self.spool.outbox_fd, name, request)

        original_validate = MODULE.validate_host_request

        def replace_request(*args: object) -> dict[str, object]:
            validated = original_validate(*args)
            path.rename(displaced)
            path.write_text('{"replacement":true}\n', encoding="utf-8")
            path.chmod(0o600)
            return validated

        with mock.patch.object(
            MODULE,
            "validate_host_request",
            side_effect=replace_request,
        ), mock.patch.object(MODULE, "tmux_action") as action, self.assertRaisesRegex(
            MODULE.EditorError,
            "changed during conditional retirement",
        ):
            MODULE.consume_outbox(self.paths, self.spool, record, self.token)

        action.assert_not_called()
        self.assertEqual(path.read_text(encoding="utf-8"), '{"replacement":true}\n')
        self.assertTrue(displaced.exists())
        ack = MODULE.read_private_json(
            self.spool.root / "acks" / f"{request_id}.json",
            "ack",
        )
        self.assertFalse(ack["ok"])
        self.assertIn("changed during conditional retirement", ack["error"])
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "error")
        self.assertEqual(persisted["error"], ack["error"])
        self.assertTrue(MODULE.auth_path(self.spool).exists())

    def test_disappeared_request_never_executes_an_authenticated_action(self) -> None:
        """A false retirement result is reconciled before any host side effect."""
        record = self.record()
        request_id = str(uuid.uuid4())
        name = f"{request_id}.json"
        request = MODULE.signed_message(
            self.token,
            "host_request",
            {
                "version": MODULE.VERSION,
                "request_id": request_id,
                "action": "lazygit",
                "created_at": MODULE.utc_now(),
            },
        )
        MODULE.atomic_create_json_at(self.spool.outbox_fd, name, request)
        original_unlink = MODULE.unlink_regular_at

        def disappear(
            directory_fd: int,
            entry: str,
            **kwargs: object,
        ) -> bool:
            if directory_fd == self.spool.outbox_fd and entry == name:
                return False
            return original_unlink(directory_fd, entry, **kwargs)

        with mock.patch.object(MODULE, "unlink_regular_at", side_effect=disappear), mock.patch.object(
            MODULE,
            "tmux_action",
        ) as action, self.assertRaisesRegex(
            MODULE.EditorError,
            "host spool request disappeared before execution",
        ):
            MODULE.consume_outbox(self.paths, self.spool, record, self.token)

        action.assert_not_called()
        ack = MODULE.read_private_json(
            self.spool.root / "acks" / f"{request_id}.json",
            "ack",
        )
        self.assertFalse(ack["ok"])
        self.assertEqual(ack["error"], "host spool request disappeared before execution")
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "error")
        self.assertEqual(persisted["error"], ack["error"])
        self.assertTrue(MODULE.auth_path(self.spool).exists())

    def test_invalid_request_cleanup_failure_preserves_validation_primary(self) -> None:
        """A poison-message cleanup error never masks its authentication failure."""
        record = self.record()
        request_id = str(uuid.uuid4())
        request = MODULE.signed_message(
            self.token,
            "host_request",
            {
                "version": MODULE.VERSION,
                "request_id": request_id,
                "action": "lazygit",
                "created_at": MODULE.utc_now(),
            },
        )
        wrong_name = f"{uuid.uuid4()}.json"
        MODULE.atomic_create_json_at(self.spool.outbox_fd, wrong_name, request)

        with mock.patch.object(
            MODULE,
            "unlink_regular_at",
            side_effect=MODULE.EditorError("poison cleanup failed"),
        ), mock.patch.object(MODULE, "progress") as reported, self.assertRaisesRegex(
            MODULE.EditorError,
            "filename does not match its id",
        ) as caught:
            MODULE.consume_outbox(self.paths, self.spool, record, self.token)

        self.assertTrue((self.spool.root / "outbox" / wrong_name).exists())
        self.assertIn("invalid request retirement failed: poison cleanup failed", str(caught.exception))
        self.assertIsInstance(caught.exception.__cause__, MODULE.EditorError)
        self.assertEqual(
            str(caught.exception.__cause__),
            "host spool request filename does not match its id",
        )
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "error")
        self.assertEqual(persisted["error"], str(caught.exception))
        reported.assert_called_once()
        self.assertIn("poison cleanup failed", reported.call_args.args[0])

    def test_ack_publication_syncs_the_pinned_ack_directory(self) -> None:
        """A positive acknowledgement is not reported before its directory is synced."""
        self.record()
        request = MODULE.signed_message(self.token, "host_request", {
            "version": MODULE.VERSION,
            "request_id": str(uuid.uuid4()),
            "action": "lazygit",
            "created_at": MODULE.utc_now(),
        })
        real_fsync = MODULE.os.fsync
        synced: list[int] = []

        def capture_fsync(descriptor: int) -> None:
            synced.append(descriptor)
            real_fsync(descriptor)

        with mock.patch.object(MODULE.os, "fsync", side_effect=capture_fsync):
            MODULE.write_ack(self.spool, self.token, request, True, None)

        self.assertIn(self.spool.acks_fd, synced)

    def test_request_reconciliation_attempts_every_step_with_primary_first(self) -> None:
        """ACK and record cleanup failures aggregate after every independent attempt."""
        record = self.record()
        request = MODULE.signed_message(
            self.token,
            "host_request",
            {
                "version": MODULE.VERSION,
                "request_id": str(uuid.uuid4()),
                "action": "host_editor",
                "created_at": MODULE.utc_now(),
            },
        )
        MODULE.write_ack(self.spool, self.token, request, True, None)
        attempts: list[str] = []

        def fail_positive_ack(*_args: object, **_kwargs: object) -> bool:
            attempts.append("positive")
            raise MODULE.EditorError("positive ACK cleanup failed")

        def fail_negative_ack(*_args: object, **_kwargs: object) -> None:
            attempts.append("negative")
            raise MODULE.EditorError("negative ACK write failed")

        def fail_record(*_args: object, **_kwargs: object) -> MODULE.FileIdentity:
            attempts.append("record")
            raise MODULE.EditorError("record update failed")

        primary = MODULE.EditorError("primary host handoff failure")
        with mock.patch.object(MODULE, "unlink_regular_at", side_effect=fail_positive_ack), mock.patch.object(
            MODULE,
            "write_ack",
            side_effect=fail_negative_ack,
        ), mock.patch.object(
            MODULE,
            "update_workspace_record",
            side_effect=fail_record,
        ), self.assertRaisesRegex(
            MODULE.EditorError,
            "^primary host handoff failure; request reconciliation failures:",
        ):
            MODULE.record_request_error(
                self.paths,
                self.spool,
                record,
                self.token,
                request,
                primary,
                True,
            )

        self.assertEqual(attempts, ["positive", "negative", "record"])
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "running")
        self.assertTrue(MODULE.auth_path(self.spool).exists())
        positive = MODULE.read_private_json(
            self.spool.root / "acks" / f"{request['request_id']}.json",
            "positive acknowledgement",
        )
        self.assertTrue(positive["ok"])

    def test_host_action_failure_is_acknowledged_without_execution_retry(self) -> None:
        """Failed host actions produce one negative ACK and no replay."""
        record = self.record()
        spool = self.spool
        request_id = str(uuid.uuid4())
        request = MODULE.signed_message(self.token, "host_request", {
            "version": MODULE.VERSION,
            "request_id": request_id,
            "action": "lazygit",
            "created_at": MODULE.utc_now(),
        })
        name = f"{request_id}.json"
        path = spool.root / "outbox" / name
        MODULE.atomic_create_json_at(spool.outbox_fd, name, request)
        original_unlink = MODULE.unlink_regular_at
        action_started = False

        def reject_action(*_args: object) -> None:
            nonlocal action_started
            action_started = True
            raise MODULE.EditorError("rejected")

        def reject_late_retirement(
            directory_fd: int,
            entry: str,
            **kwargs: object,
        ) -> bool:
            if directory_fd == spool.outbox_fd and entry == name and action_started:
                raise MODULE.EditorError("late retirement masked the action failure")
            return original_unlink(directory_fd, entry, **kwargs)

        with mock.patch.object(MODULE, "unlink_regular_at", side_effect=reject_late_retirement), mock.patch.object(
            MODULE,
            "tmux_action",
            side_effect=reject_action,
        ):
            MODULE.consume_outbox(self.paths, spool, record, self.token)
        ack = MODULE.read_private_json(spool.root / "acks" / f"{request_id}.json", "ack")
        self.assertFalse(ack["ok"])
        self.assertEqual(ack["error"], "rejected")
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "error")
        self.assertEqual(persisted["error"], "rejected")
        self.assertFalse(path.exists())
        self.assertTrue(MODULE.auth_path(spool).exists())

    def test_host_handoff_verifies_respawn_then_retires_record_and_auth(self) -> None:
        """A successful host handoff removes the only fallback-blocking record."""
        record = self.record()
        spool = self.spool
        request_id = str(uuid.uuid4())
        request = MODULE.signed_message(self.token, "host_request", {
            "version": MODULE.VERSION,
            "request_id": request_id,
            "action": "host_editor",
            "created_at": MODULE.utc_now(),
        })
        MODULE.atomic_create_json_at(spool.outbox_fd, f"{request_id}.json", request)
        restored = MODULE.PaneObservation(False, 8008, None, "")
        events: list[str] = []
        original_write_ack = MODULE.write_ack
        original_remove_record = MODULE.remove_workspace_record
        original_unlink = MODULE.unlink_regular_at
        reconciled = False
        outbox_retirements = 0

        def retire_request(
            directory_fd: int,
            entry: str,
            **kwargs: object,
        ) -> bool:
            nonlocal outbox_retirements
            if directory_fd == spool.outbox_fd and entry == f"{request_id}.json":
                if reconciled:
                    raise MODULE.EditorError("late retirement escaped after host handoff")
                events.append("request")
                outbox_retirements += 1
            return original_unlink(directory_fd, entry, **kwargs)

        def write_ack(*args: object, **kwargs: object) -> None:
            events.append("ack")
            original_write_ack(*args, **kwargs)

        def remove_record(*args: object, **kwargs: object) -> None:
            nonlocal reconciled
            events.append("record")
            original_remove_record(*args, **kwargs)
            reconciled = True

        with mock.patch.object(MODULE, "unlink_regular_at", side_effect=retire_request), mock.patch.object(
            MODULE,
            "respawn_host_editor",
            return_value=restored,
        ) as respawn, mock.patch.object(
            MODULE,
            "write_ack",
            side_effect=write_ack,
        ), mock.patch.object(MODULE, "remove_workspace_record", side_effect=remove_record):
            self.assertEqual(MODULE.consume_outbox(self.paths, spool, record, self.token), (1, True))
        respawn.assert_called_once_with(record)
        self.assertEqual(events, ["request", "ack", "record"])
        self.assertEqual(outbox_retirements, 1)
        self.assertFalse((spool.root / "outbox" / f"{request_id}.json").exists())
        self.assertFalse(MODULE.record_path(self.paths, self.repo).exists())
        self.assertFalse(MODULE.auth_path(spool).exists())
        ack = MODULE.read_private_json(spool.root / "acks" / f"{request_id}.json", "ack")
        self.assertTrue(ack["ok"])

    def test_committed_handoff_ack_survives_directory_and_warning_sink_failures(self) -> None:
        """A visible ACK remains successful when durability and stderr warnings fail."""
        record = self.record()
        request_id = str(uuid.uuid4())
        name = f"{request_id}.json"
        request = MODULE.signed_message(
            self.token,
            "host_request",
            {
                "version": MODULE.VERSION,
                "request_id": request_id,
                "action": "host_editor",
                "created_at": MODULE.utc_now(),
            },
        )
        MODULE.atomic_create_json_at(self.spool.outbox_fd, name, request)
        restored = MODULE.PaneObservation(False, 8008, None, "")
        real_fsync = MODULE.os.fsync

        def fail_ack_directory_sync(descriptor: int) -> None:
            if descriptor == self.spool.acks_fd:
                raise OSError("injected acknowledgement directory fsync failure")
            real_fsync(descriptor)

        with mock.patch.object(MODULE.os, "fsync", side_effect=fail_ack_directory_sync), mock.patch.object(
            MODULE,
            "respawn_host_editor",
            return_value=restored,
        ), mock.patch.object(
            MODULE,
            "progress",
            side_effect=OSError("stderr sink failed"),
        ) as reported:
            self.assertEqual(
                MODULE.consume_outbox(self.paths, self.spool, record, self.token),
                (1, True),
            )

        reported.assert_called_once()
        self.assertIn("publication was already committed", reported.call_args.args[0])
        self.assertFalse((self.spool.root / "outbox" / name).exists())
        self.assertFalse(MODULE.record_path(self.paths, self.repo).exists())
        self.assertFalse(MODULE.auth_path(self.spool).exists())
        ack = MODULE.read_private_json(
            self.spool.root / "acks" / name,
            "committed acknowledgement",
        )
        self.assertTrue(ack["ok"])
        self.assertTrue(MODULE.valid_message_auth(self.token, "ack", ack))

    def test_host_handoff_failure_keeps_error_record_and_negative_ack(self) -> None:
        """A pre-transition host respawn failure remains fail closed without success."""
        record = self.record()
        spool = self.spool
        request_id = str(uuid.uuid4())
        request = MODULE.signed_message(self.token, "host_request", {
            "version": MODULE.VERSION,
            "request_id": request_id,
            "action": "host_editor",
            "created_at": MODULE.utc_now(),
        })
        MODULE.atomic_create_json_at(spool.outbox_fd, f"{request_id}.json", request)
        with mock.patch.object(
            MODULE,
            "respawn_host_editor",
            side_effect=MODULE.EditorError("tmux respawn rejected"),
        ):
            self.assertEqual(MODULE.consume_outbox(self.paths, spool, record, self.token), (1, False))
        self.assertEqual(MODULE.load_record(self.paths, self.repo)["status"], "error")
        ack = MODULE.read_private_json(spool.root / "acks" / f"{request_id}.json", "ack")
        self.assertFalse(ack["ok"])
        self.assertEqual(ack["error"], "tmux respawn rejected")
        self.assertTrue(MODULE.valid_message_auth(self.token, "ack", ack))

    def test_host_handoff_transition_failure_stops_coordinator(self) -> None:
        """A failure after pane restoration starts never returns to container monitoring."""
        record = self.record()
        spool = self.spool
        request_id = str(uuid.uuid4())
        request = MODULE.signed_message(self.token, "host_request", {
            "version": MODULE.VERSION,
            "request_id": request_id,
            "action": "host_editor",
            "created_at": MODULE.utc_now(),
        })
        MODULE.atomic_create_json_at(spool.outbox_fd, f"{request_id}.json", request)
        with mock.patch.object(
            MODULE,
            "respawn_host_editor",
            side_effect=MODULE.HostPaneTransitioned("tmux post-respawn check failed"),
        ), self.assertRaisesRegex(MODULE.EditorError, "coordinator stopped"):
            MODULE.consume_outbox(self.paths, spool, record, self.token)

        self.assertEqual(MODULE.load_record(self.paths, self.repo)["status"], "error")

    def test_host_handoff_ack_failure_preserves_fail_closed_record(self) -> None:
        """A positive ACK write failure never retires the lifecycle record."""
        record = self.record()
        spool = self.spool
        request_id = str(uuid.uuid4())
        request = MODULE.signed_message(
            self.token,
            "host_request",
            {
                "version": MODULE.VERSION,
                "request_id": request_id,
                "action": "host_editor",
                "created_at": MODULE.utc_now(),
            },
        )
        MODULE.atomic_create_json_at(spool.outbox_fd, f"{request_id}.json", request)
        original_write_ack = MODULE.write_ack
        attempts = 0

        def flaky_ack(*args: object, **kwargs: object) -> None:
            nonlocal attempts
            attempts += 1
            if attempts == 1:
                raise MODULE.EditorError("ack persistence failed")
            original_write_ack(*args, **kwargs)

        restored = MODULE.PaneObservation(False, 8008, None, "")
        with mock.patch.object(MODULE, "respawn_host_editor", return_value=restored), mock.patch.object(
            MODULE,
            "write_ack",
            side_effect=flaky_ack,
        ), self.assertRaisesRegex(MODULE.EditorError, "coordinator stopped"):
            MODULE.consume_outbox(self.paths, spool, record, self.token)
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "error")
        self.assertTrue(MODULE.record_path(self.paths, self.repo).exists())
        ack = MODULE.read_private_json(spool.root / "acks" / f"{request_id}.json", "ack")
        self.assertFalse(ack["ok"])
        self.assertEqual(ack["error"], "ack persistence failed")

    def test_host_handoff_state_failure_stops_after_restoring_host(self) -> None:
        """A post-respawn state failure escapes monitoring and persists an error record."""
        record = self.record()
        spool = self.spool
        request_id = str(uuid.uuid4())
        request = MODULE.signed_message(self.token, "host_request", {
            "version": MODULE.VERSION,
            "request_id": request_id,
            "action": "host_editor",
            "created_at": MODULE.utc_now(),
        })
        MODULE.atomic_create_json_at(spool.outbox_fd, f"{request_id}.json", request)
        original_update = MODULE.update_workspace_record

        def flaky_update(
            paths: MODULE.StateDirectories,
            root: pathlib.Path,
            current: dict[str, object],
            **changes: object,
        ) -> MODULE.FileIdentity:
            if changes.get("status") == "stopped":
                raise MODULE.EditorError("state persistence failed")
            return original_update(paths, root, current, **changes)

        restored = MODULE.PaneObservation(False, 8008, None, "")
        with mock.patch.object(MODULE, "respawn_host_editor", return_value=restored), mock.patch.object(
            MODULE,
            "update_workspace_record",
            side_effect=flaky_update,
        ), self.assertRaisesRegex(MODULE.EditorError, "coordinator stopped"):
            MODULE.consume_outbox(self.paths, spool, record, self.token)

        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "error")
        self.assertEqual(persisted["error"], "state persistence failed")

    def test_monitor_does_not_observe_host_pane_after_handoff_failure(self) -> None:
        """A failed post-respawn handoff terminates monitoring before another pane poll."""
        record = self.record()
        with mock.patch.object(
            MODULE,
            "consume_outbox",
            side_effect=MODULE.EditorError("host editor was restored; coordinator stopped"),
        ), mock.patch.object(MODULE, "observe_pane") as observe, self.assertRaisesRegex(
            MODULE.EditorError,
            "coordinator stopped",
        ):
            MODULE.monitor_editor(self.paths, self.spool, record, self.token)

        observe.assert_not_called()

    def test_explicit_host_command_recovers_dead_pane_and_retires_record(self) -> None:
        """The out-of-band host command can recover a dead container pane."""
        self.record("dead")
        arguments = argparse.Namespace(repo=str(self.repo))
        restored = MODULE.PaneObservation(False, 8008, None, "")
        with mock.patch.object(MODULE, "repo_root", return_value=self.repo), mock.patch.object(
            MODULE,
            "restore_or_verify_host_pane",
            return_value=restored,
        ) as restore:
            MODULE.cmd_host(arguments)
        restore.assert_called_once_with(mock.ANY)
        self.assertFalse(MODULE.record_path(self.paths, self.repo).exists())
        self.assertFalse(MODULE.auth_path(MODULE.spool_path(self.paths, self.repo)).exists())

    def test_explicit_host_command_rejects_a_reused_pane_pid(self) -> None:
        """A stale lifecycle record never authorizes respawning another pane process."""
        self.record("dead")
        arguments = argparse.Namespace(repo=str(self.repo))
        changed = MODULE.PaneObservation(True, 9999, 0, MODULE.pane_marker(self.repo))
        with mock.patch.object(MODULE, "repo_root", return_value=self.repo), mock.patch.object(
            MODULE,
            "observe_pane",
            return_value=changed,
        ), mock.patch.object(MODULE, "respawn_host_editor") as respawn, self.assertRaisesRegex(
            MODULE.EditorError,
            "PID no longer matches",
        ):
            MODULE.cmd_host(arguments)

        respawn.assert_not_called()
        self.assertEqual(MODULE.load_record(self.paths, self.repo)["status"], "error")

    def test_monitor_reconciles_once_more_on_quick_pane_exit(self) -> None:
        """A quick pane exit still performs final authenticated reconciliation."""
        record = self.record()
        record["pane_pid"] = 123
        spool = self.spool
        with mock.patch.object(
            MODULE,
            "consume_outbox",
            return_value=(0, False),
        ) as consume, mock.patch.object(
            MODULE,
            "observe_pane",
            return_value=MODULE.PaneObservation(True, 123, 9, MODULE.pane_marker(self.repo)),
        ):
            self.assertEqual(MODULE.monitor_editor(self.paths, spool, record, self.token), (9, False))
        self.assertEqual(consume.call_count, 2)

    def test_quick_exit_final_reconciliation_preserves_verified_handoff(self) -> None:
        """A handoff consumed after pane death does not recreate retired state."""
        record = self.record()
        record["pane_pid"] = 123
        spool = self.spool
        with mock.patch.object(
            MODULE,
            "consume_outbox",
            side_effect=((0, False), (1, True)),
        ), mock.patch.object(
            MODULE,
            "observe_pane",
            return_value=MODULE.PaneObservation(True, 123, 0, MODULE.pane_marker(self.repo)),
        ):
            self.assertEqual(MODULE.monitor_editor(self.paths, spool, record, self.token), (0, True))

    def test_monitor_cancellation_stays_fail_closed(self) -> None:
        """Explicit coordinator cancellation reports a lifecycle error."""
        record = self.record()
        record["pane_pid"] = 123
        spool = self.spool
        with mock.patch.object(
            MODULE,
            "consume_outbox",
            return_value=(0, False),
        ), mock.patch.object(
            MODULE,
            "observe_pane",
            return_value=MODULE.PaneObservation(False, 123, None, MODULE.pane_marker(self.repo)),
        ), mock.patch.object(
            MODULE.time,
            "sleep",
            side_effect=KeyboardInterrupt,
        ), self.assertRaisesRegex(MODULE.EditorError, "cancelled"):
            MODULE.monitor_editor(self.paths, spool, record, self.token)

    def test_auth_secret_exists_only_in_private_auth_file(self) -> None:
        """The raw spool secret never enters records, argv, environment, or logs."""
        record = self.record()
        spool = self.spool
        self.assertEqual(MODULE.read_auth(spool), self.token)
        self.assertNotIn("token", record)
        projection = "\n".join(MODULE.remote_environment(record, "/tmp/private-spool"))
        self.assertNotIn(self.token, projection)
        command = MODULE.editor_argv("/managed/devcontainer", self.repo, self.config, record, "/tmp/private-spool")
        self.assertNotIn(self.token, "\n".join(command))
        MODULE.append_log(MODULE.log_path(self.paths, self.repo), "lifecycle running")
        self.assertNotIn(self.token, MODULE.log_path(self.paths, self.repo).read_text(encoding="utf-8"))

    def test_auth_symlink_and_message_clobber_are_rejected(self) -> None:
        """Authentication follows no symlink and request publication is no-clobber."""
        spool = self.spool
        auth = MODULE.auth_path(spool)
        target = self.root / "outside-auth.json"
        target.write_text('{"unchanged":true}\n', encoding="utf-8")
        auth.symlink_to(target)
        with self.assertRaisesRegex(MODULE.EditorError, "unsafe"):
            MODULE.read_auth(spool)
        with self.assertRaisesRegex(MODULE.EditorError, "already exists"):
            MODULE.create_auth(spool, "s" * 32)
        self.assertEqual(target.read_text(encoding="utf-8"), '{"unchanged":true}\n')
        request = spool.root / "inbox" / f"{uuid.uuid4()}.json"
        MODULE.atomic_create_json_at(spool.inbox_fd, request.name, {"first": True})
        with self.assertRaisesRegex(MODULE.EditorError, "already exists"):
            MODULE.atomic_create_json_at(spool.inbox_fd, request.name, {"second": True})
        self.assertEqual(MODULE.read_private_json(request, "request"), {"first": True})

    def test_atomic_message_is_immediately_readable_as_one_link(self) -> None:
        """The exclusive rename exposes only a complete single-link message."""
        spool = self.spool
        name = f"{uuid.uuid4()}.json"
        request = spool.root / "inbox" / name
        real_rename = MODULE.exclusive_rename_at
        published = False
        observed: tuple[dict[str, object], int] | None = None

        def publish(directory_fd: int, source: str, destination: str) -> bool:
            nonlocal observed, published
            published = real_rename(directory_fd, source, destination)
            if published:
                payload, identity = MODULE.read_private_snapshot_at(
                    directory_fd,
                    destination,
                    "immediate message consumer",
                )
                observed = (MODULE.decode_json_object(payload, "immediate message consumer"), identity.links)
            return published

        with mock.patch.object(MODULE, "exclusive_rename_at", side_effect=publish):
            MODULE.atomic_create_json_at(spool.inbox_fd, name, {"complete": True})

        self.assertTrue(published)
        self.assertEqual(observed, ({"complete": True}, 1))
        self.assertEqual(MODULE.read_private_json(request, "request"), {"complete": True})
        self.assertEqual(stat.S_IMODE(request.stat().st_mode), 0o600)

    def test_atomic_message_race_preserves_rival_and_cleans_staging(self) -> None:
        """A rival winning the destination race is never clobbered by publication."""
        name = f"{uuid.uuid4()}.json"
        path = self.spool.root / "inbox" / name
        real_rename = MODULE.exclusive_rename_at

        def rival_wins(directory_fd: int, source: str, destination: str) -> bool:
            MODULE.direct_create_bytes_at(directory_fd, destination, b'{"rival":true}\n')
            return real_rename(directory_fd, source, destination)

        with mock.patch.object(
            MODULE,
            "exclusive_rename_at",
            side_effect=rival_wins,
        ), self.assertRaisesRegex(MODULE.EditorError, "private message already exists"):
            MODULE.atomic_create_json_at(self.spool.inbox_fd, name, {"ours": True})

        self.assertEqual(MODULE.read_private_json(path, "rival message"), {"rival": True})
        self.assertEqual(
            [
                entry.name
                for entry in (self.spool.root / "inbox").iterdir()
                if entry.name.startswith(f".{name}.")
            ],
            [],
        )

    def test_rename_commit_survives_fsync_and_warning_sink_failure(self) -> None:
        """Post-commit failures cannot roll back or misreport a visible ACK."""
        self.record()
        request = MODULE.signed_message(
            self.token,
            "host_request",
            {
                "version": MODULE.VERSION,
                "request_id": str(uuid.uuid4()),
                "action": "lazygit",
                "created_at": MODULE.utc_now(),
            },
        )
        name = f"{request['request_id']}.json"

        with mock.patch.object(
            MODULE,
            "fsync_directory",
            side_effect=MODULE.EditorError("injected acknowledgement directory fsync failure"),
        ), mock.patch.object(
            MODULE,
            "progress",
            side_effect=OSError("stderr sink failed"),
        ) as reported:
            MODULE.write_ack(self.spool, self.token, request, True, None)

        value, identity = MODULE.read_private_json_snapshot_at(
            self.spool.acks_fd,
            name,
            "committed acknowledgement",
        )
        reported.assert_called_once()
        self.assertIn("publication was already committed", reported.call_args.args[0])
        self.assertTrue(value["ok"])
        self.assertEqual(identity.links, 1)

    def test_atomic_state_has_no_fallible_step_after_replacement(self) -> None:
        """A replaced lifecycle record is already durable and owner-only."""
        record = MODULE.record_path(self.paths, self.repo)
        MODULE.atomic_json(record, {"generation": 1})

        with mock.patch.object(
            MODULE.pathlib.Path,
            "chmod",
            side_effect=AssertionError("post-replacement chmod"),
        ):
            MODULE.atomic_json(record, {"generation": 2})

        self.assertEqual(MODULE.read_private_json(record, "record"), {"generation": 2})
        self.assertEqual(stat.S_IMODE(record.stat().st_mode), 0o600)

    def test_request_and_status_filename_binding_fail_closed(self) -> None:
        """Authenticated payloads remain bound to UUID and workspace filenames."""
        record = self.record()
        spool = self.spool
        request = MODULE.signed_message(self.token, "host_request", {
            "version": MODULE.VERSION,
            "request_id": str(uuid.uuid4()),
            "action": "lazygit",
            "created_at": MODULE.utc_now(),
        })
        wrong = spool.root / "outbox" / f"{uuid.uuid4()}.json"
        MODULE.atomic_create_json_at(spool.outbox_fd, wrong.name, request)
        with self.assertRaisesRegex(MODULE.EditorError, "filename does not match"):
            MODULE.consume_outbox(self.paths, spool, record, self.token)
        self.assertEqual(MODULE.load_record(self.paths, self.repo)["status"], "error")

        correct = MODULE.record_path(self.paths, self.repo)
        mismatched = correct.with_name("0" * 64 + ".json")
        correct.rename(mismatched)
        arguments = argparse.Namespace(all=True, repo=None, json=True)
        with self.assertRaisesRegex(MODULE.EditorError, "filename does not match"):
            MODULE.cmd_status(arguments)

    def test_workspace_record_projects_oversized_nul_error_before_commit(self) -> None:
        """Every committed transition remains directly loadable under the record schema."""
        record = self.record()
        diagnostic = "bad\0" + "x" * 4097 + "full-tail"

        MODULE.update_workspace_record(
            self.paths,
            self.repo,
            record,
            status="error",
            error=diagnostic,
        )

        persisted = MODULE.load_record(self.paths, self.repo)
        projected = persisted["error"]
        self.assertIsInstance(projected, str)
        assert isinstance(projected, str)
        self.assertLessEqual(len(projected), MODULE.MAX_RECORD_ERROR_CHARS)
        self.assertNotIn("\0", projected)
        self.assertTrue(projected.startswith("bad\\0"))
        self.assertTrue(projected.endswith(MODULE.RECORD_ERROR_SUFFIX))
        detail = MODULE.log_path(self.paths, self.repo).read_text(encoding="utf-8")
        self.assertIn("bad\\0", detail)
        self.assertIn("full-tail", detail)

    def test_workspace_record_mutates_memory_only_after_durable_persist(self) -> None:
        """A failed anchored write leaves the coordinator's in-memory record unchanged."""
        record = self.record()
        original = dict(record)

        with mock.patch.object(
            MODULE,
            "atomic_replace_json_at",
            side_effect=MODULE.EditorError("disk full"),
        ), self.assertRaisesRegex(MODULE.EditorError, "disk full"):
            MODULE.update_workspace_record(
                self.paths,
                self.repo,
                record,
                status="error",
                error="write failed",
            )

        self.assertEqual(record, original)

    def test_noncanonical_record_root_is_rejected_before_replace(self) -> None:
        """A traversal-bearing transition never reaches the atomic replace boundary."""
        record = self.record()
        original = MODULE.load_record(self.paths, self.repo)
        escaped = "/workspaces/repo/../escape"

        with mock.patch.object(MODULE, "atomic_replace_json_at") as replace, self.assertRaisesRegex(
            MODULE.EditorError,
            "container root is invalid",
        ):
            MODULE.update_workspace_record(
                self.paths,
                self.repo,
                record,
                container_root=escaped,
                workspace_key={
                    "runtime": "container",
                    "root": escaped,
                    "repo_identity": str(self.repo),
                },
            )

        replace.assert_not_called()
        self.assertEqual(MODULE.load_record(self.paths, self.repo), original)

    def test_record_retirement_syncs_its_parent_directory(self) -> None:
        """Record absence is not published until the workspace directory is synced."""
        self.record()
        path = MODULE.record_path(self.paths, self.repo)
        parent = path.parent.stat()
        real_fsync = MODULE.os.fsync
        parent_synced = False

        def capture_fsync(descriptor: int) -> None:
            nonlocal parent_synced
            opened = os.fstat(descriptor)
            if (opened.st_dev, opened.st_ino) == (parent.st_dev, parent.st_ino):
                parent_synced = True
            real_fsync(descriptor)

        with mock.patch.object(MODULE.os, "fsync", side_effect=capture_fsync):
            MODULE.remove_record(path)

        self.assertTrue(parent_synced)
        self.assertFalse(path.exists())

    def test_record_commit_and_retirement_do_not_report_false_rollback(self) -> None:
        """Directory-sync failure after mutation remains committed success with a warning."""
        record = self.record()
        workspaces_fd = self.paths.descriptor("workspaces")
        real_fsync = MODULE.os.fsync

        def fail_directory_sync(descriptor: int) -> None:
            if descriptor == workspaces_fd:
                raise OSError("injected directory sync failure")
            real_fsync(descriptor)

        with mock.patch.object(MODULE.os, "fsync", side_effect=fail_directory_sync), mock.patch.object(
            MODULE,
            "progress",
        ) as reported:
            identity = MODULE.update_workspace_record(
                self.paths,
                self.repo,
                record,
                status="error",
                error="committed",
            )
            MODULE.remove_workspace_record(self.paths, self.repo, identity)

        self.assertFalse(MODULE.record_path(self.paths, self.repo).exists())
        self.assertGreaterEqual(reported.call_count, 2)

    def test_mount_arguments_reject_devcontainer_delimiter_injection(self) -> None:
        """Bind sources and targets reject commas, line breaks, and NUL bytes."""
        for source, target in (
            (pathlib.Path("/tmp/source,readonly"), "/work"),
            (pathlib.Path("/tmp/source\nnext"), "/work"),
            (pathlib.Path("/tmp/source"), "/work,target=/escape"),
            (pathlib.Path("/tmp/source"), "/work\0escape"),
        ):
            with self.assertRaisesRegex(MODULE.EditorError, "delimiter"):
                MODULE.mount_argument(source, target)

    def test_exec_preserves_empty_nonprogram_arguments(self) -> None:
        """Container execution retains every argv element after a non-empty program."""
        record = self.record()
        arguments = argparse.Namespace(
            cwd=str(self.repo),
            argv=["--", "printf", "%s", ""],
        )
        result = subprocess.CompletedProcess(["devcontainer", "exec"], 0, b"", b"")

        with mock.patch.object(MODULE, "prepare_state", return_value=self.paths), mock.patch.object(
            MODULE,
            "canonical_root",
            return_value=self.repo,
        ), mock.patch.object(MODULE, "repo_root", return_value=self.repo), mock.patch.object(
            MODULE,
            "selected_record",
            return_value=record,
        ), mock.patch.object(MODULE, "cli_path", return_value="/managed/devcontainer"), mock.patch.object(
            MODULE,
            "run",
            return_value=result,
        ) as execute, self.assertRaises(SystemExit) as exited:
            MODULE.cmd_exec(arguments)

        self.assertEqual(exited.exception.code, 0)
        execute.assert_called_once_with(
            [
                "/managed/devcontainer",
                "exec",
                "--workspace-folder",
                str(self.repo),
                "--config",
                str(self.config),
                "--workdir",
                "/workspaces/repo",
                "printf",
                "%s",
                "",
            ],
            check=False,
        )

    def test_container_respawn_is_checked_ordered_and_bound_to_explicit_pane(self) -> None:
        """The coordinator verifies marker and PID only after checked respawn steps."""
        record = self.record()
        calls: list[tuple[list[str], dict[str, object]]] = []
        observations = iter(
            (
                b"0\t7007\t\t\n",
                f"0\t4242\t\t{MODULE.pane_marker(self.repo)}\n".encode(),
            )
        )

        def execute(argv: list[str], **kwargs: object) -> subprocess.CompletedProcess[bytes]:
            calls.append((list(argv), dict(kwargs)))
            stdout = b""
            if argv[1] == "display-message":
                stdout = next(observations)
            return subprocess.CompletedProcess(argv, 0, stdout, b"")

        with mock.patch.object(MODULE.shutil, "which", return_value="/opt/tmux"), mock.patch.object(
            MODULE,
            "run",
            side_effect=execute,
        ):
            observation = MODULE.respawn_container_editor(record, ["devcontainer", "exec", "nvim"])
        self.assertEqual(observation.pid, 4242)
        self.assertEqual(
            [call[0][1] for call in calls],
            ["display-message", "set-option", "respawn-pane", "set-option", "select-pane", "display-message"],
        )
        self.assertTrue(all("check" not in kwargs or kwargs["check"] is True for _, kwargs in calls))
        self.assertTrue(all("%7" in argv for argv, _ in calls))

    def test_host_respawn_is_verified_before_lifecycle_retirement(self) -> None:
        """Host handoff checks a new alive PID and removed marker after respawn."""
        record = self.record()
        record["pane_pid"] = 4242
        calls: list[list[str]] = []
        observations = iter(
            (
                f"0\t4242\t\t{MODULE.pane_marker(self.repo)}\n".encode(),
                b"0\t5252\t\t\n",
            )
        )

        def execute(argv: list[str], **_kwargs: object) -> subprocess.CompletedProcess[bytes]:
            calls.append(list(argv))
            stdout = next(observations) if argv[1] == "display-message" else b""
            return subprocess.CompletedProcess(argv, 0, stdout, b"")

        with mock.patch.object(MODULE.shutil, "which", return_value="/opt/tmux"), mock.patch.object(
            MODULE,
            "run",
            side_effect=execute,
        ):
            observation = MODULE.respawn_host_editor(record)
        self.assertEqual(observation.pid, 5252)
        self.assertEqual(
            [argv[1] for argv in calls],
            ["display-message", "respawn-pane", "set-option", "select-pane", "display-message"],
        )
        self.assertEqual(calls[1][-1], "exec nvim")

    def test_cmd_up_holds_lock_until_verified_pane_exit(self) -> None:
        """Running is persisted after pane verification and the flock spans monitoring."""
        arguments = argparse.Namespace(
            repo=str(self.repo),
            config=None,
            recreate=False,
            allow_network=False,
            tmux_pane="%7",
            claim_id="00000000-0000-4000-8000-000000000011",
            timeout=1.0,
        )
        result = subprocess.CompletedProcess(
            ["devcontainer", "up"],
            0,
            b'{"containerId":"abc","remoteWorkspaceFolder":"/workspaces/repo"}',
            b"",
        )
        events: list[str] = []

        def verified(record: dict[str, object], command: list[str]) -> MODULE.PaneObservation:
            events.append("verified")
            self.assertNotIn("token", record)
            self.assertNotIn(MODULE.read_auth(self.spool), "\n".join(command))
            return MODULE.PaneObservation(False, 4242, None, MODULE.pane_marker(self.repo))

        def monitored(*_args: object) -> tuple[int, bool]:
            events.append("monitored")
            self.assertEqual(MODULE.load_record(self.paths, self.repo)["status"], "running")
            with self.assertRaisesRegex(MODULE.EditorError, "busy"), MODULE.workspace_lock(
                self.paths,
                self.repo,
            ):
                pass
            return 0, False

        with mock.patch.object(MODULE, "repo_root", return_value=self.repo), mock.patch.object(
            MODULE,
            "require_editor_pane",
            return_value=("%7", 7007),
        ), mock.patch.object(MODULE, "cli_path", return_value="/managed/devcontainer"), mock.patch.object(
            MODULE,
            "preserve_lockfile_flag",
            return_value="--no-lockfile",
        ), mock.patch.object(
            MODULE,
            "run",
            return_value=result,
        ), mock.patch.object(MODULE, "respawn_container_editor", side_effect=verified), mock.patch.object(
            MODULE,
            "monitor_editor",
            side_effect=monitored,
        ):
            MODULE.cmd_up(arguments)
        self.assertEqual(events, ["verified", "monitored"])
        self.assertEqual(MODULE.load_record(self.paths, self.repo)["status"], "dead")
        self.assertFalse(MODULE.auth_path(MODULE.spool_path(self.paths, self.repo)).exists())

    def test_cmd_up_respawn_failure_never_publishes_running(self) -> None:
        """A checked tmux failure leaves an error record and revokes spool auth."""
        arguments = argparse.Namespace(
            repo=str(self.repo),
            config=None,
            recreate=False,
            allow_network=False,
            tmux_pane="%7",
            claim_id="00000000-0000-4000-8000-000000000012",
            timeout=1.0,
        )
        result = subprocess.CompletedProcess(
            ["devcontainer", "up"],
            0,
            b'{"containerId":"abc","remoteWorkspaceFolder":"/workspaces/repo"}',
            b"",
        )
        with mock.patch.object(MODULE, "repo_root", return_value=self.repo), mock.patch.object(
            MODULE,
            "require_editor_pane",
            return_value=("%7", 7007),
        ), mock.patch.object(MODULE, "cli_path", return_value="/managed/devcontainer"), mock.patch.object(
            MODULE,
            "preserve_lockfile_flag",
            return_value="--no-lockfile",
        ), mock.patch.object(
            MODULE,
            "run",
            return_value=result,
        ), mock.patch.object(
            MODULE,
            "respawn_container_editor",
            side_effect=MODULE.EditorError("tmux respawn rejected"),
        ), mock.patch.object(MODULE, "monitor_editor") as monitor, self.assertRaisesRegex(
            MODULE.EditorError,
            "tmux respawn rejected",
        ):
            MODULE.cmd_up(arguments)
        monitor.assert_not_called()
        record = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(record["status"], "error")
        self.assertNotEqual(record["status"], "running")
        self.assertFalse(MODULE.auth_path(MODULE.spool_path(self.paths, self.repo)).exists())

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
        self.assertIn("--tmux-pane", result.stdout)
        self.assertIn("--claim-id", result.stdout)


if __name__ == "__main__":
    unittest.main()
