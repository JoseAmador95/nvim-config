#!/usr/bin/env python3
"""Safely materialize and inventory one private verified npm bundle."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import io
import json
import os
import pathlib
import re
import secrets
import shlex
import stat
import sys
import tarfile
import zlib
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from typing import BinaryIO, NoReturn

MAX_NODE_ARCHIVE_BYTES = 96 * 1024 * 1024
MAX_PACKAGE_ARCHIVE_BYTES = 32 * 1024 * 1024
MAX_PACKAGE_ENTRIES = 4090
MAX_NODE_ENTRIES = 20000
MAX_NODE_EXPANDED_BYTES = 512 * 1024 * 1024
MAX_PACKAGE_FILE_BYTES = 32 * 1024 * 1024
MAX_PACKAGE_BYTES = 128 * 1024 * 1024
MAX_BUNDLE_ENTRIES = 4096
MAX_BUNDLE_FILE_BYTES = 256 * 1024 * 1024
MAX_BUNDLE_BYTES = 512 * 1024 * 1024
PRIVATE_DIRECTORY_MODE = 0o700
PRIVATE_FILE_MODE = 0o600
PRIVATE_EXECUTABLE_MODE = 0o700
MAX_CLOSURE_PATH_BYTES = 512
MAX_CLOSURE_DEPTH = 64
MAX_TAR_EXTENSION_BYTES = 64 * 1024
MAX_PACKAGE_TAR_BYTES = MAX_PACKAGE_BYTES + MAX_PACKAGE_ENTRIES * 2048
MAX_NODE_TAR_BYTES = MAX_NODE_EXPANDED_BYTES + MAX_NODE_ENTRIES * 2048
MAX_SCRATCH_ATTEMPTS = 32
STREAM_CHUNK_BYTES = 1024 * 1024
TAR_EXTENSION_TYPES = frozenset({b"x", b"g", b"X", b"L", b"K"})
PAX_EXTENSION_TYPES = frozenset({b"x", b"g", b"X"})
STAT_FIELDS = (
    "st_dev",
    "st_ino",
    "st_size",
    "st_mode",
    "st_nlink",
    "st_mtime_ns",
    "st_ctime_ns",
)


class BundleError(Exception):
    """Report one bounded fail-closed bundle construction error."""


def same_identity(left: os.stat_result, right: os.stat_result) -> bool:
    """Return whether two snapshots identify one unchanged filesystem entry."""
    return all(getattr(left, name) == getattr(right, name) for name in STAT_FIELDS)


def same_object(left: os.stat_result, right: os.stat_result) -> bool:
    """Return whether two snapshots identify the same filesystem object."""
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


def owned_by_current_user(info: os.stat_result) -> bool:
    """Return whether a filesystem entry belongs to the effective user."""
    return not hasattr(os, "geteuid") or info.st_uid == os.geteuid()


@dataclass
class RootAnchor:
    """Descriptor-bound private root with final lexical identity validation."""

    path: pathlib.Path
    descriptor: int
    opened: os.stat_result

    def close(self) -> None:
        """Close the anchored root descriptor."""
        os.close(self.descriptor)

    def revalidate(self) -> None:
        """Require the lexical root to still identify the anchored directory."""
        try:
            current = os.fstat(self.descriptor)
            lexical = self.path.lstat()
            resolved = self.path.resolve(strict=True)
        except OSError as error:
            fail(f"bundle root identity could not be rechecked: {error}")
        if (
            not same_object(self.opened, current)
            or not same_object(current, lexical)
            or resolved != self.path
        ):
            fail("bundle root changed while it was used")
        validate_bundle_directory(current)


def fail(message: str) -> NoReturn:
    """Raise one user-facing bundle error."""
    raise BundleError(message)


def safe_relative(
    value: str,
    *,
    prefix: str | None = None,
    portable: bool = False,
) -> pathlib.PurePosixPath:
    """Return a canonical non-traversing archive member path."""
    if (
        not value
        or len(value) > 1024
        or "\x00" in value
        or "\\" in value
        or value.startswith("/")
    ):
        fail("archive member path is unsafe")
    path = pathlib.PurePosixPath(value)
    if any(part in {"", ".", ".."} for part in path.parts) or str(path) != value.rstrip(
        "/"
    ):
        fail("archive member path is not canonical")
    if prefix is not None and (not path.parts or path.parts[0] != prefix):
        fail("npm archive contains content outside package/")
    if portable and re.fullmatch(r"[A-Za-z0-9._@+\-/]+", str(path)) is None:
        fail("npm archive member path is outside the portable closure alphabet")
    if portable:
        relative = pathlib.PurePosixPath(*path.parts[1:]) if prefix else path
        closure_relative = path if prefix else relative
        if (
            len(str(closure_relative).encode("utf-8")) > MAX_CLOSURE_PATH_BYTES
            or len(closure_relative.parts) > MAX_CLOSURE_DEPTH
        ):
            fail("npm archive member path exceeds the verified closure limits")
    return path


def stable_archive(path: pathlib.Path, maximum: int) -> tuple[int, os.stat_result]:
    """Open one bounded, single-link, regular archive without following links."""
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        fail(f"archive could not be opened safely: {error}")
    opened = os.fstat(descriptor)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_nlink != 1
        or opened.st_size < 1
        or opened.st_size > maximum
    ):
        os.close(descriptor)
        fail("archive is not one bounded single-link regular file")
    return descriptor, opened


def hash_descriptor(
    descriptor: int, algorithm: str, expected_size: int, maximum: int
) -> str:
    """Hash exactly one bounded descriptor snapshot from the beginning."""
    if expected_size < 0 or expected_size > maximum:
        fail("file size is outside the hashing limit")
    digest = hashlib.new(algorithm)
    os.lseek(descriptor, 0, os.SEEK_SET)
    remaining = expected_size
    while remaining:
        chunk = os.read(descriptor, min(1024 * 1024, remaining))
        if not chunk:
            fail("file was truncated while it was hashed")
        digest.update(chunk)
        remaining -= len(chunk)
    if os.read(descriptor, 1):
        fail("file grew while it was hashed")
    return digest.hexdigest()


def verify_archive_identity(
    path: pathlib.Path, descriptor: int, opened: os.stat_result
) -> None:
    """Require an archive pathname and descriptor to retain one exact identity."""
    current = os.fstat(descriptor)
    try:
        lexical = path.lstat()
    except OSError as error:
        fail(f"archive identity could not be rechecked: {error}")
    fields = (
        "st_dev",
        "st_ino",
        "st_size",
        "st_mode",
        "st_nlink",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    if any(getattr(opened, name) != getattr(current, name) for name in fields):
        fail("archive changed while it was read")
    if any(getattr(opened, name) != getattr(lexical, name) for name in fields):
        fail("archive path changed while it was read")


def tar_size(header: bytes) -> int:
    """Decode one bounded portable tar size field without extended allocation."""
    field = header[124:136]
    if not field or field[0] & 0x80:
        fail("archive uses an unsupported binary size field")
    encoded = field.strip(b" \0")
    if not encoded:
        return 0
    if any(character < ord("0") or character > ord("7") for character in encoded):
        fail("archive size field is invalid")
    return int(encoded, 8)


def validate_tar_end(stream: BinaryIO, length: int) -> None:
    """Require two zero blocks followed only by block-aligned zero padding."""
    second = stream.read(tarfile.BLOCKSIZE)
    if len(second) != tarfile.BLOCKSIZE or any(second):
        fail("decompressed tar end marker is invalid")
    remaining = length - stream.tell()
    while remaining:
        chunk = stream.read(min(STREAM_CHUNK_BYTES, remaining))
        if not chunk or any(chunk):
            fail("decompressed tar contains trailing payload")
        remaining -= len(chunk)


def scan_tar_payload(stream: BinaryIO, typeflag: bytes, size: int, padded: int) -> None:
    """Inspect one bounded extended payload and skip its exact record padding."""
    if typeflag == b"S":
        fail("GNU sparse tar entries are unsupported")
    if typeflag not in TAR_EXTENSION_TYPES:
        stream.seek(padded, os.SEEK_CUR)
        return
    if size > MAX_TAR_EXTENSION_BYTES:
        fail("archive extended header exceeds the size limit")
    payload = stream.read(size)
    if len(payload) != size:
        fail("archive extended header is truncated")
    if typeflag in PAX_EXTENSION_TYPES and b"GNU.sparse." in payload:
        fail("GNU sparse PAX metadata is unsupported")
    stream.seek(padded - size, os.SEEK_CUR)


def scan_tar_controls(stream: BinaryIO, maximum: int, maximum_entries: int) -> None:
    """Reject oversized control records before Python's tar parser sees them."""
    stream.seek(0, os.SEEK_END)
    length = stream.tell()
    stream.seek(0)
    if length > maximum or length % tarfile.BLOCKSIZE != 0:
        fail("decompressed tar stream is not block-aligned within its size limit")
    entries = 0
    offset = 0
    while offset + tarfile.BLOCKSIZE <= length:
        header = stream.read(tarfile.BLOCKSIZE)
        if len(header) != tarfile.BLOCKSIZE:
            fail("decompressed tar header is truncated")
        offset += tarfile.BLOCKSIZE
        if not any(header):
            validate_tar_end(stream, length)
            stream.seek(0)
            return
        entries += 1
        if entries > maximum_entries * 2 + 2:
            fail("archive contains too many raw headers")
        size = tar_size(header)
        padded = (size + tarfile.BLOCKSIZE - 1) // tarfile.BLOCKSIZE * tarfile.BLOCKSIZE
        offset += padded
        if offset > length or offset > maximum:
            fail("decompressed tar stream exceeds the size limit")
        scan_tar_payload(stream, header[156:157], size, padded)
    fail("decompressed tar end marker is absent")


