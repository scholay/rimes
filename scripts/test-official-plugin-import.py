import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("prepare_plugins", Path(__file__).with_name("prepare-official-plugins.py"))
prepare_plugins = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare_plugins)


class PluginImportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "OfficialPlugins"
        self.source.mkdir()
        for name, contents in {"native/macos/Test.swift": "initial source\n", "VERSION": "1.1.0\n", "LICENSE": "license",
                               "NOTICE": "notice", "LICENSES/MIT-legacy.txt": "legacy",
                               "THIRD_PARTY_NOTICES.md": "provenance"}.items():
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        self.mapping = {"schemaVersion": 1, "files": [{"source": "native/macos/Test.swift", "destination": "Sources/Test.swift"}]}
        (self.source / "source-map.json").write_text(json.dumps(self.mapping))
        subprocess.run(["git", "init", "-q", str(self.source)], check=True)
        subprocess.run(["git", "-C", str(self.source), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.source), "-c", "user.name=Test Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], check=True)

    def prepare(self, update=False):
        return prepare_plugins.prepare(self.root, self.source, update)

    def test_pin_and_repeat_import(self):
        self.assertEqual(self.prepare(True), 1)
        self.assertEqual(self.prepare(), 1)
        self.assertEqual((self.root / "Sources/Test.swift").read_text(), "initial source\n")

    def test_changed_dependency_requires_reviewed_lock(self):
        self.prepare(True)
        (self.source / "native/macos/Test.swift").write_text("new source\n")
        with self.assertRaisesRegex(ValueError, "differs from"):
            self.prepare()
        with self.assertRaisesRegex(ValueError, "Commit reviewed changes"):
            self.prepare(True)
        subprocess.run(["git", "-C", str(self.source), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.source), "-c", "user.name=Test Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture update"], check=True)
        self.prepare(True)
        self.assertEqual((self.root / "Sources/Test.swift").read_text(), "new source\n")

    def test_local_edits_are_never_overwritten(self):
        self.prepare(True)
        destination = self.root / "Sources/Test.swift"
        destination.write_text("user edit\n")
        with self.assertRaisesRegex(ValueError, "Preserved local edit"):
            self.prepare(True)
        self.assertEqual(destination.read_text(), "user edit\n")

    def test_reject_escaping_destination_before_copy(self):
        self.mapping["files"][0]["destination"] = "Sources/../../outside.swift"
        (self.source / "source-map.json").write_text(json.dumps(self.mapping))
        with self.assertRaises(ValueError):
            self.prepare(True)
        self.assertFalse((self.root / "Sources/Test.swift").exists())

    def test_reject_symlink_in_destination(self):
        outside = self.root / "other"
        outside.mkdir()
        try:
            (self.root / "Sources").symlink_to(outside, target_is_directory=True)
        except OSError as error:
            if getattr(error, "winerror", None) == 1314:
                self.skipTest("directory symlinks require Windows developer mode or elevation")
            raise
        with self.assertRaisesRegex(ValueError, "symlinks"):
            self.prepare(True)
        self.assertFalse((outside / "Test.swift").exists())


if __name__ == "__main__":
    unittest.main()
