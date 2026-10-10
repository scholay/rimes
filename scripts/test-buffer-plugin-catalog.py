"""Regression checks for byte-pinned catalog files on Windows checkouts."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "buffer_plugin_catalog", ROOT / "scripts/sync-buffer-plugin-catalog.py"
)
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)


class BufferPluginCatalogTests(unittest.TestCase):
    def test_catalog_matches_pinned_packages_and_manifest_bytes(self):
        catalog.run(check=True)

    def test_generated_files_keep_lf_with_windows_autocrlf(self):
        files = (
            "Catalog/buffer-plugins.json",
            "Catalog/Plugins/builtin.apple-translation/manifest.json",
            "Catalog/Plugins/builtin.codex-cli/manifest.json",
            "Sources/RimeBuffer/PresetBufferPluginCatalog.generated.swift",
        )
        with tempfile.TemporaryDirectory(prefix="rimes-catalog-eol-") as temp:
            source = Path(temp) / "source"
            checkout = Path(temp) / "checkout"
            source.mkdir()
            (source / ".gitattributes").write_bytes(
                (ROOT / ".gitattributes").read_bytes()
            )
            for relative in files:
                path = source / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"first line\nsecond line\n")
            # An unpinned control proves autocrlf really is active in the clone.
            control = "Catalog/unpinned-control.txt"
            (source / control).write_bytes(b"first line\nsecond line\n")

            def git(*args):
                subprocess.run(
                    ["git", *args], check=True, capture_output=True, text=True
                )

            git("-c", "core.autocrlf=false", "init", "-q", str(source))
            git("-C", str(source), "add", ".")
            git(
                "-C", str(source), "-c", "user.name=Test Fixture",
                "-c", "user.email=fixture@example.invalid", "commit", "-qm",
                "fixture\n\nCo-authored-by: Codex <267193182+codex@users.noreply.github.com>",
            )
            git(
                "clone", "-q", "--no-local", "-c", "core.autocrlf=true",
                str(source), str(checkout),
            )
            for relative in files:
                with self.subTest(path=relative):
                    self.assertEqual(
                        (checkout / relative).read_bytes(),
                        b"first line\nsecond line\n",
                    )
            self.assertEqual(
                (checkout / control).read_bytes(),
                b"first line\r\nsecond line\r\n",
            )


if __name__ == "__main__":
    unittest.main()