def cleanup_private_scratch(root_descriptor: int, name: str, descriptor: int) -> None:
    """Best-effort remove one failed scratch name and always close its descriptor."""
    if name:
        try:
            opened = os.fstat(descriptor)
            lexical = os.stat(name, dir_fd=root_descriptor, follow_symlinks=False)
            if same_object(opened, lexical):
                os.unlink(name, dir_fd=root_descriptor)
                os.fsync(root_descriptor)
        except FileNotFoundError:
            pass
        except OSError:
            pass
    try:
        os.close(descriptor)
    except OSError:
        pass


def private_scratch(root_descriptor: int) -> BinaryIO:
    """Create and immediately unlink one private descriptor-relative scratch file."""
    flags = (
        os.O_RDWR
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    descriptor: int | None = None
    name = ""
    for _ in range(MAX_SCRATCH_ATTEMPTS):
        name = ".tar-scratch-" + secrets.token_hex(16)
        try:
            descriptor = os.open(name, flags, PRIVATE_FILE_MODE, dir_fd=root_descriptor)
            break
        except FileExistsError:
            continue
    if descriptor is None:
        fail("private tar scratch namespace is exhausted")
    try:
        os.fchmod(descriptor, PRIVATE_FILE_MODE)
        opened = os.fstat(descriptor)
        lexical = os.stat(name, dir_fd=root_descriptor, follow_symlinks=False)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or stat.S_IMODE(opened.st_mode) != PRIVATE_FILE_MODE
            or not owned_by_current_user(opened)
            or not same_identity(opened, lexical)
        ):
            fail("private tar scratch file is unsafe")
        os.unlink(name, dir_fd=root_descriptor)
        name = ""
        if os.fstat(descriptor).st_nlink != 0:
            fail("private tar scratch file could not be unlinked")
        os.fsync(root_descriptor)
        stream = os.fdopen(descriptor, "w+b")
        descriptor = None
        return stream
    finally:
        if descriptor is not None:
            cleanup_private_scratch(root_descriptor, name, descriptor)


