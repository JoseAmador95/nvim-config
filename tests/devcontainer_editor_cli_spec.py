"""Focused contracts for the Dev Container editor launcher."""

from __future__ import annotations

import argparse
import contextlib
import errno
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import re
import selectors
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
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

KNOWN_HOSTS_LINE = "nvim-podman-test ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest\n"


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
        self.cli = self.root / "devcontainer"
        self.cli.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.cli.chmod(0o700)
        self.cli = self.cli.resolve(strict=True)
        self.docker = self.root / "docker"
        self.docker.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.docker.chmod(0o700)
        self.docker = self.docker.resolve(strict=True)
        self.repo = self.repo.resolve(strict=True)
        self.config = self.repo / ".devcontainer/devcontainer.json"
        self.file = self.repo / "file.txt"
        self.state = self.root / "state"
        self.environment = mock.patch.dict(
            os.environ,
            {"NVIM_DEVCONTAINER_STATE_HOME": str(self.state)},
        )
        self.environment.start()
        os.environ.pop("SSH_AUTH_SOCK", None)
        os.environ.pop("CONTAINER_CONNECTION", None)
        os.environ.pop("CONTAINER_HOST", None)
        os.environ.pop("CONTAINER_SSHKEY", None)
        self.paths = MODULE.prepare_state()
        self.spool_context = MODULE.workspace_spool(
            MODULE.spool_path(self.paths, self.repo)
        )
        self.spool = self.spool_context.__enter__()

    def tearDown(self) -> None:
        """Restore process environment and remove the isolated fixture."""
        self.spool_context.__exit__(None, None, None)
        self.environment.stop()
        self.temporary.cleanup()

    def read_process_line(
        self,
        process: subprocess.Popen[bytes],
        timeout: float = 5.0,
    ) -> bytes:
        """Read one child line without allowing a failed canary to hang."""
        assert process.stdout is not None
        output = bytearray()
        deadline = time.monotonic() + timeout
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while b"\n" not in output:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    self.fail("timed out waiting for child output")
                if not selector.select(remaining):
                    self.fail("timed out waiting for child output")
                payload = os.read(process.stdout.fileno(), 4096)
                if not payload:
                    break
                output.extend(payload)
        return bytes(output)

    def finish_process(
        self,
        process: subprocess.Popen[bytes],
    ) -> tuple[int, bytes, bytes]:
        """Close a child's stdin leash, reap it, and collect remaining output."""
        if process.stdin is not None and not process.stdin.closed:
            with contextlib.suppress(OSError, ValueError):
                process.stdin.close()
        try:
            code = process.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            process.kill()
            code = process.wait(timeout=5.0)
        stdout = b"" if process.stdout is None else process.stdout.read()
        stderr = b"" if process.stderr is None else process.stderr.read()
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                stream.close()
        return code, stdout, stderr

    def record(
        self, status: str = "running", pid: int | None = None
    ) -> dict[str, object]:
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
                "phase": {
                    "running": "monitoring-editor",
                    "stopped": "returning-host",
                    "dead": "monitoring-editor",
                }.get(status, "claimed"),
                "pid": os.getpid() if pid is None else pid,
                "container_root": "/workspaces/repo",
                "container_id": "abc",
                "workspace_key": {
                    "runtime": "container",
                    "root": "/workspaces/repo",
                    "repo_identity": str(self.repo),
                },
                "cli_path": str(self.cli),
                "docker_path": str(self.docker),
            }
        )
        MODULE.atomic_json(MODULE.record_path(self.paths, self.repo), value)
        MODULE.unlink_regular_at(self.spool.root_fd, "auth.json")
        MODULE.create_auth(self.spool, self.token)
        return value

    def snapshot_source(self, name: str = "config-source") -> pathlib.Path:
        """Create one small, explicit Neovim runtime closure."""
        source = self.root / name
        source.mkdir()
        (source / "init.lua").write_text("return true\n", encoding="utf-8")
        (source / "lazy-lock.json").write_text("{}\n", encoding="utf-8")
        for directory in ("lua", "local-plugins", "scripts", "after", "tombi"):
            (source / directory).mkdir()
        (source / "lua/runtime.lua").write_text("return {}\n", encoding="utf-8")
        (source / "local-plugins/plugin.lua").write_text(
            "return {}\n", encoding="utf-8"
        )
        runner = source / "scripts/runner"
        runner.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        runner.chmod(0o700)
        (source / "after/after.lua").write_text("return true\n", encoding="utf-8")
        (source / "tombi/config.toml").write_text("version = 1\n", encoding="utf-8")
        unrelated = source / "not-runtime"
        unrelated.mkdir()
        (unrelated / "ignored.txt").write_text("ignored\n", encoding="utf-8")
        return source.resolve(strict=True)

    def podman_machine_fixture(
        self,
        *,
        name: str = "podman-machine-default",
        pin_id: str = "a" * 64,
        host: str = "127.0.0.1",
    ) -> MODULE.PodmanMachine:
        """Create one locally attested-shaped Podman Machine fixture."""
        identity = self.root / f"{name}.key"
        identity.write_text("private test key\n", encoding="utf-8")
        identity.chmod(0o600)
        identity = identity.resolve(strict=True)
        details = identity.stat()
        return MODULE.PodmanMachine(
            name,
            "core",
            host,
            51234,
            1000,
            identity,
            details.st_dev,
            details.st_ino,
            "2026-09-06T00:00:00Z",
            pin_id,
        )

    def relay_forwarding_fixture(
        self,
        *,
        pin_id: str = "a" * 64,
        host_path: pathlib.Path = pathlib.Path("/private/tmp/agent"),
    ) -> MODULE.AgentForwarding:
        """Build one current authenticated Podman relay forwarding plan."""
        return MODULE.AgentForwarding(
            "podman-machine-relay",
            MODULE.HostAgentSnapshot(
                host_path,
                1,
                2,
                os.getuid(),
                stat.S_IFSOCK | 0o600,
                self.agent_authority_fixture(host_path),
            ),
            self.podman_machine_fixture(pin_id=pin_id),
            None,
            MODULE.new_relay_agent_socket(),
        )

    def agent_authority_fixture(
        self, socket_path: pathlib.Path
    ) -> tuple[MODULE.DirectoryAuthority, ...]:
        """Build a minimal already-attested parent chain for mocked paths."""
        return (
            MODULE.DirectoryAuthority(
                socket_path.parent,
                1,
                3,
                os.getuid(),
                os.getgid(),
                stat.S_IFDIR | 0o700,
            ),
        )

    def test_state_and_spool_are_owner_only(self) -> None:
        """Private directories and JSON files remain 0700/0600."""
        for path in self.paths.values():
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
        spool = self.spool
        for path in (
            spool.root,
            spool.root / "inbox",
            spool.root / "outbox",
            spool.root / "acks",
        ):
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

        self.assertEqual(
            MODULE.consume_outbox(self.paths, self.spool, record, self.token),
            (0, False),
        )
        self.assertEqual(victim.read_text(encoding="utf-8"), '{"must_remain":true}\n')

    def test_spool_descriptor_helpers_reject_non_basename_entries(self) -> None:
        """Descriptor-relative state helpers never traverse outside their pinned directory."""
        with self.assertRaisesRegex(MODULE.EditorError, "not a basename"):
            MODULE.atomic_create_json_at(
                self.spool.outbox_fd, "../outside.json", {"ok": True}
            )
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

        MODULE.update_workspace_record(
            self.paths, self.repo, record, status="error", error="anchored"
        )
        pinned_record = pinned_workspaces / MODULE.record_name(self.repo)
        self.assertEqual(
            MODULE.read_private_json(pinned_record, "record")["error"], "anchored"
        )
        self.assertEqual(list(outside_workspaces.iterdir()), [])

        locks = self.paths["locks"]
        pinned_locks = self.state / "pinned-locks"
        locks.rename(pinned_locks)
        outside_locks = self.root / "outside-locks"
        outside_locks.mkdir(mode=0o700)
        locks.symlink_to(outside_locks, target_is_directory=True)
        with MODULE.workspace_lock(self.paths, self.repo):
            self.assertTrue((pinned_locks / MODULE.record_name(self.repo)).exists())
            with (
                self.assertRaisesRegex(MODULE.EditorError, "busy"),
                MODULE.workspace_lock(
                    self.paths,
                    self.repo,
                ),
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

        with (
            mock.patch.object(
                MODULE.os, "link", side_effect=AssertionError("auth hardlink")
            ),
            mock.patch.object(
                MODULE.os,
                "fsync",
                side_effect=capture_fsync,
            ),
        ):
            MODULE.create_auth(self.spool, token)

        auth = MODULE.auth_path(self.spool)
        self.assertEqual(auth.stat().st_nlink, 1)
        self.assertIn(self.spool.root_fd, synced)
        self.assertEqual(
            [
                path.name
                for path in self.spool.root.iterdir()
                if "auth.json." in path.name
            ],
            [],
        )

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

    def test_retirement_stat_failure_restores_canonical_basename(self) -> None:
        """Reservation inspection failure restores the exact private entry."""
        name = "stat-failure.json"
        path = self.spool.root / "inbox" / name
        payload = b'{"preserved":true}\n'
        MODULE.atomic_create_bytes_at(self.spool.inbox_fd, name, payload)
        real_stat = MODULE.os.stat
        injected = False

        def fail_reservation_stat(
            target: object, *args: object, **kwargs: object
        ) -> os.stat_result:
            nonlocal injected
            if (
                isinstance(target, str)
                and target.startswith(f".{name}.")
                and target.endswith(".retire")
                and kwargs.get("dir_fd") == self.spool.inbox_fd
            ):
                injected = True
                raise OSError("injected reservation stat failure")
            return real_stat(target, *args, **kwargs)

        with (
            mock.patch.object(MODULE.os, "stat", side_effect=fail_reservation_stat),
            self.assertRaisesRegex(
                MODULE.EditorError,
                "^could not inspect retirement reservation.*injected reservation stat failure",
            ) as caught,
        ):
            MODULE.unlink_regular_at(self.spool.inbox_fd, name)

        self.assertTrue(injected)
        self.assertEqual(path.read_bytes(), payload)
        self.assertEqual(list(path.parent.glob(f".{name}.*.retire")), [])
        self.assertIsInstance(caught.exception.__cause__, OSError)

    def test_retirement_unlink_failure_restores_canonical_basename(self) -> None:
        """Reservation unlink failure restores the exact private entry."""
        name = "unlink-failure.json"
        path = self.spool.root / "inbox" / name
        payload = b'{"preserved":true}\n'
        MODULE.atomic_create_bytes_at(self.spool.inbox_fd, name, payload)
        real_unlink = MODULE.os.unlink
        injected = False

        def fail_reservation_unlink(
            target: object, *args: object, **kwargs: object
        ) -> None:
            nonlocal injected
            if (
                isinstance(target, str)
                and target.startswith(f".{name}.")
                and target.endswith(".retire")
                and kwargs.get("dir_fd") == self.spool.inbox_fd
            ):
                injected = True
                raise OSError("injected reservation unlink failure")
            real_unlink(target, *args, **kwargs)

        with (
            mock.patch.object(MODULE.os, "unlink", side_effect=fail_reservation_unlink),
            self.assertRaisesRegex(
                MODULE.EditorError,
                "^could not retire private entry.*injected reservation unlink failure",
            ) as caught,
        ):
            MODULE.unlink_regular_at(self.spool.inbox_fd, name)

        self.assertTrue(injected)
        self.assertEqual(path.read_bytes(), payload)
        self.assertEqual(list(path.parent.glob(f".{name}.*.retire")), [])
        self.assertIsInstance(caught.exception.__cause__, OSError)

    def test_retirement_restore_failure_keeps_primary_diagnostic_first(self) -> None:
        """A newer canonical entry is never clobbered when restoration also fails."""
        name = "restore-failure.json"
        path = self.spool.root / "inbox" / name
        MODULE.atomic_create_bytes_at(self.spool.inbox_fd, name, b"original\n")
        real_unlink = MODULE.os.unlink

        def replace_then_fail(target: object, *args: object, **kwargs: object) -> None:
            if (
                isinstance(target, str)
                and target.startswith(f".{name}.")
                and target.endswith(".retire")
                and kwargs.get("dir_fd") == self.spool.inbox_fd
            ):
                path.write_bytes(b"replacement\n")
                path.chmod(0o600)
                raise OSError("injected retirement failure")
            real_unlink(target, *args, **kwargs)

        with (
            mock.patch.object(MODULE.os, "unlink", side_effect=replace_then_fail),
            self.assertRaisesRegex(
                MODULE.EditorError,
                "^could not retire private entry.*retirement reservation restoration failed",
            ) as caught,
        ):
            MODULE.unlink_regular_at(self.spool.inbox_fd, name)

        reservations = list(path.parent.glob(f".{name}.*.retire"))
        self.assertEqual(path.read_bytes(), b"replacement\n")
        self.assertEqual(len(reservations), 1)
        self.assertEqual(reservations[0].read_bytes(), b"original\n")
        self.assertIsInstance(caught.exception.__cause__, MODULE.EditorError)
        reservations[0].unlink()

    def test_auth_hardlink_created_between_stat_and_open_is_rejected(self) -> None:
        """Descriptor validation repeats single-link ownership after opening."""
        MODULE.create_auth(self.spool, "a" * 43)
        auth = MODULE.auth_path(self.spool)
        duplicate = self.spool.root / "raced-auth-link.json"
        real_open = MODULE.os.open
        raced = False

        def race_open(path: object, flags: int, *args: object, **kwargs: object) -> int:
            nonlocal raced
            if (
                path == "auth.json"
                and kwargs.get("dir_fd") == self.spool.root_fd
                and not raced
            ):
                raced = True
                os.link(auth, duplicate)
            return real_open(path, flags, *args, **kwargs)

        with (
            mock.patch.object(MODULE.os, "open", side_effect=race_open),
            self.assertRaisesRegex(
                MODULE.EditorError,
                "changed while opening",
            ),
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

        with (
            mock.patch.object(
                MODULE, "write_descriptor", side_effect=replace_after_write
            ),
            self.assertRaisesRegex(
                MODULE.EditorError,
                "injected write boundary failure",
            ),
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
                raise MODULE.EditorError(
                    "primary authentication write failure"
                ) from cause

        with (
            mock.patch.object(MODULE, "write_descriptor", side_effect=fail_write),
            mock.patch.object(
                MODULE,
                "unlink_regular_at",
                side_effect=MODULE.EditorError("authentication cleanup failed"),
            ),
            mock.patch.object(
                MODULE,
                "progress",
                side_effect=ValueError("stderr is closed"),
            ) as reported,
            self.assertRaises(MODULE.EditorError) as caught,
        ):
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
        with (
            mock.patch.dict(
                os.environ,
                {"NVIM_DEVCONTAINER_STATE_HOME": str(linked)},
            ),
            self.assertRaisesRegex(MODULE.EditorError, "not a real directory"),
        ):
            MODULE.prepare_state()
        path = MODULE.record_path(self.paths, self.repo)
        path.symlink_to(self.file)
        with self.assertRaisesRegex(MODULE.EditorError, "unsafe"):
            MODULE.selected_record(self.paths, self.repo)

    def test_state_root_rejects_shared_non_home_storage(self) -> None:
        """Lifecycle state cannot be redirected to a shared host mount."""
        with (
            mock.patch.dict(
                os.environ,
                {"NVIM_DEVCONTAINER_STATE_HOME": "/srv/shared/nvim-devcontainer"},
            ),
            self.assertRaisesRegex(MODULE.EditorError, "below HOME"),
        ):
            MODULE.state_root()

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
        """Lifecycle mounts use the certified CLI's required public grammar."""
        spool = self.spool
        agent = self.root / "agent.sock"
        argv, remote = MODULE.up_argv(
            "/managed/devcontainer",
            "/managed/podman",
            self.repo,
            self.config,
            spool.root,
            True,
            agent,
            "--no-lockfile",
        )
        self.assertEqual(argv[:2], ["/managed/devcontainer", "up"])
        self.assertIn("/managed/podman", argv)
        self.assertEqual(argv[argv.index("--log-format") + 1], "json")
        self.assertIn("--remove-existing-container", argv)
        self.assertIn("SSH_AUTH_SOCK=/tmp/nvim-config-ssh-agent.sock", argv)
        self.assertIn("--no-lockfile", argv)
        self.assertIn(str(spool.root), "\n".join(argv))
        self.assertTrue(remote.startswith("/tmp/nvim-devcontainer-"))
        mounts = [
            argv[index + 1]
            for index, argument in enumerate(argv)
            if argument == "--mount"
        ]
        official_089_mount = re.compile(
            r"^type=(bind|volume),source=([^,]+),target=([^,]+)"
            r"(?:,external=(true|false))?$"
        )
        self.assertEqual(len(mounts), 2)
        self.assertTrue(all(official_089_mount.fullmatch(value) for value in mounts))
        self.assertTrue(all("readonly" not in value for value in mounts))
        self.assertTrue(all("external=" not in value for value in mounts))
        self.assertNotIn(f"source={MODULE.CONFIG_ROOT},", "\n".join(mounts))
        self.assertEqual(
            mounts[0],
            f"type=bind,source={spool.root},target={remote}",
        )

    def test_podman_machine_agent_defers_hooks_without_an_agent_mount(self) -> None:
        """The Podman relay projects only its proxy path before deferred hooks."""
        host = MODULE.HostAgentSnapshot(
            host_path := pathlib.Path("/var/run/com.apple.launchd.example/Listeners"),
            1,
            2,
            os.getuid(),
            stat.S_IFSOCK | 0o600,
            self.agent_authority_fixture(host_path),
        )
        machine = MODULE.PodmanMachine(
            "podman-machine-default",
            "core",
            "127.0.0.1",
            51234,
            1000,
            self.root / "machine-key",
            3,
            4,
            "2026-09-06T00:00:00Z",
            "a" * 64,
        )
        proxy_socket = MODULE.new_relay_agent_socket()
        forwarding = MODULE.AgentForwarding(
            "podman-machine-relay",
            host,
            machine,
            None,
            proxy_socket,
        )
        argv, _remote = MODULE.up_argv(
            "/managed/devcontainer",
            "/managed/podman",
            self.repo,
            self.config,
            self.spool.root,
            False,
            forwarding,
            "--no-lockfile",
        )
        rendered = "\n".join(argv)
        self.assertNotIn("/var/run/com.apple.launchd", rendered)
        self.assertNotIn("type=volume", rendered)
        self.assertEqual(argv.count("--mount"), 1)
        self.assertIn(f"SSH_AUTH_SOCK={proxy_socket}", argv)
        self.assertIn("--skip-post-create", argv)

    def test_forwarding_plan_discovers_only_exact_darwin_podman(self) -> None:
        """Every Darwin Podman plan pins a machine, even with forwarding disabled."""
        host = MODULE.HostAgentSnapshot(
            host_path := pathlib.Path("/private/tmp/agent"),
            1,
            2,
            os.getuid(),
            stat.S_IFSOCK | 0o600,
            self.agent_authority_fixture(host_path),
        )
        machine = MODULE.PodmanMachine(
            "machine",
            "core",
            "127.0.0.1",
            51234,
            1000,
            self.root / "key",
            3,
            4,
            "created",
            "f" * 64,
        )
        with mock.patch.object(
            MODULE, "discover_podman_machine", return_value=machine
        ) as discover:
            with mock.patch.object(MODULE.sys, "platform", "darwin"):
                relay = MODULE.forwarding_plan(self.repo, "/managed/podman", host)
                direct = MODULE.forwarding_plan(self.repo, "/managed/docker", host)
                disabled = MODULE.forwarding_plan(self.repo, "/managed/podman", None)
                pinned = MODULE.forwarding_plan(
                    self.repo,
                    "/managed/podman",
                    None,
                    machine,
                )
            with mock.patch.object(MODULE.sys, "platform", "linux"):
                linux = MODULE.forwarding_plan(self.repo, "/managed/podman", host)
        self.assertEqual(relay.transport, "podman-machine-relay")
        self.assertIsNone(relay.mount_source)
        self.assertIsNotNone(relay.container_socket)
        assert relay.container_socket is not None
        self.assertIsNotNone(
            MODULE.RELAY_AGENT_SOCKET_RE.fullmatch(relay.container_socket)
        )
        self.assertEqual(direct.transport, "direct-bind")
        self.assertEqual(disabled.transport, "disabled")
        self.assertIs(disabled.machine, machine)
        self.assertIs(pinned.machine, machine)
        self.assertEqual(linux.transport, "direct-bind")
        self.assertEqual(discover.call_args_list, [mock.call("/managed/podman")] * 2)

    def test_pinned_engine_environment_overrides_ambient_routing(self) -> None:
        """Every Podman subprocess receives the exact attested SSH endpoint."""
        machine = self.podman_machine_fixture(host="::1")
        with mock.patch.dict(
            os.environ,
            {
                "CONTAINER_CONNECTION": "other",
                "CONTAINER_HOST": "ssh://wrong.example/run/podman.sock",
                "CONTAINER_SSHKEY": "/tmp/wrong-key",
                "DOCKER_HOST": "unix:///tmp/wrong.sock",
                "KEEP_ME": "yes",
            },
        ):
            environment = MODULE.pinned_engine_environment(machine)
        assert environment is not None
        self.assertNotIn("CONTAINER_CONNECTION", environment)
        self.assertNotIn("DOCKER_HOST", environment)
        self.assertEqual(
            environment["CONTAINER_HOST"],
            "ssh://core@[::1]:51234/run/user/1000/podman/podman.sock",
        )
        self.assertEqual(environment["CONTAINER_SSHKEY"], str(machine.identity))
        self.assertEqual(environment["KEEP_ME"], "yes")

    def test_podman_connection_selection_honors_exact_overrides(self) -> None:
        """Connection overrides select exactly one object and never fall back."""
        first = {
            "Name": "first",
            "URI": "ssh://core@127.0.0.1:5001/run/user/1000/podman/podman.sock",
            "Default": True,
            "IsMachine": True,
        }
        second = {
            "Name": "second",
            "URI": "ssh://core@127.0.0.1:5002/run/user/1000/podman/podman.sock",
            "Default": False,
            "IsMachine": True,
        }
        with mock.patch.dict(
            os.environ,
            {"CONTAINER_CONNECTION": "second", "CONTAINER_HOST": second["URI"]},
        ):
            self.assertIs(MODULE.selected_podman_connection([first, second]), second)
        with (
            mock.patch.dict(os.environ, {"CONTAINER_CONNECTION": "missing"}),
            self.assertRaisesRegex(MODULE.EditorError, "missing or ambiguous"),
        ):
            MODULE.selected_podman_connection([first, second])
        with (
            mock.patch.dict(os.environ, {"CONTAINER_SSHKEY": "/tmp/other-key"}),
            self.assertRaisesRegex(MODULE.EditorError, "CONTAINER_SSHKEY"),
        ):
            MODULE.discover_podman_machine("/managed/podman")

    def test_podman_endpoint_rejects_external_and_rootful_uris(self) -> None:
        """Only numeric-loopback rootless Podman Machine sockets are accepted."""
        base = {"Name": "machine", "IsMachine": True}
        external = dict(
            base,
            URI="ssh://core@192.0.2.1:5001/run/user/1000/podman/podman.sock",
        )
        rootful = dict(base, URI="ssh://core@127.0.0.1:5001/run/podman/podman.sock")
        with self.assertRaisesRegex(MODULE.EditorError, "not loopback"):
            MODULE.connection_endpoint(external)
        with self.assertRaisesRegex(MODULE.EditorError, "not a rootless"):
            MODULE.connection_endpoint(rootful)

    def test_podman_machine_discovery_cross_checks_all_metadata(self) -> None:
        """Connection, list, and inspect must agree on the local machine identity."""
        identity = self.root / "podman-machine-key"
        identity.write_text("private test key\n", encoding="utf-8")
        identity.chmod(0o600)
        identity = identity.resolve(strict=True)
        connection = [
            {
                "Name": "podman-machine-default",
                "URI": "ssh://core@127.0.0.1:51234/run/user/1000/podman/podman.sock",
                "Identity": str(identity),
                "Default": True,
                "IsMachine": True,
            }
        ]
        listed = [
            {
                "Name": "podman-machine-default",
                "Running": True,
                "Rootful": False,
                "RemoteUsername": "core",
                "Port": 51234,
                "IdentityPath": str(identity),
            }
        ]
        inspected = [
            {
                "Name": "podman-machine-default",
                "State": "running",
                "Rootful": False,
                "Created": "2026-09-06T00:00:00Z",
                "SSHConfig": {
                    "RemoteUsername": "core",
                    "Port": 51234,
                    "IdentityPath": str(identity),
                },
            }
        ]
        results = [
            (subprocess.CompletedProcess([], 0, json.dumps(value).encode(), b""), False)
            for value in (connection, listed, inspected)
        ]
        with mock.patch.object(
            MODULE, "run_bounded_capture", side_effect=results
        ) as execute:
            machine = MODULE.discover_podman_machine("/managed/podman")
        self.assertEqual(machine.name, "podman-machine-default")
        self.assertEqual(machine.uid, 1000)
        self.assertEqual(machine.identity, identity)
        self.assertEqual(len(execute.call_args_list), 3)
        self.assertEqual(execute.call_args_list[-1].args[0][-2:], ["--", machine.name])
        moved_connection = dict(connection[0])
        moved_listed = dict(listed[0], Port=60000)
        moved_inspected = dict(
            inspected[0],
            SSHConfig=dict(inspected[0]["SSHConfig"], Port=60000),
        )
        moved = MODULE.validate_machine_match(
            moved_connection,
            moved_listed,
            moved_inspected,
            ("core", "127.0.0.1", 60000, 1000),
        )
        self.assertEqual(machine.pin_id, moved.pin_id)

    def test_stored_podman_machine_reselects_name_and_rejects_pin_drift(self) -> None:
        """Later actions re-attest the stored endpoint instead of using a new default."""
        expected = self.podman_machine_fixture(name="recorded", pin_id="b" * 64)
        record = {"podman_connection": {"name": "recorded", "machine_pin": "b" * 64}}
        with (
            mock.patch.object(MODULE.sys, "platform", "darwin"),
            mock.patch.object(
                MODULE,
                "discover_podman_machine",
                return_value=expected,
            ) as discover,
        ):
            self.assertIs(
                MODULE.stored_podman_machine(record, "/managed/podman"),
                expected,
            )
        discover.assert_called_once_with("/managed/podman", "recorded")

        changed = expected._replace(pin_id="c" * 64)
        with (
            mock.patch.object(MODULE.sys, "platform", "darwin"),
            mock.patch.object(
                MODULE,
                "discover_podman_machine",
                return_value=changed,
            ),
            self.assertRaisesRegex(MODULE.EditorError, "identity changed"),
        ):
            MODULE.stored_podman_machine(record, "/managed/podman")
        with self.assertRaisesRegex(MODULE.EditorError, "unexpected Podman"):
            MODULE.stored_podman_machine(record, "/managed/docker")

    def test_relay_container_is_attested_by_full_identity_and_network(self) -> None:
        """The proxy targets one exact running host-network workspace container."""
        container_id = "b" * 64
        environment = {"CONTAINER_HOST": "ssh://pinned"}
        inspected = {
            "Id": container_id,
            "State": {"Running": True},
            "Config": {
                "Labels": {
                    "devcontainer.local_folder": str(self.repo),
                    "devcontainer.config_file": str(self.config),
                }
            },
            "HostConfig": {"NetworkMode": "host"},
        }
        with mock.patch.object(
            MODULE, "bounded_json_command", return_value=[inspected]
        ) as inspect:
            actual = MODULE.attested_relay_container(
                str(self.docker),
                self.repo,
                self.config,
                container_id,
                environment,
            )
        self.assertIs(actual, inspected)
        inspect.assert_called_once_with(
            [
                str(self.docker),
                "inspect",
                "--type",
                "container",
                "--",
                container_id,
            ],
            "podman container inspect",
            env=environment,
        )

    def test_relay_container_rejects_wrong_identity_labels_and_network(self) -> None:
        """No short ID, foreign workspace, or bridged container can host the proxy."""
        container_id = "c" * 64
        valid = {
            "Id": container_id,
            "State": {"Running": True},
            "Config": {
                "Labels": {
                    "devcontainer.local_folder": str(self.repo),
                    "devcontainer.config_file": str(self.config),
                }
            },
            "HostConfig": {"NetworkMode": "host"},
        }
        with self.assertRaisesRegex(MODULE.EditorError, "full hexadecimal identity"):
            MODULE.attested_relay_container(
                str(self.docker), self.repo, self.config, "short", None
            )
        invalid = (
            ([], "missing or ambiguous"),
            ([dict(valid, Id="d" * 64)], "missing or ambiguous"),
            (
                [dict(valid, Config={"Labels": {"wrong": "workspace"}})],
                "labels do not match",
            ),
            ([dict(valid, HostConfig={"NetworkMode": "bridge"})], "network mode host"),
        )
        for records, message in invalid:
            with (
                self.subTest(message=message),
                mock.patch.object(MODULE, "bounded_json_command", return_value=records),
                self.assertRaisesRegex(MODULE.EditorError, message),
            ):
                MODULE.attested_relay_container(
                    str(self.docker),
                    self.repo,
                    self.config,
                    container_id,
                    None,
                )

    def test_metadata_capture_drains_noise_with_bounded_retention(self) -> None:
        """Metadata subprocesses cannot retain unbounded stdout or stderr."""
        script = "import os;os.write(1, b'o' * 131072);os.write(2, b'e' * 131072)"
        result, overflow = MODULE.run_bounded_capture(
            [sys.executable, "-c", script],
            timeout=5.0,
            stdout_limit=1024,
            stderr_limit=2048,
        )
        self.assertEqual(result.returncode, 0)
        self.assertTrue(overflow)
        self.assertEqual(result.stdout, b"o" * 1024)
        self.assertEqual(result.stderr, b"e" * 2048)

    def test_metadata_capture_timeout_reaps_its_child(self) -> None:
        """A timed-out metadata probe terminates and reaps its owned child."""
        pid_file = self.root / "bounded-child.pid"
        script = (
            "import os, pathlib, sys, time;"
            "pathlib.Path(sys.argv[1]).write_text(str(os.getpid()));"
            "time.sleep(30)"
        )
        with self.assertRaisesRegex(MODULE.EditorError, "timed out"):
            MODULE.run_bounded_capture(
                [sys.executable, "-c", script, str(pid_file)],
                timeout=0.5,
                stdout_limit=1024,
            )
        self.assertTrue(pid_file.exists())
        self.assertFalse(MODULE.pid_alive(int(pid_file.read_text(encoding="utf-8"))))

    def test_metadata_capture_cleanup_closes_pipes_before_reporting_reap_failure(
        self,
    ) -> None:
        """A secondary reap failure cannot strand either owned output pipe."""
        process = mock.Mock(spec=subprocess.Popen)
        process.stdout = io.BytesIO(b"stdout")
        process.stderr = io.BytesIO(b"stderr")
        primary = MODULE.EditorError("probe failed")
        cleanup = MODULE.EditorError("child remained alive")
        with (
            mock.patch.object(MODULE.subprocess, "Popen", return_value=process),
            mock.patch.object(
                MODULE,
                "drain_bounded_capture",
                side_effect=primary,
            ),
            mock.patch.object(
                MODULE,
                "stop_and_reap_process",
                side_effect=cleanup,
            ),
            self.assertRaisesRegex(
                MODULE.EditorError,
                "probe failed; bounded command cleanup failed: child remained alive",
            ),
        ):
            MODULE.run_bounded_capture(
                ["/managed/probe"],
                timeout=1.0,
                stdout_limit=1024,
            )
        self.assertTrue(process.stdout.closed)
        self.assertTrue(process.stderr.closed)

    def test_explicit_unsafe_agent_fails_but_off_never_probes_it(self) -> None:
        """An unsafe explicit SSH_AUTH_SOCK is not treated as absent."""
        unsafe = self.root / "not-a-socket"
        unsafe.write_text("not a socket", encoding="utf-8")
        with (
            mock.patch.dict(os.environ, {"SSH_AUTH_SOCK": str(unsafe)}),
            self.assertRaisesRegex(MODULE.EditorError, "not a socket"),
        ):
            MODULE.ssh_agent("auto")
        with mock.patch.dict(os.environ, {"SSH_AUTH_SOCK": str(unsafe)}):
            self.assertIsNone(MODULE.ssh_agent("off"))

    def test_host_agent_authority_rejects_a_nonsticky_writable_ancestor(
        self,
    ) -> None:
        """An attacker-writable ancestor cannot redirect the validated socket."""
        safe = self.root / "agent-parent"
        safe.mkdir(mode=0o700)
        safe = safe.resolve(strict=True)
        authority = MODULE.host_agent_authority_chain(safe)
        self.assertEqual(authority[-1].path, safe)
        self.assertEqual(stat.S_IMODE(authority[-1].mode), 0o700)

        writable = self.root / "writable"
        writable.mkdir(mode=0o700)
        writable.chmod(0o777)
        child = writable / "agent-parent"
        child.mkdir(mode=0o700)
        child = child.resolve(strict=True)
        with self.assertRaisesRegex(MODULE.EditorError, "unsafe writable directory"):
            MODULE.host_agent_authority_chain(child)

        writable.chmod(0o1777)
        sticky_authority = MODULE.host_agent_authority_chain(child)
        self.assertEqual(sticky_authority[-1].path, child)

    def test_launchd_writable_ancestor_exception_is_exact(self) -> None:
        """Only the canonical macOS root:daemon launchd runtime shape is allowed."""
        runtime = MODULE.DirectoryAuthority(
            pathlib.Path("/private/var/run"),
            1,
            2,
            0,
            1,
            stat.S_IFDIR | 0o775,
        )
        launchd = MODULE.DirectoryAuthority(
            pathlib.Path("/private/var/run/com.apple.launchd.Abc123"),
            1,
            3,
            os.getuid(),
            os.getgid(),
            stat.S_IFDIR | 0o700,
        )
        with mock.patch.object(MODULE.sys, "platform", "darwin"):
            self.assertTrue(MODULE.darwin_launchd_runtime_exception(runtime, launchd))
            self.assertFalse(
                MODULE.darwin_launchd_runtime_exception(
                    runtime._replace(group=20),
                    launchd,
                )
            )
            self.assertFalse(
                MODULE.darwin_launchd_runtime_exception(
                    runtime,
                    launchd._replace(path=pathlib.Path("/private/var/run/other")),
                )
            )

    def test_known_hosts_pin_is_private_bounded_and_corruption_fails(self) -> None:
        """Machine pins are created privately and never accept corrupt reuse."""
        machine = MODULE.PodmanMachine(
            "machine",
            "core",
            "127.0.0.1",
            51234,
            1000,
            self.root / "unused-key",
            1,
            2,
            "created",
            "b" * 64,
        )
        pin = MODULE.prepare_known_hosts(self.paths, machine)
        self.assertEqual(stat.S_IMODE(pin.stat().st_mode), 0o600)
        self.assertEqual(pin.name, f"{machine.pin_id}.known_hosts")
        with self.assertRaisesRegex(MODULE.EditorError, "unsafe or corrupt"):
            MODULE.validate_known_hosts(pin, allow_empty=False)
        pin.write_text(
            "nvim-podman-test ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest\n",
            encoding="utf-8",
        )
        MODULE.validate_known_hosts(pin, allow_empty=False)
        pin.chmod(0o644)
        with self.assertRaisesRegex(MODULE.EditorError, "unsafe or corrupt"):
            MODULE.validate_known_hosts(pin, allow_empty=False)

    def test_machine_pin_lock_closes_its_descriptor_on_interrupt(self) -> None:
        """Waiting for another first-use enrollment remains bounded and leak-free."""
        machine = MODULE.PodmanMachine(
            "machine",
            "core",
            "127.0.0.1",
            51234,
            1000,
            self.root / "unused-key",
            1,
            2,
            "created",
            "9" * 64,
        )
        real_close = os.close

        def blocked(_descriptor: int, operation: int) -> None:
            if operation & MODULE.fcntl.LOCK_NB:
                raise BlockingIOError(errno.EWOULDBLOCK, "busy")

        with (
            mock.patch.object(MODULE.fcntl, "flock", side_effect=blocked),
            mock.patch.object(MODULE.time, "sleep", side_effect=KeyboardInterrupt),
            mock.patch.object(MODULE.os, "close", wraps=real_close) as close,
            self.assertRaises(KeyboardInterrupt),
            MODULE.machine_pin_lock(self.paths, machine),
        ):
            self.fail("the busy pin lock must not be entered")
        close.assert_called_once()

    def test_failed_first_remote_setup_preserves_an_enrolled_host_key(self) -> None:
        """A key learned before remote failure is durable before error return."""
        plan = self.relay_forwarding_fixture(pin_id="8" * 64)
        machine = plan.machine
        assert machine is not None
        relay = MODULE.PodmanAgentRelay(self.paths, self.repo, plan, "/managed/podman")

        def enroll_then_fail(path: pathlib.Path, *, accept_new: bool) -> None:
            self.assertTrue(accept_new)
            path.write_text(KNOWN_HOSTS_LINE, encoding="utf-8")
            raise MODULE.EditorError("remote setup failed")

        real_fsync = os.fsync
        machines_fd = self.paths.descriptor("machines")
        with (
            mock.patch.object(relay, "_probe_remote", side_effect=enroll_then_fail),
            mock.patch.object(MODULE.os, "fsync", wraps=real_fsync) as synced,
            self.assertRaisesRegex(MODULE.EditorError, "remote setup failed"),
        ):
            relay._prepare_first_pinned_remote()
        pin = MODULE.known_hosts_path(self.paths, machine)
        self.assertTrue(pin.exists())
        MODULE.validate_known_hosts(pin, allow_empty=False)
        synced.assert_any_call(machines_fd)
        self.assertTrue(
            any(call.args[0] != machines_fd for call in synced.call_args_list)
        )
        self.assertEqual(synced.call_args_list[-1], mock.call(machines_fd))

    def test_successful_first_remote_enrollment_is_synced_before_lock_release(
        self,
    ) -> None:
        """Enrollment fsyncs pin then directory before releasing its TOFU lock."""
        plan = self.relay_forwarding_fixture(pin_id="3" * 64)
        machine = plan.machine
        assert machine is not None
        relay = MODULE.PodmanAgentRelay(self.paths, self.repo, plan, "/managed/podman")

        def enroll(path: pathlib.Path, *, accept_new: bool) -> None:
            self.assertTrue(accept_new)
            path.write_text(KNOWN_HOSTS_LINE, encoding="utf-8")

        real_fsync = os.fsync
        real_flock = MODULE.fcntl.flock
        machines_fd = self.paths.descriptor("machines")
        events: list[str] = []

        def record_fsync(descriptor: int) -> None:
            events.append(
                "directory-fsync" if descriptor == machines_fd else "file-fsync"
            )
            real_fsync(descriptor)

        def record_flock(descriptor: int, operation: int) -> None:
            events.append("unlock" if operation == MODULE.fcntl.LOCK_UN else "lock")
            real_flock(descriptor, operation)

        with (
            mock.patch.object(relay, "_probe_remote", side_effect=enroll),
            mock.patch.object(MODULE.os, "fsync", side_effect=record_fsync),
            mock.patch.object(MODULE.fcntl, "flock", side_effect=record_flock),
        ):
            known_hosts = relay._prepare_first_pinned_remote()
        MODULE.validate_known_hosts(known_hosts, allow_empty=False)
        file_sync = events.index("file-fsync")
        directory_sync = len(events) - 1 - events[::-1].index("directory-fsync")
        unlock = events.index("unlock")
        self.assertLess(file_sync, directory_sync)
        self.assertLess(directory_sync, unlock)

    def test_failed_empty_first_remote_setup_durably_retires_its_pin(self) -> None:
        """A failed enrollment removes only its same empty inode and syncs that."""
        plan = self.relay_forwarding_fixture(pin_id="4" * 64)
        machine = plan.machine
        assert machine is not None
        relay = MODULE.PodmanAgentRelay(self.paths, self.repo, plan, "/managed/podman")
        real_fsync = os.fsync
        machines_fd = self.paths.descriptor("machines")
        with (
            mock.patch.object(
                relay,
                "_probe_remote",
                side_effect=MODULE.EditorError("remote setup failed"),
            ),
            mock.patch.object(MODULE.os, "fsync", wraps=real_fsync) as synced,
            self.assertRaisesRegex(MODULE.EditorError, "remote setup failed"),
        ):
            relay._prepare_first_pinned_remote()
        self.assertFalse(MODULE.known_hosts_path(self.paths, machine).exists())
        self.assertGreaterEqual(
            sum(call == mock.call(machines_fd) for call in synced.call_args_list),
            2,
        )

    def test_known_hosts_file_fsync_failure_fails_closed_and_retains_pin(self) -> None:
        """A failed key flush cannot delete the learned trust and reopen TOFU."""
        plan = self.relay_forwarding_fixture(pin_id="5" * 64)
        machine = plan.machine
        assert machine is not None
        relay = MODULE.PodmanAgentRelay(self.paths, self.repo, plan, "/managed/podman")
        pin = MODULE.known_hosts_path(self.paths, machine)
        real_fsync = os.fsync
        pin_inode: int | None = None

        def enroll(path: pathlib.Path, *, accept_new: bool) -> None:
            nonlocal pin_inode
            self.assertTrue(accept_new)
            path.write_text(KNOWN_HOSTS_LINE, encoding="utf-8")
            pin_inode = path.stat().st_ino

        def fail_pin_fsync(descriptor: int) -> None:
            if pin_inode is not None and os.fstat(descriptor).st_ino == pin_inode:
                raise OSError(errno.EIO, "injected pin fsync failure")
            real_fsync(descriptor)

        with (
            mock.patch.object(relay, "_probe_remote", side_effect=enroll),
            mock.patch.object(MODULE.os, "fsync", side_effect=fail_pin_fsync),
            self.assertRaisesRegex(MODULE.EditorError, "injected pin fsync failure"),
        ):
            relay._prepare_first_pinned_remote()
        self.assertTrue(pin.exists())
        self.assertEqual(pin.stat().st_ino, pin_inode)
        MODULE.validate_known_hosts(pin, allow_empty=False)

    def test_known_hosts_directory_fsync_failure_retains_the_learned_pin(self) -> None:
        """A failed directory flush reports failure without deleting trust."""
        plan = self.relay_forwarding_fixture(pin_id="6" * 64)
        machine = plan.machine
        assert machine is not None
        relay = MODULE.PodmanAgentRelay(self.paths, self.repo, plan, "/managed/podman")
        pin = MODULE.known_hosts_path(self.paths, machine)
        real_fsync = os.fsync
        machines_fd = self.paths.descriptor("machines")
        enrolled = False

        def enroll(path: pathlib.Path, *, accept_new: bool) -> None:
            nonlocal enrolled
            self.assertTrue(accept_new)
            path.write_text(KNOWN_HOSTS_LINE, encoding="utf-8")
            enrolled = True

        def fail_directory_fsync(descriptor: int) -> None:
            if enrolled and descriptor == machines_fd:
                raise OSError(errno.EIO, "injected directory fsync failure")
            real_fsync(descriptor)

        with (
            mock.patch.object(relay, "_probe_remote", side_effect=enroll),
            mock.patch.object(MODULE.os, "fsync", side_effect=fail_directory_fsync),
            self.assertRaisesRegex(
                MODULE.EditorError,
                "injected directory fsync failure",
            ),
        ):
            relay._prepare_first_pinned_remote()
        self.assertTrue(pin.exists())
        MODULE.validate_known_hosts(pin, allow_empty=False)

    def test_known_hosts_replacement_after_probe_is_preserved_and_rejected(
        self,
    ) -> None:
        """Persistence never adopts or removes a same-owner replacement inode."""
        plan = self.relay_forwarding_fixture(pin_id="7" * 64)
        machine = plan.machine
        assert machine is not None
        relay = MODULE.PodmanAgentRelay(self.paths, self.repo, plan, "/managed/podman")
        pin = MODULE.known_hosts_path(self.paths, machine)
        displaced = self.paths["machines"] / "displaced-known-hosts"
        replacement_inode: int | None = None
        fsynced_inodes: list[int] = []
        real_fsync = os.fsync

        def replace_after_probe(path: pathlib.Path, *, accept_new: bool) -> None:
            nonlocal replacement_inode
            self.assertTrue(accept_new)
            path.write_text(KNOWN_HOSTS_LINE, encoding="utf-8")
            path.rename(displaced)
            path.write_text(
                KNOWN_HOSTS_LINE.replace("test", "replacement"), encoding="utf-8"
            )
            path.chmod(0o600)
            replacement_inode = path.stat().st_ino

        def record_fsync(descriptor: int) -> None:
            fsynced_inodes.append(os.fstat(descriptor).st_ino)
            real_fsync(descriptor)

        with (
            mock.patch.object(relay, "_probe_remote", side_effect=replace_after_probe),
            mock.patch.object(MODULE.os, "fsync", side_effect=record_fsync),
            self.assertRaisesRegex(MODULE.EditorError, "authority changed"),
        ):
            relay._prepare_first_pinned_remote()
        self.assertTrue(pin.exists())
        self.assertEqual(pin.stat().st_ino, replacement_inode)
        self.assertNotIn(replacement_inode, fsynced_inodes)
        self.assertTrue(displaced.exists())

    def test_known_hosts_replacement_during_file_fsync_blocks_directory_commit(
        self,
    ) -> None:
        """A post-flush path swap is detected before committing its directory."""
        plan = self.relay_forwarding_fixture(pin_id="d" * 64)
        machine = plan.machine
        assert machine is not None
        relay = MODULE.PodmanAgentRelay(self.paths, self.repo, plan, "/managed/podman")
        pin = MODULE.known_hosts_path(self.paths, machine)
        displaced = self.paths["machines"] / "fsync-displaced-known-hosts"
        machines_fd = self.paths.descriptor("machines")
        real_fsync = os.fsync
        pin_inode: int | None = None
        armed = False
        directory_committed = False

        def enroll(path: pathlib.Path, *, accept_new: bool) -> None:
            nonlocal armed, pin_inode
            self.assertTrue(accept_new)
            path.write_text(KNOWN_HOSTS_LINE, encoding="utf-8")
            pin_inode = path.stat().st_ino
            armed = True

        def replace_during_fsync(descriptor: int) -> None:
            nonlocal armed, directory_committed
            current_inode = os.fstat(descriptor).st_ino
            if armed and current_inode == pin_inode:
                armed = False
                pin.rename(displaced)
                pin.write_text(
                    KNOWN_HOSTS_LINE.replace("test", "replacement"),
                    encoding="utf-8",
                )
                pin.chmod(0o600)
            elif armed and descriptor == machines_fd:
                directory_committed = True
            real_fsync(descriptor)

        with (
            mock.patch.object(relay, "_probe_remote", side_effect=enroll),
            mock.patch.object(MODULE.os, "fsync", side_effect=replace_during_fsync),
            self.assertRaisesRegex(MODULE.EditorError, "changed during persistence"),
        ):
            relay._prepare_first_pinned_remote()
        self.assertFalse(directory_committed)
        self.assertTrue(pin.exists())
        self.assertNotEqual(pin.stat().st_ino, pin_inode)
        self.assertTrue(displaced.exists())

    def test_existing_known_hosts_pin_is_resynced_after_probe(self) -> None:
        """A pre-existing valid pin also receives file and directory durability."""
        plan = self.relay_forwarding_fixture(pin_id="0" * 64)
        machine = plan.machine
        assert machine is not None
        relay = MODULE.PodmanAgentRelay(self.paths, self.repo, plan, "/managed/podman")
        pin = MODULE.prepare_known_hosts(self.paths, machine)
        pin.write_text(KNOWN_HOSTS_LINE, encoding="utf-8")
        inode = pin.stat().st_ino
        machines_fd = self.paths.descriptor("machines")
        fsynced_inodes: list[int] = []
        real_fsync = os.fsync

        def record_fsync(descriptor: int) -> None:
            fsynced_inodes.append(os.fstat(descriptor).st_ino)
            real_fsync(descriptor)

        with (
            mock.patch.object(relay, "_probe_remote") as probe,
            mock.patch.object(MODULE.os, "fsync", side_effect=record_fsync),
        ):
            known_hosts = relay._prepare_first_pinned_remote()
        probe.assert_called_once_with(pin, accept_new=False)
        self.assertEqual(known_hosts.stat().st_ino, inode)
        self.assertIn(inode, fsynced_inodes)
        self.assertEqual(fsynced_inodes[-1], os.fstat(machines_fd).st_ino)

    def test_relay_ssh_argv_is_hardened_and_forward_precedes_destination(self) -> None:
        """The relay uses only hardened OpenSSH argv and a loopback destination."""
        identity = self.root / "machine-identity"
        identity.write_text("private key\n", encoding="utf-8")
        identity.chmod(0o600)
        details = identity.stat()
        machine = MODULE.PodmanMachine(
            "machine",
            "core",
            "127.0.0.1",
            51234,
            1000,
            identity,
            details.st_dev,
            details.st_ino,
            "created",
            "c" * 64,
        )
        host = MODULE.HostAgentSnapshot(
            host_path := pathlib.Path("/private/tmp/com.apple.launchd.test/Listeners"),
            1,
            2,
            os.getuid(),
            stat.S_IFSOCK | 0o600,
            self.agent_authority_fixture(host_path),
        )
        plan = MODULE.AgentForwarding(
            "podman-machine-relay",
            host,
            machine,
            None,
            MODULE.new_relay_agent_socket(),
        )
        relay = MODULE.PodmanAgentRelay(self.paths, self.repo, plan, "/managed/podman")
        relay.port = 60001
        argv = relay._relay_argv(self.root / "known_hosts", "d" * 64)
        reverse = f"127.0.0.1:60001:{relay.gate.path}"
        self.assertEqual(argv[0], "/usr/bin/ssh")
        self.assertLess(argv.index("-R"), argv.index("127.0.0.1"))
        self.assertIn("-oIdentityAgent=none", argv)
        self.assertLess(argv.index("-oIdentityFile=none"), argv.index("-i"))
        self.assertIn("-oProxyCommand=none", argv)
        self.assertIn("-oExitOnForwardFailure=yes", argv)
        self.assertIn("-oStrictHostKeyChecking=yes", argv)
        self.assertIn("-oUpdateHostKeys=no", argv)
        enrollment = MODULE.ssh_base_argv(
            machine,
            self.root / "known_hosts",
            accept_new=True,
        )
        self.assertIn("-oStrictHostKeyChecking=accept-new", enrollment)
        self.assertIn("-oUpdateHostKeys=no", enrollment)
        self.assertEqual(argv[argv.index("-R") + 1], reverse)
        self.assertNotIn(str(host.path), reverse)
        self.assertNotIn(relay.gate.token.hex(), "\n".join(argv))
        self.assertIn('test "$4" = "127.0.0.1:$port"', argv[-1])
        self.assertIn("d" * 64, argv[-1])
        self.assertIn("cat >/dev/null", argv[-1])

    def test_relay_retries_an_exited_forward_with_a_fresh_port(self) -> None:
        """A VM port collision is reaped before one bounded fresh-port retry."""
        plan = self.relay_forwarding_fixture(pin_id="1" * 64)
        relay = MODULE.PodmanAgentRelay(self.paths, self.repo, plan, "/managed/podman")

        def process(exit_code: int | None) -> mock.Mock:
            child = mock.Mock(spec=subprocess.Popen)
            child.stdin = mock.Mock(closed=False)
            child.stdout = mock.Mock(closed=False)
            child.stderr = mock.Mock(closed=False)
            child.poll.return_value = exit_code
            child.wait.return_value = exit_code
            return child

        collided = process(255)
        running = process(None)
        known_hosts = self.root / "known_hosts"
        with (
            mock.patch.object(MODULE, "exact_executable_path"),
            mock.patch.object(MODULE, "validate_machine_identity"),
            mock.patch.object(MODULE, "revalidate_host_agent"),
            mock.patch.object(
                relay,
                "_prepare_first_pinned_remote",
                return_value=known_hosts,
            ),
            mock.patch.object(relay.gate, "start"),
            mock.patch.object(relay.gate, "check"),
            mock.patch.object(
                MODULE.secrets,
                "randbelow",
                side_effect=[7, 7],
            ),
            mock.patch.object(
                MODULE.secrets,
                "token_hex",
                side_effect=["a" * 64, "b" * 64],
            ),
            mock.patch.object(
                MODULE.subprocess,
                "Popen",
                side_effect=[collided, running],
            ) as popen,
            mock.patch.object(
                relay,
                "_wait_ready",
                side_effect=[MODULE.EditorError("forward failed"), None],
            ) as ready,
        ):
            relay.start()

        self.assertEqual(popen.call_count, 2)
        forwards = [
            call.args[0][call.args[0].index("-R") + 1] for call in popen.call_args_list
        ]
        self.assertTrue(forwards[0].startswith("127.0.0.1:49159:"))
        self.assertTrue(forwards[1].startswith("127.0.0.1:49160:"))
        self.assertEqual(
            ready.call_args_list, [mock.call("a" * 64), mock.call("b" * 64)]
        )
        collided.stdin.close.assert_called_once_with()
        collided.wait.assert_called_once_with(timeout=2.0)
        self.assertIs(relay.process, running)
        self.assertEqual(relay.port, 49160)

    def test_relay_does_not_retry_a_live_readiness_failure(self) -> None:
        """Protocol failures on a live child fail closed instead of multiplying it."""
        plan = self.relay_forwarding_fixture(pin_id="2" * 64)
        relay = MODULE.PodmanAgentRelay(self.paths, self.repo, plan, "/managed/podman")
        child = mock.Mock(spec=subprocess.Popen)
        child.stdin = mock.Mock(closed=False)
        child.stdout = mock.Mock(closed=False)
        child.stderr = mock.Mock(closed=False)
        child.poll.return_value = None
        child.wait.return_value = 0
        with (
            mock.patch.object(MODULE, "exact_executable_path"),
            mock.patch.object(MODULE, "validate_machine_identity"),
            mock.patch.object(MODULE, "revalidate_host_agent"),
            mock.patch.object(
                relay,
                "_prepare_first_pinned_remote",
                return_value=self.root / "known_hosts",
            ),
            mock.patch.object(relay.gate, "start"),
            mock.patch.object(MODULE.subprocess, "Popen", return_value=child) as popen,
            mock.patch.object(
                relay,
                "_wait_ready",
                side_effect=MODULE.EditorError("nonce mismatch"),
            ),
            self.assertRaisesRegex(MODULE.EditorError, "nonce mismatch"),
        ):
            relay.start()
        popen.assert_called_once()
        child.stdin.close.assert_called_once_with()

    def test_relay_programs_require_loopback_auth_and_private_proxy_socket(
        self,
    ) -> None:
        """The VM and container programs expose only authenticated private endpoints."""
        self.assertIn('/usr/bin/ss -H -ltn "sport = :$port"', MODULE.REMOTE_AGENT_READY)
        self.assertIn('test "$4" = "127.0.0.1:$port"', MODULE.REMOTE_AGENT_READY)
        self.assertLess(
            MODULE.REMOTE_AGENT_READY.index("printf '%s\\n'"),
            MODULE.REMOTE_AGENT_READY.index("cat >/dev/null"),
        )
        proxy = MODULE.CONTAINER_AGENT_PROXY
        self.assertIn("directory.mkdir(mode=0o700)", proxy)
        self.assertIn("os.chmod(SOCKET_PATH, 0o600)", proxy)
        self.assertIn("authority = proxy_parent_authority(directory)", proxy)
        self.assertIn("mode & stat.S_ISVTX", proxy)
        self.assertGreaterEqual(proxy.count("require_parent_authority(authority)"), 3)
        self.assertIn("previous_umask = os.umask(0o177)", proxy)
        self.assertIn("elif bound:", proxy)
        self.assertIn("proxy socket identity unavailable for cleanup", proxy)
        self.assertIn("prove_listener_path(listener)", proxy)
        self.assertLess(
            proxy.index("prove_listener_path(listener)"), proxy.index("print(NONCE")
        )
        self.assertIn('socket.create_connection(("127.0.0.1", PORT), 5.0)', proxy)
        self.assertIn(f"{MODULE.AGENT_AUTH_PROXY_CONTEXT!r} + challenge", proxy)
        self.assertIn(
            f"{MODULE.AGENT_AUTH_GATE_CONTEXT!r} + challenge + response",
            proxy,
        )
        self.assertGreaterEqual(proxy.count("hmac.compare_digest"), 2)
        self.assertIn("def wait_for_parent(worker):", proxy)
        self.assertIn('raise RuntimeError("proxy accept loop exited")', proxy)
        self.assertIn("stream.shutdown(socket.SHUT_RDWR)", proxy)
        self.assertLess(
            proxy.index("authenticate_upstream()"), proxy.index("print(NONCE")
        )
        self.assertIn("remove_owned_socket(identity)", proxy)
        self.assertIn("remove_owned_directory(SOCKET_PATH.parent", proxy)
        self.assertIn("container SSH-agent proxy cleanup failed", proxy)
        compile(proxy, "<container-agent-proxy>", "exec")

    def test_container_proxy_mutual_auth_relay_and_cleanup_canary(self) -> None:
        """The embedded proxy authenticates both peers, relays, and retires its path."""
        short_tmp = pathlib.Path("/tmp").resolve(strict=True)
        token = os.urandom(MODULE.AGENT_AUTH_TOKEN_BYTES)
        nonce = "proxy-ready"
        request = b"agent-request"
        reply = b"agent-response"
        gate_errors: list[BaseException] = []
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            server.bind(("127.0.0.1", 0))
        except PermissionError as error:
            server.close()
            self.skipTest(f"loopback TCP is unavailable: {error}")
        server.listen(2)
        server.settimeout(5.0)
        port = server.getsockname()[1]

        def serve_gate() -> None:
            try:
                for index in range(2):
                    connection, _address = server.accept()
                    with connection:
                        connection.settimeout(5.0)
                        challenge = (
                            bytes((65 + index,)) * MODULE.AGENT_AUTH_CHALLENGE_BYTES
                        )
                        connection.sendall(challenge)
                        response = MODULE.receive_exact_socket(
                            connection,
                            MODULE.AGENT_AUTH_RESPONSE_BYTES,
                        )
                        expected = MODULE.agent_proxy_response(token, challenge)
                        if response != expected:
                            raise AssertionError("proxy response did not authenticate")
                        connection.sendall(
                            MODULE.agent_gate_acknowledgement(
                                token,
                                challenge,
                                response,
                            )
                        )
                        if index == 1:
                            payload = MODULE.receive_exact_socket(
                                connection,
                                len(request),
                            )
                            if payload != request:
                                raise AssertionError("proxy payload did not reach gate")
                            connection.sendall(reply)
            except BaseException as error:  # noqa: BLE001 - return thread failure
                gate_errors.append(error)

        gate_thread = threading.Thread(target=serve_gate)
        gate_thread.start()
        process: subprocess.Popen[bytes] | None = None
        finished = False
        with tempfile.TemporaryDirectory(prefix="nvp.", dir=short_tmp) as base:
            proxy_directory = pathlib.Path(base) / "p"
            proxy_socket = proxy_directory / "agent.sock"
            try:
                process = subprocess.Popen(
                    [
                        sys.executable,
                        "-I",
                        "-S",
                        "-c",
                        MODULE.CONTAINER_AGENT_PROXY,
                        str(proxy_socket),
                        str(port),
                        nonce,
                    ],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                assert process.stdin is not None
                process.stdin.write(token.hex().encode("ascii") + b"\n")
                process.stdin.flush()
                self.assertEqual(self.read_process_line(process), f"{nonce}\n".encode())
                self.assertEqual(stat.S_IMODE(proxy_directory.stat().st_mode), 0o700)
                self.assertEqual(stat.S_IMODE(proxy_socket.stat().st_mode), 0o600)
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.settimeout(5.0)
                    client.connect(os.fspath(proxy_socket))
                    client.sendall(request)
                    self.assertEqual(
                        MODULE.receive_exact_socket(client, len(reply)),
                        reply,
                    )
                code, remaining_stdout, stderr = self.finish_process(process)
                finished = True
                self.assertEqual(code, 0, stderr.decode("utf-8", "replace"))
                self.assertEqual(remaining_stdout, b"")
                self.assertEqual(stderr, b"")
                self.assertFalse(proxy_socket.exists())
                self.assertFalse(proxy_directory.exists())
            finally:
                if process is not None and not finished:
                    self.finish_process(process)
                server.close()
                gate_thread.join(timeout=6.0)
        self.assertFalse(gate_thread.is_alive())
        if gate_errors:
            raise gate_errors[0]

    def test_container_proxy_rejects_bad_gate_ack_and_cleans_up(self) -> None:
        """The embedded proxy publishes no readiness after a forged gate ACK."""
        short_tmp = pathlib.Path("/tmp").resolve(strict=True)
        token = os.urandom(MODULE.AGENT_AUTH_TOKEN_BYTES)
        nonce = "must-not-be-ready"
        gate_errors: list[BaseException] = []
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            server.bind(("127.0.0.1", 0))
        except PermissionError as error:
            server.close()
            self.skipTest(f"loopback TCP is unavailable: {error}")
        server.listen(1)
        server.settimeout(5.0)
        port = server.getsockname()[1]

        def serve_bad_gate() -> None:
            try:
                connection, _address = server.accept()
                with connection:
                    connection.settimeout(5.0)
                    challenge = b"x" * MODULE.AGENT_AUTH_CHALLENGE_BYTES
                    connection.sendall(challenge)
                    response = MODULE.receive_exact_socket(
                        connection,
                        MODULE.AGENT_AUTH_RESPONSE_BYTES,
                    )
                    if response != MODULE.agent_proxy_response(token, challenge):
                        raise AssertionError("proxy response did not authenticate")
                    connection.sendall(b"!" * MODULE.AGENT_AUTH_ACK_BYTES)
            except BaseException as error:  # noqa: BLE001 - return thread failure
                gate_errors.append(error)

        gate_thread = threading.Thread(target=serve_bad_gate)
        gate_thread.start()
        process: subprocess.Popen[bytes] | None = None
        finished = False
        with tempfile.TemporaryDirectory(prefix="nvp.", dir=short_tmp) as base:
            proxy_directory = pathlib.Path(base) / "p"
            proxy_socket = proxy_directory / "agent.sock"
            try:
                process = subprocess.Popen(
                    [
                        sys.executable,
                        "-I",
                        "-S",
                        "-c",
                        MODULE.CONTAINER_AGENT_PROXY,
                        str(proxy_socket),
                        str(port),
                        nonce,
                    ],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                assert process.stdin is not None
                process.stdin.write(token.hex().encode("ascii") + b"\n")
                process.stdin.flush()
                self.assertEqual(self.read_process_line(process), b"")
                code, remaining_stdout, stderr = self.finish_process(process)
                finished = True
                self.assertEqual(code, 1)
                self.assertEqual(remaining_stdout, b"")
                self.assertIn(b"relay authentication failed", stderr)
                self.assertNotIn(nonce.encode(), stderr)
                self.assertFalse(proxy_socket.exists())
                self.assertFalse(proxy_directory.exists())
            finally:
                if process is not None and not finished:
                    self.finish_process(process)
                server.close()
                gate_thread.join(timeout=6.0)
        self.assertFalse(gate_thread.is_alive())
        if gate_errors:
            raise gate_errors[0]

    def test_container_proxy_cleanup_failure_is_a_nonzero_exit(self) -> None:
        """An exact directory-retirement failure remains visible to supervision."""
        short_tmp = pathlib.Path("/tmp").resolve(strict=True)
        token = os.urandom(MODULE.AGENT_AUTH_TOKEN_BYTES)
        nonce = "cleanup-ready"
        gate_errors: list[BaseException] = []
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            server.bind(("127.0.0.1", 0))
        except PermissionError as error:
            server.close()
            self.skipTest(f"loopback TCP is unavailable: {error}")
        server.listen(1)
        server.settimeout(5.0)
        port = server.getsockname()[1]

        def serve_gate() -> None:
            try:
                connection, _address = server.accept()
                with connection:
                    connection.settimeout(5.0)
                    challenge = b"z" * MODULE.AGENT_AUTH_CHALLENGE_BYTES
                    connection.sendall(challenge)
                    response = MODULE.receive_exact_socket(
                        connection,
                        MODULE.AGENT_AUTH_RESPONSE_BYTES,
                    )
                    if response != MODULE.agent_proxy_response(token, challenge):
                        raise AssertionError("proxy response did not authenticate")
                    connection.sendall(
                        MODULE.agent_gate_acknowledgement(
                            token,
                            challenge,
                            response,
                        )
                    )
            except BaseException as error:  # noqa: BLE001 - return thread failure
                gate_errors.append(error)

        gate_thread = threading.Thread(target=serve_gate)
        gate_thread.start()
        process: subprocess.Popen[bytes] | None = None
        finished = False
        with tempfile.TemporaryDirectory(prefix="nvp.", dir=short_tmp) as base:
            proxy_directory = pathlib.Path(base) / "p"
            proxy_socket = proxy_directory / "agent.sock"
            obstruction = proxy_directory / "preserve-me"
            try:
                process = subprocess.Popen(
                    [
                        sys.executable,
                        "-I",
                        "-S",
                        "-c",
                        MODULE.CONTAINER_AGENT_PROXY,
                        str(proxy_socket),
                        str(port),
                        nonce,
                    ],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                assert process.stdin is not None
                process.stdin.write(token.hex().encode("ascii") + b"\n")
                process.stdin.flush()
                self.assertEqual(self.read_process_line(process), f"{nonce}\n".encode())
                obstruction.write_text("do not delete\n", encoding="utf-8")
                code, remaining_stdout, stderr = self.finish_process(process)
                finished = True
                self.assertEqual(code, 1)
                self.assertEqual(remaining_stdout, b"")
                self.assertIn(b"proxy directory cleanup failed", stderr)
                self.assertFalse(proxy_socket.exists())
                self.assertTrue(proxy_directory.is_dir())
                self.assertEqual(
                    obstruction.read_text(encoding="utf-8"),
                    "do not delete\n",
                )
            finally:
                if process is not None and not finished:
                    self.finish_process(process)
                server.close()
                gate_thread.join(timeout=6.0)
                if obstruction.exists():
                    obstruction.unlink()
                if proxy_directory.exists():
                    proxy_directory.rmdir()
        self.assertFalse(gate_thread.is_alive())
        if gate_errors:
            raise gate_errors[0]

    def test_container_proxy_cleanup_preserves_a_replacement_socket(self) -> None:
        """Proxy retirement rejects and preserves a replacement pathname inode."""
        short_tmp = pathlib.Path("/tmp").resolve(strict=True)
        token = os.urandom(MODULE.AGENT_AUTH_TOKEN_BYTES)
        nonce = "replacement-ready"
        gate_errors: list[BaseException] = []
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            server.bind(("127.0.0.1", 0))
        except PermissionError as error:
            server.close()
            self.skipTest(f"loopback TCP is unavailable: {error}")
        server.listen(1)
        server.settimeout(5.0)
        port = server.getsockname()[1]

        def serve_gate() -> None:
            try:
                connection, _address = server.accept()
                with connection:
                    connection.settimeout(5.0)
                    challenge = b"r" * MODULE.AGENT_AUTH_CHALLENGE_BYTES
                    connection.sendall(challenge)
                    response = MODULE.receive_exact_socket(
                        connection,
                        MODULE.AGENT_AUTH_RESPONSE_BYTES,
                    )
                    if response != MODULE.agent_proxy_response(token, challenge):
                        raise AssertionError("proxy response did not authenticate")
                    connection.sendall(
                        MODULE.agent_gate_acknowledgement(
                            token,
                            challenge,
                            response,
                        )
                    )
            except BaseException as error:  # noqa: BLE001 - return thread failure
                gate_errors.append(error)

        gate_thread = threading.Thread(target=serve_gate)
        gate_thread.start()
        process: subprocess.Popen[bytes] | None = None
        replacement: socket.socket | None = None
        finished = False
        with tempfile.TemporaryDirectory(prefix="nvp.", dir=short_tmp) as base:
            proxy_directory = pathlib.Path(base) / "p"
            proxy_socket = proxy_directory / "agent.sock"
            try:
                process = subprocess.Popen(
                    [
                        sys.executable,
                        "-I",
                        "-S",
                        "-c",
                        MODULE.CONTAINER_AGENT_PROXY,
                        str(proxy_socket),
                        str(port),
                        nonce,
                    ],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                assert process.stdin is not None
                process.stdin.write(token.hex().encode("ascii") + b"\n")
                process.stdin.flush()
                self.assertEqual(self.read_process_line(process), f"{nonce}\n".encode())
                original = proxy_socket.lstat()
                proxy_socket.unlink()
                replacement = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                replacement.bind(os.fspath(proxy_socket))
                replacement_details = proxy_socket.lstat()
                self.assertNotEqual(replacement_details.st_ino, original.st_ino)

                code, remaining_stdout, stderr = self.finish_process(process)
                finished = True
                self.assertEqual(code, 1)
                self.assertEqual(remaining_stdout, b"")
                self.assertIn(b"proxy socket changed before cleanup", stderr)
                current = proxy_socket.lstat()
                self.assertEqual(current.st_ino, replacement_details.st_ino)
                self.assertEqual(current.st_dev, replacement_details.st_dev)
            finally:
                if process is not None and not finished:
                    self.finish_process(process)
                server.close()
                gate_thread.join(timeout=6.0)
                MODULE.close_socket(replacement)
                with contextlib.suppress(FileNotFoundError):
                    proxy_socket.unlink()
                if proxy_directory.exists():
                    proxy_directory.rmdir()
        self.assertFalse(gate_thread.is_alive())
        if gate_errors:
            raise gate_errors[0]

    def test_relay_gate_rejects_a_replayed_response_before_agent_connect(self) -> None:
        """A response for another challenge cannot reach the host SSH agent."""
        forwarding = self.relay_forwarding_fixture(pin_id="9" * 64)
        host = forwarding.host
        assert host is not None
        gate = MODULE.HostAgentGate(self.paths, host)
        old_challenge = b"o" * MODULE.AGENT_AUTH_CHALLENGE_BYTES
        challenge = b"n" * MODULE.AGENT_AUTH_CHALLENGE_BYTES
        replay = MODULE.agent_proxy_response(gate.token, old_challenge)
        client = mock.Mock(spec=socket.socket)
        client.recv.return_value = replay
        with (
            mock.patch.object(MODULE.secrets, "token_bytes", return_value=challenge),
            mock.patch.object(MODULE.socket, "socket") as open_agent,
        ):
            self.assertIsNone(gate._authenticated_host_connection(client))
        client.sendall.assert_called_once_with(challenge)
        open_agent.assert_not_called()

    def test_relay_gate_connects_only_after_current_challenge_authentication(
        self,
    ) -> None:
        """A current HMAC response revalidates authority before opening the agent."""
        forwarding = self.relay_forwarding_fixture(pin_id="b" * 64)
        host = forwarding.host
        assert host is not None
        gate = MODULE.HostAgentGate(self.paths, host)
        challenge = b"c" * MODULE.AGENT_AUTH_CHALLENGE_BYTES
        response = MODULE.agent_proxy_response(gate.token, challenge)
        acknowledgement = MODULE.agent_gate_acknowledgement(
            gate.token,
            challenge,
            response,
        )
        client = mock.Mock(spec=socket.socket)
        client.recv.return_value = response
        upstream = mock.Mock(spec=socket.socket)
        with (
            mock.patch.object(MODULE.secrets, "token_bytes", return_value=challenge),
            mock.patch.object(MODULE, "revalidate_host_agent") as revalidate,
            mock.patch.object(MODULE.socket, "socket", return_value=upstream),
        ):
            actual = gate._authenticated_host_connection(client)
        self.assertIs(actual, upstream)
        self.assertEqual(
            client.sendall.call_args_list,
            [mock.call(challenge), mock.call(acknowledgement)],
        )
        revalidate.assert_called_once_with(host)
        upstream.settimeout.assert_called_once_with(5.0)
        upstream.connect.assert_called_once_with(os.fspath(host.path))

    def test_relay_gate_start_preserves_its_primary_when_retirement_fails(
        self,
    ) -> None:
        """Partial startup cleanup reports both failures after closing the listener."""
        forwarding = self.relay_forwarding_fixture(pin_id="1" * 64)
        host = forwarding.host
        assert host is not None
        gate = MODULE.HostAgentGate(self.paths, host)
        gate.path = self.root / "gate.sock"
        gate.name = gate.path.name
        listener = mock.Mock(spec=socket.socket)
        listener.bind.side_effect = MODULE.EditorError("bind failed")
        with (
            mock.patch.object(MODULE, "revalidate_directory_path"),
            mock.patch.object(MODULE, "revalidate_host_agent"),
            mock.patch.object(MODULE.socket, "socket", return_value=listener),
            mock.patch.object(
                gate,
                "_retire_socket",
                side_effect=MODULE.EditorError("retirement failed"),
            ),
            self.assertRaisesRegex(
                MODULE.EditorError,
                "bind failed; host SSH-agent gate startup cleanup failed: "
                "retirement failed",
            ),
        ):
            gate.start()
        listener.close.assert_called_once_with()

    def test_relay_gate_thread_start_failure_leaves_cleanup_retryable(self) -> None:
        """A never-started accept thread cannot mask its original start failure."""
        forwarding = self.relay_forwarding_fixture(pin_id="a" * 64)
        host = forwarding.host
        assert host is not None
        gate = MODULE.HostAgentGate(self.paths, host)
        listener = mock.Mock(spec=socket.socket)
        accept_thread = mock.Mock(spec=threading.Thread)
        accept_thread.start.side_effect = RuntimeError("thread refused to start")
        details = mock.Mock()
        details.st_mode = stat.S_IFSOCK | 0o600
        details.st_uid = os.getuid()
        details.st_dev = 41
        details.st_ino = 42
        identity = MODULE.SocketIdentity(41, 42, os.getuid(), details.st_mode)
        real_umask = os.umask
        with (
            mock.patch.object(MODULE, "MAX_UNIX_SOCKET_PATH_BYTES", 4096),
            mock.patch.object(MODULE, "revalidate_directory_path"),
            mock.patch.object(MODULE, "revalidate_host_agent"),
            mock.patch.object(MODULE.socket, "socket", return_value=listener),
            mock.patch.object(MODULE.pathlib.Path, "lstat", return_value=details),
            mock.patch.object(MODULE.os, "chmod"),
            mock.patch.object(gate, "_socket_identity", return_value=identity),
            mock.patch.object(gate, "_retire_socket") as retire,
            mock.patch.object(
                MODULE.threading,
                "Thread",
                return_value=accept_thread,
            ),
            mock.patch.object(
                MODULE.os,
                "umask",
                wraps=real_umask,
            ) as set_umask,
            self.assertRaisesRegex(RuntimeError, "thread refused to start"),
        ):
            gate.start()
        self.assertEqual(set_umask.call_args_list[0], mock.call(0o177))
        self.assertEqual(len(set_umask.call_args_list), 2)
        self.assertIsNone(gate.listener)
        self.assertIsNone(gate.accept_thread)
        listener.close.assert_called_once_with()
        retire.assert_called_once_with()
        gate.close()
        self.assertTrue(gate.closed)
        accept_thread.join.assert_not_called()

    def test_relay_gate_accept_loop_survives_socket_timeout_on_python39(self) -> None:
        """An idle socket timeout remains a polling tick on the host runtime."""
        forwarding = self.relay_forwarding_fixture(pin_id="4" * 64)
        host = forwarding.host
        assert host is not None
        gate = MODULE.HostAgentGate(self.paths, host)
        listener = mock.Mock(spec=socket.socket)
        attempts = 0

        def accept() -> tuple[socket.socket, object]:
            nonlocal attempts
            attempts += 1
            if attempts == 1:
                raise socket.timeout("idle")  # noqa: UP041 - Apple Python 3.9
            gate.stop.set()
            raise OSError("closed")

        listener.accept.side_effect = accept
        gate._accept(listener)
        self.assertEqual(attempts, 2)
        self.assertIsNone(gate.failure)

    def test_relay_gate_records_a_non_timeout_accept_failure(self) -> None:
        """A real accept error exits the loop and remains visible to supervision."""
        forwarding = self.relay_forwarding_fixture(pin_id="7" * 64)
        host = forwarding.host
        assert host is not None
        gate = MODULE.HostAgentGate(self.paths, host)
        listener = mock.Mock(spec=socket.socket)
        listener.accept.side_effect = OSError("listener failed")

        gate._accept(listener)

        self.assertEqual(
            gate.failure,
            "host SSH-agent gate accept failed: listener failed",
        )
        listener.accept.assert_called_once_with()

    def test_relay_gate_rejects_an_overlong_unix_socket_path(self) -> None:
        """AF_UNIX path bounds fail before metadata checks or socket creation."""
        forwarding = self.relay_forwarding_fixture(pin_id="8" * 64)
        host = forwarding.host
        assert host is not None
        gate = MODULE.HostAgentGate(self.paths, host)
        gate.path = pathlib.Path("/tmp") / (
            "x" * (MODULE.MAX_UNIX_SOCKET_PATH_BYTES + 1)
        )
        gate.name = gate.path.name
        with (
            mock.patch.object(MODULE, "revalidate_directory_path") as revalidate,
            mock.patch.object(MODULE, "revalidate_host_agent") as revalidate_agent,
            mock.patch.object(MODULE.socket, "socket") as open_socket,
            self.assertRaisesRegex(MODULE.EditorError, "exceeds the Unix path limit"),
        ):
            gate.start()
        revalidate.assert_not_called()
        revalidate_agent.assert_not_called()
        open_socket.assert_not_called()

    def test_relay_gate_close_cannot_observe_an_unstarted_worker(self) -> None:
        """Worker publication and shutdown are serialized across Thread.start."""
        forwarding = self.relay_forwarding_fixture(pin_id="5" * 64)
        host = forwarding.host
        assert host is not None
        gate = MODULE.HostAgentGate(self.paths, host)
        client = mock.Mock(spec=socket.socket)
        worker = mock.Mock(spec=threading.Thread)
        start_entered = threading.Event()
        release_start = threading.Event()
        close_entered = threading.Event()
        premature_join = threading.Event()
        worker_started = False
        failures: list[BaseException] = []

        def delayed_start() -> None:
            nonlocal worker_started
            start_entered.set()
            if not release_start.wait(2.0):
                raise RuntimeError("test did not release worker start")
            worker_started = True

        def guarded_join(_timeout: float) -> None:
            if not worker_started:
                premature_join.set()
                raise RuntimeError("cannot join thread before it is started")

        def start_worker() -> None:
            try:
                gate._start_worker(client)
            except BaseException as error:  # noqa: BLE001 - return thread failure
                failures.append(error)

        def close_gate() -> None:
            close_entered.set()
            try:
                gate.close()
            except BaseException as error:  # noqa: BLE001 - return thread failure
                failures.append(error)

        worker.start.side_effect = delayed_start
        worker.join.side_effect = guarded_join
        worker.is_alive.return_value = False
        starter = threading.Thread(target=start_worker)
        closer = threading.Thread(target=close_gate)
        with mock.patch.object(MODULE.threading, "Thread", return_value=worker):
            starter.start()
            self.assertTrue(start_entered.wait(2.0))
            closer.start()
            self.assertTrue(close_entered.wait(2.0))
            self.assertFalse(premature_join.wait(0.2))
            release_start.set()
            starter.join(2.0)
            closer.join(2.0)

        self.assertFalse(starter.is_alive())
        self.assertFalse(closer.is_alive())
        self.assertEqual(failures, [])
        worker.start.assert_called_once_with()
        worker.join.assert_called_once()
        self.assertTrue(gate.stop.is_set())
        self.assertTrue(gate.closed)
        client.close.assert_called()

    def test_relay_gate_close_unblocks_a_backpressured_worker(self) -> None:
        """Full-duplex shutdown releases a worker blocked in peer sendall."""
        forwarding = self.relay_forwarding_fixture(pin_id="6" * 64)
        host = forwarding.host
        assert host is not None
        gate = MODULE.HostAgentGate(self.paths, host)
        left, left_peer = socket.socketpair()
        right, right_peer = socket.socketpair()
        entered = threading.Event()
        released = threading.Event()
        failures: list[BaseException] = []

        class BackpressuredStream:
            def fileno(self) -> int:
                return right.fileno()

            def recv(self, size: int) -> bytes:
                return right.recv(size)

            def sendall(self, _payload: bytes) -> None:
                entered.set()
                if not released.wait(5.0):
                    raise TimeoutError("test relay remained backpressured")

            def shutdown(self, how: int) -> None:
                released.set()
                right.shutdown(how)

            def close(self) -> None:
                right.close()

        blocked = BackpressuredStream()

        def relay() -> None:
            try:
                MODULE.relay_socket_pair(left, blocked, gate.stop)
            except OSError:
                pass
            except BaseException as error:  # noqa: BLE001 - return thread failure
                failures.append(error)

        worker = threading.Thread(target=relay)
        gate.active.update((left, blocked))
        gate.workers.add(worker)
        try:
            worker.start()
            left_peer.sendall(b"blocked-agent-frame")
            self.assertTrue(entered.wait(2.0))
            gate.close()
            worker.join(2.0)
            self.assertFalse(worker.is_alive())
            self.assertEqual(failures, [])
            self.assertTrue(gate.closed)
        finally:
            released.set()
            MODULE.close_socket(left)
            MODULE.close_socket(left_peer)
            MODULE.close_socket(right)
            MODULE.close_socket(right_peer)
            worker.join(2.0)

    def test_relay_gate_close_finishes_cleanup_after_an_interrupted_join(self) -> None:
        """A join interruption is retryable after all remaining cleanup runs."""
        forwarding = self.relay_forwarding_fixture(pin_id="2" * 64)
        host = forwarding.host
        assert host is not None
        gate = MODULE.HostAgentGate(self.paths, host)
        listener = mock.Mock(spec=socket.socket)
        accept_thread = mock.Mock(spec=threading.Thread)
        accept_thread.join.side_effect = KeyboardInterrupt()
        accept_thread.is_alive.return_value = False
        gate.listener = listener
        gate.accept_thread = accept_thread
        with self.assertRaisesRegex(MODULE.EditorError, "cleanup was interrupted"):
            gate.close()
        self.assertTrue(gate.closed)
        listener.close.assert_called_once_with()
        gate.close()

    def test_relay_proxy_argv_pins_container_without_exposing_auth_token(self) -> None:
        """The container proxy uses an exact ID while its token stays on stdin."""
        relay = MODULE.PodmanAgentRelay(
            self.paths,
            self.repo,
            self.relay_forwarding_fixture(pin_id="a" * 64),
            str(self.docker),
        )
        relay.port = 60002
        container_id = "d" * 64
        nonce = "e" * 64
        argv = relay._proxy_argv(str(self.cli), self.config, container_id, nonce)
        self.assertEqual(argv[0:2], [str(self.cli), "exec"])
        self.assertEqual(argv[argv.index("--container-id") + 1], container_id)
        self.assertEqual(argv[-3:], [relay.container_socket, "60002", nonce])
        python = argv.index("/usr/bin/python3")
        self.assertEqual(
            argv[python : python + 4], ["/usr/bin/python3", "-I", "-S", "-c"]
        )
        rendered = "\n".join(argv)
        self.assertNotIn(relay.gate.token.hex(), rendered)
        self.assertNotIn(str(relay.host_agent.path), rendered)
        self.assertEqual(len(relay.gate.token_line), MODULE.AGENT_AUTH_FRAME_BYTES)

    def test_relay_parent_stdin_is_an_idempotent_eof_leash(self) -> None:
        """Closing twice synchronously reaps both leashed relay children."""
        plan = self.relay_forwarding_fixture(pin_id="e" * 64)
        relay = MODULE.PodmanAgentRelay(self.paths, self.repo, plan, "/managed/podman")
        relay.process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import sys; print('ssh-ready', flush=True); sys.stdin.buffer.read()",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        relay.proxy_process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                "import sys; print('proxy-ready', flush=True); sys.stdin.buffer.read()",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        ssh_process = relay.process
        proxy_process = relay.proxy_process
        relay._wait_ready("ssh-ready")
        relay._wait_ready(
            "proxy-ready",
            proxy_process,
            "Podman SSH-agent container proxy",
            relay.proxy_stderr,
        )
        self.assertIsNone(ssh_process.poll())
        self.assertIsNone(proxy_process.poll())
        relay.close()
        relay.close()
        self.assertEqual(ssh_process.poll(), 0)
        self.assertEqual(proxy_process.poll(), 0)

    def test_relay_close_surfaces_reaped_proxy_cleanup_failure_once(self) -> None:
        """A nonzero leashed proxy is reported but not retained for a false retry."""
        plan = self.relay_forwarding_fixture(pin_id="d" * 64)
        relay = MODULE.PodmanAgentRelay(self.paths, self.repo, plan, "/managed/podman")
        relay.proxy_process = subprocess.Popen(
            [
                sys.executable,
                "-c",
                (
                    "import sys; sys.stdin.buffer.read(); "
                    "sys.stderr.write('exact proxy retirement failed'); "
                    "raise SystemExit(17)"
                ),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        process = relay.proxy_process
        with self.assertRaises(MODULE.EditorError) as raised:
            relay.close()
        message = str(raised.exception)
        self.assertIn("container proxy exited 17", message)
        self.assertIn("exact proxy retirement failed", message)
        self.assertIsNone(relay.proxy_process)
        self.assertEqual(process.poll(), 17)
        self.assertFalse(relay.closed)
        relay.close()
        self.assertTrue(relay.closed)

    def test_relay_readiness_failure_includes_safe_ssh_diagnostics(self) -> None:
        """Early SSH failures retain useful text without terminal controls."""
        relay = object.__new__(MODULE.PodmanAgentRelay)
        relay.stderr = bytearray()
        relay.proxy_stderr = bytearray()
        script = (
            "import sys;sys.stderr.write("
            "'\\x1b[31mauth failed\\x1b[0m\\x1b]0;title\\x07')"
        )
        relay.process = subprocess.Popen(
            [sys.executable, "-c", script],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        process = relay.process
        try:
            with self.assertRaises(MODULE.EditorError) as raised:
                relay._wait_ready("expected")
            message = str(raised.exception)
            self.assertIn("auth failed", message)
            self.assertNotIn("\x1b", message)
            self.assertNotIn("title", message)
        finally:
            MODULE.stop_and_reap_process(process)
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()

    def test_relay_wait_treats_wait_and_poll_oserrors_as_not_reaped(self) -> None:
        """Cleanup never leaks raw process inspection errors."""
        process = mock.Mock(spec=subprocess.Popen)
        process.wait.side_effect = ChildProcessError("wait failed")
        process.poll.side_effect = ChildProcessError("poll failed")
        self.assertFalse(MODULE.PodmanAgentRelay._wait_process(process, 0.1))

    def test_relay_close_retries_after_an_interrupted_wait(self) -> None:
        """Cleanup remains retryable until the SSH child is synchronously reaped."""
        plan = self.relay_forwarding_fixture(pin_id="f" * 64)
        relay = MODULE.PodmanAgentRelay(self.paths, self.repo, plan, "/managed/podman")
        process = mock.Mock(spec=subprocess.Popen)
        process.stdin = mock.Mock(closed=False)
        process.stdout = mock.Mock(closed=False)
        process.stderr = mock.Mock(closed=False)
        process.wait.side_effect = [KeyboardInterrupt(), None]
        process.poll.side_effect = [None, 0]
        relay.process = process
        relay.close()
        process.stdin.close.assert_called_once_with()
        process.terminate.assert_called_once_with()
        process.kill.assert_not_called()
        self.assertIsNone(relay.process)
        self.assertTrue(relay.closed)

    def test_relay_cleanup_never_masks_non_exception_control_flow(self) -> None:
        """Cleanup failure annotates KeyboardInterrupt but does not replace it."""
        primary = KeyboardInterrupt()
        cleanup = MODULE.EditorError("relay remained alive")
        with mock.patch.object(MODULE, "warn_nonfatal") as warn:
            MODULE.propagate_relay_cleanup_failure(primary, cleanup)
        warn.assert_called_once()
        with self.assertRaisesRegex(MODULE.EditorError, "relay remained alive"):
            MODULE.propagate_relay_cleanup_failure(None, cleanup)

    def test_owned_process_cleanup_survives_terminate_errors(self) -> None:
        """Cleanup still kills and reaps when graceful termination itself fails."""
        process = mock.Mock(spec=subprocess.Popen)
        process.poll.return_value = None
        process.terminate.side_effect = PermissionError("terminate denied")
        process.wait.side_effect = [
            subprocess.TimeoutExpired(["probe"], 2.0),
            0,
        ]
        MODULE.stop_and_reap_process(process)
        process.kill.assert_called_once_with()
        self.assertEqual(process.wait.call_count, 2)

    def test_relay_diagnostic_drain_has_a_per_poll_budget(self) -> None:
        """Neither noisy relay child can monopolize lifecycle reconciliation."""
        relay = object.__new__(MODULE.PodmanAgentRelay)
        relay.stderr = bytearray()
        relay.proxy_stderr = bytearray()
        relay.process = mock.Mock(spec=subprocess.Popen)
        relay.process.stderr = mock.Mock()
        relay.process.stderr.closed = False
        relay.process.stderr.fileno.return_value = 17
        relay.proxy_process = mock.Mock(spec=subprocess.Popen)
        relay.proxy_process.stderr = mock.Mock()
        relay.proxy_process.stderr.closed = False
        relay.proxy_process.stderr.fileno.return_value = 18
        with mock.patch.object(
            MODULE.os,
            "read",
            return_value=b"x" * 65536,
        ) as read:
            relay._drain_stderr()
        self.assertEqual(
            read.call_count,
            2 * MODULE.MAX_RELAY_DRAIN_BYTES // 65536,
        )
        self.assertEqual(len(relay.stderr), MODULE.MAX_RELAY_STDERR_BYTES)
        self.assertEqual(len(relay.proxy_stderr), MODULE.MAX_RELAY_STDERR_BYTES)

    def test_relay_exit_diagnostic_strips_terminal_controls(self) -> None:
        """Untrusted SSH diagnostics cannot inject controls into records or toasts."""
        relay = MODULE.PodmanAgentRelay(
            self.paths,
            self.repo,
            self.relay_forwarding_fixture(pin_id="6" * 64),
            "/managed/podman",
        )
        relay.stderr = bytearray(b"\x1b[31mfailure\x1b[0m\x1b]0;title\x07")
        relay.proxy_stderr = bytearray(b"\x1b[32mproxy failed\x1b[0m")
        relay.process = mock.Mock(spec=subprocess.Popen)
        relay.process.poll.return_value = None
        relay.proxy_process = mock.Mock(spec=subprocess.Popen)
        relay.proxy_process.poll.return_value = 17
        with (
            mock.patch.object(relay, "_drain_stderr"),
            mock.patch.object(relay, "_stop_owned_components"),
            self.assertRaises(MODULE.EditorError) as raised,
        ):
            relay.check()
        message = str(raised.exception)
        self.assertIn("container proxy exited 17", message)
        self.assertIn("failure", message)
        self.assertIn("proxy failed", message)
        self.assertNotIn("\x1b", message)
        self.assertNotIn("title", message)

    def test_external_up_detects_a_spool_root_swap_after_the_call(self) -> None:
        """The lifecycle fails closed when the lexical mount source changes during up."""
        command, _ = MODULE.up_argv(
            "/managed/devcontainer",
            "/managed/podman",
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

        def swap_root(
            *_args: object, **_kwargs: object
        ) -> subprocess.CompletedProcess[bytes]:
            self.spool.root.rename(pinned)
            self.spool.root.symlink_to(outside, target_is_directory=True)
            return subprocess.CompletedProcess(command, 0, b"{}", b"")

        with (
            mock.patch.object(MODULE, "run_streamed_up", side_effect=swap_root),
            self.assertRaisesRegex(
                MODULE.EditorError,
                "no longer names its pinned directory",
            ),
        ):
            MODULE.run_up_with_pinned_spool(
                command,
                self.spool,
                1.0,
                MODULE.log_path(self.paths, self.repo),
            )

    def test_streamed_up_is_live_concurrent_bounded_and_decodable(self) -> None:
        """Stderr is visible before exit while large output cannot deadlock stdout."""
        proceed = self.root / "stream-proceed"
        ready = self.root / "stream-ready"
        release = self.root / "stream-release"
        script = (
            "import json, pathlib, sys, time\n"
            "proceed, ready, release = map(pathlib.Path, sys.argv[1:])\n"
            "print(json.dumps({'type':'start','text':'initial build'}), file=sys.stderr, flush=True)\n"
            "while not proceed.exists(): time.sleep(0.005)\n"
            "print(json.dumps({'containerId':'abc','remoteWorkspaceFolder':'/workspaces/repo'}), flush=True)\n"
            "for index in range(6000):\n"
            " print(json.dumps({'type':'progress','text':'bulk-' + str(index) + '-' + ('x' * 80)}), file=sys.stderr)\n"
            "sys.stderr.flush()\n"
            "ready.touch()\n"
            "while not release.exists(): time.sleep(0.005)"
        )
        command = [sys.executable, "-c", script, str(proceed), str(ready), str(release)]
        log = MODULE.log_path(self.paths, self.repo)
        outcome: dict[str, object] = {}

        def invoke() -> None:
            try:
                outcome["result"] = MODULE.run_up_with_pinned_spool(
                    command, self.spool, 10.0, log
                )
            except Exception as error:  # noqa: BLE001 - propagate thread failures
                outcome["error"] = error

        worker = threading.Thread(target=invoke)
        worker.start()
        try:
            deadline = time.monotonic() + 5.0
            while time.monotonic() < deadline:
                if log.exists() and "initial build" in log.read_text(encoding="utf-8"):
                    break
                time.sleep(0.01)
            else:
                self.fail("initial stderr was not visible while devcontainer up ran")
            self.assertTrue(worker.is_alive())
            proceed.touch()
            deadline = time.monotonic() + 5.0
            while time.monotonic() < deadline and not ready.exists():
                time.sleep(0.01)
            self.assertTrue(ready.exists(), "interleaved output blocked on a full pipe")
            self.assertTrue(worker.is_alive())
        finally:
            proceed.touch(exist_ok=True)
            release.touch(exist_ok=True)
            worker.join(timeout=5.0)

        self.assertFalse(worker.is_alive())
        self.assertNotIn("error", outcome)
        result = outcome["result"]
        assert isinstance(result, subprocess.CompletedProcess)
        self.assertEqual(MODULE.decode_up(result), ("abc", "/workspaces/repo"))
        content = log.read_bytes()
        self.assertLessEqual(len(content), MODULE.MAX_LOG_BYTES)
        self.assertTrue(content.startswith(MODULE.LOG_TRUNCATION_MARKER))
        self.assertIn(b"bulk-5999", content)
        details = log.stat()
        self.assertEqual(stat.S_IMODE(details.st_mode), 0o600)
        self.assertEqual(details.st_nlink, 1)

    def test_json_log_frames_are_fragment_safe_and_terminal_sanitized(self) -> None:
        """Known and malformed CLI frames stay readable without terminal controls."""
        log = MODULE.log_path(self.paths, self.repo)
        with MODULE.LifecycleLogWriter(log) as writer:
            stream = MODULE.DevcontainerLogStream(writer)
            stream.feed(b'{"type":"sta')
            stream.feed(b'rt","text":"Build image"}\r\n')
            stream.feed(
                b'{"type":"raw","content":{"type":"Buffer","data":[114,97,119]}}\n'
            )
            stream.feed(b'{"type":"stop","description":"Build image"}\n')
            stream.feed(
                b'{"type":"progress","name":"Features","status":"running",'
                b'"stepDetail":"Downloading"}\n'
            )
            stream.feed(b'{"type":"unknown","message":"\u001b[31munknown\u001b[0m"}\n')
            stream.feed(b"malformed \xff \x00 \x1b[31mred\x1b[0m \x1b]0;title\x07end\r")
            stream.feed(b"x" * (MODULE.MAX_LOG_EVENT_BYTES + 20) + b"\n")
            stream.finish()

        content = log.read_text(encoding="utf-8")
        self.assertIn("[start] Build image", content)
        self.assertIn("devcontainer: raw", content)
        self.assertIn("[stop] Build image", content)
        self.assertIn("[progress] Features: running - Downloading", content)
        self.assertIn("[unknown]", content)
        self.assertIn("malformed �  red end", content)
        self.assertIn("[event truncated]", content)
        for control in ("\x00", "\x1b", "\x07", "\x9b", "title"):
            self.assertNotIn(control, content)

    def test_streamed_up_timeout_and_interrupt_reap_the_child(self) -> None:
        """Timeout and keyboard interruption terminate and reap the owned process."""
        log = MODULE.log_path(self.paths, self.repo)
        pid_file = self.root / "streamed-child.pid"
        script = (
            "import os, pathlib, sys, time\n"
            "pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))\n"
            "time.sleep(30)"
        )
        with (
            MODULE.LifecycleLogWriter(log) as writer,
            self.assertRaisesRegex(MODULE.EditorError, "timed out"),
        ):
            MODULE.run_streamed_up(
                [sys.executable, "-c", script, str(pid_file)], 0.5, writer
            )
        self.assertTrue(pid_file.exists())
        self.assertFalse(MODULE.pid_alive(int(pid_file.read_text(encoding="utf-8"))))

        process = mock.Mock()
        process.stdout = io.BytesIO()
        process.stderr = io.BytesIO()
        process.poll.return_value = None
        process.wait.return_value = 0
        with (
            MODULE.LifecycleLogWriter(log) as writer,
            mock.patch.object(MODULE.subprocess, "Popen", return_value=process),
            mock.patch.object(
                MODULE, "drain_up_process", side_effect=KeyboardInterrupt
            ),
            self.assertRaisesRegex(MODULE.EditorError, "cancelled"),
        ):
            MODULE.run_streamed_up(["/managed/devcontainer", "up"], 1.0, writer)
        process.terminate.assert_called_once_with()
        self.assertGreaterEqual(process.wait.call_count, 1)

    def test_streamed_up_rejects_oversized_stdout_after_draining_it(self) -> None:
        """The final JSON channel stays capped even when the child writes past it."""
        log = MODULE.log_path(self.paths, self.repo)
        script = (
            f"import sys;sys.stdout.buffer.write(b'x' * {MODULE.MAX_JSON_BYTES + 1})"
        )
        with (
            MODULE.LifecycleLogWriter(log) as writer,
            self.assertRaisesRegex(MODULE.EditorError, "exceeds 64 KiB"),
        ):
            MODULE.run_streamed_up([sys.executable, "-c", script], 5.0, writer)

    def test_streamed_up_cleanup_closes_pipes_without_masking_primary(self) -> None:
        """A reap failure is secondary, while both owned pipes still close."""
        process = mock.Mock(spec=subprocess.Popen)
        process.stdout = io.BytesIO(b"stdout")
        process.stderr = io.BytesIO(b"stderr")
        cleanup = MODULE.EditorError("child remained alive")
        primary = MODULE.EditorError("build failed")
        with (
            mock.patch.object(
                MODULE,
                "stop_and_reap_process",
                side_effect=cleanup,
            ),
            mock.patch.object(MODULE, "report_cleanup_failure") as report,
        ):
            MODULE.cleanup_streamed_up_process(process, primary)
        self.assertTrue(process.stdout.closed)
        self.assertTrue(process.stderr.closed)
        report.assert_called_once_with(
            primary,
            "devcontainer up cleanup failed",
            cleanup,
        )

        process.stdout = io.BytesIO(b"stdout")
        process.stderr = io.BytesIO(b"stderr")
        with (
            mock.patch.object(
                MODULE,
                "stop_and_reap_process",
                side_effect=cleanup,
            ),
            self.assertRaisesRegex(MODULE.EditorError, "child remained alive"),
        ):
            MODULE.cleanup_streamed_up_process(process, None)
        self.assertTrue(process.stdout.closed)
        self.assertTrue(process.stderr.closed)

    def test_up_exit_wait_keeps_supervising_the_relay(self) -> None:
        """Closed output pipes do not create an unsupervised process-wait window."""
        process = mock.Mock(spec=subprocess.Popen)
        process.args = ["devcontainer", "up"]
        process.wait.side_effect = [
            subprocess.TimeoutExpired(process.args, 0.1),
            None,
        ]
        relay = mock.Mock(spec=MODULE.PodmanAgentRelay)
        MODULE.wait_for_up_process(
            process,
            time.monotonic() + 1.0,
            1.0,
            relay,
        )
        self.assertEqual(relay.check.call_count, 2)

    def test_lifecycle_log_rejects_symlinks_without_touching_the_target(self) -> None:
        """A hostile log pathname cannot redirect streamed lifecycle output."""
        target = self.root / "outside-log"
        target.write_text("unchanged\n", encoding="utf-8")
        path = MODULE.log_path(self.paths, self.repo)
        path.symlink_to(target)
        with self.assertRaises(MODULE.EditorError):
            MODULE.append_log(path, "must not escape")
        self.assertEqual(target.read_text(encoding="utf-8"), "unchanged\n")

    def test_container_log_pager_follows_live_output(self) -> None:
        """The host popup pager follows appends instead of opening a static tail."""
        self.record("error")
        path = MODULE.log_path(self.paths, self.repo)
        MODULE.append_log(path, "lifecycle failed")
        arguments = argparse.Namespace(repo=str(self.repo), pager=True)
        with (
            mock.patch.object(MODULE, "prepare_state", return_value=self.paths),
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(MODULE.shutil, "which", return_value="/usr/bin/less"),
            mock.patch.object(
                MODULE.os,
                "execv",
                side_effect=RuntimeError("captured pager"),
            ) as execute,
            self.assertRaisesRegex(RuntimeError, "captured pager"),
        ):
            MODULE.cmd_log(arguments)
        execute.assert_called_once_with(
            "/usr/bin/less",
            ["/usr/bin/less", "+F", "-R", "--", str(path)],
        )

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
            with (
                self.subTest(container_root=container_root),
                self.assertRaisesRegex(
                    MODULE.EditorError,
                    "remote workspace",
                ),
            ):
                MODULE.decode_up(result)

    def test_v5_phase_is_closed_while_v4_loads_without_rewrite(self) -> None:
        """Only v5 requires a known phase and reading v4 does not migrate it."""
        record = self.record("running")
        record["version"] = MODULE.PHASE_RECORD_VERSION
        record.pop("podman_connection")
        self.assertEqual(record["phase"], "monitoring-editor")
        for phase in (None, "building", 7):
            candidate = dict(record)
            candidate["phase"] = phase
            with (
                self.subTest(phase=phase),
                self.assertRaisesRegex(MODULE.EditorError, "phase is invalid"),
            ):
                MODULE.validate_record(candidate, self.repo)
        missing = dict(record)
        missing.pop("phase")
        with self.assertRaisesRegex(MODULE.EditorError, "schema is invalid"):
            MODULE.validate_record(missing, self.repo)

        record["version"] = MODULE.RUNTIME_RECORD_VERSION
        record.pop("phase")
        MODULE.atomic_json(MODULE.record_path(self.paths, self.repo), record)
        loaded = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(loaded["version"], MODULE.RUNTIME_RECORD_VERSION)
        self.assertNotIn("phase", loaded)
        self.assertNotIn(
            "phase",
            MODULE.read_private_json(
                MODULE.record_path(self.paths, self.repo), "workspace record"
            ),
        )

    def test_v6_podman_connection_schema_is_closed_and_strictly_typed(self) -> None:
        """The exact connection identity accepts no coercion or unknown fields."""
        record = self.record("running")
        record["podman_connection"] = {
            "name": "podman-machine-default",
            "machine_pin": "d" * 64,
        }
        validated = MODULE.validate_record(record, self.repo)
        self.assertEqual(validated["podman_connection"], record["podman_connection"])

        invalid_connections = (
            {"name": 7, "machine_pin": "d" * 64},
            {"name": "machine", "machine_pin": 7},
            {"name": "machine", "machine_pin": "D" * 64},
            {"name": "../machine", "machine_pin": "d" * 64},
            {"name": "machine", "machine_pin": "d" * 64, "extra": True},
        )
        for connection in invalid_connections:
            candidate = dict(record)
            candidate["podman_connection"] = connection
            with (
                self.subTest(connection=connection),
                self.assertRaisesRegex(MODULE.EditorError, "connection is invalid"),
            ):
                MODULE.validate_record(candidate, self.repo)

        phase_record = dict(record)
        phase_record["version"] = MODULE.PHASE_RECORD_VERSION
        phase_record.pop("podman_connection")
        self.assertEqual(
            MODULE.validate_record(phase_record, self.repo)["version"],
            MODULE.PHASE_RECORD_VERSION,
        )

    def test_offline_environment_reaches_tools_with_the_startup_claim(self) -> None:
        """The container receives offline policy and its one-shot startup claim."""
        record = self.record()
        values = MODULE.remote_environment(record, "/tmp/spool")
        self.assertIn("NVIM_CONFIG_OFFLINE=1", values)
        self.assertIn(
            f"NVIM_DEVCONTAINER_START_CLAIM_ID={record['claim_id']}",
            values,
        )
        record["network_authorized"] = True
        self.assertIn(
            "NVIM_CONFIG_OFFLINE=0", MODULE.remote_environment(record, "/tmp/spool")
        )

    def test_agent_probe_uses_the_exact_docker_compatible_engine(self) -> None:
        """SSH-agent parity is checked through the same pinned engine."""
        result = subprocess.CompletedProcess([str(self.cli), "exec"], 0, b"", b"")
        with mock.patch.object(
            MODULE, "run_bounded_capture", return_value=(result, False)
        ) as execute:
            MODULE.verify_agent(
                str(self.cli),
                str(self.docker),
                self.repo,
                self.config,
            )
        command = execute.call_args.args[0]
        self.assertEqual(command[0:2], [str(self.cli), "exec"])
        self.assertEqual(
            command[command.index("--docker-path") + 1],
            str(self.docker),
        )
        self.assertEqual(command[-2:], ["nvim-agent-probe", MODULE.DIRECT_AGENT_SOCKET])
        self.assertIn("/usr/bin/ssh-add -l", command[-3])
        self.assertNotIn("command -v ssh-add", command[-3])
        self.assertIn('case "$code" in 0|1)', command[-3])
        self.assertNotIn("--container-id", command)
        self.assertEqual(execute.call_args.kwargs["env"], None)

        missing_mount = subprocess.CompletedProcess(
            [str(self.cli), "exec"], 121, b"", b""
        )
        container_id = "f" * 64
        environment = {"CONTAINER_HOST": "ssh://pinned"}
        proxy_socket = MODULE.new_relay_agent_socket()
        with (
            mock.patch.object(
                MODULE,
                "run_bounded_capture",
                return_value=(missing_mount, False),
            ) as relay_execute,
            self.assertRaisesRegex(MODULE.EditorError, "proxy socket is unavailable"),
        ):
            MODULE.verify_agent(
                str(self.cli),
                str(self.docker),
                self.repo,
                self.config,
                proxy_socket,
                environment,
                container_id,
            )
        relay_command = relay_execute.call_args.args[0]
        self.assertEqual(
            relay_command[relay_command.index("--container-id") + 1], container_id
        )
        self.assertEqual(relay_execute.call_args.kwargs["env"], environment)

    def test_runtime_paths_are_exact_and_never_use_path_fallback(self) -> None:
        """The launcher accepts only exact regular executables supplied by the host."""
        self.assertEqual(MODULE.cli_path(str(self.cli)), str(self.cli))
        self.assertEqual(MODULE.docker_path(str(self.docker)), str(self.docker))
        with (
            mock.patch.object(
                MODULE.shutil,
                "which",
                side_effect=AssertionError("PATH was consulted"),
            ),
            self.assertRaisesRegex(MODULE.EditorError, "canonical and absolute"),
        ):
            MODULE.cli_path("devcontainer")
        link = self.root / "podman-link"
        link.symlink_to(self.docker)
        with self.assertRaisesRegex(MODULE.EditorError, "canonical executable"):
            MODULE.docker_path(str(link))

        selected_parent = self.root / "selected-runtime"
        selected_parent.mkdir()
        selected_cli = selected_parent / "devcontainer"
        selected_cli.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        selected_cli.chmod(0o700)
        selected_cli = selected_cli.resolve(strict=True)
        record = {"version": MODULE.RECORD_VERSION, "cli_path": str(selected_cli)}
        self.assertEqual(MODULE.stored_cli_path(record), str(selected_cli))
        moved_parent = self.root / "selected-runtime-original"
        selected_parent.rename(moved_parent)
        rival_parent = self.root / "selected-runtime-rival"
        rival_parent.mkdir()
        rival_cli = rival_parent / "devcontainer"
        rival_cli.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        rival_cli.chmod(0o700)
        selected_parent.symlink_to(rival_parent, target_is_directory=True)
        with self.assertRaisesRegex(MODULE.EditorError, "canonical executable"):
            MODULE.stored_cli_path(record)

    def test_preserve_lockfile_selects_flags_at_each_invocation(self) -> None:
        """Preserve chooses absent and present lock modes after an on-demand probe."""
        help_text = "\n".join(
            sorted(
                MODULE.UP_REQUIRED_OPTIONS
                | MODULE.EXEC_REQUIRED_OPTIONS
                | MODULE.RUN_USER_COMMANDS_REQUIRED_OPTIONS
            )
        ).encode()
        supported = subprocess.CompletedProcess(
            ["devcontainer", "up", "--help"],
            0,
            help_text,
            b"",
        )
        with mock.patch.object(MODULE, "run", return_value=supported) as execute:
            self.assertEqual(
                MODULE.preserve_lockfile_flag(
                    "/managed/devcontainer",
                    "/managed/podman",
                    self.config,
                ),
                "--no-lockfile",
            )
            lockfile = MODULE.lockfile_path(self.config)
            self.assertEqual(lockfile, self.config.with_name("devcontainer-lock.json"))
            lockfile.write_text('{"lockfileVersion":1}\n', encoding="utf-8")
            self.assertEqual(
                MODULE.preserve_lockfile_flag(
                    "/managed/devcontainer",
                    "/managed/podman",
                    self.config,
                ),
                "--frozen-lockfile",
            )
        self.assertEqual(
            execute.call_count,
            6,
            "capability was cached instead of probed per invocation",
        )
        representative = MODULE.mount_argument(
            pathlib.Path("/"), "/tmp/nvim-devcontainer-capability-probe"
        )
        expected_up = mock.call(
            [
                "/managed/devcontainer",
                "up",
                "--help",
                "--docker-path",
                "/managed/podman",
                "--mount",
                representative,
            ],
            timeout=5.0,
            check=False,
            env=None,
        )
        expected_exec = mock.call(
            [
                "/managed/devcontainer",
                "exec",
                "--help",
                "--docker-path",
                "/managed/podman",
            ],
            timeout=5.0,
            check=False,
            env=None,
        )
        expected_user_commands = mock.call(
            [
                "/managed/devcontainer",
                "run-user-commands",
                "--help",
                "--docker-path",
                "/managed/podman",
            ],
            timeout=5.0,
            check=False,
            env=None,
        )
        self.assertEqual(
            execute.call_args_list,
            [
                expected_up,
                expected_exec,
                expected_user_commands,
                expected_up,
                expected_exec,
                expected_user_commands,
            ],
        )

    def test_preserve_lockfile_fails_closed_when_cli_is_unsupported(self) -> None:
        """An old or ambiguous CLI cannot silently mutate lockfile state."""
        unsupported = subprocess.CompletedProcess(
            ["devcontainer", "up", "--help"],
            0,
            b"--no-lockfile\n",
            b"",
        )
        with (
            mock.patch.object(MODULE, "run", return_value=unsupported),
            self.assertRaisesRegex(
                MODULE.EditorError,
                "required up options",
            ),
        ):
            MODULE.preserve_lockfile_flag(
                "/managed/devcontainer",
                "/managed/podman",
                self.config,
            )

    def test_preserve_lockfile_rejects_deficient_exec_surface(self) -> None:
        """Doctor probing fails closed when latest CLI exec lacks one used option."""
        up_help = subprocess.CompletedProcess(
            ["devcontainer", "up", "--help"],
            0,
            "\n".join(sorted(MODULE.UP_REQUIRED_OPTIONS)).encode(),
            b"",
        )
        exec_help = subprocess.CompletedProcess(
            ["devcontainer", "exec", "--help"],
            0,
            "\n".join(sorted(MODULE.EXEC_REQUIRED_OPTIONS - {"--remote-env"})).encode(),
            b"",
        )
        user_commands_help = subprocess.CompletedProcess(
            ["devcontainer", "run-user-commands", "--help"],
            0,
            "\n".join(sorted(MODULE.RUN_USER_COMMANDS_REQUIRED_OPTIONS)).encode(),
            b"",
        )
        with (
            mock.patch.object(
                MODULE,
                "run",
                side_effect=(up_help, exec_help, user_commands_help),
            ),
            self.assertRaisesRegex(MODULE.EditorError, "required exec options"),
        ):
            MODULE.preserve_lockfile_flag(
                "/managed/devcontainer",
                "/managed/podman",
                self.config,
            )

    def test_preserve_lockfile_rejects_deficient_user_commands_surface(self) -> None:
        """Deferred relay hooks require the complete run-user-commands surface."""
        up_help = subprocess.CompletedProcess(
            ["devcontainer", "up", "--help"],
            0,
            "\n".join(sorted(MODULE.UP_REQUIRED_OPTIONS)).encode(),
            b"",
        )
        exec_help = subprocess.CompletedProcess(
            ["devcontainer", "exec", "--help"],
            0,
            "\n".join(sorted(MODULE.EXEC_REQUIRED_OPTIONS)).encode(),
            b"",
        )
        user_commands_help = subprocess.CompletedProcess(
            ["devcontainer", "run-user-commands", "--help"],
            0,
            "\n".join(
                sorted(MODULE.RUN_USER_COMMANDS_REQUIRED_OPTIONS - {"--container-id"})
            ).encode(),
            b"",
        )
        with (
            mock.patch.object(
                MODULE,
                "run",
                side_effect=(up_help, exec_help, user_commands_help),
            ),
            self.assertRaisesRegex(MODULE.EditorError, "required run-user-commands"),
        ):
            MODULE.preserve_lockfile_flag(
                "/managed/devcontainer",
                "/managed/podman",
                self.config,
            )

    def test_doctor_revalidates_exact_tools_without_touching_lifecycle_state(
        self,
    ) -> None:
        """Doctor probes exact paths without touching lifecycle records."""
        arguments = argparse.Namespace(
            repo=str(self.repo),
            config=None,
            cli_path=str(self.cli),
            docker_path=str(self.docker),
            lockfile_policy="preserve",
            ssh_agent="off",
        )
        output = io.StringIO()
        doctor_state = self.root / "doctor-must-not-create-state"
        with (
            contextlib.redirect_stdout(output),
            mock.patch.dict(
                os.environ,
                {"NVIM_DEVCONTAINER_STATE_HOME": str(doctor_state)},
            ),
            mock.patch.object(
                MODULE,
                "repo_root",
                return_value=self.repo,
            ),
            mock.patch.object(
                MODULE,
                "probe_version",
                side_effect=("devcontainer 1.2.3", "podman version 6.1.1"),
            ) as probe,
            mock.patch.object(
                MODULE,
                "preserve_lockfile_flag",
                return_value="--no-lockfile",
            ) as preserve,
            mock.patch.object(
                MODULE,
                "validate_config_snapshot_source",
                return_value=MODULE.SnapshotTotals(7, 1234),
            ) as validate_snapshot,
            mock.patch.object(
                MODULE,
                "prepare_state",
                side_effect=AssertionError("doctor created lifecycle state"),
            ),
        ):
            MODULE.cmd_doctor(arguments)
        payload = json.loads(output.getvalue())
        self.assertEqual(payload["cli"], str(self.cli))
        self.assertEqual(payload["docker"], str(self.docker))
        self.assertEqual(
            probe.call_args_list,
            [
                mock.call(str(self.cli), "Dev Containers CLI"),
                mock.call(str(self.docker), "Docker-compatible engine"),
            ],
        )
        preserve.assert_called_once_with(
            str(self.cli), str(self.docker), self.config, None
        )
        validate_snapshot.assert_called_once_with()
        self.assertEqual(payload["config_snapshot_files"], 7)
        self.assertEqual(payload["config_snapshot_bytes"], 1234)
        self.assertEqual(payload["config_snapshot_mode"], "private-per-claim")
        self.assertEqual(payload["ssh_agent_transport"], "disabled")
        self.assertFalse(doctor_state.exists())
        self.assertEqual(list(self.paths["workspaces"].iterdir()), [])

    def test_wait_claim_propagates_the_exact_record_error(self) -> None:
        """Detached quick failure reports its durable diagnostic without replacing it."""
        record = self.record("error")
        record["error"] = "podman socket is unreachable"
        MODULE.atomic_json(MODULE.record_path(self.paths, self.repo), record)
        arguments = argparse.Namespace(
            repo=str(self.repo),
            claim_id=record["claim_id"],
            timeout=1.0,
        )
        with (
            mock.patch.object(MODULE, "prepare_state", return_value=self.paths),
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            self.assertRaisesRegex(
                MODULE.EditorError,
                "^podman socket is unreachable$",
            ),
        ):
            MODULE.cmd_wait_claim(arguments)

    def test_workspace_lock_rejects_hard_link_without_modifying_peer(self) -> None:
        """A hard-linked lock never truncates the other pathname's contents."""
        lock = self.paths["locks"] / f"{MODULE.workspace_id(self.repo)}.json"
        victim = self.root / "private-peer.json"
        victim.write_bytes(b"earlier private contents\n")
        victim.chmod(0o600)
        os.link(victim, lock)

        with (
            self.assertRaisesRegex(MODULE.EditorError, "unsafe"),
            MODULE.workspace_lock(
                self.paths,
                self.repo,
            ),
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
            with (
                self.assertRaisesRegex(MODULE.EditorError, "busy"),
                MODULE.workspace_lock(
                    self.paths,
                    self.repo,
                ),
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
            with (
                self.assertRaisesRegex(MODULE.EditorError, "busy"),
                MODULE.workspace_lock(
                    self.paths,
                    self.repo,
                ),
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
            tmux_pane="%7",
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
            self.assertEqual(argv[-2:], ["--tmux-pane", "%7"])
            with (
                self.assertRaisesRegex(MODULE.EditorError, "busy"),
                original_lock(
                    self.paths,
                    self.repo,
                ),
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

        with (
            mock.patch.object(MODULE, "workspace_lock", side_effect=capture_lock),
            mock.patch.object(
                MODULE.os,
                "execv",
                side_effect=reject_exec,
            ),
            self.assertRaisesRegex(MODULE.EditorError, "could not hand off"),
        ):
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
            with (
                mock.patch.object(MODULE, "repo_root", return_value=self.repo),
                mock.patch.object(
                    MODULE,
                    "open_location",
                    side_effect=publish_starting,
                ),
                mock.patch.object(MODULE.os, "execv") as execute,
                self.assertRaisesRegex(
                    MODULE.EditorError,
                    "busy",
                ),
            ):
                MODULE.cmd_open_location(arguments)
            execute.assert_not_called()
            self.assertEqual(
                MODULE.load_record(self.paths, self.repo)["status"], "starting"
            )
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
            cli_path=str(self.cli),
            docker_path=str(self.docker),
            tmux_pane="%7",
            claim_id="00000000-0000-4000-8000-000000000010",
            timeout=1.0,
        )
        with (
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "require_editor_pane",
                return_value=("%7", 7007),
            ),
            mock.patch.object(
                MODULE,
                "cli_path",
                side_effect=MODULE.EditorError("CLI is broken"),
            ),
            self.assertRaisesRegex(MODULE.EditorError, "CLI is broken"),
        ):
            MODULE.cmd_up(arguments)
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "error")
        with self.assertRaisesRegex(MODULE.EditorError, "fallback is disabled"):
            MODULE.selected_record(self.paths, self.repo)

    def test_fresh_up_rejects_an_unsafe_log_before_publishing_a_claim(self) -> None:
        """A bad log cannot strand a durable starting record before reconciliation."""
        log = MODULE.log_path(self.paths, self.repo)
        log.write_text("unsafe\n", encoding="utf-8")
        log.chmod(0o640)
        arguments = argparse.Namespace(
            repo=str(self.repo),
            config=None,
            recreate=False,
            allow_network=False,
            cli_path=str(self.cli),
            docker_path=str(self.docker),
            tmux_pane="%7",
            claim_id="00000000-0000-4000-8000-000000000015",
            timeout=1.0,
        )
        with (
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "require_editor_pane",
                return_value=("%7", 7007),
            ),
            self.assertRaisesRegex(MODULE.EditorError, "private lifecycle log"),
        ):
            MODULE.cmd_up(arguments)

        self.assertFalse(MODULE.record_path(self.paths, self.repo).exists())
        self.assertEqual(log.read_text(encoding="utf-8"), "unsafe\n")
        self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o640)

    def test_running_log_io_failure_reconciles_the_published_claim(self) -> None:
        """A raw append failure cannot leave a dead coordinator recorded running."""
        arguments = argparse.Namespace(
            repo=str(self.repo),
            config=None,
            recreate=False,
            allow_network=False,
            cli_path=str(self.cli),
            docker_path=str(self.docker),
            tmux_pane="%7",
            claim_id="00000000-0000-4000-8000-000000000016",
            timeout=1.0,
        )

        def fail_running_log(
            paths: MODULE.StateDirectories,
            _spool: MODULE.SpoolDirectories,
            root: pathlib.Path,
            _config: pathlib.Path,
            record: dict[str, object],
            log: pathlib.Path,
            _token: str,
            _cli: str,
            _docker: str,
            _agent: pathlib.Path | None,
            **_policy: object,
        ) -> None:
            container_root = "/workspaces/repo"
            MODULE.update_workspace_record(
                paths,
                root,
                record,
                status="running",
                phase="monitoring-editor",
                container_id="abc",
                container_root=container_root,
                workspace_key={
                    "runtime": "container",
                    "root": container_root,
                    "repo_identity": str(root),
                },
            )
            with (
                MODULE.LifecycleLogWriter(log) as writer,
                mock.patch.object(
                    MODULE.os,
                    "lseek",
                    side_effect=OSError(errno.EIO, "injected log failure"),
                ),
            ):
                writer.append("lifecycle running")

        with (
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "require_editor_pane",
                return_value=("%7", 7007),
            ),
            mock.patch.object(
                MODULE,
                "run_container_lifecycle",
                side_effect=fail_running_log,
            ),
            self.assertRaisesRegex(
                MODULE.EditorError,
                "could not append private lifecycle log",
            ),
        ):
            MODULE.cmd_up(arguments)

        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "error")
        self.assertIn("could not append private lifecycle log", persisted["error"])
        self.assertFalse(MODULE.auth_path(self.spool).exists())

    def test_lifecycle_reconciliation_attempts_every_cleanup_and_keeps_primary_first(
        self,
    ) -> None:
        """Record, auth, and log failures aggregate only after every cleanup attempt."""
        arguments = argparse.Namespace(
            repo=str(self.repo),
            config=None,
            recreate=False,
            allow_network=False,
            cli_path=str(self.cli),
            docker_path=str(self.docker),
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

        with (
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "require_editor_pane",
                return_value=("%7", 7007),
            ),
            mock.patch.object(
                MODULE,
                "cli_path",
                side_effect=MODULE.EditorError("primary lifecycle failure"),
            ),
            mock.patch.object(
                MODULE,
                "update_workspace_record",
                side_effect=fail_error_record,
            ),
            mock.patch.object(MODULE, "remove_auth", side_effect=fail_auth_cleanup),
            mock.patch.object(
                MODULE,
                "append_log",
                side_effect=fail_error_log,
            ),
            mock.patch.object(MODULE, "progress") as reported,
            self.assertRaisesRegex(
                MODULE.EditorError,
                "^primary lifecycle failure; lifecycle reconciliation failures:",
            ),
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

    def test_editor_open_requires_the_callers_exact_active_pane(self) -> None:
        """A same-repository lifecycle in another session cannot steal routing."""
        self.record()
        arguments = argparse.Namespace(
            wait_editor=False,
            cwd=str(self.repo),
            file=str(self.file),
            line=1,
            column=1,
            wait_timeout=1.0,
            fallback_exact=True,
            tmux_pane="%8",
        )
        with (
            mock.patch.object(MODULE, "prepare_state", return_value=self.paths),
            mock.patch.object(
                MODULE,
                "repo_root",
                return_value=self.repo,
            ),
            mock.patch.object(MODULE, "exact_fallback_if_absent") as fallback,
            self.assertRaisesRegex(
                MODULE.EditorError,
                "does not match the requested pane",
            ),
        ):
            MODULE.cmd_editor_open(arguments)

        fallback.assert_not_called()
        self.assertEqual(list((self.spool.root / "inbox").glob("*.json")), [])

    def test_wait_ack_rejects_mismatched_auth_and_timeout(self) -> None:
        """Spool acknowledgements authenticate and fail closed when absent."""
        spool = self.spool
        token = "t" * 43
        request = MODULE.signed_message(
            token,
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
        path = spool.root / "acks" / f"{request['request_id']}.json"
        MODULE.atomic_create_json_at(
            spool.acks_fd,
            path.name,
            MODULE.signed_message(
                "wrong" * 10,
                "ack",
                {
                    "version": MODULE.VERSION,
                    "request_id": request["request_id"],
                    "ok": True,
                    "action": "open_location",
                    "error": None,
                },
            ),
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
            with (
                self.subTest(payload=payload),
                mock.patch.object(
                    MODULE.os,
                    "fsync",
                    side_effect=capture_fsync,
                ),
                self.assertRaisesRegex(MODULE.EditorError, "not valid JSON"),
            ):
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

        with (
            mock.patch.object(
                MODULE,
                "decode_json_object",
                side_effect=replace_then_decode,
            ),
            mock.patch.object(MODULE, "progress") as reported,
            self.assertRaisesRegex(
                MODULE.EditorError,
                "^spool acknowledgement is not valid JSON.*; acknowledgement retirement failed:",
            ) as caught,
        ):
            MODULE.wait_ack(self.spool, self.token, request, 0.1)

        self.assertEqual(path.read_text(encoding="utf-8"), '{"replacement":true}\n')
        self.assertTrue(displaced.exists())
        self.assertIsInstance(caught.exception.__cause__, MODULE.EditorError)
        self.assertIn("not valid JSON", str(caught.exception.__cause__))
        reported.assert_called_once()
        self.assertIn(
            "changed during conditional retirement", reported.call_args.args[0]
        )

    def test_ack_cleanup_failure_preserves_decode_primary_and_warning_failure(
        self,
    ) -> None:
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

        with (
            mock.patch.object(
                MODULE,
                "unlink_regular_at",
                side_effect=MODULE.EditorError("ack cleanup failed"),
            ),
            mock.patch.object(
                MODULE,
                "progress",
                side_effect=OSError("stderr sink failed"),
            ) as reported,
            self.assertRaisesRegex(
                MODULE.EditorError,
                "^spool acknowledgement is not valid JSON.*; "
                "acknowledgement retirement failed: ack cleanup failed$",
            ) as caught,
        ):
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
        path = spool.root / "outbox" / f"{request_id}.json"
        MODULE.atomic_create_json_at(spool.outbox_fd, path.name, request)
        with mock.patch.object(MODULE, "tmux_action") as action:
            self.assertEqual(
                MODULE.consume_outbox(self.paths, spool, record, self.token), (1, False)
            )
            action.assert_called_once_with(record, "lazygit")
        self.assertFalse(path.exists())
        ack = MODULE.read_private_json(
            spool.root / "acks" / f"{request_id}.json", "ack"
        )
        self.assertTrue(ack["ok"])
        self.assertTrue(MODULE.valid_message_auth(self.token, "ack", ack))
        self.assertNotIn("token", ack)
        self.assertEqual(
            MODULE.consume_outbox(self.paths, spool, record, self.token), (0, False)
        )

    def test_editor_ready_ack_requires_no_tmux_side_effect(self) -> None:
        """Readiness is acknowledged only through the active authenticated monitor."""
        record = self.record()
        request_id = str(uuid.uuid4())
        request = MODULE.signed_message(
            self.token,
            "host_request",
            {
                "version": MODULE.VERSION,
                "request_id": request_id,
                "action": "editor_ready",
                "created_at": MODULE.utc_now(),
            },
        )
        name = f"{request_id}.json"
        MODULE.atomic_create_json_at(self.spool.outbox_fd, name, request)

        with (
            mock.patch.object(
                MODULE.shutil,
                "which",
                side_effect=AssertionError("readiness acknowledgement queried tmux"),
            ),
            mock.patch.object(
                MODULE,
                "run",
                side_effect=AssertionError("readiness acknowledgement ran a process"),
            ),
        ):
            self.assertEqual(
                MODULE.consume_outbox(
                    self.paths,
                    self.spool,
                    record,
                    self.token,
                ),
                (1, False),
            )

        ack = MODULE.read_private_json(
            self.spool.root / "acks" / name,
            "readiness acknowledgement",
        )
        self.assertTrue(ack["ok"])
        self.assertEqual(ack["action"], "editor_ready")
        self.assertTrue(MODULE.valid_message_auth(self.token, "ack", ack))

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

        with (
            mock.patch.object(MODULE.os, "fsync", side_effect=fail_outbox_sync),
            mock.patch.object(
                MODULE,
                "progress",
                side_effect=OSError("stderr sink failed"),
            ),
            mock.patch.object(MODULE, "tmux_action", side_effect=normal_action),
        ):
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

        with (
            mock.patch.object(MODULE.os, "fsync", side_effect=capture_fsync),
            mock.patch.object(
                MODULE,
                "respawn_host_editor",
                side_effect=restore_host,
            ),
        ):
            self.assertEqual(
                MODULE.consume_outbox(self.paths, self.spool, record, self.token),
                (1, True),
            )

        self.assertEqual(events[:2], ["outbox-fsync", "host-restore"])
        self.assertFalse((self.spool.root / "outbox" / second_name).exists())

    def test_malformed_outbox_json_snapshots_are_retired_with_primary_error(
        self,
    ) -> None:
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
            with (
                self.subTest(payload=payload),
                mock.patch.object(
                    MODULE,
                    "tmux_action",
                ) as action,
                mock.patch.object(
                    MODULE.os,
                    "fsync",
                    side_effect=capture_fsync,
                ),
                self.assertRaisesRegex(MODULE.EditorError, expected),
            ):
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

        with (
            mock.patch.object(MODULE, "tmux_action") as action,
            self.assertRaisesRegex(
                MODULE.EditorError,
                "host spool request schema is invalid",
            ),
        ):
            MODULE.consume_outbox(self.paths, self.spool, record, self.token)

        action.assert_not_called()
        self.assertFalse(path.exists())
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "error")
        self.assertEqual(persisted["error"], "host spool request schema is invalid")

    def test_corrupt_outbox_replacement_is_preserved_without_masking_decode_error(
        self,
    ) -> None:
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

        with (
            mock.patch.object(
                MODULE,
                "decode_json_object",
                side_effect=replace_then_decode,
            ),
            mock.patch.object(MODULE, "progress") as reported,
            mock.patch.object(
                MODULE,
                "tmux_action",
            ) as action,
            self.assertRaisesRegex(MODULE.EditorError, "not valid JSON"),
        ):
            MODULE.consume_outbox(self.paths, self.spool, record, self.token)

        action.assert_not_called()
        self.assertEqual(path.read_text(encoding="utf-8"), '{"replacement":true}\n')
        self.assertTrue(displaced.exists())
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "error")
        self.assertIn("not valid JSON", persisted["error"])
        reported.assert_called_once()
        self.assertIn(
            "changed during conditional retirement", reported.call_args.args[0]
        )

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

        with (
            mock.patch.object(
                MODULE,
                "validate_host_request",
                side_effect=replace_request,
            ),
            mock.patch.object(MODULE, "tmux_action") as action,
            self.assertRaisesRegex(
                MODULE.EditorError,
                "changed during conditional retirement",
            ),
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

        with (
            mock.patch.object(MODULE, "unlink_regular_at", side_effect=disappear),
            mock.patch.object(
                MODULE,
                "tmux_action",
            ) as action,
            self.assertRaisesRegex(
                MODULE.EditorError,
                "host spool request disappeared before execution",
            ),
        ):
            MODULE.consume_outbox(self.paths, self.spool, record, self.token)

        action.assert_not_called()
        ack = MODULE.read_private_json(
            self.spool.root / "acks" / f"{request_id}.json",
            "ack",
        )
        self.assertFalse(ack["ok"])
        self.assertEqual(
            ack["error"], "host spool request disappeared before execution"
        )
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

        with (
            mock.patch.object(
                MODULE,
                "unlink_regular_at",
                side_effect=MODULE.EditorError("poison cleanup failed"),
            ),
            mock.patch.object(MODULE, "progress") as reported,
            self.assertRaisesRegex(
                MODULE.EditorError,
                "filename does not match its id",
            ) as caught,
        ):
            MODULE.consume_outbox(self.paths, self.spool, record, self.token)

        self.assertTrue((self.spool.root / "outbox" / wrong_name).exists())
        self.assertIn(
            "invalid request retirement failed: poison cleanup failed",
            str(caught.exception),
        )
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
        real_fsync = MODULE.os.fsync
        synced: list[int] = []

        def capture_fsync(descriptor: int) -> None:
            synced.append(descriptor)
            real_fsync(descriptor)

        with mock.patch.object(MODULE.os, "fsync", side_effect=capture_fsync):
            MODULE.write_ack(self.spool, self.token, request, True, None)

        self.assertIn(self.spool.acks_fd, synced)

    def test_request_reconciliation_attempts_every_step_with_primary_first(
        self,
    ) -> None:
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
        with (
            mock.patch.object(
                MODULE, "unlink_regular_at", side_effect=fail_positive_ack
            ),
            mock.patch.object(
                MODULE,
                "write_ack",
                side_effect=fail_negative_ack,
            ),
            mock.patch.object(
                MODULE,
                "update_workspace_record",
                side_effect=fail_record,
            ),
            self.assertRaisesRegex(
                MODULE.EditorError,
                "^primary host handoff failure; request reconciliation failures:",
            ),
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

        with (
            mock.patch.object(
                MODULE, "unlink_regular_at", side_effect=reject_late_retirement
            ),
            mock.patch.object(
                MODULE,
                "tmux_action",
                side_effect=reject_action,
            ),
        ):
            MODULE.consume_outbox(self.paths, spool, record, self.token)
        ack = MODULE.read_private_json(
            spool.root / "acks" / f"{request_id}.json", "ack"
        )
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
        snapshot = MODULE.create_config_snapshot(
            spool, record["claim_id"], self.snapshot_source("handoff-source")
        )
        self.addCleanup(os.close, snapshot.descriptor)
        MODULE.publish_snapshot_lease(
            self.paths, spool, self.repo, record["claim_id"], snapshot
        )
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
        restored = MODULE.PaneObservation(False, 8008, None, "")
        events: list[str] = []
        original_write_ack = MODULE.write_ack
        original_remove_record = MODULE.remove_workspace_record
        original_unlink = MODULE.unlink_regular_at
        reconciled = False
        outbox_retirements = 0
        relay = mock.Mock(spec=MODULE.PodmanAgentRelay)

        def respawn_host(_record: dict[str, object]) -> MODULE.PaneObservation:
            events.append("respawn")
            return restored

        relay.close.side_effect = lambda: events.append("relay")

        def retire_request(
            directory_fd: int,
            entry: str,
            **kwargs: object,
        ) -> bool:
            nonlocal outbox_retirements
            if directory_fd == spool.outbox_fd and entry == f"{request_id}.json":
                if reconciled:
                    raise MODULE.EditorError(
                        "late retirement escaped after host handoff"
                    )
                events.append("request")
                outbox_retirements += 1
            return original_unlink(directory_fd, entry, **kwargs)

        def write_ack(*args: object, **kwargs: object) -> None:
            self.assertFalse(snapshot.path.exists())
            events.append("ack")
            original_write_ack(*args, **kwargs)

        def remove_record(*args: object, **kwargs: object) -> None:
            nonlocal reconciled
            events.append("record")
            original_remove_record(*args, **kwargs)
            reconciled = True

        with (
            mock.patch.object(MODULE, "unlink_regular_at", side_effect=retire_request),
            mock.patch.object(
                MODULE,
                "respawn_host_editor",
                side_effect=respawn_host,
            ) as respawn,
            mock.patch.object(
                MODULE,
                "write_ack",
                side_effect=write_ack,
            ),
            mock.patch.object(
                MODULE, "remove_workspace_record", side_effect=remove_record
            ),
        ):
            self.assertEqual(
                MODULE.consume_outbox(
                    self.paths,
                    spool,
                    record,
                    self.token,
                    relay=relay,
                ),
                (1, True),
            )
        respawn.assert_called_once_with(record)
        relay.close.assert_called_once_with()
        self.assertEqual(events, ["request", "respawn", "relay", "ack", "record"])
        self.assertEqual(outbox_retirements, 1)
        self.assertFalse((spool.root / "outbox" / f"{request_id}.json").exists())
        self.assertFalse(MODULE.record_path(self.paths, self.repo).exists())
        self.assertFalse(MODULE.auth_path(spool).exists())
        self.assertFalse(snapshot.path.exists())
        ack = MODULE.read_private_json(
            spool.root / "acks" / f"{request_id}.json", "ack"
        )
        self.assertTrue(ack["ok"])

    def test_active_handoff_preserves_snapshot_replacement(self) -> None:
        """A host handoff rejects a replaced owner directory before pane mutation."""
        record = self.record()
        snapshot = MODULE.create_config_snapshot(
            self.spool,
            record["claim_id"],
            self.snapshot_source("handoff-replacement-source"),
        )
        self.addCleanup(os.close, snapshot.descriptor)
        MODULE.publish_snapshot_lease(
            self.paths, self.spool, self.repo, record["claim_id"], snapshot
        )
        displaced = snapshot.path.with_name(f"{snapshot.name}-handoff-original")
        snapshot.path.rename(displaced)
        snapshot.path.mkdir(mode=0o500)
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
        MODULE.atomic_create_json_at(
            self.spool.outbox_fd, f"{request_id}.json", request
        )
        try:
            with mock.patch.object(MODULE, "respawn_host_editor") as respawn:
                self.assertEqual(
                    MODULE.consume_outbox(
                        self.paths,
                        self.spool,
                        record,
                        self.token,
                        snapshot.identity,
                    ),
                    (1, False),
                )
            respawn.assert_not_called()
            self.assertTrue(snapshot.path.is_dir())
            self.assertEqual(
                MODULE.load_record(self.paths, self.repo)["status"], "error"
            )
        finally:
            snapshot.path.chmod(0o700)
            snapshot.path.rmdir()
            displaced.rename(snapshot.path)
            MODULE.retire_claim_snapshot(
                self.paths,
                self.spool,
                self.repo,
                record["claim_id"],
                snapshot.identity,
            )

    def test_committed_handoff_ack_survives_directory_and_warning_sink_failures(
        self,
    ) -> None:
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

        with (
            mock.patch.object(MODULE.os, "fsync", side_effect=fail_ack_directory_sync),
            mock.patch.object(
                MODULE,
                "respawn_host_editor",
                return_value=restored,
            ),
            mock.patch.object(
                MODULE,
                "progress",
                side_effect=OSError("stderr sink failed"),
            ) as reported,
        ):
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
        with mock.patch.object(
            MODULE,
            "respawn_host_editor",
            side_effect=MODULE.EditorError("tmux respawn rejected"),
        ):
            self.assertEqual(
                MODULE.consume_outbox(self.paths, spool, record, self.token), (1, False)
            )
        failed = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(failed["status"], "error")
        self.assertEqual(failed["phase"], "returning-host")
        ack = MODULE.read_private_json(
            spool.root / "acks" / f"{request_id}.json", "ack"
        )
        self.assertFalse(ack["ok"])
        self.assertEqual(ack["error"], "tmux respawn rejected")
        self.assertTrue(MODULE.valid_message_auth(self.token, "ack", ack))

    def test_host_handoff_transition_failure_stops_coordinator(self) -> None:
        """A failure after pane restoration starts never returns to container monitoring."""
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
        with (
            mock.patch.object(
                MODULE,
                "respawn_host_editor",
                side_effect=MODULE.HostPaneTransitioned(
                    "tmux post-respawn check failed"
                ),
            ),
            self.assertRaisesRegex(MODULE.EditorError, "coordinator stopped"),
        ):
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
        with (
            mock.patch.object(MODULE, "respawn_host_editor", return_value=restored),
            mock.patch.object(
                MODULE,
                "write_ack",
                side_effect=flaky_ack,
            ),
            self.assertRaisesRegex(MODULE.EditorError, "coordinator stopped"),
        ):
            MODULE.consume_outbox(self.paths, spool, record, self.token)
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "error")
        self.assertTrue(MODULE.record_path(self.paths, self.repo).exists())
        ack = MODULE.read_private_json(
            spool.root / "acks" / f"{request_id}.json", "ack"
        )
        self.assertFalse(ack["ok"])
        self.assertEqual(ack["error"], "ack persistence failed")

    def test_host_handoff_state_failure_stops_after_restoring_host(self) -> None:
        """A post-respawn state failure escapes monitoring and persists an error record."""
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
        with (
            mock.patch.object(MODULE, "respawn_host_editor", return_value=restored),
            mock.patch.object(
                MODULE,
                "update_workspace_record",
                side_effect=flaky_update,
            ),
            self.assertRaisesRegex(MODULE.EditorError, "coordinator stopped"),
        ):
            MODULE.consume_outbox(self.paths, spool, record, self.token)

        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "error")
        self.assertEqual(persisted["error"], "state persistence failed")

    def test_monitor_does_not_observe_host_pane_after_handoff_failure(self) -> None:
        """A failed post-respawn handoff terminates monitoring before another pane poll."""
        record = self.record()
        with (
            mock.patch.object(
                MODULE,
                "consume_outbox",
                side_effect=MODULE.EditorError(
                    "host editor was restored; coordinator stopped"
                ),
            ),
            mock.patch.object(MODULE, "observe_pane") as observe,
            self.assertRaisesRegex(
                MODULE.EditorError,
                "coordinator stopped",
            ),
        ):
            MODULE.monitor_editor(
                self.paths,
                self.spool,
                record,
                self.token,
                mock.Mock(identity=MODULE.DirectoryIdentity(1, 2, os.getuid())),
            )

        observe.assert_not_called()

    def test_explicit_host_command_recovers_dead_pane_and_retires_record(self) -> None:
        """The out-of-band host command can recover a dead container pane."""
        record = self.record("dead")
        snapshot = MODULE.create_config_snapshot(
            self.spool,
            record["claim_id"],
            self.snapshot_source("inactive-recovery-source"),
        )
        self.addCleanup(os.close, snapshot.descriptor)
        MODULE.publish_snapshot_lease(
            self.paths, self.spool, self.repo, record["claim_id"], snapshot
        )
        arguments = argparse.Namespace(repo=str(self.repo))
        restored = MODULE.PaneObservation(False, 8008, None, "")
        with (
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "restore_or_verify_host_pane",
                return_value=restored,
            ) as restore,
        ):
            MODULE.cmd_host(arguments)
        restore.assert_called_once_with(mock.ANY)
        self.assertFalse(MODULE.record_path(self.paths, self.repo).exists())
        self.assertFalse(
            MODULE.auth_path(MODULE.spool_path(self.paths, self.repo)).exists()
        )
        self.assertFalse(snapshot.path.exists())

    def test_v4_error_without_snapshot_artifact_recovers_host(self) -> None:
        """A pre-snapshot v4 error record remains explicitly recoverable."""
        record = self.record("error")
        record["container_id"] = None
        record["cli_path"] = None
        record["docker_path"] = None
        MODULE.atomic_json(MODULE.record_path(self.paths, self.repo), record)
        restored = MODULE.PaneObservation(False, 8008, None, "")
        with (
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "recover_host_pane",
                return_value=restored,
            ) as recover,
        ):
            MODULE.cmd_host(argparse.Namespace(repo=str(self.repo)))
        recover.assert_called_once()
        self.assertFalse(MODULE.record_path(self.paths, self.repo).exists())

    def test_inactive_recovery_preserves_snapshot_replacement(self) -> None:
        """Inactive recovery validates cleanup authority before touching tmux."""
        record = self.record("error")
        snapshot = MODULE.create_config_snapshot(
            self.spool,
            record["claim_id"],
            self.snapshot_source("inactive-replacement-source"),
        )
        self.addCleanup(os.close, snapshot.descriptor)
        MODULE.publish_snapshot_lease(
            self.paths, self.spool, self.repo, record["claim_id"], snapshot
        )
        displaced = snapshot.path.with_name(f"{snapshot.name}-inactive-original")
        snapshot.path.rename(displaced)
        snapshot.path.mkdir(mode=0o500)
        try:
            with (
                mock.patch.object(MODULE, "repo_root", return_value=self.repo),
                mock.patch.object(MODULE, "recover_host_pane") as recover,
                self.assertRaisesRegex(MODULE.EditorError, "identity changed"),
            ):
                MODULE.cmd_host(argparse.Namespace(repo=str(self.repo)))
            recover.assert_not_called()
            self.assertTrue(snapshot.path.is_dir())
            self.assertTrue(MODULE.record_path(self.paths, self.repo).exists())
        finally:
            snapshot.path.chmod(0o700)
            snapshot.path.rmdir()
            displaced.rename(snapshot.path)
            MODULE.retire_claim_snapshot(
                self.paths,
                self.spool,
                self.repo,
                record["claim_id"],
                snapshot.identity,
            )

    def test_explicit_host_command_adopts_restarted_exact_host_pane(self) -> None:
        """An explicit recovery retires early error state from the exact host pane."""
        record = self.record("error")
        record["version"] = MODULE.CLI_RECORD_VERSION
        record.pop("phase")
        record.pop("podman_connection")
        record["cli_path"] = None
        record.pop("docker_path")
        record["container_id"] = None
        record["error"] = "certified Dev Containers CLI was unavailable"
        MODULE.atomic_json(MODULE.record_path(self.paths, self.repo), record)
        arguments = argparse.Namespace(
            repo=str(self.repo),
            tmux_pane="%7",
            wait_timeout=4.0,
        )
        output = f"%7\t0\t8008\teditor\t1\t{self.repo}\tnvim\t\n".encode()
        result = subprocess.CompletedProcess(
            ["tmux", "display-message"], 0, output, b""
        )

        with (
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "observe_pane",
                return_value=MODULE.PaneObservation(False, 8008, None, ""),
            ),
            mock.patch.object(MODULE.shutil, "which", return_value="/usr/bin/tmux"),
            mock.patch.object(MODULE, "run", return_value=result) as run,
            mock.patch.object(MODULE, "respawn_host_editor") as respawn,
        ):
            MODULE.cmd_host(arguments)

        run.assert_called_once_with(
            [
                "/usr/bin/tmux",
                "display-message",
                "-p",
                "-t",
                "%7",
                MODULE.HOST_ADOPTION_FORMAT,
            ],
            timeout=5.0,
        )
        respawn.assert_not_called()
        self.assertFalse(MODULE.record_path(self.paths, self.repo).exists())
        self.assertFalse(MODULE.auth_path(self.spool).exists())

    def test_restarted_early_error_survives_post_rename_retirement_failure(
        self,
    ) -> None:
        """A real post-rename failure preserves truthful retryable early-error state."""
        record = self.record("error")
        record["version"] = MODULE.CLI_RECORD_VERSION
        record.pop("phase")
        record.pop("podman_connection")
        record["cli_path"] = None
        record.pop("docker_path")
        record["container_id"] = None
        record["error"] = "certified Dev Containers CLI was unavailable"
        MODULE.atomic_json(MODULE.record_path(self.paths, self.repo), record)
        arguments = argparse.Namespace(
            repo=str(self.repo),
            tmux_pane="%7",
            wait_timeout=4.0,
        )
        output = f"%7\t0\t8008\teditor\t1\t{self.repo}\tnvim\t\n".encode()
        result = subprocess.CompletedProcess(
            ["tmux", "display-message"], 0, output, b""
        )
        record_name = MODULE.record_name(self.repo)
        real_unlink = MODULE.os.unlink
        injected = False

        def fail_record_reservation_unlink(
            target: object, *args: object, **kwargs: object
        ) -> None:
            nonlocal injected
            if (
                isinstance(target, str)
                and target.startswith(f".{record_name}.")
                and target.endswith(".retire")
            ):
                injected = True
                raise OSError("injected record retirement failure")
            real_unlink(target, *args, **kwargs)

        with (
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "observe_pane",
                return_value=MODULE.PaneObservation(False, 8008, None, ""),
            ),
            mock.patch.object(MODULE.shutil, "which", return_value="/usr/bin/tmux"),
            mock.patch.object(MODULE, "run", return_value=result),
            mock.patch.object(
                MODULE.os, "unlink", side_effect=fail_record_reservation_unlink
            ),
            self.assertRaisesRegex(
                MODULE.EditorError, "injected record retirement failure"
            ),
        ):
            MODULE.cmd_host(arguments)

        self.assertTrue(injected)
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["version"], MODULE.CLI_RECORD_VERSION)
        self.assertEqual(persisted["status"], "error")
        self.assertEqual(persisted["pane_pid"], 8008)
        self.assertEqual(
            persisted["error"], "certified Dev Containers CLI was unavailable"
        )
        self.assertEqual(
            list(self.paths["workspaces"].glob(f".{record_name}.*.retire")), []
        )

    def test_restarted_host_adoption_rejects_ambiguous_tmux_state(self) -> None:
        """Every host-pane adoption predicate fails closed from one snapshot."""
        record = self.record("error")
        default = ["%7", "0", "8008", "editor", "1", str(self.repo), "nvim", ""]
        cases: dict[str, tuple[int, str] | bytes] = {
            "wrong-pane": (0, "%8"),
            "dead": (1, "1"),
            "invalid-pid": (2, "invalid"),
            "zero-pid": (2, "0"),
            "unchanged-pid": (2, "7007"),
            "wrong-window": (3, "shell"),
            "invalid-pane-count": (4, "invalid"),
            "multiple-panes": (4, "2"),
            "wrong-cwd": (5, str(self.root)),
            "noncanonical-cwd": (5, str(self.repo / ".." / "repo")),
            "wrong-command": (6, "vim"),
            "marked-pane": (7, MODULE.pane_marker(self.repo)),
            "malformed": b"not\ta\tcomplete\tsnapshot\n",
            "invalid-encoding": b"%7\t0\t8008\teditor\t1\t\xff\tnvim\t\n",
        }

        for label, change in cases.items():
            with self.subTest(label=label):
                fields = list(default)
                if isinstance(change, bytes):
                    output = change
                else:
                    index, value = change
                    fields[index] = value
                    output = ("\t".join(fields) + "\n").encode()
                result = subprocess.CompletedProcess(
                    ["tmux", "display-message"], 0, output, b""
                )
                with (
                    mock.patch.object(
                        MODULE.shutil, "which", return_value="/usr/bin/tmux"
                    ),
                    mock.patch.object(MODULE, "run", return_value=result) as run,
                    self.assertRaises(MODULE.EditorError),
                ):
                    MODULE.adopt_restarted_host_pane(record, "%7")
                run.assert_called_once()

        valid = MODULE.HostPaneSnapshot(
            "%7", False, 8008, "editor", 1, str(self.repo), "nvim", ""
        )
        for status in ("error", "stopped", "dead"):
            with self.subTest(accepted_status=status):
                record["status"] = status
                with mock.patch.object(
                    MODULE, "observe_host_pane_for_adoption", return_value=valid
                ) as observe:
                    self.assertEqual(
                        MODULE.adopt_restarted_host_pane(record, "%7"),
                        MODULE.PaneObservation(False, 8008, None, ""),
                    )
                observe.assert_called_once_with("%7")

        for status in ("starting", "running"):
            with self.subTest(status=status):
                record["status"] = status
                with (
                    mock.patch.object(
                        MODULE, "observe_host_pane_for_adoption"
                    ) as observe,
                    self.assertRaisesRegex(MODULE.EditorError, "inactive"),
                ):
                    MODULE.adopt_restarted_host_pane(record, "%7")
                observe.assert_not_called()

        record["status"] = "error"
        with (
            mock.patch.object(MODULE, "observe_host_pane_for_adoption") as observe,
            self.assertRaisesRegex(MODULE.EditorError, "does not match"),
        ):
            MODULE.adopt_restarted_host_pane(record, "%8")
        observe.assert_not_called()

    def test_unmarked_host_verification_rejects_starting_lifecycle(self) -> None:
        """An unmarked pane cannot retire a lifecycle that is still starting."""
        record = self.record("starting")
        observed = MODULE.PaneObservation(False, 7007, None, "")
        with (
            mock.patch.object(MODULE, "observe_pane", return_value=observed),
            mock.patch.object(MODULE, "respawn_host_editor") as respawn,
            self.assertRaisesRegex(MODULE.EditorError, "not the exact registered"),
        ):
            MODULE.restore_or_verify_host_pane(record)
        respawn.assert_not_called()

    def test_explicit_host_command_rejects_starting_state_before_recovery(self) -> None:
        """A starting record reaches no recovery or retirement primitive."""
        self.record("starting")
        arguments = argparse.Namespace(
            repo=str(self.repo),
            tmux_pane="%7",
            wait_timeout=4.0,
        )
        with (
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(MODULE, "recover_host_pane") as recover,
            mock.patch.object(MODULE, "respawn_host_editor") as respawn,
            mock.patch.object(MODULE, "remove_workspace_record") as remove,
            mock.patch.object(MODULE, "workspace_spool") as spool,
            self.assertRaisesRegex(MODULE.EditorError, "lifecycle is starting"),
        ):
            MODULE.cmd_host(arguments)

        recover.assert_not_called()
        respawn.assert_not_called()
        remove.assert_not_called()
        spool.assert_not_called()

    def test_explicit_host_command_rejects_running_reread_under_lock(self) -> None:
        """A racing running transition cannot enter inactive host recovery."""
        self.record("error")
        arguments = argparse.Namespace(
            repo=str(self.repo),
            tmux_pane="%7",
            wait_timeout=4.0,
        )
        original_lock = MODULE.workspace_lock

        @contextlib.contextmanager
        def transition_to_running(
            paths: MODULE.StateDirectories, root: pathlib.Path
        ) -> Iterator[int]:
            with original_lock(paths, root) as descriptor:
                current = MODULE.load_record(paths, root)
                MODULE.update_workspace_record(
                    paths, root, current, status="running", error=None
                )
                yield descriptor

        with (
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE, "workspace_lock", side_effect=transition_to_running
            ),
            mock.patch.object(MODULE, "request_active_host_action") as request,
            mock.patch.object(MODULE, "recover_host_pane") as recover,
            mock.patch.object(MODULE, "respawn_host_editor") as respawn,
            mock.patch.object(MODULE, "remove_workspace_record") as remove,
            mock.patch.object(MODULE, "workspace_spool") as spool,
            self.assertRaisesRegex(MODULE.EditorError, "lifecycle is running"),
        ):
            MODULE.cmd_host(arguments)

        request.assert_not_called()
        recover.assert_not_called()
        respawn.assert_not_called()
        remove.assert_not_called()
        spool.assert_not_called()
        self.assertEqual(MODULE.load_record(self.paths, self.repo)["status"], "running")

    def test_active_host_command_routes_through_coordinator_without_flock(self) -> None:
        """A live coordinator owns the flock, so host handoff uses its spool."""
        self.record("running")
        arguments = argparse.Namespace(
            repo=str(self.repo),
            tmux_pane="%7",
            wait_timeout=4.0,
        )
        with (
            mock.patch.object(
                MODULE,
                "prepare_state",
                return_value=self.paths,
            ),
            mock.patch.object(
                MODULE,
                "repo_root",
                return_value=self.repo,
            ),
            mock.patch.object(
                MODULE,
                "request_active_host_action",
            ) as request,
            mock.patch.object(
                MODULE,
                "workspace_lock",
                side_effect=AssertionError(
                    "active handoff attempted the held lifecycle flock"
                ),
            ),
        ):
            MODULE.cmd_host(arguments)

        request.assert_called_once_with(
            self.paths,
            self.repo,
            "host_editor",
            4.0,
            "%7",
        )

    def test_active_host_request_is_authenticated_and_waits_for_ack(self) -> None:
        """The external host switch publishes the same authenticated protocol as Neovim."""
        record = self.record("running")
        with (
            mock.patch.object(
                MODULE,
                "selected_record",
                return_value=record,
            ),
            mock.patch.object(
                MODULE,
                "verify_registered_container_pane",
            ) as verify,
            mock.patch.object(MODULE, "wait_ack") as wait,
        ):
            MODULE.request_active_host_action(
                self.paths,
                self.repo,
                "host_editor",
                4.0,
                "%7",
            )

        verify.assert_called_once_with(record, allow_dead=False)
        requests = list((self.spool.root / "outbox").glob("*.json"))
        self.assertEqual(len(requests), 1)
        request = MODULE.read_private_json(requests[0], "host request")
        self.assertEqual(request["action"], "host_editor")
        self.assertEqual(requests[0].name, f"{request['request_id']}.json")
        self.assertEqual(
            MODULE.validate_host_request(request, self.token, requests[0].name),
            request,
        )
        waited_spool, waited_token, waited_request, waited_timeout = wait.call_args.args
        self.assertEqual(waited_spool.root, self.spool.root)
        self.assertEqual(waited_token, self.token)
        self.assertEqual(waited_request, request)
        self.assertEqual(waited_timeout, 4.0)

    def test_explicit_host_command_claims_absent_state_before_respawn(self) -> None:
        """Host mode replaces an unowned pane while retaining the workspace lock."""
        arguments = argparse.Namespace(repo=str(self.repo), tmux_pane="%7")

        def restore(
            root: pathlib.Path, pane: str, pane_pid: int
        ) -> MODULE.PaneObservation:
            self.assertEqual((root, pane, pane_pid), (self.repo, "%7", 7007))
            with (
                self.assertRaisesRegex(MODULE.EditorError, "busy"),
                MODULE.workspace_lock(
                    self.paths,
                    self.repo,
                ),
            ):
                pass
            return MODULE.PaneObservation(False, 8008, None, "")

        with (
            mock.patch.object(MODULE, "prepare_state", return_value=self.paths),
            mock.patch.object(
                MODULE,
                "repo_root",
                return_value=self.repo,
            ),
            mock.patch.object(
                MODULE,
                "require_editor_pane",
                return_value=("%7", 7007),
            ),
            mock.patch.object(
                MODULE,
                "respawn_unowned_host_editor",
                side_effect=restore,
            ) as respawn,
        ):
            MODULE.cmd_host(arguments)

        respawn.assert_called_once_with(self.repo, "%7", 7007)
        self.assertFalse(MODULE.record_path(self.paths, self.repo).exists())

    def test_explicit_host_command_rejects_a_reused_pane_pid(self) -> None:
        """A stale lifecycle record never authorizes respawning another pane process."""
        self.record("dead")
        arguments = argparse.Namespace(repo=str(self.repo))
        changed = MODULE.PaneObservation(True, 9999, 0, MODULE.pane_marker(self.repo))
        with (
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "observe_pane",
                return_value=changed,
            ),
            mock.patch.object(MODULE, "respawn_host_editor") as respawn,
            self.assertRaisesRegex(
                MODULE.EditorError,
                "PID no longer matches",
            ),
        ):
            MODULE.cmd_host(arguments)

        respawn.assert_not_called()
        self.assertEqual(MODULE.load_record(self.paths, self.repo)["status"], "error")

    def test_monitor_reconciles_once_more_on_quick_pane_exit(self) -> None:
        """A quick pane exit still performs final authenticated reconciliation."""
        record = self.record()
        record["pane_pid"] = 123
        spool = self.spool
        with (
            mock.patch.object(
                MODULE,
                "consume_outbox",
                return_value=(0, False),
            ) as consume,
            mock.patch.object(
                MODULE,
                "observe_pane",
                return_value=MODULE.PaneObservation(
                    True, 123, 9, MODULE.pane_marker(self.repo)
                ),
            ),
        ):
            self.assertEqual(
                MODULE.monitor_editor(
                    self.paths,
                    spool,
                    record,
                    self.token,
                    mock.Mock(identity=MODULE.DirectoryIdentity(1, 2, os.getuid())),
                ),
                (9, False),
            )
        self.assertEqual(consume.call_count, 2)

    def test_quick_exit_final_reconciliation_preserves_verified_handoff(self) -> None:
        """A handoff consumed after pane death does not recreate retired state."""
        record = self.record()
        record["pane_pid"] = 123
        spool = self.spool
        with (
            mock.patch.object(
                MODULE,
                "consume_outbox",
                side_effect=((0, False), (1, True)),
            ),
            mock.patch.object(
                MODULE,
                "observe_pane",
                return_value=MODULE.PaneObservation(
                    True, 123, 0, MODULE.pane_marker(self.repo)
                ),
            ),
        ):
            self.assertEqual(
                MODULE.monitor_editor(
                    self.paths,
                    spool,
                    record,
                    self.token,
                    mock.Mock(identity=MODULE.DirectoryIdentity(1, 2, os.getuid())),
                ),
                (0, True),
            )

    def test_monitor_cancellation_stays_fail_closed(self) -> None:
        """Explicit coordinator cancellation reports a lifecycle error."""
        record = self.record()
        record["pane_pid"] = 123
        spool = self.spool
        with (
            mock.patch.object(
                MODULE,
                "consume_outbox",
                return_value=(0, False),
            ),
            mock.patch.object(
                MODULE,
                "observe_pane",
                return_value=MODULE.PaneObservation(
                    False, 123, None, MODULE.pane_marker(self.repo)
                ),
            ),
            mock.patch.object(
                MODULE.time,
                "sleep",
                side_effect=KeyboardInterrupt,
            ),
            self.assertRaisesRegex(MODULE.EditorError, "cancelled"),
        ):
            MODULE.monitor_editor(
                self.paths,
                spool,
                record,
                self.token,
                mock.Mock(identity=MODULE.DirectoryIdentity(1, 2, os.getuid())),
            )

    def test_auth_secret_exists_only_in_private_auth_file(self) -> None:
        """The raw spool secret never enters records, argv, environment, or logs."""
        record = self.record()
        spool = self.spool
        self.assertEqual(MODULE.read_auth(spool), self.token)
        self.assertNotIn("token", record)
        projection = "\n".join(MODULE.remote_environment(record, "/tmp/private-spool"))
        self.assertNotIn(self.token, projection)
        command = MODULE.editor_argv(
            "/managed/devcontainer",
            "/managed/podman",
            self.repo,
            self.config,
            record,
            "/tmp/private-spool",
        )
        self.assertNotIn(self.token, "\n".join(command))
        self.assertIn("/managed/podman", command)
        self.assertNotIn("--workdir", command)
        self.assertEqual(
            command[-3:],
            [
                "nvim",
                "-u",
                "/tmp/private-spool/config-00000000-0000-4000-8000-000000000009/init.lua",
            ],
        )
        MODULE.append_log(MODULE.log_path(self.paths, self.repo), "lifecycle running")
        self.assertNotIn(
            self.token,
            MODULE.log_path(self.paths, self.repo).read_text(encoding="utf-8"),
        )

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
                observed = (
                    MODULE.decode_json_object(payload, "immediate message consumer"),
                    identity.links,
                )
            return published

        with mock.patch.object(MODULE, "exclusive_rename_at", side_effect=publish):
            MODULE.atomic_create_json_at(spool.inbox_fd, name, {"complete": True})

        self.assertTrue(published)
        self.assertEqual(observed, ({"complete": True}, 1))
        self.assertEqual(
            MODULE.read_private_json(request, "request"), {"complete": True}
        )
        self.assertEqual(stat.S_IMODE(request.stat().st_mode), 0o600)

    def test_atomic_message_race_preserves_rival_and_cleans_staging(self) -> None:
        """A rival winning the destination race is never clobbered by publication."""
        name = f"{uuid.uuid4()}.json"
        path = self.spool.root / "inbox" / name
        real_rename = MODULE.exclusive_rename_at

        def rival_wins(directory_fd: int, source: str, destination: str) -> bool:
            if destination == name:
                MODULE.direct_create_bytes_at(
                    directory_fd, destination, b'{"rival":true}\n'
                )
            return real_rename(directory_fd, source, destination)

        with (
            mock.patch.object(
                MODULE,
                "exclusive_rename_at",
                side_effect=rival_wins,
            ),
            self.assertRaisesRegex(
                MODULE.EditorError, "private message already exists"
            ),
        ):
            MODULE.atomic_create_json_at(self.spool.inbox_fd, name, {"ours": True})

        self.assertEqual(
            MODULE.read_private_json(path, "rival message"), {"rival": True}
        )
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

        with (
            mock.patch.object(
                MODULE,
                "fsync_directory",
                side_effect=MODULE.EditorError(
                    "injected acknowledgement directory fsync failure"
                ),
            ),
            mock.patch.object(
                MODULE,
                "progress",
                side_effect=OSError("stderr sink failed"),
            ) as reported,
        ):
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

        with (
            mock.patch.object(
                MODULE,
                "atomic_replace_json_at",
                side_effect=MODULE.EditorError("disk full"),
            ),
            self.assertRaisesRegex(MODULE.EditorError, "disk full"),
        ):
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

        with (
            mock.patch.object(MODULE, "atomic_replace_json_at") as replace,
            self.assertRaisesRegex(
                MODULE.EditorError,
                "container root is invalid",
            ),
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

        with (
            mock.patch.object(MODULE.os, "fsync", side_effect=fail_directory_sync),
            mock.patch.object(
                MODULE,
                "progress",
            ) as reported,
        ):
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

    def test_config_snapshot_copies_only_the_frozen_runtime_closure(self) -> None:
        """A claim snapshot is independent, exact, readable, and non-writable."""
        source = self.snapshot_source()
        claim = "00000000-0000-4000-8000-000000000041"
        snapshot = MODULE.create_config_snapshot(self.spool, claim, source)
        try:
            self.assertEqual(
                {entry.name for entry in snapshot.path.iterdir()},
                set(MODULE.CONFIG_SNAPSHOT_REQUIRED + MODULE.CONFIG_SNAPSHOT_OPTIONAL)
                | {MODULE.CONFIG_SNAPSHOT_MARKER_NAME},
            )
            self.assertFalse((snapshot.path / "not-runtime").exists())
            for entry in snapshot.path.rglob("*"):
                mode = stat.S_IMODE(entry.stat().st_mode)
                self.assertEqual(mode & 0o222, 0, entry)
                self.assertTrue(mode & 0o400, entry)
                if entry.is_dir():
                    self.assertTrue(mode & 0o100, entry)
            source_runtime = source / "lua/runtime.lua"
            copied_runtime = snapshot.path / "lua/runtime.lua"
            self.assertNotEqual(
                (source_runtime.stat().st_dev, source_runtime.stat().st_ino),
                (copied_runtime.stat().st_dev, copied_runtime.stat().st_ino),
            )
            self.assertEqual(copied_runtime.stat().st_nlink, 1)
            source_runtime.write_text("return { changed = true }\n", encoding="utf-8")
            self.assertEqual(copied_runtime.read_text(encoding="utf-8"), "return {}\n")
            self.assertEqual(
                stat.S_IMODE((snapshot.path / "scripts/runner").stat().st_mode), 0o500
            )
        finally:
            MODULE.remove_claim_snapshot(self.spool, claim, snapshot.identity)
            os.close(snapshot.descriptor)
        self.assertFalse(snapshot.path.exists())

    def test_config_snapshot_rejects_unsafe_source_entries_and_bounds(self) -> None:
        """Links, special/writable entries, and each resource bound fail closed."""
        cases = ("symlink", "special", "hardlink", "writable-file", "writable-dir")
        for index, case in enumerate(cases):
            with self.subTest(case=case):
                source = self.snapshot_source(f"unsafe-{index}")
                runtime = source / "lua/runtime.lua"
                if case == "symlink":
                    (source / "lua/link.lua").symlink_to(runtime)
                elif case == "special":
                    os.mkfifo(source / "lua/fifo")
                elif case == "hardlink":
                    os.link(runtime, source / "lua/alias.lua")
                elif case == "writable-file":
                    runtime.chmod(0o666)
                else:
                    (source / "lua").chmod(0o777)
                with self.assertRaisesRegex(MODULE.EditorError, "owner-controlled"):
                    MODULE.validate_config_snapshot_source(source)

        for limit, value, message in (
            ("MAX_CONFIG_SNAPSHOT_FILES", 0, "file-count"),
            ("MAX_CONFIG_SNAPSHOT_BYTES", 1, "byte-size"),
            ("MAX_CONFIG_SNAPSHOT_DEPTH", 1, "directory-depth"),
            ("MAX_CONFIG_SNAPSHOT_DIRECTORIES", 0, "directory-count"),
            (
                "MAX_CONFIG_SNAPSHOT_DIRECTORY_ENTRIES",
                0,
                "per-directory entry-count",
            ),
        ):
            with self.subTest(limit=limit):
                source = self.snapshot_source(f"bounded-{limit}")
                with (
                    mock.patch.object(MODULE, limit, value),
                    self.assertRaisesRegex(MODULE.EditorError, message),
                ):
                    MODULE.validate_config_snapshot_source(source)

    def test_config_snapshot_detects_source_change_and_cleans_staging(self) -> None:
        """A source mutation during byte copy leaves no published or staging tree."""
        source = self.snapshot_source("changing-source")
        claim = "00000000-0000-4000-8000-000000000042"
        original_copy = MODULE.write_snapshot_bytes
        changed = False

        def mutate_after_copy(
            source_fd: int, destination_fd: int, expected_size: int
        ) -> int:
            nonlocal changed
            copied = original_copy(source_fd, destination_fd, expected_size)
            if not changed:
                changed = True
                (source / "init.lua").write_text(
                    "return false -- changed during copy\n", encoding="utf-8"
                )
            return copied

        with (
            mock.patch.object(
                MODULE, "write_snapshot_bytes", side_effect=mutate_after_copy
            ),
            self.assertRaisesRegex(MODULE.EditorError, "changed while copying"),
        ):
            MODULE.create_config_snapshot(self.spool, claim, source)
        self.assertTrue(changed)
        self.assertFalse((self.spool.root / MODULE.snapshot_name(claim)).exists())
        self.assertEqual(list(self.spool.root.glob(".config-*.tmp")), [])

    def test_config_snapshot_publication_never_clobbers_a_destination(self) -> None:
        """Existing snapshots and hostile destination links remain untouched."""
        source = self.snapshot_source("collision-source")
        claim = "00000000-0000-4000-8000-000000000043"
        snapshot = MODULE.create_config_snapshot(self.spool, claim, source)
        try:
            with self.assertRaisesRegex(MODULE.EditorError, "already exists"):
                MODULE.create_config_snapshot(self.spool, claim, source)
            self.assertEqual(
                MODULE.directory_identity(snapshot.path.stat()), snapshot.identity
            )
        finally:
            MODULE.remove_claim_snapshot(self.spool, claim, snapshot.identity)
            os.close(snapshot.descriptor)

        hostile_claim = "00000000-0000-4000-8000-000000000044"
        outside = self.root / "outside-snapshot"
        outside.mkdir()
        victim = outside / "must-remain"
        victim.write_text("unchanged\n", encoding="utf-8")
        hostile = self.spool.root / MODULE.snapshot_name(hostile_claim)
        hostile.symlink_to(outside, target_is_directory=True)
        try:
            with self.assertRaisesRegex(MODULE.EditorError, "already exists"):
                MODULE.create_config_snapshot(self.spool, hostile_claim, source)
            self.assertEqual(victim.read_text(encoding="utf-8"), "unchanged\n")
        finally:
            hostile.unlink()

    def test_config_snapshot_cleanup_does_not_follow_replacement_link(self) -> None:
        """Cleanup preserves a hostile replacement and the outside target."""
        source = self.snapshot_source("cleanup-source")
        claim = "00000000-0000-4000-8000-000000000045"
        snapshot = MODULE.create_config_snapshot(self.spool, claim, source)
        displaced_name = f"{snapshot.name}-displaced"
        displaced = self.spool.root / displaced_name
        outside = self.root / "cleanup-outside"
        outside.mkdir()
        victim = outside / "must-remain"
        victim.write_text("unchanged\n", encoding="utf-8")
        snapshot.path.rename(displaced)
        snapshot.path.symlink_to(outside, target_is_directory=True)
        try:
            with self.assertRaisesRegex(MODULE.EditorError, "real directory"):
                MODULE.remove_claim_snapshot(self.spool, claim, snapshot.identity)
            self.assertEqual(victim.read_text(encoding="utf-8"), "unchanged\n")
        finally:
            snapshot.path.unlink()
            MODULE.remove_snapshot_entry_at(
                self.spool.root_fd, displaced_name, snapshot.identity
            )
            os.close(snapshot.descriptor)

    def test_snapshot_lease_is_closed_private_and_filename_bound(self) -> None:
        """The host-only cleanup proof is exact, 0600, and not a record filename."""
        record = self.record("error")
        snapshot = MODULE.create_config_snapshot(
            self.spool,
            record["claim_id"],
            self.snapshot_source("lease-source"),
        )
        self.addCleanup(os.close, snapshot.descriptor)
        lease = MODULE.publish_snapshot_lease(
            self.paths, self.spool, self.repo, record["claim_id"], snapshot
        )
        path = self.paths["workspaces"] / lease.state_name
        self.assertFalse(path.name.endswith(".json"))
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        payload = MODULE.read_private_json(path, "config snapshot lease")
        self.assertEqual(set(payload), MODULE.SNAPSHOT_LEASE_KEYS)
        self.assertEqual(payload["host_root"], str(self.repo))
        self.assertEqual(payload["claim_id"], record["claim_id"])
        self.assertEqual(payload["snapshot_name"], snapshot.name)
        self.assertEqual(
            (payload["device"], payload["inode"], payload["owner"]),
            tuple(snapshot.identity),
        )
        marker_path = snapshot.path / MODULE.CONFIG_SNAPSHOT_MARKER_NAME
        marker_path.chmod(0o600)
        marker_path.write_text("different-marker\n", encoding="utf-8")
        marker_path.chmod(0o400)
        with self.assertRaisesRegex(MODULE.EditorError, "marker does not match"):
            MODULE.load_snapshot_lease(
                self.paths,
                self.spool,
                self.repo,
                record["claim_id"],
            )
        marker_path.chmod(0o600)
        marker_path.write_text(f"{snapshot.marker}\n", encoding="utf-8")
        marker_path.chmod(0o400)
        payload["unexpected"] = True
        MODULE.atomic_replace_json_at(
            self.paths.descriptor("workspaces"), lease.state_name, payload
        )
        with self.assertRaisesRegex(MODULE.EditorError, "schema is invalid"):
            MODULE.load_snapshot_lease(
                self.paths,
                self.spool,
                self.repo,
                record["claim_id"],
            )
        MODULE.unlink_regular_at(self.paths.descriptor("workspaces"), lease.state_name)
        MODULE.remove_claim_snapshot(self.spool, record["claim_id"], snapshot.identity)

    def test_snapshot_lease_preserves_replacement_owner_directory(self) -> None:
        """Persisted cleanup authority never removes a same-owner replacement."""
        record = self.record("error")
        snapshot = MODULE.create_config_snapshot(
            self.spool,
            record["claim_id"],
            self.snapshot_source("lease-replacement-source"),
        )
        self.addCleanup(os.close, snapshot.descriptor)
        MODULE.publish_snapshot_lease(
            self.paths, self.spool, self.repo, record["claim_id"], snapshot
        )
        displaced = snapshot.path.with_name(f"{snapshot.name}-original")
        snapshot.path.rename(displaced)
        snapshot.path.mkdir(mode=0o500)
        try:
            with self.assertRaisesRegex(MODULE.EditorError, "identity changed"):
                MODULE.retire_claim_snapshot(
                    self.paths,
                    self.spool,
                    self.repo,
                    record["claim_id"],
                )
            self.assertTrue(snapshot.path.is_dir())
            self.assertTrue(
                (
                    self.paths["workspaces"] / MODULE.snapshot_lease_name(self.repo)
                ).exists()
            )
        finally:
            snapshot.path.chmod(0o700)
            snapshot.path.rmdir()
            displaced.rename(snapshot.path)
            MODULE.retire_claim_snapshot(
                self.paths,
                self.spool,
                self.repo,
                record["claim_id"],
                snapshot.identity,
            )

    def test_container_respawn_revalidates_snapshot_before_atomic_replace(self) -> None:
        """A replaced snapshot stops immediately before the pane replacement."""
        record = self.record()
        snapshot = MODULE.create_config_snapshot(
            self.spool,
            record["claim_id"],
            self.snapshot_source("pre-respawn-replacement-source"),
        )
        self.addCleanup(os.close, snapshot.descriptor)
        displaced = snapshot.path.with_name(f"{snapshot.name}-respawn-original")
        snapshot.path.rename(displaced)
        snapshot.path.mkdir(mode=0o500)
        before = MODULE.PaneObservation(False, 7007, None, "")
        try:
            with (
                mock.patch.object(MODULE.shutil, "which", return_value="/opt/tmux"),
                mock.patch.object(MODULE, "observe_pane", return_value=before),
                mock.patch.object(MODULE, "run"),
                mock.patch.object(MODULE, "atomic_pane_respawn") as atomic_respawn,
                self.assertRaisesRegex(MODULE.EditorError, "pinned directory"),
            ):
                MODULE.respawn_container_editor(
                    record,
                    ["devcontainer", "exec", "nvim"],
                    self.spool,
                    snapshot,
                )
            atomic_respawn.assert_not_called()
            self.assertTrue(snapshot.path.is_dir())
        finally:
            snapshot.path.chmod(0o700)
            snapshot.path.rmdir()
            displaced.rename(snapshot.path)
            MODULE.remove_claim_snapshot(
                self.spool, record["claim_id"], snapshot.identity
            )

    def test_snapshot_without_sidecar_fails_closed(self) -> None:
        """Cross-process recovery cannot infer authority from a claim basename."""
        record = self.record("error")
        snapshot = MODULE.create_config_snapshot(
            self.spool,
            record["claim_id"],
            self.snapshot_source("unleased-source"),
        )
        self.addCleanup(os.close, snapshot.descriptor)
        with self.assertRaisesRegex(MODULE.EditorError, "without host-only"):
            MODULE.load_snapshot_lease(
                self.paths,
                self.spool,
                self.repo,
                record["claim_id"],
            )
        self.assertTrue(snapshot.path.is_dir())
        MODULE.remove_claim_snapshot(self.spool, record["claim_id"], snapshot.identity)

    def test_snapshot_context_cleans_on_base_exception(self) -> None:
        """Resource cleanup runs from finally without catching BaseException."""
        claim = "00000000-0000-4000-8000-000000000046"
        source = self.snapshot_source("base-exception-source")
        with (
            mock.patch.object(MODULE, "CONFIG_ROOT", source),
            self.assertRaises(KeyboardInterrupt),
            MODULE.lifecycle_config_snapshot(self.paths, self.spool, self.repo, claim),
        ):
            raise KeyboardInterrupt
        self.assertFalse((self.spool.root / MODULE.snapshot_name(claim)).exists())
        self.assertFalse(
            (self.paths["workspaces"] / MODULE.snapshot_lease_name(self.repo)).exists()
        )

    def test_snapshot_creation_interrupt_cleans_staging_and_descriptor(self) -> None:
        """An interrupted closure copy owns and retires its staging resources."""
        source = self.snapshot_source("creation-interrupt-source")
        claim = "00000000-0000-4000-8000-000000000047"
        descriptors: list[int] = []
        real_create = MODULE.create_snapshot_directory_at

        def capture_directory(parent_fd: int, name: str) -> int:
            descriptor = real_create(parent_fd, name)
            descriptors.append(descriptor)
            return descriptor

        with (
            mock.patch.object(
                MODULE,
                "create_snapshot_directory_at",
                side_effect=capture_directory,
            ),
            mock.patch.object(
                MODULE,
                "populate_or_validate_config_snapshot",
                side_effect=KeyboardInterrupt,
            ),
            self.assertRaises(KeyboardInterrupt),
        ):
            MODULE.create_config_snapshot(self.spool, claim, source)

        self.assertEqual(len(descriptors), 1)
        with self.assertRaises(OSError):
            os.fstat(descriptors[0])
        self.assertFalse((self.spool.root / MODULE.snapshot_name(claim)).exists())
        self.assertEqual(list(self.spool.root.glob(".config-*.tmp")), [])

    def test_temporary_file_identity_interrupt_closes_and_unlinks(self) -> None:
        """An interrupted first fstat recovers inode identity before cleanup."""
        temporary = ".identity-interrupt.tmp"
        descriptors: list[int] = []
        interrupted = False
        real_open = MODULE.os.open
        real_fstat = MODULE.os.fstat

        def capture_open(
            path: object, flags: int, *args: object, **kwargs: object
        ) -> int:
            descriptor = real_open(path, flags, *args, **kwargs)
            if path == temporary and kwargs.get("dir_fd") == self.spool.inbox_fd:
                descriptors.append(descriptor)
            return descriptor

        def interrupt_fstat(descriptor: int) -> os.stat_result:
            nonlocal interrupted
            if descriptors and descriptor == descriptors[0] and not interrupted:
                interrupted = True
                raise KeyboardInterrupt
            return real_fstat(descriptor)

        with (
            mock.patch.object(MODULE.os, "open", side_effect=capture_open),
            mock.patch.object(MODULE.os, "fstat", side_effect=interrupt_fstat),
            self.assertRaises(KeyboardInterrupt),
        ):
            MODULE.create_temporary_at(
                self.spool.inbox_fd,
                "target.json",
                b"payload\n",
                temporary_name=temporary,
            )

        self.assertTrue(interrupted)
        self.assertFalse((self.spool.root / "inbox" / temporary).exists())
        with self.assertRaises(OSError):
            os.fstat(descriptors[0])

    def test_snapshot_marker_identity_interrupt_closes_and_unlinks(self) -> None:
        """Marker creation also cleans an interrupted descriptor validation."""
        directory = self.root / "marker-interrupt"
        directory.mkdir(mode=0o700)
        directory_fd = os.open(directory, MODULE.directory_flags())
        descriptors: list[int] = []
        interrupted = False
        real_open = MODULE.os.open
        real_fstat = MODULE.os.fstat

        def capture_open(
            path: object, flags: int, *args: object, **kwargs: object
        ) -> int:
            descriptor = real_open(path, flags, *args, **kwargs)
            if (
                path == MODULE.CONFIG_SNAPSHOT_MARKER_NAME
                and kwargs.get("dir_fd") == directory_fd
            ):
                descriptors.append(descriptor)
            return descriptor

        def interrupt_fstat(descriptor: int) -> os.stat_result:
            nonlocal interrupted
            if descriptors and descriptor == descriptors[0] and not interrupted:
                interrupted = True
                raise KeyboardInterrupt
            return real_fstat(descriptor)

        try:
            with (
                mock.patch.object(MODULE.os, "open", side_effect=capture_open),
                mock.patch.object(MODULE.os, "fstat", side_effect=interrupt_fstat),
                self.assertRaises(KeyboardInterrupt),
            ):
                MODULE.create_snapshot_marker_at(directory_fd, "m" * 32)
        finally:
            os.close(directory_fd)

        self.assertTrue(interrupted)
        self.assertFalse((directory / MODULE.CONFIG_SNAPSHOT_MARKER_NAME).exists())
        with self.assertRaises(OSError):
            os.fstat(descriptors[0])

    def test_snapshot_publication_interrupt_cleans_published_identity(self) -> None:
        """A signal after the snapshot rename cannot strand its final basename."""
        source = self.snapshot_source("publication-interrupt-source")
        claim = "00000000-0000-4000-8000-000000000048"
        final_name = MODULE.snapshot_name(claim)
        descriptors: list[int] = []
        real_create = MODULE.create_snapshot_directory_at
        real_rename = MODULE.exclusive_rename_at

        def capture_directory(parent_fd: int, name: str) -> int:
            descriptor = real_create(parent_fd, name)
            descriptors.append(descriptor)
            return descriptor

        def interrupt_after_rename(
            directory_fd: int, source_name: str, destination: str
        ) -> bool:
            renamed = real_rename(directory_fd, source_name, destination)
            if destination == final_name and renamed:
                raise SystemExit(71)
            return renamed

        with (
            mock.patch.object(
                MODULE,
                "create_snapshot_directory_at",
                side_effect=capture_directory,
            ),
            mock.patch.object(
                MODULE,
                "exclusive_rename_at",
                side_effect=interrupt_after_rename,
            ),
            self.assertRaises(SystemExit) as exited,
        ):
            MODULE.create_config_snapshot(self.spool, claim, source)

        self.assertEqual(exited.exception.code, 71)
        with self.assertRaises(OSError):
            os.fstat(descriptors[0])
        self.assertFalse((self.spool.root / final_name).exists())
        self.assertEqual(list(self.spool.root.glob(".config-*.tmp")), [])

    def test_snapshot_child_interrupt_closes_source_descriptor(self) -> None:
        """A bound failure after opening a source directory closes its descriptor."""
        source = self.snapshot_source("child-interrupt-source")
        source_fd, _ = MODULE.open_snapshot_source_path(source)
        descriptors: list[int] = []
        real_open = MODULE.open_snapshot_source_directory_at

        def capture_child(*args: object, **kwargs: object) -> int:
            descriptor = real_open(*args, **kwargs)
            descriptors.append(descriptor)
            return descriptor

        try:
            with (
                mock.patch.object(
                    MODULE,
                    "open_snapshot_source_directory_at",
                    side_effect=capture_child,
                ),
                mock.patch.object(
                    MODULE,
                    "bounded_snapshot_directory",
                    side_effect=KeyboardInterrupt,
                ),
                self.assertRaises(KeyboardInterrupt),
            ):
                MODULE.copy_or_validate_snapshot_entry_at(
                    source_fd,
                    None,
                    "lua",
                    1,
                    MODULE.SnapshotTotals(0, 0),
                )
        finally:
            os.close(source_fd)

        self.assertEqual(len(descriptors), 1)
        with self.assertRaises(OSError):
            os.fstat(descriptors[0])

    def test_snapshot_revalidation_rechecks_basename_after_tree_walk(self) -> None:
        """A basename replacement during traversal is rejected before use."""
        source = self.snapshot_source("revalidation-race-source")
        claim = "00000000-0000-4000-8000-000000000049"
        snapshot = MODULE.create_config_snapshot(self.spool, claim, source)
        displaced = snapshot.path.with_name(f"{snapshot.name}-original")
        real_validate = MODULE.validate_config_snapshot_tree
        replaced = False

        def replace_after_validation(
            directory_fd: int, marker: str, depth: int = 0
        ) -> MODULE.SnapshotTotals:
            nonlocal replaced
            totals = real_validate(directory_fd, marker, depth)
            if depth == 0 and not replaced:
                replaced = True
                snapshot.path.rename(displaced)
                snapshot.path.mkdir(mode=0o500)
            return totals

        try:
            with (
                mock.patch.object(
                    MODULE,
                    "validate_config_snapshot_tree",
                    side_effect=replace_after_validation,
                ),
                self.assertRaisesRegex(MODULE.EditorError, "changed during"),
            ):
                MODULE.revalidate_config_snapshot(self.spool, snapshot)
            self.assertTrue(snapshot.path.is_dir())
            self.assertTrue(displaced.is_dir())
        finally:
            snapshot.path.chmod(0o700)
            snapshot.path.rmdir()
            displaced.rename(snapshot.path)
            MODULE.remove_claim_snapshot(self.spool, claim, snapshot.identity)
            os.close(snapshot.descriptor)

    def test_snapshot_reservation_interrupt_restores_exact_basename(self) -> None:
        """A signal in rename ownership transfer restores the original snapshot."""
        source = self.snapshot_source("reservation-interrupt-source")
        claim = "00000000-0000-4000-8000-000000000050"
        snapshot = MODULE.create_config_snapshot(self.spool, claim, source)
        removal_descriptors: list[int] = []
        real_open = MODULE.open_snapshot_directory_at
        real_rename = MODULE.exclusive_rename_at

        def capture_open(parent_fd: int, name: str) -> object:
            opened = real_open(parent_fd, name)
            if name == snapshot.name and opened[0] is not None:
                removal_descriptors.append(opened[0])
            return opened

        def interrupt_reservation(
            directory_fd: int, source_name: str, destination: str
        ) -> bool:
            renamed = real_rename(directory_fd, source_name, destination)
            if source_name == snapshot.name and destination.endswith(".retire"):
                raise SystemExit(73)
            return renamed

        try:
            with (
                mock.patch.object(
                    MODULE,
                    "open_snapshot_directory_at",
                    side_effect=capture_open,
                ),
                mock.patch.object(
                    MODULE,
                    "exclusive_rename_at",
                    side_effect=interrupt_reservation,
                ),
                self.assertRaises(SystemExit) as exited,
            ):
                MODULE.remove_claim_snapshot(self.spool, claim, snapshot.identity)
            self.assertEqual(exited.exception.code, 73)
            self.assertEqual(
                MODULE.directory_identity(snapshot.path.stat()), snapshot.identity
            )
            self.assertEqual(
                list(self.spool.root.glob(f".{snapshot.name}.*.retire")), []
            )
            with self.assertRaises(OSError):
                os.fstat(removal_descriptors[0])
        finally:
            MODULE.remove_claim_snapshot(self.spool, claim, snapshot.identity)
            os.close(snapshot.descriptor)

    def test_snapshot_cleanup_interrupt_finishes_partial_retirement(self) -> None:
        """An interruption after retirement begins never restores a partial tree."""
        source = self.snapshot_source("cleanup-interrupt-source")
        claim = "00000000-0000-4000-8000-000000000051"
        snapshot = MODULE.create_config_snapshot(self.spool, claim, source)
        real_clear = MODULE.clear_snapshot_directory
        interrupted = False

        def interrupt_once(descriptor: int, depth: int = 0) -> None:
            nonlocal interrupted
            if not interrupted:
                interrupted = True
                raise KeyboardInterrupt
            real_clear(descriptor, depth)

        try:
            with (
                mock.patch.object(
                    MODULE,
                    "clear_snapshot_directory",
                    side_effect=interrupt_once,
                ),
                self.assertRaises(KeyboardInterrupt),
            ):
                MODULE.remove_claim_snapshot(self.spool, claim, snapshot.identity)
            self.assertTrue(interrupted)
            self.assertFalse(snapshot.path.exists())
            self.assertEqual(list(self.spool.root.glob("*.retire")), [])
        finally:
            if snapshot.path.exists():
                MODULE.remove_claim_snapshot(self.spool, claim, snapshot.identity)
            os.close(snapshot.descriptor)

    def test_snapshot_lease_reload_interrupt_rolls_back_exact_sidecar(self) -> None:
        """A post-create lease validation interrupt leaves no sidecar."""
        record = self.record("error")
        snapshot = MODULE.create_config_snapshot(
            self.spool,
            record["claim_id"],
            self.snapshot_source("lease-reload-interrupt-source"),
        )
        sidecar = self.paths["workspaces"] / MODULE.snapshot_lease_name(self.repo)
        try:
            with (
                mock.patch.object(
                    MODULE,
                    "load_snapshot_lease",
                    side_effect=KeyboardInterrupt,
                ),
                self.assertRaises(KeyboardInterrupt),
            ):
                MODULE.publish_snapshot_lease(
                    self.paths,
                    self.spool,
                    self.repo,
                    record["claim_id"],
                    snapshot,
                )
            self.assertFalse(sidecar.exists())
            self.assertEqual(list(sidecar.parent.glob(f".{sidecar.name}.*.tmp")), [])
        finally:
            MODULE.remove_claim_snapshot(
                self.spool, record["claim_id"], snapshot.identity
            )
            os.close(snapshot.descriptor)

    def test_duplicate_snapshot_lease_publish_preserves_first_identity(self) -> None:
        """A no-clobber failure cannot adopt or delete an existing valid lease."""
        record = self.record("error")
        snapshot = MODULE.create_config_snapshot(
            self.spool,
            record["claim_id"],
            self.snapshot_source("duplicate-lease-source"),
        )
        lease = MODULE.publish_snapshot_lease(
            self.paths, self.spool, self.repo, record["claim_id"], snapshot
        )
        sidecar = self.paths["workspaces"] / lease.state_name
        before = sidecar.read_bytes()
        try:
            with self.assertRaisesRegex(MODULE.EditorError, "already exists"):
                MODULE.publish_snapshot_lease(
                    self.paths,
                    self.spool,
                    self.repo,
                    record["claim_id"],
                    snapshot,
                )
            self.assertEqual(sidecar.read_bytes(), before)
            self.assertEqual(MODULE.file_identity(sidecar.stat()), lease.state_identity)
        finally:
            MODULE.retire_snapshot_lease(self.paths, self.spool, self.repo, lease)
            os.close(snapshot.descriptor)

    def test_snapshot_lease_rename_interrupt_cleans_lifecycle(self) -> None:
        """A signal after sidecar rename retires both lifecycle artifacts."""
        claim = "00000000-0000-4000-8000-000000000052"
        source = self.snapshot_source("lease-rename-interrupt-source")
        state_name = MODULE.snapshot_lease_name(self.repo)
        real_rename = MODULE.exclusive_rename_at
        snapshots: list[MODULE.ConfigSnapshot] = []
        real_create = MODULE.create_config_snapshot

        def capture_snapshot(*args: object, **kwargs: object) -> object:
            snapshot = real_create(*args, **kwargs)
            snapshots.append(snapshot)
            return snapshot

        def interrupt_sidecar_rename(
            directory_fd: int, source_name: str, destination: str
        ) -> bool:
            renamed = real_rename(directory_fd, source_name, destination)
            if (
                directory_fd == self.paths.descriptor("workspaces")
                and destination == state_name
                and renamed
            ):
                raise SystemExit(74)
            return renamed

        with (
            mock.patch.object(MODULE, "CONFIG_ROOT", source),
            mock.patch.object(
                MODULE,
                "create_config_snapshot",
                side_effect=capture_snapshot,
            ),
            mock.patch.object(
                MODULE,
                "exclusive_rename_at",
                side_effect=interrupt_sidecar_rename,
            ),
            self.assertRaises(SystemExit) as exited,
            MODULE.lifecycle_config_snapshot(self.paths, self.spool, self.repo, claim),
        ):
            self.fail("lifecycle yielded after interrupted sidecar publication")

        self.assertEqual(exited.exception.code, 74)
        self.assertFalse((self.spool.root / MODULE.snapshot_name(claim)).exists())
        self.assertFalse((self.paths["workspaces"] / state_name).exists())
        self.assertEqual(
            list(self.paths["workspaces"].glob(f".{state_name}.*.tmp")), []
        )
        self.assertEqual(len(snapshots), 1)
        with self.assertRaises(OSError):
            os.fstat(snapshots[0].descriptor)

    def test_snapshot_context_preserves_sidecar_replacement(self) -> None:
        """Cleanup removes its snapshot but never a replacement lease file."""
        claim = "00000000-0000-4000-8000-000000000053"
        source = self.snapshot_source("sidecar-replacement-source")
        state_name = MODULE.snapshot_lease_name(self.repo)
        sidecar = self.paths["workspaces"] / state_name
        displaced = sidecar.with_name(f"{sidecar.name}.original")
        snapshot_path = self.spool.root / MODULE.snapshot_name(claim)
        original_identity: MODULE.FileIdentity | None = None
        replacement_identity: MODULE.FileIdentity | None = None
        try:
            with (
                mock.patch.object(MODULE, "CONFIG_ROOT", source),
                self.assertRaisesRegex(MODULE.EditorError, "changed during"),
                MODULE.lifecycle_config_snapshot(
                    self.paths, self.spool, self.repo, claim
                ),
            ):
                original_identity = MODULE.file_identity(sidecar.stat())
                sidecar.rename(displaced)
                replacement_identity = MODULE.atomic_create_bytes_at(
                    self.paths.descriptor("workspaces"),
                    state_name,
                    b'{"replacement":true}\n',
                )
            self.assertFalse(snapshot_path.exists())
            self.assertEqual(sidecar.read_bytes(), b'{"replacement":true}\n')
            self.assertTrue(displaced.exists())
        finally:
            if replacement_identity is not None:
                MODULE.unlink_regular_at(
                    self.paths.descriptor("workspaces"),
                    state_name,
                    expected=replacement_identity,
                )
            if original_identity is not None:
                MODULE.remove_file_identity_at(
                    self.paths.descriptor("workspaces"),
                    (displaced.name,),
                    original_identity,
                )

    def test_missing_sidecar_cleanup_still_retires_snapshot(self) -> None:
        """A disappeared lease reports failure after removing its exact snapshot."""
        claim = "00000000-0000-4000-8000-000000000054"
        source = self.snapshot_source("missing-sidecar-source")
        state_name = MODULE.snapshot_lease_name(self.repo)
        snapshot_path = self.spool.root / MODULE.snapshot_name(claim)

        with (
            mock.patch.object(MODULE, "CONFIG_ROOT", source),
            self.assertRaisesRegex(MODULE.EditorError, "disappeared before retirement"),
            MODULE.lifecycle_config_snapshot(self.paths, self.spool, self.repo, claim),
        ):
            MODULE.unlink_regular_at(self.paths.descriptor("workspaces"), state_name)

        self.assertFalse(snapshot_path.exists())
        self.assertFalse((self.paths["workspaces"] / state_name).exists())

    def test_exec_preserves_empty_nonprogram_arguments(self) -> None:
        """The fixed cwd trampoline retains empty and shell-shaped argv elements."""
        record = self.record()
        nested = self.repo / "nested"
        nested.mkdir()
        arguments = argparse.Namespace(
            cwd=str(nested),
            argv=["--", "printf", "%s", "", "; touch /tmp/nope", "$(false)"],
        )
        result = subprocess.CompletedProcess(["devcontainer", "exec"], 0, b"", b"")

        with (
            mock.patch.object(MODULE, "prepare_state", return_value=self.paths),
            mock.patch.object(
                MODULE,
                "canonical_root",
                return_value=nested,
            ),
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "selected_record",
                return_value=record,
            ),
            mock.patch.object(
                MODULE,
                "run",
                return_value=result,
            ) as execute,
            self.assertRaises(SystemExit) as exited,
        ):
            MODULE.cmd_exec(arguments)

        self.assertEqual(exited.exception.code, 0)
        execute.assert_called_once_with(
            [
                str(self.cli),
                "exec",
                "--workspace-folder",
                str(self.repo),
                "--config",
                str(self.config),
                "--docker-path",
                str(self.docker),
                "/bin/sh",
                "-c",
                MODULE.EXEC_CWD_TRAMPOLINE,
                "nvim-devcontainer-exec",
                "/workspaces/repo/nested",
                "printf",
                "%s",
                "",
                "; touch /tmp/nope",
                "$(false)",
            ],
            check=False,
            env=None,
        )

    def test_legacy_record_is_readable_but_cannot_execute_or_restart(self) -> None:
        """Version-2 state remains inspectable without guessing a CLI identity."""
        record = self.record("dead")
        record["version"] = MODULE.LEGACY_RECORD_VERSION
        record.pop("phase")
        record.pop("podman_connection")
        record.pop("cli_path")
        record.pop("docker_path")
        MODULE.atomic_json(MODULE.record_path(self.paths, self.repo), record)

        loaded = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(loaded["version"], 2)
        self.assertNotIn("cli_path", loaded)
        with self.assertRaisesRegex(MODULE.EditorError, "legacy workspace records"):
            MODULE.stored_cli_path(loaded)

        arguments = argparse.Namespace(
            repo=str(self.repo),
            tmux_pane="%7",
            claim_id="00000000-0000-4000-8000-000000000088",
            recreate=False,
            timeout=1.0,
        )
        with (
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            self.assertRaisesRegex(
                MODULE.EditorError,
                "predates the pinned runtime executable contract",
            ),
        ):
            MODULE.cmd_restart_dead(arguments)
        self.assertEqual(MODULE.load_record(self.paths, self.repo)["version"], 2)

        record = self.record("dead")
        record["version"] = MODULE.CLI_RECORD_VERSION
        record.pop("phase")
        record.pop("podman_connection")
        record.pop("docker_path")
        MODULE.atomic_json(MODULE.record_path(self.paths, self.repo), record)
        loaded = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(MODULE.stored_cli_path(loaded), str(self.cli))
        with self.assertRaisesRegex(MODULE.EditorError, "predates the pinned Docker"):
            MODULE.stored_runtime_paths(loaded)

    def test_exec_uses_persisted_cli_when_path_resolution_drifts(self) -> None:
        """An active record, not the caller's current PATH, selects the CLI."""
        record = self.record()
        arguments = argparse.Namespace(cwd=str(self.repo), argv=["--", "true"])
        result = subprocess.CompletedProcess([str(self.cli), "exec"], 0, b"", b"")

        with (
            mock.patch.object(MODULE, "prepare_state", return_value=self.paths),
            mock.patch.object(
                MODULE,
                "canonical_root",
                return_value=self.repo,
            ),
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "selected_record",
                return_value=record,
            ),
            mock.patch.object(
                MODULE.shutil,
                "which",
                side_effect=AssertionError("PATH was consulted"),
            ),
            mock.patch.object(MODULE, "run", return_value=result) as execute,
            self.assertRaises(SystemExit) as exited,
        ):
            MODULE.cmd_exec(arguments)

        self.assertEqual(exited.exception.code, 0)
        self.assertEqual(execute.call_args.args[0][0], str(self.cli))

    def test_exec_routes_through_the_reattested_podman_endpoint(self) -> None:
        """Container exec cannot follow a changed ambient Podman default."""
        record = self.record()
        machine = self.podman_machine_fixture(pin_id="e" * 64)
        container_id = "e" * 64
        record["container_id"] = container_id
        record["podman_connection"] = {
            "name": machine.name,
            "machine_pin": machine.pin_id,
        }
        environment = MODULE.pinned_engine_environment(machine)
        arguments = argparse.Namespace(cwd=str(self.repo), argv=["--", "true"])
        result = subprocess.CompletedProcess([str(self.cli), "exec"], 0, b"", b"")

        with (
            mock.patch.object(MODULE, "prepare_state", return_value=self.paths),
            mock.patch.object(MODULE, "canonical_root", return_value=self.repo),
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(MODULE, "selected_record", return_value=record),
            mock.patch.object(
                MODULE,
                "stored_podman_machine",
                return_value=machine,
            ) as stored_machine,
            mock.patch.object(MODULE, "run", return_value=result) as execute,
            self.assertRaises(SystemExit) as exited,
        ):
            MODULE.cmd_exec(arguments)

        self.assertEqual(exited.exception.code, 0)
        stored_machine.assert_called_once_with(record, str(self.docker))
        self.assertEqual(execute.call_args.kwargs["env"], environment)
        command = execute.call_args.args[0]
        self.assertEqual(command[command.index("--container-id") + 1], container_id)

    def test_restart_dead_reclaims_exact_pane_under_workspace_lock(self) -> None:
        """A dead v4 record upgrades only during an explicit fresh restart."""
        old = self.record("dead")
        old["version"] = MODULE.RUNTIME_RECORD_VERSION
        old.pop("phase")
        old.pop("podman_connection")
        MODULE.atomic_json(MODULE.record_path(self.paths, self.repo), old)
        self.assertEqual(
            MODULE.load_record(self.paths, self.repo)["version"],
            MODULE.RUNTIME_RECORD_VERSION,
        )
        old_snapshot = MODULE.create_config_snapshot(
            self.spool,
            old["claim_id"],
            self.snapshot_source("dead-restart-source"),
        )
        self.addCleanup(os.close, old_snapshot.descriptor)
        MODULE.publish_snapshot_lease(
            self.paths, self.spool, self.repo, old["claim_id"], old_snapshot
        )
        claim = "00000000-0000-4000-8000-000000000088"
        arguments = argparse.Namespace(
            repo=str(self.repo),
            tmux_pane="%7",
            claim_id=claim,
            recreate=False,
            timeout=1.0,
        )
        observed = MODULE.PaneObservation(True, 7007, 0, MODULE.pane_marker(self.repo))

        def exercise_lifecycle(
            paths: MODULE.StateDirectories,
            _spool: MODULE.SpoolDirectories,
            root: pathlib.Path,
            config: pathlib.Path,
            record: dict[str, object],
            _log: pathlib.Path,
            _token: str,
            cli: str,
            docker: str,
            _agent: pathlib.Path | None,
            **policy: object,
        ) -> None:
            self.assertEqual(
                (root, config, cli, docker),
                (self.repo, self.config, str(self.cli), str(self.docker)),
            )
            self.assertEqual(record["claim_id"], claim)
            self.assertEqual(record["status"], "starting")
            self.assertEqual(record["version"], MODULE.RECORD_VERSION)
            self.assertEqual(record["phase"], "claimed")
            self.assertFalse(old_snapshot.path.exists())
            self.assertTrue(policy["allow_dead_pane"])
            with (
                self.assertRaisesRegex(MODULE.EditorError, "busy"),
                MODULE.workspace_lock(
                    paths,
                    root,
                ),
            ):
                pass

        with (
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "verify_registered_container_pane",
                return_value=observed,
            ) as verify,
            mock.patch.object(
                MODULE,
                "run_container_lifecycle",
                side_effect=exercise_lifecycle,
            ),
        ):
            MODULE.cmd_restart_dead(arguments)

        verify.assert_called_once_with(mock.ANY, allow_dead=True)
        restarted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(restarted["version"], MODULE.RECORD_VERSION)
        self.assertEqual(restarted["claim_id"], claim)
        self.assertNotEqual(restarted["claim_id"], old["claim_id"])
        self.assertFalse(old_snapshot.path.exists())

    def test_restart_dead_reuses_the_recorded_podman_endpoint(self) -> None:
        """A v6 restart re-attests its stored machine and ignores default drift."""
        podman = self.root / "podman"
        podman.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        podman.chmod(0o700)
        podman = podman.resolve(strict=True)
        machine = self.podman_machine_fixture(name="recorded", pin_id="b" * 64)
        old = self.record("dead")
        old["docker_path"] = str(podman)
        old["podman_connection"] = {
            "name": machine.name,
            "machine_pin": machine.pin_id,
        }
        MODULE.atomic_json(MODULE.record_path(self.paths, self.repo), old)
        claim = "00000000-0000-4000-8000-000000000087"
        arguments = argparse.Namespace(
            repo=str(self.repo),
            tmux_pane="%7",
            claim_id=claim,
            recreate=False,
            timeout=1.0,
        )
        observed = MODULE.PaneObservation(True, 7007, 0, MODULE.pane_marker(self.repo))

        def exercise_lifecycle(
            _paths: MODULE.StateDirectories,
            _spool: MODULE.SpoolDirectories,
            _root: pathlib.Path,
            _config: pathlib.Path,
            record: dict[str, object],
            _log: pathlib.Path,
            _token: str,
            _cli: str,
            docker: str,
            forwarding: MODULE.AgentForwarding,
            **_policy: object,
        ) -> None:
            self.assertEqual(docker, str(podman))
            self.assertIs(forwarding.machine, machine)
            self.assertEqual(
                record["podman_connection"],
                {"name": machine.name, "machine_pin": machine.pin_id},
            )

        with (
            mock.patch.object(MODULE.sys, "platform", "darwin"),
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "verify_registered_container_pane",
                return_value=observed,
            ),
            mock.patch.object(
                MODULE,
                "discover_podman_machine",
                return_value=machine,
            ) as discover,
            mock.patch.object(
                MODULE,
                "run_container_lifecycle",
                side_effect=exercise_lifecycle,
            ),
        ):
            MODULE.cmd_restart_dead(arguments)

        discover.assert_called_once_with(str(podman), machine.name)
        restarted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(restarted["claim_id"], claim)
        self.assertEqual(restarted["podman_connection"], old["podman_connection"])

    def test_restart_dead_rejects_podman_pin_drift_before_state_mutation(self) -> None:
        """Changed machine identity leaves the prior dead record recoverable."""
        podman = self.root / "podman"
        podman.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        podman.chmod(0o700)
        podman = podman.resolve(strict=True)
        old = self.record("dead")
        old["docker_path"] = str(podman)
        old["podman_connection"] = {
            "name": "recorded",
            "machine_pin": "b" * 64,
        }
        MODULE.atomic_json(MODULE.record_path(self.paths, self.repo), old)
        changed = self.podman_machine_fixture(name="recorded", pin_id="c" * 64)
        arguments = argparse.Namespace(
            repo=str(self.repo),
            tmux_pane="%7",
            claim_id="00000000-0000-4000-8000-000000000086",
            recreate=False,
            timeout=1.0,
        )
        observed = MODULE.PaneObservation(True, 7007, 0, MODULE.pane_marker(self.repo))

        with (
            mock.patch.object(MODULE.sys, "platform", "darwin"),
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "verify_registered_container_pane",
                return_value=observed,
            ),
            mock.patch.object(
                MODULE,
                "discover_podman_machine",
                return_value=changed,
            ),
            mock.patch.object(MODULE, "run_container_lifecycle") as lifecycle,
            self.assertRaisesRegex(MODULE.EditorError, "identity changed"),
        ):
            MODULE.cmd_restart_dead(arguments)

        lifecycle.assert_not_called()
        self.assertEqual(MODULE.load_record(self.paths, self.repo), old)
        self.assertFalse(MODULE.log_path(self.paths, self.repo).exists())

    def test_restart_dead_keeps_v5_podman_state_recovery_only(self) -> None:
        """A legacy Podman record is never rebound to today's default machine."""
        podman = self.root / "podman"
        podman.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        podman.chmod(0o700)
        podman = podman.resolve(strict=True)
        old = self.record("dead")
        old["version"] = MODULE.PHASE_RECORD_VERSION
        old["docker_path"] = str(podman)
        old.pop("podman_connection")
        MODULE.atomic_json(MODULE.record_path(self.paths, self.repo), old)
        arguments = argparse.Namespace(
            repo=str(self.repo),
            tmux_pane="%7",
            claim_id="00000000-0000-4000-8000-000000000085",
            recreate=False,
            timeout=1.0,
        )
        observed = MODULE.PaneObservation(True, 7007, 0, MODULE.pane_marker(self.repo))

        with (
            mock.patch.object(MODULE.sys, "platform", "darwin"),
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "verify_registered_container_pane",
                return_value=observed,
            ),
            mock.patch.object(MODULE, "discover_podman_machine") as discover,
            self.assertRaisesRegex(MODULE.EditorError, "predates the pinned Podman"),
        ):
            MODULE.cmd_restart_dead(arguments)

        discover.assert_not_called()
        self.assertEqual(MODULE.load_record(self.paths, self.repo), old)

    def test_restart_rejects_an_unsafe_log_before_upgrading_the_dead_record(
        self,
    ) -> None:
        """Log validation failure preserves the recoverable v4 dead lifecycle."""
        old = self.record("dead")
        old["version"] = MODULE.RUNTIME_RECORD_VERSION
        old.pop("phase")
        old.pop("podman_connection")
        MODULE.atomic_json(MODULE.record_path(self.paths, self.repo), old)
        log = MODULE.log_path(self.paths, self.repo)
        log.write_text("unsafe\n", encoding="utf-8")
        log.chmod(0o640)
        arguments = argparse.Namespace(
            repo=str(self.repo),
            tmux_pane="%7",
            claim_id="00000000-0000-4000-8000-000000000090",
            recreate=False,
            timeout=1.0,
        )
        observed = MODULE.PaneObservation(
            True,
            7007,
            0,
            MODULE.pane_marker(self.repo),
        )
        with (
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "verify_registered_container_pane",
                return_value=observed,
            ),
            self.assertRaisesRegex(MODULE.EditorError, "private lifecycle log"),
        ):
            MODULE.cmd_restart_dead(arguments)

        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["version"], MODULE.RUNTIME_RECORD_VERSION)
        self.assertEqual(persisted["status"], "dead")
        self.assertEqual(persisted["claim_id"], old["claim_id"])
        self.assertEqual(log.read_text(encoding="utf-8"), "unsafe\n")
        self.assertEqual(stat.S_IMODE(log.stat().st_mode), 0o640)

    def test_restart_dead_preserves_snapshot_replacement(self) -> None:
        """A dead restart never retires a replacement owner directory."""
        record = self.record("dead")
        snapshot = MODULE.create_config_snapshot(
            self.spool,
            record["claim_id"],
            self.snapshot_source("restart-replacement-source"),
        )
        self.addCleanup(os.close, snapshot.descriptor)
        MODULE.publish_snapshot_lease(
            self.paths, self.spool, self.repo, record["claim_id"], snapshot
        )
        displaced = snapshot.path.with_name(f"{snapshot.name}-restart-original")
        snapshot.path.rename(displaced)
        snapshot.path.mkdir(mode=0o500)
        arguments = argparse.Namespace(
            repo=str(self.repo),
            tmux_pane="%7",
            claim_id="00000000-0000-4000-8000-000000000089",
            recreate=False,
            timeout=1.0,
        )
        try:
            with (
                mock.patch.object(MODULE, "repo_root", return_value=self.repo),
                mock.patch.object(MODULE, "verify_registered_container_pane") as verify,
                mock.patch.object(MODULE, "run_container_lifecycle") as lifecycle,
                self.assertRaisesRegex(MODULE.EditorError, "identity changed"),
            ):
                MODULE.cmd_restart_dead(arguments)
            verify.assert_not_called()
            lifecycle.assert_not_called()
            self.assertEqual(
                MODULE.load_record(self.paths, self.repo)["claim_id"],
                record["claim_id"],
            )
            self.assertTrue(snapshot.path.is_dir())
        finally:
            snapshot.path.chmod(0o700)
            snapshot.path.rmdir()
            displaced.rename(snapshot.path)
            MODULE.retire_claim_snapshot(
                self.paths,
                self.spool,
                self.repo,
                record["claim_id"],
                snapshot.identity,
            )

    def test_check_active_requires_the_registered_live_pane(self) -> None:
        """A focus-only probe cannot accept a stale or different editor pane."""
        record = self.record("running")
        valid = argparse.Namespace(repo=str(self.repo), tmux_pane="%7")
        invalid = argparse.Namespace(repo=str(self.repo), tmux_pane="%8")
        with (
            mock.patch.object(
                MODULE,
                "prepare_state",
                return_value=self.paths,
            ),
            mock.patch.object(
                MODULE,
                "repo_root",
                return_value=self.repo,
            ),
            mock.patch.object(
                MODULE,
                "verify_registered_container_pane",
            ) as verify,
        ):
            MODULE.cmd_check_active(valid)
            verify.assert_called_once_with(record, allow_dead=False)
            with self.assertRaisesRegex(MODULE.EditorError, "does not match"):
                MODULE.cmd_check_active(invalid)

        verify.assert_called_once_with(record, allow_dead=False)

    def test_check_active_calls_real_live_pane_verifier(self) -> None:
        """The active probe supplies the required alive-pane policy to the real verifier."""
        record = self.record("running")
        arguments = argparse.Namespace(repo=str(self.repo), tmux_pane="%7")
        observed = MODULE.PaneObservation(
            False, 7007, None, MODULE.pane_marker(self.repo)
        )
        with (
            mock.patch.object(
                MODULE,
                "prepare_state",
                return_value=self.paths,
            ),
            mock.patch.object(
                MODULE,
                "repo_root",
                return_value=self.repo,
            ),
            mock.patch.object(MODULE, "observe_pane", return_value=observed) as observe,
        ):
            MODULE.cmd_check_active(arguments)

        observe.assert_called_once_with(record)

    def test_blocking_host_fallback_forwards_ready_pane_and_timeout(self) -> None:
        """The wrapper preserves the exact-editor blocking handshake."""
        arguments = argparse.Namespace(
            wait_editor=True,
            signal_ready=True,
            tmux_pane="%7",
            wait_timeout=9.5,
            editor_file=str(self.file),
        )
        captured: list[str] = []

        def reject_exec(_path: pathlib.Path, argv: list[str]) -> None:
            captured.extend(argv)
            raise OSError("injected exec boundary")

        with (
            mock.patch.object(MODULE.os, "set_inheritable"),
            mock.patch.object(
                MODULE.os,
                "execv",
                side_effect=reject_exec,
            ),
            self.assertRaisesRegex(MODULE.EditorError, "could not hand off"),
        ):
            MODULE.exact_fallback(arguments, 99)

        self.assertEqual(
            captured[1:],
            [
                "--wait-editor",
                "--signal-ready",
                "--tmux-pane",
                "%7",
                "--wait-timeout",
                "9.5",
                str(self.file),
            ],
        )

    def test_container_respawn_is_checked_ordered_and_bound_to_explicit_pane(
        self,
    ) -> None:
        """The coordinator verifies marker and PID only after checked respawn steps."""
        record = self.record()
        transition_claim = uuid.UUID("71717171-7171-4171-8171-717171717171")
        calls: list[tuple[list[str], dict[str, object]]] = []
        observations = iter(
            (
                b"0\t7007\t\t\n",
                f"0\t4242\t\t{MODULE.pane_marker(self.repo)}\n".encode(),
            )
        )

        def execute(
            argv: list[str], **kwargs: object
        ) -> subprocess.CompletedProcess[bytes]:
            calls.append((list(argv), dict(kwargs)))
            stdout = b""
            if argv[1] == "display-message":
                if argv[-1] == MODULE.PANE_FORMAT:
                    stdout = next(observations)
                else:
                    stdout = f"{transition_claim}\t4242\n".encode()
            return subprocess.CompletedProcess(argv, 0, stdout, b"")

        snapshot = MODULE.create_config_snapshot(
            self.spool,
            record["claim_id"],
            self.snapshot_source("respawn-source"),
        )
        self.addCleanup(os.close, snapshot.descriptor)
        with (
            mock.patch.object(MODULE.uuid, "uuid4", return_value=transition_claim),
            mock.patch.object(
                MODULE.shutil,
                "which",
                return_value="/opt/tmux",
            ),
            mock.patch.object(
                MODULE,
                "run",
                side_effect=execute,
            ),
        ):
            observation = MODULE.respawn_container_editor(
                record,
                ["devcontainer", "exec", "nvim"],
                self.spool,
                snapshot,
            )
        self.assertEqual(observation.pid, 4242)
        self.assertEqual(
            [call[0][1] for call in calls],
            [
                "display-message",
                "set-option",
                "if-shell",
                "display-message",
                "if-shell",
                "display-message",
            ],
        )
        self.assertIn("respawn-pane", calls[2][0][-2])
        self.assertTrue(
            all("check" not in kwargs or kwargs["check"] is True for _, kwargs in calls)
        )
        self.assertTrue(all("%7" in argv for argv, _ in calls))

    def test_host_respawn_is_verified_before_lifecycle_retirement(self) -> None:
        """Host handoff checks a new alive PID and removed marker after respawn."""
        record = self.record()
        record["pane_pid"] = 4242
        transition_claim = uuid.UUID("72727272-7272-4272-8272-727272727272")
        calls: list[list[str]] = []
        observations = iter(
            (
                f"0\t4242\t\t{MODULE.pane_marker(self.repo)}\n".encode(),
                b"0\t5252\t\t\n",
            )
        )

        def execute(
            argv: list[str], **_kwargs: object
        ) -> subprocess.CompletedProcess[bytes]:
            calls.append(list(argv))
            stdout = b""
            if argv[1] == "display-message":
                if argv[-1] == MODULE.PANE_FORMAT:
                    stdout = next(observations)
                else:
                    stdout = f"{transition_claim}\t5252\n".encode()
            return subprocess.CompletedProcess(argv, 0, stdout, b"")

        with (
            mock.patch.object(MODULE.uuid, "uuid4", return_value=transition_claim),
            mock.patch.object(
                MODULE.shutil,
                "which",
                return_value="/opt/tmux",
            ),
            mock.patch.object(
                MODULE,
                "run",
                side_effect=execute,
            ),
        ):
            observation = MODULE.respawn_host_editor(record)
        self.assertEqual(observation.pid, 5252)
        self.assertEqual(
            [argv[1] for argv in calls],
            [
                "display-message",
                "if-shell",
                "display-message",
                "if-shell",
                "display-message",
            ],
        )
        self.assertIn("exec nvim", calls[1][-2])

    def test_unowned_host_respawn_rejects_replacement_between_check_and_action(
        self,
    ) -> None:
        """The tmux-side predicate blocks a pane substituted after observation."""
        calls: list[list[str]] = []

        def execute(
            argv: list[str], **_kwargs: object
        ) -> subprocess.CompletedProcess[bytes]:
            calls.append(list(argv))
            if argv[1] != "display-message":
                return subprocess.CompletedProcess(argv, 0, b"", b"")
            if argv[-1] == MODULE.PANE_FORMAT:
                return subprocess.CompletedProcess(argv, 0, b"0\t7007\t\t\n", b"")
            # A false atomic predicate publishes no fresh transition claim.
            return subprocess.CompletedProcess(argv, 0, b"\t\n", b"")

        with (
            mock.patch.object(MODULE.shutil, "which", return_value="/opt/tmux"),
            mock.patch.object(
                MODULE,
                "run",
                side_effect=execute,
            ),
            self.assertRaisesRegex(
                MODULE.EditorError, "changed before atomic replacement"
            ),
        ):
            MODULE.respawn_unowned_host_editor(self.repo, "%7", 7007)

        self.assertEqual(
            [argv[1] for argv in calls],
            ["display-message", "if-shell", "display-message", "if-shell"],
        )
        self.assertIn("#{pane_pid}", calls[1][5])
        self.assertIn("0|7007|", calls[1][5])
        self.assertFalse(any(argv[1] == "respawn-pane" for argv in calls))

    def test_cmd_up_holds_lock_until_verified_pane_exit(self) -> None:
        """Running is persisted after pane verification and the flock spans monitoring."""
        config_source = self.snapshot_source("lifecycle-success-source")
        claim = "00000000-0000-4000-8000-000000000011"
        snapshot_path = self.spool.root / MODULE.snapshot_name(claim)
        arguments = argparse.Namespace(
            repo=str(self.repo),
            config=None,
            recreate=False,
            allow_network=False,
            cli_path=str(self.cli),
            docker_path=str(self.docker),
            tmux_pane="%7",
            claim_id=claim,
            timeout=1.0,
        )
        result = subprocess.CompletedProcess(
            ["devcontainer", "up"],
            0,
            b'{"containerId":"abc","remoteWorkspaceFolder":"/workspaces/repo"}',
            b"",
        )
        events: list[str] = []
        phases: list[str] = []
        original_phase = MODULE.update_workspace_phase

        def capture_phase(
            paths: MODULE.StateDirectories,
            root: pathlib.Path,
            record: dict[str, object],
            phase: str,
        ) -> None:
            phases.append(phase)
            original_phase(paths, root, record, phase)

        def lifecycle_run(
            argv: list[str], **_kwargs: object
        ) -> subprocess.CompletedProcess[bytes]:
            self.assertEqual(argv[1], "exec")
            self.assertNotIn("--workdir", argv)
            self.assertEqual(
                argv[-7:-4], ["/bin/sh", "-c", MODULE.REMOTE_SNAPSHOT_PROBE]
            )
            self.assertEqual(argv[-4], "nvim-config-snapshot-probe")
            self.assertTrue(argv[-2].endswith(MODULE.CONFIG_SNAPSHOT_MARKER_NAME))
            events.append("probe")
            return subprocess.CompletedProcess(argv, 0, b"", b"")

        def agent_probe(
            argv: list[str], **_kwargs: object
        ) -> tuple[subprocess.CompletedProcess[bytes], bool]:
            self.assertEqual(argv[0:2], ["/managed/devcontainer", "exec"])
            self.assertNotIn("--container-id", argv)
            self.assertEqual(
                argv[-2:], ["nvim-agent-probe", MODULE.DIRECT_AGENT_SOCKET]
            )
            events.append("agent")
            self.assertEqual(
                MODULE.load_record(self.paths, self.repo)["phase"],
                "checking-ssh-agent",
            )
            return subprocess.CompletedProcess(argv, 0, b"", b""), False

        def streamed_up(
            _argv: list[str],
            _timeout: float,
            _writer: MODULE.LifecycleLogWriter,
            **_kwargs: object,
        ) -> subprocess.CompletedProcess[bytes]:
            events.append("up")
            return result

        def verified(
            record: dict[str, object],
            command: list[str],
            spool: MODULE.SpoolDirectories,
            snapshot: MODULE.ConfigSnapshot,
            *,
            allow_dead: bool = False,
        ) -> MODULE.PaneObservation:
            events.append("respawn")
            self.assertFalse(allow_dead)
            self.assertNotIn("token", record)
            self.assertNotIn(MODULE.read_auth(self.spool), "\n".join(command))
            self.assertTrue(snapshot_path.is_dir())
            self.assertEqual(spool.root, self.spool.root)
            self.assertEqual(snapshot.path, snapshot_path)
            self.assertNotIn("--workdir", command)
            spool_environment = next(
                argument
                for argument in command
                if argument.startswith("NVIM_DEVCONTAINER_SPOOL_ROOT=")
            )
            remote_spool = spool_environment.split("=", 1)[1]
            self.assertEqual(
                command[-3:],
                [
                    "nvim",
                    "-u",
                    f"{remote_spool}/{MODULE.snapshot_name(claim)}/init.lua",
                ],
            )
            return MODULE.PaneObservation(
                False, 4242, None, MODULE.pane_marker(self.repo)
            )

        def monitored(*_args: object) -> tuple[int, bool]:
            events.append("monitored")
            self.assertEqual(
                MODULE.load_record(self.paths, self.repo)["status"], "running"
            )
            self.assertEqual(
                MODULE.load_record(self.paths, self.repo)["phase"],
                "monitoring-editor",
            )
            self.assertIn(
                "lifecycle running container=abc",
                MODULE.log_path(self.paths, self.repo).read_text(encoding="utf-8"),
            )
            self.assertTrue(snapshot_path.is_dir())
            with (
                self.assertRaisesRegex(MODULE.EditorError, "busy"),
                MODULE.workspace_lock(
                    self.paths,
                    self.repo,
                ),
            ):
                pass
            return 0, False

        with (
            mock.patch.object(MODULE, "CONFIG_ROOT", config_source),
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "ssh_agent",
                return_value=self.root / "agent.sock",
            ),
            mock.patch.object(
                MODULE,
                "require_editor_pane",
                return_value=("%7", 7007),
            ),
            mock.patch.object(MODULE, "cli_path", return_value="/managed/devcontainer"),
            mock.patch.object(
                MODULE,
                "preserve_lockfile_flag",
                return_value="--no-lockfile",
            ),
            mock.patch.object(
                MODULE,
                "run",
                side_effect=lifecycle_run,
            ),
            mock.patch.object(
                MODULE,
                "run_bounded_capture",
                side_effect=agent_probe,
            ),
            mock.patch.object(MODULE, "run_streamed_up", side_effect=streamed_up),
            mock.patch.object(
                MODULE,
                "update_workspace_phase",
                side_effect=capture_phase,
            ),
            mock.patch.object(MODULE, "respawn_container_editor", side_effect=verified),
            mock.patch.object(
                MODULE,
                "monitor_editor",
                side_effect=monitored,
            ),
        ):
            MODULE.cmd_up(arguments)
        self.assertEqual(events, ["up", "agent", "probe", "respawn", "monitored"])
        self.assertEqual(
            phases,
            [
                "preparing-config",
                "starting-container",
                "checking-ssh-agent",
                "checking-editor-config",
                "opening-editor",
            ],
        )
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "dead")
        self.assertEqual(persisted["version"], MODULE.RECORD_VERSION)
        self.assertEqual(persisted["cli_path"], "/managed/devcontainer")
        self.assertEqual(persisted["docker_path"], str(self.docker))
        self.assertFalse(
            MODULE.auth_path(MODULE.spool_path(self.paths, self.repo)).exists()
        )
        self.assertFalse(snapshot_path.exists())

    def test_direct_agent_replacement_aborts_before_devcontainer_up(self) -> None:
        """A replaced host-agent socket is rejected immediately before launch."""
        record = self.record(status="starting")
        snapshot = MODULE.HostAgentSnapshot(
            host_path := self.root / "agent.sock",
            1,
            2,
            os.getuid(),
            stat.S_IFSOCK | 0o600,
            self.agent_authority_fixture(host_path),
        )
        forwarding = MODULE.AgentForwarding(
            "direct-bind",
            snapshot,
            None,
            snapshot.path,
            MODULE.DIRECT_AGENT_SOCKET,
        )
        run_up = mock.Mock()
        with (
            mock.patch.object(
                MODULE, "preserve_lockfile_flag", return_value="--no-lockfile"
            ),
            mock.patch.object(
                MODULE,
                "lifecycle_config_snapshot",
                return_value=contextlib.nullcontext(mock.Mock()),
            ),
            mock.patch.object(
                MODULE,
                "revalidate_host_agent",
                side_effect=MODULE.EditorError("host SSH-agent socket changed"),
            ) as revalidate,
            mock.patch.object(MODULE, "run_up_with_pinned_spool", run_up),
            self.assertRaisesRegex(MODULE.EditorError, "host SSH-agent socket changed"),
        ):
            MODULE.run_container_lifecycle(
                self.paths,
                self.spool,
                self.repo,
                self.config,
                record,
                MODULE.log_path(self.paths, self.repo),
                self.token,
                str(self.cli),
                str(self.docker),
                forwarding,
                recreate=False,
                timeout=1.0,
                allow_dead_pane=False,
            )
        revalidate.assert_called_once_with(snapshot)
        run_up.assert_not_called()

    def test_dead_relay_aborts_before_container_pane_respawn(self) -> None:
        """Relay liveness is rechecked immediately before mutating the tmux pane."""
        record = self.record(status="starting")
        forwarding = self.relay_forwarding_fixture(pin_id="7" * 64)
        machine = forwarding.machine
        assert machine is not None
        container_id = "7" * 64
        expected_env = MODULE.pinned_engine_environment(machine)
        relay = mock.Mock(spec=MODULE.PodmanAgentRelay)
        relay.container_socket = forwarding.container_socket
        relay.check.side_effect = [
            None,
            None,
            None,
            MODULE.EditorError("relay exited before respawn"),
        ]
        up = subprocess.CompletedProcess(
            ["devcontainer", "up"],
            0,
            json.dumps(
                {
                    "containerId": container_id,
                    "remoteWorkspaceFolder": "/workspaces/repo",
                }
            ).encode(),
            b"",
        )
        respawn = mock.Mock()
        with (
            mock.patch.object(MODULE, "PodmanAgentRelay", return_value=relay),
            mock.patch.object(MODULE, "revalidate_engine_machine"),
            mock.patch.object(
                MODULE, "preserve_lockfile_flag", return_value="--no-lockfile"
            ),
            mock.patch.object(
                MODULE,
                "lifecycle_config_snapshot",
                return_value=contextlib.nullcontext(mock.Mock()),
            ),
            mock.patch.object(MODULE, "run_up_with_pinned_spool", return_value=up),
            mock.patch.object(MODULE, "verify_agent") as verify_agent,
            mock.patch.object(MODULE, "revalidate_config_snapshot"),
            mock.patch.object(MODULE, "verify_remote_config_snapshot"),
            mock.patch.object(MODULE, "respawn_container_editor", respawn),
            self.assertRaisesRegex(MODULE.EditorError, "before respawn"),
        ):
            MODULE.run_container_lifecycle(
                self.paths,
                self.spool,
                self.repo,
                self.config,
                record,
                MODULE.log_path(self.paths, self.repo),
                self.token,
                str(self.cli),
                str(self.docker),
                forwarding,
                recreate=False,
                timeout=1.0,
                allow_dead_pane=False,
            )
        respawn.assert_not_called()
        relay.start_container_proxy.assert_called_once_with(
            str(self.cli), self.config, container_id, expected_env
        )
        self.assertEqual(verify_agent.call_count, 2)
        for call in verify_agent.call_args_list:
            self.assertEqual(call.args[-2:], (expected_env, container_id))
        relay.close.assert_called_once_with()

    def test_podman_lifecycle_pins_every_container_subprocess(self) -> None:
        """Build, probes, and detached editor share one exact engine endpoint."""
        record = self.record(status="starting")
        record["ssh_agent_forwarding"] = True
        machine = self.podman_machine_fixture(pin_id="8" * 64)
        forwarding = MODULE.AgentForwarding(
            "podman-machine-relay",
            MODULE.HostAgentSnapshot(
                host_path := pathlib.Path("/private/tmp/agent"),
                1,
                2,
                os.getuid(),
                stat.S_IFSOCK | 0o600,
                self.agent_authority_fixture(host_path),
            ),
            machine,
            None,
            MODULE.new_relay_agent_socket(),
        )
        relay = mock.Mock(spec=MODULE.PodmanAgentRelay)
        relay.container_socket = forwarding.container_socket
        container_id = "8" * 64
        up = subprocess.CompletedProcess(
            ["devcontainer", "up"],
            0,
            json.dumps(
                {
                    "containerId": container_id,
                    "remoteWorkspaceFolder": "/workspaces/repo",
                }
            ).encode(),
            b"",
        )
        observation = MODULE.PaneObservation(
            False,
            4242,
            None,
            MODULE.pane_marker(self.repo),
        )
        expected_env = MODULE.pinned_engine_environment(machine)
        snapshot = mock.Mock(spec=MODULE.ConfigSnapshot)

        with (
            mock.patch.object(MODULE, "PodmanAgentRelay", return_value=relay),
            mock.patch.object(MODULE, "revalidate_engine_machine"),
            mock.patch.object(
                MODULE,
                "preserve_lockfile_flag",
                return_value="--no-lockfile",
            ) as preserve,
            mock.patch.object(
                MODULE,
                "lifecycle_config_snapshot",
                return_value=contextlib.nullcontext(snapshot),
            ),
            mock.patch.object(
                MODULE,
                "run_up_with_pinned_spool",
                return_value=up,
            ) as run_up,
            mock.patch.object(MODULE, "verify_agent") as verify_agent,
            mock.patch.object(MODULE, "revalidate_config_snapshot"),
            mock.patch.object(
                MODULE,
                "verify_remote_config_snapshot",
            ) as verify_snapshot,
            mock.patch.object(
                MODULE,
                "respawn_container_editor",
                return_value=observation,
            ) as respawn,
            mock.patch.object(MODULE, "monitor_editor", return_value=(0, False)),
        ):
            MODULE.run_container_lifecycle(
                self.paths,
                self.spool,
                self.repo,
                self.config,
                record,
                MODULE.log_path(self.paths, self.repo),
                self.token,
                str(self.cli),
                str(self.docker),
                forwarding,
                recreate=False,
                timeout=1.0,
                allow_dead_pane=False,
            )

        self.assertEqual(preserve.call_args.args[-1], expected_env)
        self.assertEqual(run_up.call_count, 2)
        self.assertTrue(
            all(call.args[-1] == expected_env for call in run_up.call_args_list)
        )
        user_commands = run_up.call_args_list[1].args[0]
        self.assertEqual(user_commands[0:2], [str(self.cli), "run-user-commands"])
        self.assertEqual(
            user_commands[user_commands.index("--container-id") + 1], container_id
        )
        relay.start.assert_called_once_with()
        relay.start_container_proxy.assert_called_once_with(
            str(self.cli), self.config, container_id, expected_env
        )
        self.assertEqual(verify_agent.call_count, 2)
        for call in verify_agent.call_args_list:
            self.assertEqual(call.args[-2:], (expected_env, container_id))
        self.assertEqual(
            verify_snapshot.call_args.args[-2:], (expected_env, container_id)
        )
        editor_command = respawn.call_args.args[1]
        self.assertEqual(
            editor_command[:7],
            [
                "/usr/bin/env",
                "-u",
                "CONTAINER_CONNECTION",
                "-u",
                "DOCKER_HOST",
                f"CONTAINER_HOST={MODULE.podman_machine_uri(machine)}",
                f"CONTAINER_SSHKEY={machine.identity}",
            ],
        )
        relay.close.assert_called_once_with()

    def test_cmd_up_interrupt_reconciles_record_and_auth_then_reraises(self) -> None:
        """Control-flow interruption leaves recoverable error state, never starting."""
        claim = "00000000-0000-4000-8000-000000000017"
        arguments = argparse.Namespace(
            repo=str(self.repo),
            config=None,
            recreate=False,
            allow_network=False,
            cli_path=str(self.cli),
            docker_path=str(self.docker),
            tmux_pane="%7",
            claim_id=claim,
            timeout=1.0,
            ssh_agent="auto",
        )
        with (
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(MODULE, "require_editor_pane", return_value=("%7", 7007)),
            mock.patch.object(MODULE, "ssh_agent", return_value=None),
            mock.patch.object(MODULE, "cli_path", return_value=str(self.cli)),
            mock.patch.object(MODULE, "docker_path", return_value=str(self.docker)),
            mock.patch.object(
                MODULE, "run_container_lifecycle", side_effect=KeyboardInterrupt
            ),
            self.assertRaises(KeyboardInterrupt),
        ):
            MODULE.cmd_up(arguments)
        persisted = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(persisted["status"], "error")
        self.assertIn("KeyboardInterrupt", str(persisted["error"]))
        self.assertFalse(
            MODULE.auth_path(MODULE.spool_path(self.paths, self.repo)).exists()
        )

    def test_cmd_up_remote_snapshot_probe_fails_before_respawn(self) -> None:
        """A stale or unreadable reused mount cannot start container Neovim."""
        config_source = self.snapshot_source("remote-probe-failure-source")
        claim = "00000000-0000-4000-8000-000000000013"
        snapshot_path = self.spool.root / MODULE.snapshot_name(claim)
        arguments = argparse.Namespace(
            repo=str(self.repo),
            config=None,
            recreate=False,
            allow_network=False,
            cli_path=str(self.cli),
            docker_path=str(self.docker),
            tmux_pane="%7",
            claim_id=claim,
            timeout=1.0,
        )
        up = subprocess.CompletedProcess(
            ["devcontainer", "up"],
            0,
            b'{"containerId":"abc","remoteWorkspaceFolder":"/workspaces/repo"}',
            b"",
        )
        failed_probe = subprocess.CompletedProcess(
            ["devcontainer", "exec"], 19, b"", b"marker mismatch"
        )
        with (
            mock.patch.object(MODULE, "CONFIG_ROOT", config_source),
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(MODULE, "ssh_agent", return_value=None),
            mock.patch.object(MODULE, "require_editor_pane", return_value=("%7", 7007)),
            mock.patch.object(MODULE, "cli_path", return_value=str(self.cli)),
            mock.patch.object(
                MODULE, "preserve_lockfile_flag", return_value="--no-lockfile"
            ),
            mock.patch.object(MODULE, "run_streamed_up", return_value=up),
            mock.patch.object(MODULE, "run", return_value=failed_probe),
            mock.patch.object(MODULE, "respawn_container_editor") as respawn,
            mock.patch.object(MODULE, "monitor_editor") as monitor,
            self.assertRaisesRegex(MODULE.EditorError, "cannot read the exact"),
        ):
            MODULE.cmd_up(arguments)
        respawn.assert_not_called()
        monitor.assert_not_called()
        self.assertFalse(snapshot_path.exists())
        self.assertFalse(
            (self.paths["workspaces"] / MODULE.snapshot_lease_name(self.repo)).exists()
        )
        self.assertEqual(MODULE.load_record(self.paths, self.repo)["status"], "error")

    def test_cmd_up_respawn_failure_never_publishes_running(self) -> None:
        """A checked tmux failure leaves an error record and revokes spool auth."""
        config_source = self.snapshot_source("lifecycle-error-source")
        claim = "00000000-0000-4000-8000-000000000012"
        snapshot_path = self.spool.root / MODULE.snapshot_name(claim)
        arguments = argparse.Namespace(
            repo=str(self.repo),
            config=None,
            recreate=False,
            allow_network=False,
            cli_path=str(self.cli),
            docker_path=str(self.docker),
            tmux_pane="%7",
            claim_id=claim,
            timeout=1.0,
        )
        result = subprocess.CompletedProcess(
            ["devcontainer", "up"],
            0,
            b'{"containerId":"abc","remoteWorkspaceFolder":"/workspaces/repo"}',
            b"",
        )
        with (
            mock.patch.object(MODULE, "CONFIG_ROOT", config_source),
            mock.patch.object(MODULE, "repo_root", return_value=self.repo),
            mock.patch.object(
                MODULE,
                "require_editor_pane",
                return_value=("%7", 7007),
            ),
            mock.patch.object(MODULE, "cli_path", return_value="/managed/devcontainer"),
            mock.patch.object(
                MODULE,
                "preserve_lockfile_flag",
                return_value="--no-lockfile",
            ),
            mock.patch.object(
                MODULE,
                "run_streamed_up",
                return_value=result,
            ),
            mock.patch.object(
                MODULE,
                "run",
                return_value=subprocess.CompletedProcess(
                    ["devcontainer", "exec"], 0, b"", b""
                ),
            ),
            mock.patch.object(
                MODULE,
                "respawn_container_editor",
                side_effect=MODULE.EditorError("tmux respawn rejected"),
            ),
            mock.patch.object(MODULE, "monitor_editor") as monitor,
            self.assertRaisesRegex(
                MODULE.EditorError,
                "tmux respawn rejected",
            ),
        ):
            MODULE.cmd_up(arguments)
        monitor.assert_not_called()
        record = MODULE.load_record(self.paths, self.repo)
        self.assertEqual(record["status"], "error")
        self.assertEqual(record["phase"], "opening-editor")
        self.assertNotEqual(record["status"], "running")
        self.assertFalse(
            MODULE.auth_path(MODULE.spool_path(self.paths, self.repo)).exists()
        )
        self.assertFalse(snapshot_path.exists())

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
        self.assertIn("--cli-path", result.stdout)
        self.assertIn("--docker-path", result.stdout)
        self.assertIn("--tmux-pane", result.stdout)
        self.assertIn("--claim-id", result.stdout)
        restart = subprocess.run(
            [str(REPO / "scripts/devcontainer-editor"), "restart-dead", "--help"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(restart.returncode, 0, restart.stderr)
        self.assertNotIn("--cli", restart.stdout)
        claim = subprocess.run(
            [str(REPO / "scripts/devcontainer-editor"), "new-claim-id"],
            check=False,
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(claim.returncode, 0, claim.stderr)
        self.assertEqual(uuid.UUID(claim.stdout.strip()).version, 4)


if __name__ == "__main__":
    unittest.main()
