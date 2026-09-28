"""Focused contracts for the private verified npm bundle helper."""

from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

REPO = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts/verified-npm-bundle.py"
LOADER = importlib.machinery.SourceFileLoader("verified_npm_bundle", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
LOADER.exec_module(MODULE)


def add_file(archive: tarfile.TarFile, name: str, contents: bytes) -> None:
    """Add one deterministic regular member to a tar fixture."""
    member = tarfile.TarInfo(name)
    member.size = len(contents)
    member.mode = 0o644
    archive.addfile(member, io.BytesIO(contents))


def package_archive(path: pathlib.Path, members: list[tuple[str, bytes]]) -> str:
    """Create one gzip npm archive and return its canonical sha512 SRI."""
    with tarfile.open(path, "w:gz") as archive:
        root = tarfile.TarInfo("package")
        root.type = tarfile.DIRTYPE
        root.mode = 0o755
        archive.addfile(root)
        for name, contents in members:
            add_file(archive, name, contents)
    digest = hashlib.sha512(path.read_bytes()).digest()
    return "sha512-" + base64.b64encode(digest).decode("ascii")


def node_archive(
    path: pathlib.Path, members: list[tarfile.TarInfo | tuple[str, bytes]]
) -> str:
    """Create one gzip Node fixture and return its sha256 digest."""
    with tarfile.open(path, "w:gz") as archive:
        for member in members:
            if isinstance(member, tuple):
                add_file(archive, member[0], member[1])
            else:
                archive.addfile(member)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def extended_name_archive(path: pathlib.Path, archive_format: int) -> None:
    """Create a compact gzip tar whose extended name payload exceeds policy."""
    with tarfile.open(path, "w:gz", format=archive_format) as archive:
        add_file(archive, "package/" + "a" * 4096, b"payload")


def pax_record(key: str, value: str) -> bytes:
    """Encode one canonical PAX key/value record."""
    body = f" {key}={value}\n".encode()
    length = len(body) + 1
    while True:
        record = str(length).encode() + body
        if len(record) == length:
            return record
        length = len(record)


def raw_tar_archive(
    path: pathlib.Path, members: list[tuple[str, bytes, bytes]]
) -> None:
    """Create one gzip archive from exact raw tar member typeflags and payloads."""
    contents = bytearray()
    for name, typeflag, payload in members:
        member = tarfile.TarInfo(name)
        member.type = typeflag
        member.size = len(payload)
        member.mode = 0o644
        contents.extend(member.tobuf(format=tarfile.GNU_FORMAT))
        contents.extend(payload)
        contents.extend(b"\0" * (-len(payload) % tarfile.BLOCKSIZE))
    contents.extend(b"\0" * (tarfile.BLOCKSIZE * 2))
    path.write_bytes(gzip.compress(bytes(contents), mtime=0))


class VerifiedNpmBundleTest(unittest.TestCase):
    """Exercise bounded extraction and exact private closure behavior."""

    def setUp(self) -> None:
        """Create one isolated private extraction root."""
        self.temporary = tempfile.TemporaryDirectory(prefix="verified-npm-bundle-spec.")
        self.base = pathlib.Path(self.temporary.name).resolve(strict=True)
        self.root = self.base / "bundle"
        self.root.mkdir(mode=0o700)
        self.root.chmod(0o700)

    def tearDown(self) -> None:
        """Remove the isolated fixture."""
        self.temporary.cleanup()

    def fresh_root(self, name: str) -> pathlib.Path:
        """Create one separate private output root for a hostile fixture."""
        root = self.base / name
        root.mkdir(mode=0o700)
        root.chmod(0o700)
        return root

    def assert_scratch_failure_cleanup(self, failure_name: str, index: int) -> None:
        """Require one injected post-create failure to remove and close scratch state."""
        root_path = self.fresh_root(f"scratch-failure-{failure_name}")
        root = MODULE.anchor_private_root(root_path)
        token = f"{index:032x}"
        scratch_name = f".tar-scratch-{token}"
        descriptors: list[int] = []
        real_open = MODULE.os.open
        original = getattr(MODULE.os, failure_name)
        calls = 0

        def capture_open(
            path: object, flags: int, *args: object, **kwargs: object
        ) -> int:
            descriptor = real_open(path, flags, *args, **kwargs)
            if path == scratch_name:
                descriptors.append(descriptor)
            return descriptor

        def fail_once(*args: object, **kwargs: object) -> object:
            nonlocal calls
            calls += 1
            if calls == 1:
                raise OSError(f"injected {failure_name} failure")
            return original(*args, **kwargs)

        try:
            with (
                mock.patch.object(MODULE.secrets, "token_hex", return_value=token),
                mock.patch.object(MODULE.os, "open", side_effect=capture_open),
                mock.patch.object(MODULE.os, failure_name, side_effect=fail_once),
                self.assertRaises(OSError),
            ):
                MODULE.private_scratch(root.descriptor)
        finally:
            root.close()
        self.assertEqual(len(descriptors), 1, failure_name)
        self.assertFalse((root_path / scratch_name).exists(), failure_name)
        with self.assertRaises(OSError, msg=failure_name):
            os.fstat(descriptors[0])

    def test_package_extraction_is_private_and_dependency_free(self) -> None:
        """Only canonical regular package members enter the private tree."""
        archive = self.base / "package.tgz"
        integrity = package_archive(
            archive,
            [
                ("package/package.json", b'{"name":"@devcontainers/cli"}\n'),
                ("package/devcontainer.js", b"process.exit(0);\n"),
            ],
        )
        MODULE.extract_package(
            argparse.Namespace(
                archive=str(archive), integrity=integrity, root=str(self.root)
            )
        )
        package = self.root / "package"
        self.assertEqual(stat.S_IMODE(package.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((package / "package.json").stat().st_mode), 0o600)
        self.assertEqual(
            (package / "devcontainer.js").read_bytes(), b"process.exit(0);\n"
        )

    def test_package_path_depth_matches_the_final_bundle_closure(self) -> None:
        """The archive budget includes package/ exactly as the live closure does."""
        accepted_name = "package/" + "/".join(["d"] * 62) + "/file.js"
        archive = self.base / "depth-boundary.tgz"
        integrity = package_archive(archive, [(accepted_name, b"boundary")])
        MODULE.extract_package(
            argparse.Namespace(
                archive=str(archive), integrity=integrity, root=str(self.root)
            )
        )
        self.assertEqual((self.root / accepted_name).read_bytes(), b"boundary")
        rejected_name = "package/" + "/".join(["d"] * 63) + "/file.js"
        rejected = self.base / "depth-overflow.tgz"
        rejected_integrity = package_archive(rejected, [(rejected_name, b"overflow")])
        with self.assertRaises(MODULE.BundleError):
            MODULE.extract_package(
                argparse.Namespace(
                    archive=str(rejected),
                    integrity=rejected_integrity,
                    root=str(self.fresh_root("depth-overflow")),
                )
            )

    def test_traversal_duplicate_links_and_dependencies_are_rejected(self) -> None:
        """Malicious archive shapes fail before publishing package content."""
        cases = [
            [("package/../escape", b"escape")],
            [("package/node_modules/dep.js", b"dependency")],
            [("package/NODE_MODULES/dep.js", b"dependency")],
            [("package/Node_Modules/dep.js", b"dependency")],
            [("package/same.js", b"one"), ("package/same.js", b"two")],
            [("package/" + "a" * 513, b"long")],
            [("package/" + "/".join(["d"] * 65) + "/file.js", b"deep")],
        ]
        for index, members in enumerate(cases):
            archive = self.base / f"bad-{index}.tgz"
            integrity = package_archive(archive, members)
            with self.assertRaises(MODULE.BundleError):
                MODULE.extract_package(
                    argparse.Namespace(
                        archive=str(archive), integrity=integrity, root=str(self.root)
                    )
                )
            if (self.root / "package").exists():
                for child in (self.root / "package").iterdir():
                    if child.is_file():
                        child.unlink()
        link_archive = self.base / "link.tgz"
        with tarfile.open(link_archive, "w:gz") as archive:
            root = tarfile.TarInfo("package")
            root.type = tarfile.DIRTYPE
            archive.addfile(root)
            link = tarfile.TarInfo("package/devcontainer.js")
            link.type = tarfile.SYMTYPE
            link.linkname = "/tmp/escape"
            archive.addfile(link)
        integrity = "sha512-" + base64.b64encode(
            hashlib.sha512(link_archive.read_bytes()).digest()
        ).decode("ascii")
        with self.assertRaises(MODULE.BundleError):
            MODULE.extract_package(
                argparse.Namespace(
                    archive=str(link_archive), integrity=integrity, root=str(self.root)
                )
            )

    def test_truncated_and_oversize_archives_fail_closed(self) -> None:
        """Truncation and configured file bounds are enforced before success."""
        archive = self.base / "truncated.tgz"
        package_archive(archive, [("package/devcontainer.js", b"content")])
        archive.write_bytes(archive.read_bytes()[:20])
        integrity = "sha512-" + base64.b64encode(
            hashlib.sha512(archive.read_bytes()).digest()
        ).decode("ascii")
        with self.assertRaises(MODULE.BundleError):
            MODULE.extract_package(
                argparse.Namespace(
                    archive=str(archive), integrity=integrity, root=str(self.root)
                )
            )
        bounded = self.base / "oversize.tgz"
        integrity = package_archive(bounded, [("package/large.js", b"12345")])
        with (
            mock.patch.object(MODULE, "MAX_PACKAGE_FILE_BYTES", 4),
            self.assertRaises(MODULE.BundleError),
        ):
            MODULE.extract_package(
                argparse.Namespace(
                    archive=str(bounded), integrity=integrity, root=str(self.root)
                )
            )

    def test_pax_and_gnu_longname_bombs_fail_before_tarfile_parsing(self) -> None:
        """Extended control payloads stay bounded for package and Node archives."""
        for label, archive_format in (
            ("pax", tarfile.PAX_FORMAT),
            ("gnu", tarfile.GNU_FORMAT),
        ):
            archive = self.base / f"{label}-longname.tgz"
            extended_name_archive(archive, archive_format)
            self.assertLess(archive.stat().st_size, 4096)
            package_integrity = "sha512-" + base64.b64encode(
                hashlib.sha512(archive.read_bytes()).digest()
            ).decode("ascii")
            for kind in ("package", "node"):
                parser = mock.Mock(side_effect=AssertionError("tarfile parser ran"))
                root = self.fresh_root(f"{label}-{kind}-bomb")
                arguments = argparse.Namespace(
                    archive=str(archive),
                    integrity=package_integrity,
                    member="node-v24.20.0-test/bin/node",
                    root=str(root),
                    sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                )
                with (
                    mock.patch.object(MODULE, "MAX_TAR_EXTENSION_BYTES", 512),
                    mock.patch.object(MODULE.tarfile, "open", parser),
                    self.assertRaises(MODULE.BundleError),
                ):
                    if kind == "package":
                        MODULE.extract_package(arguments)
                    else:
                        MODULE.extract_node(arguments)
                parser.assert_not_called()

    def test_solaris_pax_and_gnu_sparse_fail_before_tarfile_parsing(self) -> None:
        """Solaris PAX and every GNU sparse control fail within pre-parser bounds."""
        sparse = pax_record("GNU.sparse.map", "0,1")
        cases = [
            ("solaris-pax", [("PaxHeader", b"X", b"x" * 513)]),
            ("gnu-sparse", [("package/sparse", b"S", b"")]),
        ]
        cases.extend(
            (label, [("PaxHeader", typeflag, sparse)])
            for label, typeflag in (
                ("pax-sparse-local", b"x"),
                ("pax-sparse-global", b"g"),
                ("pax-sparse-solaris", b"X"),
            )
        )
        for label, members in cases:
            archive = self.base / f"{label}.tgz"
            raw_tar_archive(archive, members)
            integrity = "sha512-" + base64.b64encode(
                hashlib.sha512(archive.read_bytes()).digest()
            ).decode("ascii")
            for kind in ("package", "node"):
                parser = mock.Mock(side_effect=AssertionError("tarfile parser ran"))
                arguments = argparse.Namespace(
                    archive=str(archive),
                    integrity=integrity,
                    member="node-v24.20.0-test/bin/node",
                    root=str(self.fresh_root(f"{label}-{kind}")),
                    sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                )
                with (
                    mock.patch.object(MODULE, "MAX_TAR_EXTENSION_BYTES", 512),
                    mock.patch.object(MODULE.tarfile, "open", parser),
                    self.assertRaises(MODULE.BundleError),
                ):
                    if kind == "package":
                        MODULE.extract_package(arguments)
                    else:
                        MODULE.extract_node(arguments)
                parser.assert_not_called()

    def test_single_gzip_and_tar_end_reject_all_trailing_payload(self) -> None:
        """Only one gzip member and zero-only tar record padding are accepted."""
        package = self.base / "trailing-base-package.tgz"
        package_archive(package, [("package/file.js", b"payload")])
        node = self.base / "trailing-base-node.tgz"
        member = "node-v24.20.0-test/bin/node"
        node_archive(node, [(member, b"node")])
        for kind, source in (("package", package), ("node", node)):
            tar_bytes = gzip.decompress(source.read_bytes())
            hostile = {
                "concatenated": source.read_bytes() + gzip.compress(b"second", mtime=0),
                "compressed-padding": source.read_bytes() + b"\0" * 8,
                "tar-trailing-aligned": gzip.compress(
                    tar_bytes + b"T" * tarfile.BLOCKSIZE, mtime=0
                ),
                "tar-trailing-unaligned": gzip.compress(
                    tar_bytes + b"TRAILING", mtime=0
                ),
            }
            for label, contents in hostile.items():
                archive = self.base / f"{kind}-{label}.tgz"
                archive.write_bytes(contents)
                arguments = argparse.Namespace(
                    archive=str(archive),
                    integrity="sha512-"
                    + base64.b64encode(hashlib.sha512(contents).digest()).decode(
                        "ascii"
                    ),
                    member=member,
                    root=str(self.fresh_root(f"{kind}-{label}-root")),
                    sha256=hashlib.sha256(contents).hexdigest(),
                )
                with self.assertRaises(MODULE.BundleError):
                    if kind == "package":
                        MODULE.extract_package(arguments)
                    else:
                        MODULE.extract_node(arguments)

        padded = self.base / "valid-extra-zero-padding.tgz"
        padded_bytes = gzip.compress(
            gzip.decompress(package.read_bytes()) + b"\0" * tarfile.BLOCKSIZE,
            mtime=0,
        )
        padded.write_bytes(padded_bytes)
        MODULE.extract_package(
            argparse.Namespace(
                archive=str(padded),
                integrity="sha512-"
                + base64.b64encode(hashlib.sha512(padded_bytes).digest()).decode(
                    "ascii"
                ),
                root=str(self.fresh_root("valid-extra-zero-padding")),
            )
        )

    def test_decompressed_tar_limit_fails_before_tarfile_parsing(self) -> None:
        """A gzip stream cannot expand beyond its action-specific tar budget."""
        archive = self.base / "expanded-limit.tgz"
        integrity = package_archive(archive, [("package/file.js", b"payload")])
        parser = mock.Mock(side_effect=AssertionError("tarfile parser ran"))
        with (
            mock.patch.object(MODULE, "MAX_PACKAGE_TAR_BYTES", 1024),
            mock.patch.object(MODULE.tarfile, "open", parser),
            self.assertRaises(MODULE.BundleError),
        ):
            MODULE.extract_package(
                argparse.Namespace(
                    archive=str(archive), integrity=integrity, root=str(self.root)
                )
            )
        parser.assert_not_called()

    def test_tar_scratch_is_unlinked_inside_the_anchored_private_root(self) -> None:
        """Ambient TMPDIR is unused and no scratch name survives extraction."""
        archive = self.base / "private-scratch.tgz"
        integrity = package_archive(archive, [("package/file.js", b"payload")])
        root = self.fresh_root("private-scratch-root")
        outside = self.fresh_root("hostile-tmpdir")
        token = "a" * 32
        with (
            mock.patch.dict(MODULE.os.environ, {"TMPDIR": str(outside)}),
            mock.patch.object(MODULE.secrets, "token_hex", return_value=token),
        ):
            MODULE.extract_package(
                argparse.Namespace(
                    archive=str(archive), integrity=integrity, root=str(root)
                )
            )
        self.assertEqual(list(outside.iterdir()), [])
        self.assertFalse((root / f".tar-scratch-{token}").exists())
        self.assertEqual((root / "package/file.js").read_bytes(), b"payload")

    def test_tar_scratch_failures_leave_no_name_or_descriptor(self) -> None:
        """Failures unlink each unchanged observable scratch name and close its fd."""
        failure_points = ("fchmod", "fstat", "stat", "unlink", "fsync", "fdopen")
        for index, failure_name in enumerate(failure_points):
            self.assert_scratch_failure_cleanup(failure_name, index)

    def test_tar_scratch_cleanup_preserves_an_ambiguous_rival(self) -> None:
        """Persistent lexical-stat failure preserves a rival and closes the old fd."""
        root_path = self.fresh_root("scratch-rival")
        root = MODULE.anchor_private_root(root_path)
        token = "f" * 32
        scratch_name = f".tar-scratch-{token}"
        displaced = root_path / "displaced-scratch-evidence"
        descriptors: list[int] = []
        real_open = MODULE.os.open
        real_fchmod = MODULE.os.fchmod

        def capture_open(
            path: object, flags: int, *args: object, **kwargs: object
        ) -> int:
            descriptor = real_open(path, flags, *args, **kwargs)
            if path == scratch_name:
                descriptors.append(descriptor)
            return descriptor

        def swap_then_chmod(descriptor: int, mode: int) -> None:
            real_fchmod(descriptor, mode)
            (root_path / scratch_name).rename(displaced)
            rival = real_open(
                scratch_name,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
                dir_fd=root.descriptor,
            )
            os.write(rival, b"rival")
            os.close(rival)

        try:
            with (
                mock.patch.object(MODULE.secrets, "token_hex", return_value=token),
                mock.patch.object(MODULE.os, "open", side_effect=capture_open),
                mock.patch.object(MODULE.os, "fchmod", side_effect=swap_then_chmod),
                mock.patch.object(
                    MODULE.os,
                    "stat",
                    side_effect=OSError("injected ambiguous stat failure"),
                ),
                self.assertRaises(OSError),
            ):
                MODULE.private_scratch(root.descriptor)
        finally:
            root.close()
        self.assertEqual((root_path / scratch_name).read_bytes(), b"rival")
        self.assertTrue(displaced.exists())
        with self.assertRaises(OSError):
            os.fstat(descriptors[0])

    def test_partial_writes_are_completed_and_closure_rejects_hardlinks(self) -> None:
        """Short writes do not truncate files and hardlinks cannot enter receipts."""
        source = io.BytesIO(b"partial-write")
        real_write = MODULE.os.write

        def short_write(descriptor: int, value: bytes) -> int:
            return real_write(descriptor, value[: max(1, len(value) // 2)])

        with mock.patch.object(MODULE.os, "write", side_effect=short_write):
            root = MODULE.anchor_private_root(self.root)
            try:
                MODULE.private_file(
                    root.descriptor,
                    pathlib.PurePosixPath("package/file.js"),
                    source,
                    len(b"partial-write"),
                )
                root.revalidate()
            finally:
                root.close()
        path = self.root / "package/file.js"
        self.assertEqual(path.read_bytes(), b"partial-write")
        os.link(path, self.root / "package/duplicate.js")
        with self.assertRaises(MODULE.BundleError):
            MODULE.closure(argparse.Namespace(root=str(self.root)))

    def test_node_extraction_materializes_only_the_pinned_binary(self) -> None:
        """A valid Node fixture publishes only bin/node with executable mode."""
        archive = self.base / "node.tgz"
        member = "node-v24.20.0-test/bin/node"
        digest = node_archive(
            archive,
            [
                (member, b"private-node\n"),
                ("node-v24.20.0-test/lib/ignored.js", b"ignored\n"),
            ],
        )
        MODULE.extract_node(
            argparse.Namespace(
                archive=str(archive), member=member, root=str(self.root), sha256=digest
            )
        )
        node = self.root / "node/bin/node"
        self.assertEqual(node.read_bytes(), b"private-node\n")
        self.assertEqual(stat.S_IMODE(node.stat().st_mode), 0o700)
        self.assertEqual(
            sorted(
                path.relative_to(self.root).as_posix()
                for path in self.root.rglob("*")
                if path.is_file()
            ),
            ["node/bin/node"],
        )

    def test_node_checksum_truncation_and_duplicate_member_fail_closed(self) -> None:
        """Pinned digest, readable gzip data, and unique binary membership are mandatory."""
        member = "node-v24.20.0-test/bin/node"
        archive = self.base / "node-checksum.tgz"
        node_archive(archive, [(member, b"node")])
        with self.assertRaises(MODULE.BundleError):
            MODULE.extract_node(
                argparse.Namespace(
                    archive=str(archive),
                    member=member,
                    root=str(self.fresh_root("bad-checksum")),
                    sha256="0" * 64,
                )
            )
        truncated = self.base / "node-truncated.tgz"
        truncated.write_bytes(archive.read_bytes()[:20])
        with self.assertRaises(MODULE.BundleError):
            MODULE.extract_node(
                argparse.Namespace(
                    archive=str(truncated),
                    member=member,
                    root=str(self.fresh_root("truncated")),
                    sha256=hashlib.sha256(truncated.read_bytes()).hexdigest(),
                )
            )
        duplicate = self.base / "node-duplicate.tgz"
        duplicate_digest = node_archive(duplicate, [(member, b"one"), (member, b"two")])
        with self.assertRaises(MODULE.BundleError):
            MODULE.extract_node(
                argparse.Namespace(
                    archive=str(duplicate),
                    member=member,
                    root=str(self.fresh_root("duplicate")),
                    sha256=duplicate_digest,
                )
            )

    def test_node_unsafe_and_special_members_fail_closed(self) -> None:
        """Traversal and special archive entries are rejected even when unselected."""
        binary = "node-v24.20.0-test/bin/node"
        special = tarfile.TarInfo("node-v24.20.0-test/device")
        special.type = tarfile.CHRTYPE
        special.devmajor = 1
        special.devminor = 3
        cases: list[list[tarfile.TarInfo | tuple[str, bytes]]] = [
            [(binary, b"node"), ("node-v24.20.0-test/../escape", b"escape")],
            [(binary, b"node"), special],
        ]
        for index, members in enumerate(cases):
            archive = self.base / f"node-hostile-{index}.tgz"
            digest = node_archive(archive, members)
            with self.assertRaises(MODULE.BundleError):
                MODULE.extract_node(
                    argparse.Namespace(
                        archive=str(archive),
                        member=binary,
                        root=str(self.fresh_root(f"hostile-{index}")),
                        sha256=digest,
                    )
                )

    def test_finalization_revalidates_package_and_writes_an_absolute_wrapper(
        self,
    ) -> None:
        """Finalization binds metadata, CLI regularity, and immutable absolute paths."""
        archive = self.base / "finalize.tgz"
        package = {
            "name": "@devcontainers/cli",
            "version": "1.2.3",
            "bin": {"devcontainer": "devcontainer.js"},
            "engines": {"node": ">=18 <25"},
        }
        integrity = package_archive(
            archive,
            [
                ("package/package.json", json.dumps(package).encode()),
                ("package/devcontainer.js", b"process.exit(0);\n"),
            ],
        )
        MODULE.extract_package(
            argparse.Namespace(
                archive=str(archive), integrity=integrity, root=str(self.root)
            )
        )
        info = self.root.stat()
        install_root = str(self.base / "immutable bundle")
        MODULE.finalize_package(
            argparse.Namespace(
                install_root=install_root,
                metadata=json.dumps(package),
                root=str(self.root),
                root_dev=info.st_dev,
                root_ino=info.st_ino,
            )
        )
        wrapper = self.root / "bin/devcontainer"
        contents = wrapper.read_text()
        self.assertEqual(stat.S_IMODE(wrapper.stat().st_mode), 0o700)
        self.assertIn(f"'{install_root}/node/bin/node'", contents)
        self.assertIn(f"'{install_root}/package/devcontainer.js'", contents)
        self.assertNotIn("${0", contents)

    def test_finalization_rejects_peer_dependencies_and_a_missing_cli(self) -> None:
        """Extracted metadata and its declared regular CLI are both mandatory."""
        base_package: dict[str, object] = {
            "name": "@devcontainers/cli",
            "version": "1.2.3",
            "bin": {"devcontainer": "devcontainer.js"},
            "engines": {"node": ">=18 <25"},
        }
        cases = [
            ({**base_package, "peerDependencies": {"peer": "1"}}, True),
            (base_package, False),
        ]
        for index, (package, include_cli) in enumerate(cases):
            root = self.fresh_root(f"finalize-bad-{index}")
            archive = self.base / f"finalize-bad-{index}.tgz"
            members = [("package/package.json", json.dumps(package).encode())]
            if include_cli:
                members.append(("package/devcontainer.js", b"process.exit(0);\n"))
            integrity = package_archive(archive, members)
            MODULE.extract_package(
                argparse.Namespace(
                    archive=str(archive), integrity=integrity, root=str(root)
                )
            )
            info = root.stat()
            with self.assertRaises(MODULE.BundleError):
                MODULE.finalize_package(
                    argparse.Namespace(
                        install_root=str(self.base / f"published-{index}"),
                        metadata=json.dumps(base_package),
                        root=str(root),
                        root_dev=info.st_dev,
                        root_ino=info.st_ino,
                    )
                )

    def test_hash_file_rejects_a_lexical_swap_after_hashing(self) -> None:
        """The final pathname must still identify the descriptor that was hashed."""
        original = self.root / "original"
        replacement = self.root / "replacement"
        original.write_bytes(b"original")
        replacement.write_bytes(b"replacement")
        original.chmod(0o600)
        replacement.chmod(0o600)
        root = MODULE.anchor_private_root(self.root)
        info = os.stat("original", dir_fd=root.descriptor, follow_symlinks=False)
        replacement_info = replacement.lstat()
        try:
            with (
                mock.patch.object(MODULE.os, "stat", return_value=replacement_info),
                self.assertRaises(MODULE.BundleError),
            ):
                MODULE.hash_file(root.descriptor, "original", info)
        finally:
            root.close()

    def test_root_swap_never_redirects_descriptor_relative_extraction(self) -> None:
        """Replacing the lexical root cannot redirect writes or yield success."""
        archive = self.base / "root-swap.tgz"
        integrity = package_archive(
            archive,
            [
                ("package/package.json", b'{"name":"@devcontainers/cli"}\n'),
                ("package/devcontainer.js", b"process.exit(0);\n"),
            ],
        )
        moved = self.base / "anchored-root"
        outside = self.fresh_root("outside")
        real_open = MODULE.os.open
        swapped = False

        def swap_before_create(
            path: object, flags: int, *args: object, **kwargs: object
        ) -> int:
            nonlocal swapped
            if (
                path == "package.json"
                and kwargs.get("dir_fd") is not None
                and not swapped
            ):
                swapped = True
                self.root.rename(moved)
                self.root.symlink_to(outside, target_is_directory=True)
            return real_open(path, flags, *args, **kwargs)

        with (
            mock.patch.object(MODULE.os, "open", side_effect=swap_before_create),
            self.assertRaises(MODULE.BundleError),
        ):
            MODULE.extract_package(
                argparse.Namespace(
                    archive=str(archive), integrity=integrity, root=str(self.root)
                )
            )
        self.assertTrue(swapped, "fixture did not replace the lexical root")
        self.assertEqual(
            list(outside.iterdir()), [], "extraction followed the replacement symlink"
        )
        self.assertEqual(
            (moved / "package/package.json").read_bytes(),
            b'{"name":"@devcontainers/cli"}\n',
        )

    def test_stage_cleanup_is_descriptor_relative_and_rejects_a_replacement(
        self,
    ) -> None:
        """Cleanup empties its exact stage but never recursively deletes a rival root."""
        nested = self.root / "nested"
        nested.mkdir(mode=0o700)
        nested.chmod(0o700)
        payload = nested / "payload"
        payload.write_bytes(b"payload")
        payload.chmod(0o600)
        info = self.root.stat()
        MODULE.clean_stage(
            argparse.Namespace(root=str(self.root), dev=info.st_dev, ino=info.st_ino)
        )
        self.assertEqual(list(self.root.iterdir()), [])

        captured = self.root.stat()
        displaced = self.base / "displaced-stage"
        self.root.rename(displaced)
        self.root.mkdir(mode=0o700)
        self.root.chmod(0o700)
        secret = self.root / "secret"
        secret.write_bytes(b"rival")
        secret.chmod(0o600)
        with self.assertRaises(MODULE.BundleError):
            MODULE.clean_stage(
                argparse.Namespace(
                    root=str(self.root), dev=captured.st_dev, ino=captured.st_ino
                )
            )
        self.assertEqual(secret.read_bytes(), b"rival")

    def test_stage_cleanup_handles_the_maximum_bundle_directory_depth(self) -> None:
        """The staging container does not make a valid closure uncleanable."""
        deep = self.root / "bundle/package" / pathlib.Path(*(["d"] * 62))
        deep.mkdir(parents=True, mode=0o700)
        cursor = deep
        while cursor != self.root:
            cursor.chmod(0o700)
            cursor = cursor.parent
        payload = deep / "file.js"
        payload.write_bytes(b"boundary")
        payload.chmod(0o600)
        info = self.root.stat()
        MODULE.clean_stage(
            argparse.Namespace(root=str(self.root), dev=info.st_dev, ino=info.st_ino)
        )
        self.assertEqual(list(self.root.iterdir()), [])

    def test_cli_reports_unexpected_io_errors_without_tracebacks(self) -> None:
        """The command boundary converts filesystem failures to bounded stderr."""
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "extract-package",
                "--archive",
                str(self.base / "missing.tgz"),
                "--integrity",
                "sha512-" + base64.b64encode(b"a" * 64).decode("ascii"),
                "--root",
                str(self.root),
                "--root-dev",
                str(self.root.stat().st_dev),
                "--root-ino",
                str(self.root.stat().st_ino),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("verified-npm-bundle:", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_isolated_python_argv_ignores_hostile_pythonpath_customization(
        self,
    ) -> None:
        """The production -I -B argv cannot run ambient workspace Python code."""
        customization = self.base / "pythonpath"
        customization.mkdir()
        marker = self.base / "sitecustomize-ran"
        (customization / "sitecustomize.py").write_text(
            f"from pathlib import Path\nPath({str(marker)!r}).write_text('ran')\n"
        )
        info = self.root.stat()
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(customization)
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                "-B",
                str(SCRIPT),
                "closure",
                "--root",
                str(self.root),
                "--root-dev",
                str(info.st_dev),
                "--root-ino",
                str(info.st_ino),
            ],
            check=False,
            capture_output=True,
            env=environment,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(marker.exists())
        self.assertFalse((customization / "__pycache__").exists())


if __name__ == "__main__":
    unittest.main()