def write_expanded(stream: BinaryIO, contents: bytes, total: int, maximum: int) -> int:
    """Append one bounded decompression chunk to the private scratch stream."""
    total += len(contents)
    if total > maximum:
        fail("decompressed tar stream exceeds the size limit")
    if stream.write(contents) != len(contents):
        fail("decompressed tar staging write was incomplete")
    return total


def expand_single_gzip(compressed: BinaryIO, stream: BinaryIO, maximum: int) -> None:
    """Expand exactly one gzip member without allocating beyond the tar budget."""
    decoder = zlib.decompressobj(zlib.MAX_WBITS | 16)
    total = 0
    try:
        while not decoder.eof:
            compressed_chunk = compressed.read(STREAM_CHUNK_BYTES)
            if not compressed_chunk:
                break
            pending = compressed_chunk
            while pending and not decoder.eof:
                contents = decoder.decompress(
                    pending, min(STREAM_CHUNK_BYTES, maximum - total + 1)
                )
                pending = decoder.unconsumed_tail
                total = write_expanded(stream, contents, total, maximum)
        if not decoder.eof:
            fail("gzip member is truncated")
        if decoder.unused_data or compressed.read(1):
            fail("gzip archive contains a trailing or concatenated member")
    except zlib.error:
        fail("gzip member is invalid")


@contextmanager
def bounded_tar_stream(
    descriptor: int,
    scratch_root: int,
    maximum: int,
    maximum_entries: int,
) -> Iterator[BinaryIO]:
    """Yield one seekable tar stream bounded before tarfile parses headers."""
    with (
        os.fdopen(os.dup(descriptor), "rb") as compressed,
        private_scratch(scratch_root) as stream,
    ):
        expand_single_gzip(compressed, stream, maximum)
        stream.flush()
        scan_tar_controls(stream, maximum, maximum_entries)
        yield stream


