#!/usr/bin/env python3
"""Small cross-platform unit tests for the reusable preview staging boundary."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).with_name("preview.py")
SPEC = importlib.util.spec_from_file_location("rimes_platform_preview", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
preview = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(preview)


class StageTests(unittest.TestCase):
    def fixture_result(self, root: Path) -> dict:
        source = root / "source"
        (source / "nested").mkdir(parents=True)
        (source / "default.yaml").write_text("schema_list: []\n", encoding="utf-8")
        (source / "nested" / "data.txt").write_text("data\n", encoding="utf-8")
        return {
            "dataRoot": source,
            "included": ["default.yaml", "nested/data.txt"],
        }

    def test_stage_copies_only_the_validated_closure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = self.fixture_result(root)
            output = root / "stage"
            with mock.patch.object(preview, "validate_repo", return_value=result):
                preview.stage_preview(root, output)
            staged = {
                path.relative_to(output).as_posix()
                for path in output.rglob("*")
                if path.is_file()
            }
            self.assertEqual(staged, set(result["included"]))
            self.assertFalse((output / preview.MANIFEST_NAME).exists())

    def test_stage_rejects_nonempty_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = self.fixture_result(root)
            output = root / "stage"
            output.mkdir()
            (output / "marker").write_text("do not overwrite\n", encoding="utf-8")
            with mock.patch.object(preview, "validate_repo", return_value=result):
                with self.assertRaises(preview.PreviewError):
                    preview.stage_preview(root, output)

    def test_stage_rejects_symlink_output_when_supported(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            result = self.fixture_result(root)
            target = root / "target"
            target.mkdir()
            output = root / "stage-link"
            try:
                output.symlink_to(target, target_is_directory=True)
            except (OSError, NotImplementedError):
                self.skipTest("directory symlinks are unavailable on this runner")
            with mock.patch.object(preview, "validate_repo", return_value=result):
                with self.assertRaises(preview.PreviewError):
                    preview.stage_preview(root, output)

    def test_portable_path_rejects_parent_escape(self) -> None:
        with self.assertRaises(preview.PreviewError):
            preview.canonical_relative_path("../secret", "test")


class MyComboInvariantTests(unittest.TestCase):
    BASE = """\
engine:
  filters:
    - uniquifier
chord_composer:
  algebra:
    - 'xform/^([qwertyuiopasdfghjklzxcvbnm,.])$/$1/'
speller:
  alphabet: 'qwertyuiopasdfghjklzxcvbnm'
  initials: 'qwertyuiopasdfghjklzxcvbnm'
recognizer:
  patterns:
    punct: '^$'
"""

    def write_schema(self, root: Path, text: str) -> None:
        (root / "my_combo.schema.yaml").write_text(text, encoding="utf-8")

    def test_single_v_invariant_accepts_literal_route(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.write_schema(root, self.BASE)
            preview.validate_my_combo_v(root)

    def test_single_v_invariant_rejects_v_filter(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            text = self.BASE.replace("    - uniquifier", "    - lua_filter@*v_filter")
            self.write_schema(root, text)
            with self.assertRaises(preview.PreviewError):
                preview.validate_my_combo_v(root)


if __name__ == "__main__":
    unittest.main()
