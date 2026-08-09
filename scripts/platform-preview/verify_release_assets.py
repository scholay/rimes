#!/usr/bin/env python3
"""Verify the final Windows/Linux platform-preview release assets.

The verifier never extracts an archive.  It streams every member, rejects
unsafe archive structure, and reconciles both platform manifests with the
reviewed policy closure and the source bytes in the selected checkout.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import stat
import sys
import tarfile
import unicodedata
import zipfile


MAX_ARCHIVE_BYTES = 256 * 1024 * 1024
MAX_FILE_BYTES = 128 * 1024 * 1024
MAX_EXPANDED_BYTES = 256 * 1024 * 1024
MAX_ARCHIVE_MEMBERS = 4096
MAX_METADATA_BYTES = 2 * 1024 * 1024
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
VERSION_PATTERN = re.compile(r"[0-9A-Za-z][0-9A-Za-z._-]{0,63}")

WINDOWS_STATIC_FILES = {
    "Install-RimesDataPreview.ps1": "platforms/windows/scripts/Install-RimesDataPreview.ps1",
    "Uninstall-RimesDataPreview.ps1": "platforms/windows/scripts/Uninstall-RimesDataPreview.ps1",
    "Verify-RimesDataPreview.ps1": "platforms/windows/scripts/Verify-RimesDataPreview.ps1",
    "lib/RimesDataPreview.Common.ps1": "platforms/windows/scripts/lib/RimesDataPreview.Common.ps1",
    "README.md": "platforms/windows/README.md",
    "LICENSE": "LICENSE",
    "THIRD_PARTY_NOTICES.md": "THIRD_PARTY_NOTICES.md",
}

LINUX_STATIC_FILES = {
    "README.md": "platforms/linux/README.md",
    "LICENSE": "LICENSE",
    "THIRD_PARTY_NOTICES.md": "THIRD_PARTY_NOTICES.md",
    "scripts/install.sh": "platforms/linux/scripts/install.sh",
    "scripts/uninstall.sh": "platforms/linux/scripts/uninstall.sh",
    "scripts/verify.sh": "platforms/linux/scripts/verify.sh",
    "scripts/package.sh": "platforms/linux/scripts/package.sh",
    "scripts/lib/common.sh": "platforms/linux/scripts/lib/common.sh",
}


class VerificationError(RuntimeError):
    """A fail-closed release-asset validation error."""


def fail(message: str) -> None:
    raise VerificationError(message)


@dataclass(frozen=True)
class FileRecord:
    size: int
    sha256: str
    data: bytes | None = None


@dataclass(frozen=True)
class ArchiveInventory:
    files: dict[str, FileRecord]
    directories: set[str]


def path_fold(path: str) -> str:
    return unicodedata.normalize("NFC", path).casefold()


def portable_relative_path(raw: object, context: str, *, directory: bool = False) -> str:
    if not isinstance(raw, str) or not raw:
        fail(f"{context}: expected a non-empty path")
    if "\x00" in raw or "\\" in raw or any(ord(character) < 32 for character in raw):
        fail(f"{context}: path contains a forbidden character: {raw!r}")
    if raw.startswith("/"):
        fail(f"{context}: absolute paths are forbidden: {raw!r}")

    if directory and raw.endswith("/"):
        raw = raw[:-1]
    elif not directory and raw.endswith("/"):
        fail(f"{context}: regular file path ends with '/': {raw!r}")
    if not raw:
        fail(f"{context}: archive root cannot be empty")

    parts = raw.split("/")
    if any(part in ("", ".", "..") for part in parts):
        fail(f"{context}: path contains an empty, '.', or '..' component: {raw!r}")
    for part in parts:
        if part.endswith((" ", ".")) or ":" in part:
            fail(f"{context}: path is not portable to Windows: {raw!r}")
        stem = part.split(".", 1)[0].casefold()
        if stem in {"con", "prn", "aux", "nul"} or re.fullmatch(
            r"com[1-9]|lpt[1-9]", stem
        ):
            fail(f"{context}: reserved Windows path component: {raw!r}")
    canonical = "/".join(parts)
    if len(canonical.encode("utf-8")) > 4096:
        fail(f"{context}: path is too long")
    return canonical


def validate_inventory_tree(files: set[str], directories: set[str], context: str) -> None:
    casing: dict[str, str] = {}
    node_types: dict[str, str] = {}

    def register(path: str, kind: str) -> None:
        parts = path.split("/")
        for index in range(1, len(parts) + 1):
            prefix = "/".join(parts[:index])
            prefix_kind = kind if index == len(parts) else "directory"
            folded = path_fold(prefix)
            previous_case = casing.setdefault(folded, prefix)
            if previous_case != prefix:
                fail(
                    f"{context}: case/Unicode-colliding paths: "
                    f"{previous_case!r} and {prefix!r}"
                )
            previous_kind = node_types.setdefault(folded, prefix_kind)
            if previous_kind != prefix_kind:
                fail(f"{context}: path is both a file and a directory: {prefix!r}")

    for directory in sorted(directories):
        register(directory, "directory")
    for filename in sorted(files):
        register(filename, "file")


def strict_json(data: bytes, context: str) -> object:
    if len(data) > MAX_METADATA_BYTES:
        fail(f"{context}: JSON metadata is too large")

    def pairs_hook(pairs: list[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                fail(f"{context}: duplicate JSON key: {key!r}")
            result[key] = value
        return result

    def reject_constant(value: str) -> object:
        fail(f"{context}: non-finite JSON number is forbidden: {value}")

    try:
        return json.loads(
            data.decode("utf-8"),
            object_pairs_hook=pairs_hook,
            parse_constant=reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{context}: invalid UTF-8 JSON: {error}")


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        fail(f"cannot hash {path}: {error}")
    return digest.hexdigest()


def records_match(first: FileRecord, second: FileRecord) -> bool:
    return first.size == second.size and hmac.compare_digest(
        first.sha256, second.sha256
    )


def stream_record(source: object, declared_size: int, capture: bool, context: str) -> FileRecord:
    digest = hashlib.sha256()
    captured = bytearray() if capture else None
    size = 0
    while True:
        chunk = source.read(1024 * 1024)  # type: ignore[attr-defined]
        if not chunk:
            break
        size += len(chunk)
        if size > declared_size or size > MAX_FILE_BYTES:
            fail(f"{context}: member exceeds its declared or reviewed size")
        digest.update(chunk)
        if captured is not None:
            if size > MAX_METADATA_BYTES:
                fail(f"{context}: captured metadata is too large")
            captured.extend(chunk)
    if size != declared_size:
        fail(f"{context}: member size mismatch (declared {declared_size}, read {size})")
    return FileRecord(
        size=size,
        sha256=digest.hexdigest(),
        data=bytes(captured) if captured is not None else None,
    )


def ensure_regular_file(path: Path, context: str, *, maximum_size: int) -> os.stat_result:
    try:
        metadata = path.lstat()
    except OSError as error:
        fail(f"{context}: cannot stat {path}: {error}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail(f"{context}: expected a regular non-symlink file: {path}")
    if metadata.st_size > maximum_size:
        fail(f"{context}: file exceeds {maximum_size} bytes: {path}")
    return metadata


def ensure_no_symlink_components(root: Path, relative: str, context: str) -> Path:
    current = root
    parts = relative.split("/")
    for index, part in enumerate(parts):
        current /= part
        try:
            metadata = current.lstat()
        except OSError as error:
            fail(f"{context}: cannot stat {current}: {error}")
        if stat.S_ISLNK(metadata.st_mode):
            fail(f"{context}: symbolic link is forbidden: {current}")
        if index < len(parts) - 1 and not stat.S_ISDIR(metadata.st_mode):
            fail(f"{context}: parent component is not a directory: {current}")
    return current


def load_expected_payload(repo_root: Path) -> dict[str, FileRecord]:
    original_root = repo_root
    try:
        repo_root = repo_root.resolve(strict=True)
    except OSError as error:
        fail(f"repository root is unavailable: {original_root}: {error}")
    if not repo_root.is_dir():
        fail(f"repository root is not a directory: {repo_root}")

    policy_relative = "scripts/platform-preview/policy.json"
    policy_path = ensure_no_symlink_components(repo_root, policy_relative, "policy")
    ensure_regular_file(policy_path, "policy", maximum_size=MAX_METADATA_BYTES)
    try:
        policy_data = policy_path.read_bytes()
    except OSError as error:
        fail(f"cannot read preview policy: {error}")
    policy = strict_json(policy_data, "preview policy")
    if (
        not isinstance(policy, dict)
        or type(policy.get("formatVersion")) is not int
        or policy.get("formatVersion") != 1
    ):
        fail("preview policy must be a formatVersion 1 object")

    source_root = portable_relative_path(policy.get("sourceRoot"), "policy sourceRoot")
    include = policy.get("include")
    if not isinstance(include, list) or not include:
        fail("preview policy include must be a non-empty array")
    relative_paths = [portable_relative_path(value, "policy include") for value in include]
    if len(relative_paths) != len(set(relative_paths)):
        fail("preview policy include contains duplicate paths")
    validate_inventory_tree(set(relative_paths), set(), "preview policy")

    data_root = ensure_no_symlink_components(repo_root, source_root, "policy source root")
    try:
        root_metadata = data_root.lstat()
    except OSError as error:
        fail(f"cannot stat policy source root: {error}")
    if not stat.S_ISDIR(root_metadata.st_mode):
        fail(f"policy source root is not a directory: {data_root}")

    records: dict[str, FileRecord] = {}
    total = 0
    for relative in sorted(relative_paths):
        path = ensure_no_symlink_components(data_root, relative, "policy source")
        metadata = ensure_regular_file(path, "policy source", maximum_size=MAX_FILE_BYTES)
        total += metadata.st_size
        if total > MAX_EXPANDED_BYTES:
            fail("policy payload exceeds the reviewed expanded-size limit")
        records[relative] = FileRecord(metadata.st_size, hash_file(path))
    return records


def load_static_files(
    repo_root: Path, mapping: dict[str, str], context: str
) -> dict[str, FileRecord]:
    original_root = repo_root
    try:
        repo_root = repo_root.resolve(strict=True)
    except OSError as error:
        fail(f"repository root is unavailable: {original_root}: {error}")
    if not repo_root.is_dir():
        fail(f"repository root is not a directory: {repo_root}")

    archive_paths = {
        portable_relative_path(path, f"{context} archive path") for path in mapping
    }
    if len(archive_paths) != len(mapping):
        fail(f"{context}: static archive allowlist contains duplicate paths")
    validate_inventory_tree(archive_paths, set(), f"{context} static allowlist")

    records: dict[str, FileRecord] = {}
    for archive_path, source_relative_raw in mapping.items():
        source_relative = portable_relative_path(
            source_relative_raw, f"{context} source path"
        )
        source_path = ensure_no_symlink_components(
            repo_root, source_relative, f"{context} source"
        )
        metadata = ensure_regular_file(
            source_path, f"{context} source", maximum_size=MAX_FILE_BYTES
        )
        records[archive_path] = FileRecord(metadata.st_size, hash_file(source_path))
    return records


def add_member(
    *,
    files: dict[str, FileRecord],
    directories: set[str],
    path: str,
    record: FileRecord | None,
    context: str,
) -> None:
    if path in files or path in directories:
        fail(f"{context}: duplicate archive path: {path!r}")
    if record is None:
        directories.add(path)
    else:
        files[path] = record


def inspect_zip(archive_path: Path, captures: set[str]) -> ArchiveInventory:
    files: dict[str, FileRecord] = {}
    directories: set[str] = set()
    total = 0
    try:
        with zipfile.ZipFile(archive_path, "r") as archive:
            infos = archive.infolist()
            if len(infos) > MAX_ARCHIVE_MEMBERS:
                fail("Windows ZIP contains too many members")
            for info in infos:
                is_directory = info.is_dir()
                name = portable_relative_path(
                    info.filename, "Windows ZIP member", directory=is_directory
                )
                if info.flag_bits & 0x1:
                    fail(f"Windows ZIP contains an encrypted member: {name}")
                if info.compress_type not in {zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED}:
                    fail(f"Windows ZIP uses an unsupported compression method: {name}")

                archived_mode = (info.external_attr >> 16) & 0xFFFF
                archived_type = stat.S_IFMT(archived_mode)
                if archived_type:
                    valid_type = (
                        archived_type == stat.S_IFDIR
                        if is_directory
                        else archived_type == stat.S_IFREG
                    )
                    if not valid_type:
                        fail(f"Windows ZIP contains a link or special file: {name}")

                if is_directory:
                    if info.file_size != 0:
                        fail(f"Windows ZIP directory has data: {name}")
                    add_member(
                        files=files,
                        directories=directories,
                        path=name,
                        record=None,
                        context="Windows ZIP",
                    )
                    continue

                if info.file_size > MAX_FILE_BYTES:
                    fail(f"Windows ZIP member exceeds the file-size limit: {name}")
                total += info.file_size
                if total > MAX_EXPANDED_BYTES:
                    fail("Windows ZIP exceeds the expanded-size limit")
                with archive.open(info, "r") as source:
                    record = stream_record(
                        source,
                        info.file_size,
                        name in captures,
                        f"Windows ZIP member {name}",
                    )
                add_member(
                    files=files,
                    directories=directories,
                    path=name,
                    record=record,
                    context="Windows ZIP",
                )
    except VerificationError:
        raise
    except (OSError, RuntimeError, zipfile.BadZipFile, NotImplementedError) as error:
        fail(f"cannot inspect Windows ZIP {archive_path}: {error}")

    validate_inventory_tree(set(files), directories, "Windows ZIP")
    return ArchiveInventory(files=files, directories=directories)


def inspect_tar_gz(archive_path: Path, captures: set[str]) -> ArchiveInventory:
    files: dict[str, FileRecord] = {}
    directories: set[str] = set()
    total = 0
    members = 0
    try:
        with tarfile.open(archive_path, mode="r|gz") as archive:
            for member in archive:
                members += 1
                if members > MAX_ARCHIVE_MEMBERS:
                    fail("Linux tar.gz contains too many members")

                if member.type == tarfile.DIRTYPE:
                    is_directory = True
                elif member.type in {tarfile.REGTYPE, tarfile.AREGTYPE} and not member.issparse():
                    is_directory = False
                else:
                    fail(
                        "Linux tar.gz contains a link, sparse entry, or special file: "
                        f"{member.name!r}"
                    )
                name = portable_relative_path(
                    member.name, "Linux tar.gz member", directory=is_directory
                )
                if member.linkname:
                    fail(f"Linux tar.gz member has an unexpected link target: {name}")
                if member.mode & (stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX):
                    fail(f"Linux tar.gz member has privileged mode bits: {name}")

                if is_directory:
                    if member.size != 0:
                        fail(f"Linux tar.gz directory has data: {name}")
                    add_member(
                        files=files,
                        directories=directories,
                        path=name,
                        record=None,
                        context="Linux tar.gz",
                    )
                    continue

                if member.size > MAX_FILE_BYTES:
                    fail(f"Linux tar.gz member exceeds the file-size limit: {name}")
                total += member.size
                if total > MAX_EXPANDED_BYTES:
                    fail("Linux tar.gz exceeds the expanded-size limit")
                source = archive.extractfile(member)
                if source is None:
                    fail(f"cannot read Linux tar.gz member: {name}")
                with source:
                    record = stream_record(
                        source,
                        member.size,
                        name in captures,
                        f"Linux tar.gz member {name}",
                    )
                add_member(
                    files=files,
                    directories=directories,
                    path=name,
                    record=record,
                    context="Linux tar.gz",
                )
    except VerificationError:
        raise
    except (OSError, EOFError, tarfile.TarError) as error:
        fail(f"cannot inspect Linux tar.gz {archive_path}: {error}")

    validate_inventory_tree(set(files), directories, "Linux tar.gz")
    return ArchiveInventory(files=files, directories=directories)


def require_captured_file(inventory: ArchiveInventory, name: str, context: str) -> bytes:
    record = inventory.files.get(name)
    if record is None:
        fail(f"{context}: required regular file is missing: {name}")
    if record.data is None:
        fail(f"{context}: internal error: metadata was not captured: {name}")
    return record.data


def verify_payload_files(
    inventory: ArchiveInventory,
    prefix: str,
    expected: dict[str, FileRecord],
    context: str,
) -> dict[str, FileRecord]:
    actual = {
        path.removeprefix(prefix): record
        for path, record in inventory.files.items()
        if path.startswith(prefix)
    }
    actual_paths = set(actual)
    expected_paths = set(expected)
    if actual_paths != expected_paths:
        fail(
            f"{context}: payload path set differs from policy; "
            f"missing={sorted(expected_paths - actual_paths)}, "
            f"extra={sorted(actual_paths - expected_paths)}"
        )
    for relative in sorted(expected):
        archived = actual[relative]
        source = expected[relative]
        if not records_match(archived, source):
            fail(f"{context}: payload bytes differ from policy source: {relative}")
    return actual


def implied_directories(files: set[str]) -> set[str]:
    result: set[str] = set()
    for path in files:
        parts = path.split("/")
        result.update("/".join(parts[:index]) for index in range(1, len(parts)))
    return result


def verify_archive_allowlist(
    inventory: ArchiveInventory, expected_files: set[str], context: str
) -> None:
    actual_files = set(inventory.files)
    if actual_files != expected_files:
        fail(
            f"{context}: regular-file set differs from the release allowlist; "
            f"missing={sorted(expected_files - actual_files)}, "
            f"extra={sorted(actual_files - expected_files)}"
        )
    unexpected_directories = inventory.directories - implied_directories(expected_files)
    if unexpected_directories:
        fail(
            f"{context}: directory set contains paths outside the release allowlist: "
            f"{sorted(unexpected_directories)}"
        )


def verify_static_files(
    inventory: ArchiveInventory,
    expected: dict[str, FileRecord],
    prefix: str,
    context: str,
) -> None:
    for relative, source in expected.items():
        archive_path = prefix + relative
        archived = inventory.files.get(archive_path)
        if archived is None:
            fail(f"{context}: required static file is missing: {archive_path}")
        if not records_match(archived, source):
            fail(
                f"{context}: static file differs from the tagged repository checkout: "
                f"{archive_path}"
            )


def parse_windows_manifest(
    data: bytes,
    version: str,
    expected: dict[str, FileRecord],
    actual: dict[str, FileRecord],
) -> dict[str, FileRecord]:
    value = strict_json(data, "Windows payload-manifest.json")
    if not isinstance(value, dict):
        fail("Windows payload-manifest.json must be an object")
    required_keys = {
        "formatVersion",
        "packageId",
        "packageVersion",
        "generatedAtUtc",
        "payloadRoot",
        "files",
    }
    if set(value) != required_keys:
        fail(
            "Windows payload-manifest.json keys drifted; "
            f"missing={sorted(required_keys - set(value))}, "
            f"extra={sorted(set(value) - required_keys)}"
        )
    if type(value.get("formatVersion")) is not int or value.get("formatVersion") != 1:
        fail("Windows payload manifest formatVersion must be 1")
    if value.get("packageId") != "org.rimes.windows-data-preview":
        fail("Windows payload manifest packageId drifted")
    if value.get("packageVersion") != version:
        fail("Windows payload manifest version does not match --version")
    if value.get("payloadRoot") != "payload/rime-data":
        fail("Windows payload manifest payloadRoot drifted")
    if not isinstance(value.get("generatedAtUtc"), str) or not value["generatedAtUtc"]:
        fail("Windows payload manifest generatedAtUtc is missing")

    entries = value.get("files")
    if not isinstance(entries, list):
        fail("Windows payload manifest files must be an array")
    manifest: dict[str, FileRecord] = {}
    order: list[str] = []
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict) or set(entry) != {"path", "size", "sha256"}:
            fail(f"Windows payload manifest entry {index} has the wrong shape")
        relative = portable_relative_path(entry.get("path"), "Windows manifest file")
        size = entry.get("size")
        digest = entry.get("sha256")
        if type(size) is not int or size < 0 or not isinstance(digest, str):
            fail(f"Windows payload manifest entry {relative} has invalid metadata")
        if SHA256_PATTERN.fullmatch(digest) is None:
            fail(f"Windows payload manifest entry {relative} has invalid SHA-256")
        if relative in manifest:
            fail(f"Windows payload manifest repeats: {relative}")
        order.append(relative)
        manifest[relative] = FileRecord(size, digest)

    expected_order = sorted(expected)
    if order != expected_order:
        fail("Windows payload manifest paths are not the exact sorted policy closure")
    validate_inventory_tree(set(manifest), set(), "Windows payload manifest")
    for relative in expected_order:
        declared = manifest[relative]
        if declared != expected[relative] or declared != FileRecord(
            actual[relative].size, actual[relative].sha256
        ):
            fail(f"Windows payload manifest disagrees with payload/source: {relative}")
    return manifest


def parse_linux_manifest(
    data: bytes,
    expected: dict[str, FileRecord],
    actual: dict[str, FileRecord],
) -> dict[str, FileRecord]:
    if len(data) > MAX_METADATA_BYTES or not data or not data.endswith(b"\n"):
        fail("Linux PAYLOAD-MANIFEST.tsv must be a bounded LF-terminated file")
    if b"\r" in data or b"\x00" in data:
        fail("Linux PAYLOAD-MANIFEST.tsv contains a forbidden byte")

    manifest: dict[str, FileRecord] = {}
    order: list[str] = []
    for index, line in enumerate(data[:-1].split(b"\n"), start=1):
        if not line or line.count(b"\t") != 1:
            fail(f"Linux payload manifest line {index} has the wrong shape")
        digest_bytes, relative_bytes = line.split(b"\t", 1)
        try:
            digest = digest_bytes.decode("ascii")
            relative_raw = relative_bytes.decode("utf-8")
        except UnicodeDecodeError as error:
            fail(f"Linux payload manifest line {index} is not valid text: {error}")
        if SHA256_PATTERN.fullmatch(digest) is None:
            fail(f"Linux payload manifest line {index} has invalid SHA-256")
        relative = portable_relative_path(relative_raw, "Linux manifest file")
        if relative in manifest:
            fail(f"Linux payload manifest repeats: {relative}")
        order.append(relative)
        archived = actual.get(relative)
        if archived is None:
            fail(f"Linux payload manifest references a missing file: {relative}")
        manifest[relative] = FileRecord(archived.size, digest)

    expected_order = sorted(expected)
    if order != expected_order:
        fail("Linux payload manifest paths are not the exact sorted policy closure")
    validate_inventory_tree(set(manifest), set(), "Linux payload manifest")
    for relative in expected_order:
        declared = manifest[relative]
        if declared != expected[relative] or declared != FileRecord(
            actual[relative].size, actual[relative].sha256
        ):
            fail(f"Linux payload manifest disagrees with payload/source: {relative}")
    return manifest


def verify_windows_archive(
    archive_path: Path,
    version: str,
    expected: dict[str, FileRecord],
    static_files: dict[str, FileRecord],
) -> dict[str, FileRecord]:
    manifest_name = "payload-manifest.json"
    inventory = inspect_zip(archive_path, {manifest_name})
    expected_files = {
        manifest_name,
        *static_files,
        *(f"payload/rime-data/{path}" for path in expected),
    }
    verify_archive_allowlist(inventory, expected_files, "Windows ZIP")
    verify_static_files(inventory, static_files, "", "Windows ZIP")
    actual = verify_payload_files(
        inventory,
        "payload/rime-data/",
        expected,
        "Windows ZIP",
    )
    manifest_data = require_captured_file(inventory, manifest_name, "Windows ZIP")
    return parse_windows_manifest(manifest_data, version, expected, actual)


def verify_linux_archive(
    archive_path: Path,
    version: str,
    expected: dict[str, FileRecord],
    static_files: dict[str, FileRecord],
) -> dict[str, FileRecord]:
    root = f"RIMES-Linux-Data-Preview-{version}"
    manifest_name = f"{root}/data/PAYLOAD-MANIFEST.tsv"
    version_name = f"{root}/VERSION"
    inventory = inspect_tar_gz(archive_path, {manifest_name, version_name})
    all_paths = set(inventory.files) | inventory.directories
    outside = sorted(
        path for path in all_paths if path != root and not path.startswith(root + "/")
    )
    if outside:
        fail(f"Linux tar.gz contains paths outside its versioned root: {outside}")
    if root not in inventory.directories:
        fail("Linux tar.gz is missing its versioned root directory")

    root_prefix = root + "/"
    expected_files = {
        manifest_name,
        version_name,
        *(root_prefix + path for path in static_files),
        *(root_prefix + f"data/rime-data/{path}" for path in expected),
    }
    verify_archive_allowlist(inventory, expected_files, "Linux tar.gz")
    verify_static_files(inventory, static_files, root_prefix, "Linux tar.gz")

    version_data = require_captured_file(inventory, version_name, "Linux tar.gz")
    if version_data != (version + "\n").encode("ascii"):
        fail("Linux archive VERSION does not match --version")
    actual = verify_payload_files(
        inventory,
        f"{root}/data/rime-data/",
        expected,
        "Linux tar.gz",
    )
    manifest_data = require_captured_file(inventory, manifest_name, "Linux tar.gz")
    return parse_linux_manifest(manifest_data, expected, actual)


def asset_filenames(version: str, platform: str) -> dict[str, tuple[str, str]]:
    result: dict[str, tuple[str, str]] = {}
    if platform in {"windows", "all"}:
        archive = f"RIMES-Windows-Data-Preview-{version}.zip"
        result["windows"] = (archive, archive + ".sha256")
    if platform in {"linux", "all"}:
        archive = f"RIMES-Linux-Data-Preview-{version}.tar.gz"
        result["linux"] = (archive, archive + ".sha256")
    return result


def validate_asset_directory(
    asset_dir: Path, expected_names: set[str]
) -> dict[str, Path]:
    if asset_dir.is_symlink():
        fail(f"asset directory must not be a symbolic link: {asset_dir}")
    try:
        if not asset_dir.is_dir():
            fail(f"asset directory does not exist: {asset_dir}")
        entries = list(os.scandir(asset_dir))
    except OSError as error:
        fail(f"cannot inspect asset directory {asset_dir}: {error}")

    actual_names = {entry.name for entry in entries}
    if actual_names != expected_names:
        fail(
            "asset directory must contain only the exact selected release files; "
            f"missing={sorted(expected_names - actual_names)}, "
            f"extra={sorted(actual_names - expected_names)}"
        )
    paths: dict[str, Path] = {}
    for entry in entries:
        if entry.is_symlink() or not entry.is_file(follow_symlinks=False):
            fail(f"release asset must be a regular non-symlink file: {entry.name}")
        paths[entry.name] = Path(entry.path)
    return paths


def verify_sidecar(archive_path: Path, checksum_path: Path) -> None:
    ensure_regular_file(archive_path, "release archive", maximum_size=MAX_ARCHIVE_BYTES)
    metadata = ensure_regular_file(checksum_path, "checksum sidecar", maximum_size=4096)
    try:
        raw = checksum_path.read_bytes()
    except OSError as error:
        fail(f"cannot read checksum sidecar {checksum_path}: {error}")
    if len(raw) != metadata.st_size:
        fail(f"checksum sidecar changed while being read: {checksum_path}")

    filename = archive_path.name.encode("ascii")
    pattern = re.compile(rb"([0-9a-f]{64})  " + re.escape(filename) + rb"\n")
    match = pattern.fullmatch(raw)
    if match is None:
        fail(
            f"checksum sidecar must contain exactly '<lowercase-sha256>  "
            f"{archive_path.name}<LF>': {checksum_path.name}"
        )
    expected_digest = match.group(1).decode("ascii")
    actual_digest = hash_file(archive_path)
    if not hmac.compare_digest(expected_digest, actual_digest):
        fail(f"release archive SHA-256 mismatch: {archive_path.name}")


def verify_release_assets(
    repo_root: Path,
    asset_dir: Path,
    version: str,
    platform: str = "all",
) -> dict[str, dict[str, FileRecord]]:
    if VERSION_PATTERN.fullmatch(version) is None:
        fail("version must be 1-64 ASCII letters, digits, dots, underscores, or hyphens")
    if platform not in {"windows", "linux", "all"}:
        fail("platform must be windows, linux, or all")

    selected = asset_filenames(version, platform)
    expected_asset_names = {
        filename for pair in selected.values() for filename in pair
    }
    paths = validate_asset_directory(asset_dir, expected_asset_names)
    expected_payload = load_expected_payload(repo_root)

    static_files: dict[str, dict[str, FileRecord]] = {}
    if "windows" in selected:
        static_files["windows"] = load_static_files(
            repo_root, WINDOWS_STATIC_FILES, "Windows release"
        )
    if "linux" in selected:
        static_files["linux"] = load_static_files(
            repo_root, LINUX_STATIC_FILES, "Linux release"
        )

    manifests: dict[str, dict[str, FileRecord]] = {}
    for name, (archive_name, checksum_name) in selected.items():
        archive_path = paths[archive_name]
        verify_sidecar(archive_path, paths[checksum_name])
        if name == "windows":
            manifests[name] = verify_windows_archive(
                archive_path, version, expected_payload, static_files[name]
            )
        else:
            manifests[name] = verify_linux_archive(
                archive_path, version, expected_payload, static_files[name]
            )

    if platform == "all" and manifests["windows"] != manifests["linux"]:
        fail("Windows and Linux platform manifests do not describe the same payload")
    return manifests


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--repo-root", type=Path, required=True)
    result.add_argument("--asset-dir", type=Path, required=True)
    result.add_argument("--version", required=True)
    result.add_argument(
        "--platform",
        choices=("windows", "linux", "all"),
        default="all",
        help="verify one platform pair or all four release files (default: all)",
    )
    return result


def main() -> int:
    arguments = parser().parse_args()
    try:
        manifests = verify_release_assets(
            arguments.repo_root,
            arguments.asset_dir,
            arguments.version,
            arguments.platform,
        )
    except VerificationError as error:
        print(f"platform-preview release-assets ERROR: {error}", file=sys.stderr)
        return 1
    payload_count = len(next(iter(manifests.values())))
    print(
        "platform-preview release-assets OK: "
        f"platform={arguments.platform} version={arguments.version} "
        f"payload_files={payload_count}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