def decode_integrity(value: str) -> bytes:
    """Decode exactly one canonical sha512 Subresource Integrity value."""
    if not value.startswith("sha512-") or any(
        character.isspace() for character in value
    ):
        fail("npm integrity is not one canonical sha512 SRI")
    encoded = value.removeprefix("sha512-")
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError):
        fail("npm integrity base64 is invalid")
    if len(decoded) != hashlib.sha512().digest_size:
        fail("npm integrity digest length is invalid")
    if base64.b64encode(decoded).decode("ascii") != encoded:
        fail("npm integrity base64 is not canonical")
    return decoded


def anchor_private_root(
    path: pathlib.Path,
    expected_dev: int | None = None,
    expected_ino: int | None = None,
) -> RootAnchor:
    """Open and validate one private real directory used as an operation root."""
    lexical = pathlib.Path(os.path.abspath(path))
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    descriptor: int | None = None
    try:
        descriptor = os.open(lexical, flags)
        info = os.fstat(descriptor)
        path_info = lexical.lstat()
        resolved = lexical.resolve(strict=True)
    except OSError as error:
        if descriptor is not None:
            os.close(descriptor)
        fail(f"bundle root is unavailable: {error}")
    if (
        not stat.S_ISDIR(info.st_mode)
        or not same_identity(info, path_info)
        or lexical != resolved
        or stat.S_IMODE(info.st_mode) != PRIVATE_DIRECTORY_MODE
        or not owned_by_current_user(info)
        or expected_dev is not None
        and info.st_dev != expected_dev
        or expected_ino is not None
        and info.st_ino != expected_ino
    ):
        os.close(descriptor)
        fail("bundle root is not one canonical private directory")
    return RootAnchor(path=resolved, descriptor=descriptor, opened=info)


def private_directory(root_descriptor: int, relative: pathlib.PurePosixPath) -> int:
    """Open or create one private descendant directory relative to an anchor."""
    current = os.dup(root_descriptor)
    try:
        for part in relative.parts:
            created = False
            try:
                os.mkdir(part, PRIVATE_DIRECTORY_MODE, dir_fd=current)
                created = True
            except FileExistsError:
                pass
            if created:
                os.fsync(current)
            flags = (
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0)
            )
            child = os.open(part, flags, dir_fd=current)
            info = os.fstat(child)
            lexical = os.stat(part, dir_fd=current, follow_symlinks=False)
            if (
                not stat.S_ISDIR(info.st_mode)
                or not same_object(info, lexical)
                or not owned_by_current_user(info)
            ):
                os.close(child)
                fail("bundle directory is unsafe")
            os.fchmod(child, PRIVATE_DIRECTORY_MODE)
            secured = os.fstat(child)
            if stat.S_IMODE(secured.st_mode) != PRIVATE_DIRECTORY_MODE:
                os.close(child)
                fail("bundle directory is not private")
            os.close(current)
            current = child
        return current
    except Exception:
        os.close(current)
        raise


def private_file(
    root_descriptor: int,
    relative: pathlib.PurePosixPath,
    source: BinaryIO,
    size: int,
    *,
    maximum: int = MAX_PACKAGE_FILE_BYTES,
    mode: int = PRIVATE_FILE_MODE,
) -> None:
    """Create one exact private regular file relative to an anchored root."""
    if size < 0 or size > maximum:
        fail("archive member is too large")
    parent_relative = relative.parent
    parent = private_directory(root_descriptor, parent_relative)
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    descriptor: int | None = None
    try:
        descriptor = os.open(relative.name, flags, mode, dir_fd=parent)
        remaining = size
        while remaining:
            chunk = source.read(min(1024 * 1024, remaining))
            if not chunk:
                fail("archive member is truncated")
            written = 0
            while written < len(chunk):
                count = os.write(descriptor, chunk[written:])
                if count <= 0:
                    fail("archive member write made no progress")
                written += count
            remaining -= len(chunk)
        if source.read(1):
            fail("archive member exceeds its declared size")
        os.fchmod(descriptor, mode)
        os.fsync(descriptor)
        opened = os.fstat(descriptor)
        lexical = os.stat(relative.name, dir_fd=parent, follow_symlinks=False)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or opened.st_size != size
            or stat.S_IMODE(opened.st_mode) != mode
            or not owned_by_current_user(opened)
            or not same_identity(opened, lexical)
        ):
            fail("created bundle file is unsafe or changed")
        os.fsync(parent)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent)


def tar_members(
    archive: tarfile.TarFile,
    *,
    prefix: str | None = None,
    maximum: int = MAX_PACKAGE_ENTRIES,
) -> Iterator[tuple[tarfile.TarInfo, pathlib.PurePosixPath]]:
    """Yield unique canonical archive members within configured bounds."""
    seen: set[str] = set()
    for index, member in enumerate(archive):
        if index >= maximum:
            fail("archive contains too many entries")
        path = safe_relative(member.name, prefix=prefix, portable=prefix == "package")
        normalized = str(path)
        if normalized in seen:
            fail("archive contains a duplicate member")
        seen.add(normalized)
        yield member, path


