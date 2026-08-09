#!/usr/bin/env python3
"""Unit tests for the final platform-preview release-asset verifier."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import stat
import sys
import tarfile
import tempfile
import unittest
import warnings
import zipfile


SCRIPT = Path(__file__).with_name("verify_release_assets.py")
SPEC = importlib.util.spec_from_file_location("rimes_release_asset_verifier", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
verifier = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = verifier
SPEC.loader.exec_module(verifier)


class ReleaseAssetFixture(unittest.TestCase):
    VERSION = "0.1.0-preview.1"
    INCLUDE = ("default.yaml", "lua/helper.lua")

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.data = self.repo / "rime-data"
        (self.repo / "scripts" / "platform-preview").mkdir(parents=True)
        (self.data / "lua").mkdir(parents=True)
        (self.data / "default.yaml").write_bytes(b"schema_list: []\n")
        (self.data / "lua" / "helper.lua").write_bytes(b"return true\n")
        policy = {
            "formatVersion": 1,
            "sourceRoot": "rime-data",
            "include": list(self.INCLUDE),
        }
        (self.repo / "scripts" / "platform-preview" / "policy.json").write_text(
            json.dumps(policy), encoding="utf-8"
        )
        source_paths = set(verifier.WINDOWS_STATIC_FILES.values()) | set(
            verifier.LINUX_STATIC_FILES.values()
        )
        self.static_source_bytes: dict[str, bytes] = {}
        for relative in sorted(source_paths):
            data = f"tagged source bytes: {relative}\n".encode("utf-8")
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            self.static_source_bytes[relative] = data

    def source_records(self) -> dict[str, tuple[int, str, bytes]]:
        result: dict[str, tuple[int, str, bytes]] = {}
        for relative in self.INCLUDE:
            data = (self.data / relative).read_bytes()
            result[relative] = (len(data), hashlib.sha256(data).hexdigest(), data)
        return result

    @staticmethod
    def write_sidecar(archive: Path, *, crlf: bool = False, filename: str | None = None) -> None:
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        newline = "\r\n" if crlf else "\n"
        name = filename if filename is not None else archive.name
        archive.with_name(archive.name + ".sha256").write_bytes(
            f"{digest}  {name}{newline}".encode("ascii")
        )

    @staticmethod
    def zip_info(name: str, mode: int) -> zipfile.ZipInfo:
        info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
        info.create_system = 3
        info.external_attr = mode << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        return info

    def build_windows(
        self,
        asset_dir: Path,
        *,
        extras: list[tuple[str, str, bytes]] | None = None,
        manifest_digest_override: dict[str, str] | None = None,
        static_override: dict[str, bytes] | None = None,
        crlf_sidecar: bool = False,
    ) -> Path:
        asset_dir.mkdir(parents=True, exist_ok=True)
        archive = asset_dir / f"RIMES-Windows-Data-Preview-{self.VERSION}.zip"
        records = self.source_records()
        manifest_files = []
        for relative in sorted(records):
            size, digest, _ = records[relative]
            if manifest_digest_override and relative in manifest_digest_override:
                digest = manifest_digest_override[relative]
            manifest_files.append({"path": relative, "size": size, "sha256": digest})
        manifest = {
            "formatVersion": 1,
            "packageId": "org.rimes.windows-data-preview",
            "packageVersion": self.VERSION,
            "generatedAtUtc": "2026-01-01T00:00:00.0000000Z",
            "payloadRoot": "payload/rime-data",
            "files": manifest_files,
        }

        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(archive, "w") as output:
                output.writestr(
                    self.zip_info("payload-manifest.json", stat.S_IFREG | 0o644),
                    (json.dumps(manifest, sort_keys=True) + "\n").encode("utf-8"),
                )
                for archive_path, source_path in verifier.WINDOWS_STATIC_FILES.items():
                    data = (static_override or {}).get(
                        archive_path, self.static_source_bytes[source_path]
                    )
                    output.writestr(
                        self.zip_info(archive_path, stat.S_IFREG | 0o644), data
                    )
                for relative in sorted(records):
                    output.writestr(
                        self.zip_info(
                            f"payload/rime-data/{relative}", stat.S_IFREG | 0o644
                        ),
                        records[relative][2],
                    )
                for name, kind, data in extras or []:
                    if kind == "file":
                        mode = stat.S_IFREG | 0o644
                    elif kind == "directory":
                        mode = stat.S_IFDIR | 0o755
                        if not name.endswith("/"):
                            name += "/"
                    elif kind == "symlink":
                        mode = stat.S_IFLNK | 0o777
                    elif kind == "fifo":
                        mode = stat.S_IFIFO | 0o644
                    else:
                        raise AssertionError(f"unknown ZIP fixture kind: {kind}")
                    output.writestr(self.zip_info(name, mode), data)
        self.write_sidecar(archive, crlf=crlf_sidecar)
        return archive

    @staticmethod
    def add_tar_directory(output: tarfile.TarFile, name: str) -> None:
        info = tarfile.TarInfo(name)
        info.type = tarfile.DIRTYPE
        info.mode = 0o755
        info.size = 0
        info.mtime = 0
        output.addfile(info)

    @staticmethod
    def add_tar_file(output: tarfile.TarFile, name: str, data: bytes) -> None:
        info = tarfile.TarInfo(name)
        info.type = tarfile.REGTYPE
        info.mode = 0o644
        info.size = len(data)
        info.mtime = 0
        output.addfile(info, io.BytesIO(data))

    def build_linux(
        self,
        asset_dir: Path,
        *,
        extras: list[tuple[str, str, bytes]] | None = None,
        payload_override: dict[str, bytes] | None = None,
        static_override: dict[str, bytes] | None = None,
    ) -> Path:
        asset_dir.mkdir(parents=True, exist_ok=True)
        archive = asset_dir / f"RIMES-Linux-Data-Preview-{self.VERSION}.tar.gz"
        root = f"RIMES-Linux-Data-Preview-{self.VERSION}"
        source_records = self.source_records()
        payload = {
            relative: (payload_override or {}).get(relative, record[2])
            for relative, record in source_records.items()
        }
        manifest = b"".join(
            hashlib.sha256(payload[relative]).hexdigest().encode("ascii")
            + b"\t"
            + relative.encode("utf-8")
            + b"\n"
            for relative in sorted(payload)
        )

        with tarfile.open(archive, "w:gz", format=tarfile.PAX_FORMAT) as output:
            self.add_tar_directory(output, root)
            self.add_tar_file(output, f"{root}/VERSION", (self.VERSION + "\n").encode())
            self.add_tar_file(output, f"{root}/data/PAYLOAD-MANIFEST.tsv", manifest)
            for archive_path, source_path in verifier.LINUX_STATIC_FILES.items():
                data = (static_override or {}).get(
                    archive_path, self.static_source_bytes[source_path]
                )
                self.add_tar_file(output, f"{root}/{archive_path}", data)
            for relative in sorted(payload):
                self.add_tar_file(
                    output, f"{root}/data/rime-data/{relative}", payload[relative]
                )
            for name, kind, data in extras or []:
                if kind == "file":
                    self.add_tar_file(output, name, data)
                elif kind == "directory":
                    self.add_tar_directory(output, name)
                else:
                    info = tarfile.TarInfo(name)
                    info.mode = 0o644
                    info.mtime = 0
                    info.size = 0
                    if kind == "symlink":
                        info.type = tarfile.SYMTYPE
                        info.linkname = "target"
                    elif kind == "hardlink":
                        info.type = tarfile.LNKTYPE
                        info.linkname = f"{root}/VERSION"
                    elif kind == "fifo":
                        info.type = tarfile.FIFOTYPE
                    else:
                        raise AssertionError(f"unknown tar fixture kind: {kind}")
                    output.addfile(info)
        self.write_sidecar(archive)
        return archive

    def assert_verification_fails(
        self, asset_dir: Path, platform: str, message_fragment: str | None = None
    ) -> None:
        with self.assertRaises(verifier.VerificationError) as raised:
            verifier.verify_release_assets(
                self.repo, asset_dir, self.VERSION, platform
            )
        if message_fragment is not None:
            self.assertIn(message_fragment, str(raised.exception))


class ValidAssetTests(ReleaseAssetFixture):
    def test_all_platform_assets_and_manifests_match_policy(self) -> None:
        assets = self.root / "all-assets"
        self.build_windows(assets)
        self.build_linux(assets)
        result = verifier.verify_release_assets(
            self.repo, assets, self.VERSION, "all"
        )
        self.assertEqual(set(result), {"windows", "linux"})
        self.assertEqual(set(result["windows"]), set(self.INCLUDE))
        self.assertEqual(result["windows"], result["linux"])

    def test_single_platform_accepts_only_its_pair(self) -> None:
        assets = self.root / "windows-assets"
        self.build_windows(assets)
        result = verifier.verify_release_assets(
            self.repo, assets, self.VERSION, "windows"
        )
        self.assertEqual(set(result), {"windows"})


class OuterAssetBoundaryTests(ReleaseAssetFixture):
    def test_asset_directory_rejects_any_extra_entry(self) -> None:
        assets = self.root / "assets"
        self.build_windows(assets)
        (assets / "notes.txt").write_text("not a release asset\n", encoding="utf-8")
        self.assert_verification_fails(assets, "windows", "only the exact")

    def test_sidecar_requires_exact_filename_and_format(self) -> None:
        for case, rewrite in (
            ("wrong-name", lambda archive, digest: f"{digest}  other.zip\n"),
            ("single-space", lambda archive, digest: f"{digest} {archive.name}\n"),
            ("uppercase", lambda archive, digest: f"{digest.upper()}  {archive.name}\n"),
        ):
            with self.subTest(case=case):
                assets = self.root / f"assets-{case}"
                archive = self.build_windows(assets)
                digest = hashlib.sha256(archive.read_bytes()).hexdigest()
                archive.with_name(archive.name + ".sha256").write_text(
                    rewrite(archive, digest), encoding="ascii", newline=""
                )
                self.assert_verification_fails(assets, "windows", "checksum sidecar")

    def test_sidecar_hash_must_match_archive(self) -> None:
        assets = self.root / "assets-hash"
        archive = self.build_windows(assets)
        with archive.open("ab") as output:
            output.write(b"tamper")
        self.assert_verification_fails(assets, "windows", "SHA-256 mismatch")

    def test_sidecar_rejects_crlf(self) -> None:
        assets = self.root / "assets-crlf"
        self.build_windows(assets, crlf_sidecar=True)
        self.assert_verification_fails(assets, "windows", "<LF>")


class ArchiveStructureTests(ReleaseAssetFixture):
    def test_zip_rejects_absolute_and_parent_escape_paths(self) -> None:
        for case, path in (("absolute", "/escape"), ("parent", "../escape")):
            with self.subTest(case=case):
                assets = self.root / f"zip-{case}"
                self.build_windows(assets, extras=[(path, "file", b"bad")])
                self.assert_verification_fails(assets, "windows", "path")

    def test_tar_rejects_parent_escape_path(self) -> None:
        assets = self.root / "tar-parent"
        self.build_linux(assets, extras=[("../escape", "file", b"bad")])
        self.assert_verification_fails(assets, "linux", "path")

    def test_zip_rejects_symlink_and_special_entries(self) -> None:
        for kind in ("symlink", "fifo"):
            with self.subTest(kind=kind):
                assets = self.root / f"zip-{kind}"
                self.build_windows(assets, extras=[("unsafe", kind, b"target")])
                self.assert_verification_fails(assets, "windows", "special file")

    def test_tar_rejects_links_and_special_entries(self) -> None:
        root = f"RIMES-Linux-Data-Preview-{self.VERSION}"
        for kind in ("symlink", "hardlink", "fifo"):
            with self.subTest(kind=kind):
                assets = self.root / f"tar-{kind}"
                self.build_linux(assets, extras=[(f"{root}/unsafe", kind, b"")])
                self.assert_verification_fails(assets, "linux", "special file")

    def test_zip_rejects_case_collision(self) -> None:
        assets = self.root / "zip-case"
        self.build_windows(
            assets, extras=[("PAYLOAD-MANIFEST.JSON", "file", b"collision")]
        )
        self.assert_verification_fails(assets, "windows", "colliding")

    def test_zip_rejects_duplicate_path(self) -> None:
        assets = self.root / "zip-duplicate"
        self.build_windows(
            assets,
            extras=[
                ("duplicate.txt", "file", b"one"),
                ("duplicate.txt", "file", b"two"),
            ],
        )
        self.assert_verification_fails(assets, "windows", "duplicate archive path")

    def test_archives_reject_unlisted_safe_regular_member(self) -> None:
        windows_assets = self.root / "windows-extra-member"
        self.build_windows(
            windows_assets, extras=[("notes.txt", "file", b"safe but unreviewed\n")]
        )
        self.assert_verification_fails(windows_assets, "windows", "release allowlist")

        linux_assets = self.root / "linux-extra-member"
        root = f"RIMES-Linux-Data-Preview-{self.VERSION}"
        self.build_linux(
            linux_assets,
            extras=[(f"{root}/notes.txt", "file", b"safe but unreviewed\n")],
        )
        self.assert_verification_fails(linux_assets, "linux", "release allowlist")


class PayloadReconciliationTests(ReleaseAssetFixture):
    def test_static_support_file_must_match_tagged_checkout(self) -> None:
        windows_assets = self.root / "windows-static-tamper"
        self.build_windows(
            windows_assets, static_override={"README.md": b"tampered\n"}
        )
        self.assert_verification_fails(
            windows_assets, "windows", "tagged repository checkout"
        )

        linux_assets = self.root / "linux-static-tamper"
        self.build_linux(
            linux_assets,
            static_override={"scripts/install.sh": b"#!/bin/sh\ntampered\n"},
        )
        self.assert_verification_fails(
            linux_assets, "linux", "tagged repository checkout"
        )

    def test_windows_manifest_hash_must_match_source_and_archive(self) -> None:
        assets = self.root / "windows-manifest"
        self.build_windows(
            assets,
            manifest_digest_override={"default.yaml": "0" * 64},
        )
        self.assert_verification_fails(assets, "windows", "disagrees")

    def test_linux_payload_and_manifest_must_match_policy_source(self) -> None:
        assets = self.root / "linux-payload"
        self.build_linux(
            assets,
            payload_override={"default.yaml": b"schema_list: [tampered]\n"},
        )
        self.assert_verification_fails(assets, "linux", "differ from policy source")


if __name__ == "__main__":
    unittest.main()