def extract_package_member(
    archive: tarfile.TarFile,
    member: tarfile.TarInfo,
    path: pathlib.PurePosixPath,
    package_root: int,
) -> int:
    """Materialize one already-validated npm archive member."""
    relative = pathlib.PurePosixPath(*path.parts[1:])
    if not relative.parts:
        if not member.isdir():
            fail("npm package root is not a directory")
        return 0
    if any(part.lower() == "node_modules" for part in relative.parts):
        fail("npm archive contains dependency content")
    if member.isdir():
        descriptor = private_directory(package_root, relative)
        os.close(descriptor)
        return 0
    if not member.isfile():
        fail("npm archive contains a link or special file")
    source = archive.extractfile(member)
    if source is None:
        fail("npm archive regular file is unreadable")
    with source:
        private_file(
            package_root,
            relative,
            source,
            member.size,
            maximum=MAX_PACKAGE_FILE_BYTES,
        )
    return member.size


def extract_package(args: argparse.Namespace) -> None:
    """Verify and extract one dependency-free npm package archive."""
    root = anchor_private_root(
        pathlib.Path(args.root),
        getattr(args, "root_dev", None),
        getattr(args, "root_ino", None),
    )
    package_root: int | None = None
    descriptor: int | None = None
    try:
        package_root = private_directory(
            root.descriptor, pathlib.PurePosixPath("package")
        )
        descriptor, opened = stable_archive(
            pathlib.Path(args.archive), MAX_PACKAGE_ARCHIVE_BYTES
        )
        expected = decode_integrity(args.integrity).hex()
        if (
            hash_descriptor(
                descriptor, "sha512", opened.st_size, MAX_PACKAGE_ARCHIVE_BYTES
            )
            != expected
        ):
            fail("npm archive sha512 does not match metadata")
        os.lseek(descriptor, 0, os.SEEK_SET)
        total = 0
        with (
            bounded_tar_stream(
                descriptor,
                root.descriptor,
                MAX_PACKAGE_TAR_BYTES,
                MAX_PACKAGE_ENTRIES,
            ) as stream,
            tarfile.open(fileobj=stream, mode="r:") as archive,
        ):
            for member, path in tar_members(archive, prefix="package"):
                total += extract_package_member(archive, member, path, package_root)
                if total > MAX_PACKAGE_BYTES:
                    fail("npm package expands beyond the size limit")
        verify_archive_identity(pathlib.Path(args.archive), descriptor, opened)
        root.revalidate()
    except (EOFError, OSError, tarfile.TarError) as error:
        fail(f"npm archive is invalid: {error}")
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if package_root is not None:
            os.close(package_root)
        root.close()


def find_node_member(archive: tarfile.TarFile, expected: str) -> tarfile.TarInfo:
    """Find one unique exact regular Node binary member."""
    selected: tarfile.TarInfo | None = None
    total = 0
    for member, path in tar_members(archive, maximum=MAX_NODE_ENTRIES):
        if member.isdev() or member.isfifo() or member.islnk():
            fail("Node archive contains a hardlink or special file")
        if not (member.isfile() or member.isdir() or member.issym()):
            fail("Node archive contains an unsupported special file")
        if member.isfile():
            if member.size < 0 or member.size > MAX_BUNDLE_FILE_BYTES:
                fail("Node archive member is outside the size limit")
            total += member.size
            if total > MAX_NODE_EXPANDED_BYTES:
                fail("Node archive expands beyond the size limit")
        if str(path) == expected:
            if selected is not None or not member.isfile():
                fail("Node archive binary member is not one regular file")
            selected = member
    if selected is None:
        fail("Node archive binary member is absent")
    return selected


def extract_node(args: argparse.Namespace) -> None:
    """Verify a Node release and materialize only its exact node binary."""
    root = anchor_private_root(
        pathlib.Path(args.root),
        getattr(args, "root_dev", None),
        getattr(args, "root_ino", None),
    )
    descriptor: int | None = None
    try:
        descriptor, opened = stable_archive(
            pathlib.Path(args.archive), MAX_NODE_ARCHIVE_BYTES
        )
        if (
            hash_descriptor(
                descriptor, "sha256", opened.st_size, MAX_NODE_ARCHIVE_BYTES
            )
            != args.sha256
        ):
            fail("Node archive sha256 does not match the pinned release")
        os.lseek(descriptor, 0, os.SEEK_SET)
        with (
            bounded_tar_stream(
                descriptor,
                root.descriptor,
                MAX_NODE_TAR_BYTES,
                MAX_NODE_ENTRIES,
            ) as stream,
            tarfile.open(fileobj=stream, mode="r:") as archive,
        ):
            member = find_node_member(archive, args.member)
            if member.size < 1 or member.size > MAX_BUNDLE_FILE_BYTES:
                fail("Node binary is outside the size limit")
            source = archive.extractfile(member)
            if source is None:
                fail("Node binary is unreadable")
            with source:
                private_file(
                    root.descriptor,
                    pathlib.PurePosixPath("node/bin/node"),
                    source,
                    member.size,
                    maximum=MAX_BUNDLE_FILE_BYTES,
                    mode=PRIVATE_EXECUTABLE_MODE,
                )
        verify_archive_identity(pathlib.Path(args.archive), descriptor, opened)
        root.revalidate()
    except (EOFError, OSError, tarfile.TarError) as error:
        fail(f"Node archive is invalid: {error}")
    finally:
        if descriptor is not None:
            os.close(descriptor)
        root.close()


def read_private_file(parent_descriptor: int, name: str, maximum: int) -> bytes:
    """Read exactly one stable private regular entry relative to its parent."""
    info = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    if stat.S_IMODE(info.st_mode) != PRIVATE_FILE_MODE:
        fail("private package file mode is unsafe")
    validate_bundle_file(info)
    if info.st_size < 1 or info.st_size > maximum:
        fail("private package file is outside the size limit")
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    try:
        opened = os.fstat(descriptor)
        remaining = opened.st_size
        chunks: list[bytes] = []
        while remaining:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                fail("private package file was truncated while it was read")
            chunks.append(chunk)
            remaining -= len(chunk)
        if os.read(descriptor, 1):
            fail("private package file grew while it was read")
        final = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    lexical = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    if (
        not same_identity(info, opened)
        or not same_identity(opened, final)
        or not same_identity(final, lexical)
    ):
        fail("private package file changed while it was read")
    return b"".join(chunks)


def dependency_fields_empty(value: dict[str, object]) -> bool:
    """Return whether every runtime dependency field is absent or empty."""
    fields = (
        "dependencies",
        "optionalDependencies",
        "peerDependencies",
        "peerDependenciesMeta",
        "bundledDependencies",
        "bundleDependencies",
    )
    return all(
        value.get(name) is None or value.get(name) == {} or value.get(name) == []
        for name in fields
    )


def finalize_package(args: argparse.Namespace) -> None:
    """Revalidate extracted metadata and create the immutable absolute wrapper."""
    root = anchor_private_root(pathlib.Path(args.root), args.root_dev, args.root_ino)
    try:
        package_info = os.stat("package", dir_fd=root.descriptor, follow_symlinks=False)
        package_descriptor = open_bundle_directory(
            root.descriptor, "package", package_info
        )
        try:
            package_data = read_private_file(
                package_descriptor, "package.json", 256 * 1024
            )
            expected = json.loads(args.metadata)
            actual = json.loads(package_data)
            expected_bin = expected.get("bin") if isinstance(expected, dict) else None
            if (
                not isinstance(expected, dict)
                or not isinstance(actual, dict)
                or not isinstance(expected_bin, dict)
                or actual.get("name") != expected.get("name")
                or actual.get("version") != expected.get("version")
                or actual.get("bin") != expected.get("bin")
                or actual.get("engines") != expected.get("engines")
                or not dependency_fields_empty(actual)
            ):
                fail(
                    "extracted package.json differs from selected dependency-free metadata"
                )
            cli_name = expected_bin.get("devcontainer")
            if cli_name != "devcontainer.js":
                fail("selected npm bin map is not exact")
            cli_info = os.stat(
                cli_name, dir_fd=package_descriptor, follow_symlinks=False
            )
            if (
                stat.S_IMODE(cli_info.st_mode) != PRIVATE_FILE_MODE
                or cli_info.st_size < 1
            ):
                fail("declared npm CLI file mode is unsafe")
            validate_bundle_file(cli_info)
        finally:
            os.close(package_descriptor)
        install_root = pathlib.PurePosixPath(args.install_root)
        if (
            not install_root.is_absolute()
            or str(install_root) != args.install_root
            or "\x00" in args.install_root
        ):
            fail("immutable install root is not canonical and absolute")
        node = str(install_root / "node/bin/node")
        cli = str(install_root / "package/devcontainer.js")
        wrapper = (
            f'#!/bin/sh\nexec {shlex.quote(node)} {shlex.quote(cli)} "$@"\n'.encode()
        )
        private_file(
            root.descriptor,
            pathlib.PurePosixPath("bin/devcontainer"),
            io.BytesIO(wrapper),
            len(wrapper),
            maximum=4096,
            mode=PRIVATE_EXECUTABLE_MODE,
        )
        root.revalidate()
    except (json.JSONDecodeError, OSError, UnicodeDecodeError) as error:
        fail(f"extracted package.json is invalid: {error}")
    finally:
        root.close()


def hash_file(parent_descriptor: int, name: str, info: os.stat_result) -> str:
    """Hash one stable private regular entry relative to its parent descriptor."""
    flags = (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    try:
        opened = os.fstat(descriptor)
        digest = hash_descriptor(
            descriptor, "sha256", opened.st_size, MAX_BUNDLE_FILE_BYTES
        )
        final = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if not same_identity(info, opened):
        fail("bundle file changed while it was opened")
    if not same_identity(opened, final):
        fail("bundle file changed while it was hashed")
    try:
        lexical = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except OSError as error:
        fail(f"bundle file path could not be rechecked: {error}")
    if not same_identity(final, lexical):
        fail("bundle file path changed while it was hashed")
    return digest


def closure_path(parent: str, name: str) -> str:
    """Return one core-compatible exact bundle closure path."""
    relative = name if not parent else f"{parent}/{name}"
    safe = safe_relative(relative, portable=True)
    if (
        len(str(safe).encode("utf-8")) > MAX_CLOSURE_PATH_BYTES
        or len(safe.parts) > MAX_CLOSURE_DEPTH
    ):
        fail("bundle closure path exceeds its configured bounds")
    return str(safe)


def validate_bundle_directory(info: os.stat_result) -> None:
    """Require one private directory snapshot."""
    if (
        not stat.S_ISDIR(info.st_mode)
        or stat.S_IMODE(info.st_mode) != PRIVATE_DIRECTORY_MODE
        or not owned_by_current_user(info)
    ):
        fail("bundle contains an unsafe directory")


def validate_bundle_file(info: os.stat_result) -> int:
    """Return the accepted private mode for one bounded regular file."""
    mode = stat.S_IMODE(info.st_mode)
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_nlink != 1
        or info.st_size < 0
        or info.st_size > MAX_BUNDLE_FILE_BYTES
        or mode not in {PRIVATE_FILE_MODE, PRIVATE_EXECUTABLE_MODE}
        or not owned_by_current_user(info)
    ):
        fail("bundle contains an unsafe regular file")
    return mode


def open_bundle_directory(
    parent_descriptor: int, name: str, expected: os.stat_result
) -> int:
    """Open one named private child directory without following links."""
    flags = (
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0)
    )
    descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    opened = os.fstat(descriptor)
    if not same_identity(expected, opened):
        os.close(descriptor)
        fail("bundle directory changed while it was opened")
    validate_bundle_directory(opened)
    return descriptor


def append_closure_entry(
    entries: list[dict[str, object]], entry: dict[str, object]
) -> None:
    """Append one entry while enforcing the shared closure count."""
    entries.append(entry)
    if len(entries) > MAX_BUNDLE_ENTRIES:
        fail("bundle closure contains too many entries")


def scan_bundle_child(
    parent_descriptor: int,
    name: str,
    parent: str,
    entries: list[dict[str, object]],
    total: int,
    depth: int,
) -> int:
    """Inventory one descriptor-relative bundle child."""
    relative = closure_path(parent, name)
    info = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    if stat.S_ISDIR(info.st_mode):
        validate_bundle_directory(info)
        append_closure_entry(
            entries,
            {"kind": "directory", "mode": PRIVATE_DIRECTORY_MODE, "path": relative},
        )
        child = open_bundle_directory(parent_descriptor, name, info)
        try:
            total = scan_bundle_directory(child, relative, entries, total, depth + 1)
            final = os.fstat(child)
            lexical = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
        finally:
            os.close(child)
        if not same_identity(info, final) or not same_identity(final, lexical):
            fail("bundle directory changed while it was scanned")
        return total
    mode = validate_bundle_file(info)
    total += info.st_size
    if total > MAX_BUNDLE_BYTES:
        fail("bundle closure exceeds its byte limit")
    append_closure_entry(
        entries,
        {
            "kind": "file",
            "mode": mode,
            "path": relative,
            "sha256": hash_file(parent_descriptor, name, info),
            "size": info.st_size,
        },
    )
    return total


def scan_bundle_directory(
    descriptor: int,
    relative: str,
    entries: list[dict[str, object]],
    total: int,
    depth: int,
) -> int:
    """Recursively inventory one descriptor-bound private bundle directory."""
    if depth > MAX_CLOSURE_DEPTH:
        fail("bundle directory nesting exceeds its limit")
    for name in sorted(os.listdir(descriptor)):
        total = scan_bundle_child(descriptor, name, relative, entries, total, depth)
    return total


def closure(args: argparse.Namespace) -> None:
    """Emit an exact sorted private closure for a completed bundle."""
    root = anchor_private_root(
        pathlib.Path(args.root),
        getattr(args, "root_dev", None),
        getattr(args, "root_ino", None),
    )
    try:
        entries: list[dict[str, object]] = []
        total = scan_bundle_directory(root.descriptor, "", entries, 0, 0)
        root.revalidate()
        entries.sort(key=lambda item: str(item["path"]))
        encoded = json.dumps(entries, separators=(",", ":"), sort_keys=True).encode(
            "utf-8"
        )
        value = {
            "bytes": total,
            "entries": entries,
            "sha256": hashlib.sha256(encoded).hexdigest(),
        }
        print(json.dumps(value, separators=(",", ":"), sort_keys=True))
    finally:
        root.close()


def clean_stage_directory(descriptor: int, depth: int = 0) -> None:
    """Remove only private regular entries below one anchored staging directory."""
    # A staging root contains the bundle directory above the final closure, so
    # safe cleanup needs exactly one additional directory level.
    if depth > MAX_CLOSURE_DEPTH + 1:
        fail("staging directory nesting exceeds its limit")
    for name in sorted(os.listdir(descriptor)):
        info = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if stat.S_ISDIR(info.st_mode):
            validate_bundle_directory(info)
            child = open_bundle_directory(descriptor, name, info)
            try:
                clean_stage_directory(child, depth + 1)
                final = os.fstat(child)
            finally:
                os.close(child)
            lexical = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if not same_object(info, final) or not same_object(final, lexical):
                fail("staging directory changed during cleanup")
            validate_bundle_directory(final)
            os.rmdir(name, dir_fd=descriptor)
        else:
            validate_bundle_file(info)
            lexical = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if not same_identity(info, lexical):
                fail("staging file changed during cleanup")
            os.unlink(name, dir_fd=descriptor)
    os.fsync(descriptor)


def clean_stage(args: argparse.Namespace) -> None:
    """Empty only the exact descriptor-bound stage created by the caller."""
    root = anchor_private_root(pathlib.Path(args.root))
    try:
        if root.opened.st_dev != args.dev or root.opened.st_ino != args.ino:
            fail("staging root identity differs from the created directory")
        clean_stage_directory(root.descriptor)
        root.revalidate()
    finally:
        root.close()


def parser() -> argparse.ArgumentParser:
    """Build the helper command-line parser."""
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="action", required=True)
    package = commands.add_parser("extract-package")
    package.add_argument("--archive", required=True)
    package.add_argument("--integrity", required=True)
    package.add_argument("--root", required=True)
    package.add_argument("--root-dev", required=True, type=int)
    package.add_argument("--root-ino", required=True, type=int)
    package.set_defaults(function=extract_package)
    node = commands.add_parser("extract-node")
    node.add_argument("--archive", required=True)
    node.add_argument("--sha256", required=True)
    node.add_argument("--member", required=True)
    node.add_argument("--root", required=True)
    node.add_argument("--root-dev", required=True, type=int)
    node.add_argument("--root-ino", required=True, type=int)
    node.set_defaults(function=extract_node)
    finalize = commands.add_parser("finalize-package")
    finalize.add_argument("--root", required=True)
    finalize.add_argument("--root-dev", required=True, type=int)
    finalize.add_argument("--root-ino", required=True, type=int)
    finalize.add_argument("--metadata", required=True)
    finalize.add_argument("--install-root", required=True)
    finalize.set_defaults(function=finalize_package)
    inventory = commands.add_parser("closure")
    inventory.add_argument("--root", required=True)
    inventory.add_argument("--root-dev", required=True, type=int)
    inventory.add_argument("--root-ino", required=True, type=int)
    inventory.set_defaults(function=closure)
    cleanup = commands.add_parser("clean-stage")
    cleanup.add_argument("--root", required=True)
    cleanup.add_argument("--dev", required=True, type=int)
    cleanup.add_argument("--ino", required=True, type=int)
    cleanup.set_defaults(function=clean_stage)
    return root


def main() -> int:
    """Run one helper action with bounded diagnostics."""
    arguments = parser().parse_args()
    try:
        arguments.function(arguments)
    except (BundleError, EOFError, OSError, tarfile.TarError) as error:
        print(f"verified-npm-bundle: {str(error)[:240]}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
