#!/usr/bin/env python3
"""Unit tests for the release version and notes rules."""

from __future__ import annotations

import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import release_tool as tool  # noqa: E402

TODAY = [
    "v0.1.0", "v0.3.8", "v0.4.1", "v0.4.2", "v0.4.3",
    "v0.5.0-preview.1", "platform-preview-v0.1.0",
]


def planned(kind: str, names: list[str], arg: str | None = None) -> tool.Plan:
    return tool.plan(kind, names, arg)


class VersionOrderTests(unittest.TestCase):
    def test_preview_sorts_before_its_stable_release(self):
        preview = tool.parse_mac_tag("v0.5.0-preview.9")
        stable = tool.parse_mac_tag("v0.5.0")
        older = tool.parse_mac_tag("v0.4.9")
        self.assertLess(older.key, preview.key)
        self.assertLess(preview.key, stable.key)

    def test_rejects_leading_zeros_and_unknown_suffixes(self):
        for name in ("v01.0.0", "v0.5.0-preview.0", "v0.5.0-rc.1", "0.5.0", "v0.5"):
            self.assertIsNone(tool.parse_mac_tag(name), name)

    def test_reads_ls_remote_lines(self):
        names = tool.tag_names(["abc123\trefs/tags/v0.4.3", "", "v0.5.0-preview.1"])
        self.assertEqual(names, ["v0.4.3", "v0.5.0-preview.1"])


class PreviewPlanTests(unittest.TestCase):
    def test_continues_the_open_line(self):
        result = planned("preview", TODAY)
        self.assertEqual(result.tag, "v0.5.0-preview.2")
        self.assertEqual(result.previous, "v0.5.0-preview.1")
        self.assertEqual(result.warnings, ())

    def test_bump_that_lands_on_the_open_line_continues_it(self):
        self.assertEqual(planned("preview", TODAY, "minor").tag, "v0.5.0-preview.2")

    def test_refuses_a_line_below_the_open_line(self):
        with self.assertRaisesRegex(tool.ReleaseError, "低于进行中的预览线"):
            planned("preview", TODAY, "patch")

    def test_a_higher_line_replaces_the_open_line_with_a_warning(self):
        result = planned("preview", TODAY, "0.6.0")
        self.assertEqual(result.tag, "v0.6.0-preview.1")
        self.assertEqual(result.previous, "v0.5.0-preview.1")
        self.assertEqual(len(result.warnings), 1)

    def test_requires_an_argument_when_no_line_is_open(self):
        names = ["v0.4.3", "v0.5.0-preview.1", "v0.5.0"]
        with self.assertRaisesRegex(tool.ReleaseError, "没有进行中的预览线"):
            planned("preview", names)
        self.assertEqual(planned("preview", names, "patch").tag, "v0.5.1-preview.1")

    def test_refuses_previews_of_a_released_version(self):
        with self.assertRaisesRegex(tool.ReleaseError, "已经正式发布"):
            planned("preview", ["v0.5.0"], "0.5.0")

    def test_first_preview_ever(self):
        result = planned("preview", [], "minor")
        self.assertEqual((result.tag, result.previous), ("v0.1.0-preview.1", None))


class StablePlanTests(unittest.TestCase):
    def test_promotes_the_open_line_with_notes_since_the_last_stable(self):
        result = planned("stable", TODAY + ["v0.5.0-preview.2"])
        self.assertEqual(result.tag, "v0.5.0")
        self.assertEqual(result.previous, "v0.4.3")

    def test_bump_from_the_highest_stable(self):
        self.assertEqual(planned("stable", TODAY, "minor").tag, "v0.5.0")
        result = planned("stable", TODAY, "patch")
        self.assertEqual(result.tag, "v0.4.4")
        self.assertEqual(len(result.warnings), 1)

    def test_refuses_existing_or_lower_versions(self):
        with self.assertRaisesRegex(tool.ReleaseError, "已存在"):
            planned("stable", TODAY, "0.4.3")
        with self.assertRaisesRegex(tool.ReleaseError, "不高于"):
            planned("stable", TODAY, "0.4.0")

    def test_stable_without_an_open_line_needs_a_version(self):
        with self.assertRaisesRegex(tool.ReleaseError, "没有可转正"):
            planned("stable", ["v0.4.3"])


class PlatformPlanTests(unittest.TestCase):
    def test_bumps_and_refuses_regressions(self):
        self.assertEqual(planned("platform", TODAY, "minor").tag, "platform-preview-v0.2.0")
        with self.assertRaisesRegex(tool.ReleaseError, "不高于"):
            planned("platform", TODAY, "0.1.0")
        with self.assertRaises(tool.ReleaseError):
            planned("platform", TODAY)


class RehearsalAndLatestTests(unittest.TestCase):
    def test_rehearsal_uses_the_next_preview(self):
        self.assertEqual(tool.rehearsal_version(TODAY), "0.5.0-preview.2")
        self.assertEqual(tool.rehearsal_version(["v0.5.0-preview.3", "v0.5.0"]), "0.5.1-preview.1")

    def test_latest_release_is_highest_published_macos_version(self):
        releases = [
            {"tagName": "platform-preview-v0.1.0", "isDraft": False},
            {"tagName": "v0.4.3", "isDraft": False},
            {"tagName": "v0.5.0-preview.1", "isDraft": False},
            {"tagName": "v0.5.0-preview.2", "isDraft": True},
        ]
        self.assertEqual(tool.latest_release(releases), "0.5.0-preview.1")
        self.assertEqual(tool.latest_release(releases, exclude="0.5.0-preview.1"), "0.4.3")
        with self.assertRaises(tool.ReleaseError):
            tool.latest_release(releases[:1])


class CommitRulesTests(unittest.TestCase):
    def commit(self, subject: str, body: str = "") -> tool.Commit:
        return tool.Commit("abc1234", subject, body)

    def test_sections(self):
        self.assertEqual(self.commit("feat(chord): add yoyo").section, "feat")
        self.assertEqual(self.commit("fix!: drop legacy path").section, "breaking")
        self.assertEqual(self.commit("refactor: x", "BREAKING CHANGE: y").section, "breaking")
        self.assertEqual(self.commit("ci: pin runner").section, "maintenance")
        self.assertEqual(self.commit("release: enable previews").section, "other")
        self.assertEqual(self.commit("Shrink the thing").section, "other")

    def test_entry_formats_scope(self):
        self.assertEqual(self.commit("feat(chord): add yoyo").entry(), "- **chord:** add yoyo (abc1234)")
        self.assertEqual(self.commit("docs: tidy").entry(), "- tidy (abc1234)")


class GitHistoryTests(unittest.TestCase):
    """Exercise notes, changelog and commit lint against a throwaway repository."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        env = {
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
            "GIT_AUTHOR_DATE": "2026-09-01T00:00:00Z", "GIT_COMMITTER_DATE": "2026-09-01T00:00:00Z",
        }
        self.env = {**os.environ, **env}
        self.run_git("init", "-q", "-b", "main")
        self.commit("chore: initial import")
        self.run_git("tag", "v0.4.3")
        self.commit("feat(chord): add yoyo schemes")
        self.commit("fix: keep the buffer link")
        self.run_git("switch", "-q", "-c", "topic")
        self.commit("docs: describe previews")
        self.run_git("switch", "-q", "main")
        self.run_git("merge", "-q", "--no-ff", "topic", "-m", "Merge #17: 呦呦音形")
        self.run_git("tag", "v0.5.0-preview.1")
        self.commit("Shrink the capsule")
        self.patch = mock.patch.object(tool, "REPO_ROOT", self.root)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()
        self.tmp.cleanup()

    def run_git(self, *args: str) -> str:
        return subprocess.run(
            ["git", *args], cwd=self.root, env=self.env, check=True, capture_output=True, text=True
        ).stdout

    def commit(self, subject: str) -> None:
        self.run_git("commit", "-q", "--allow-empty", "-m", subject)

    def test_notes_group_commits_and_list_merged_prs(self):
        notes = tool.release_notes("v0.5.0-preview.1")
        self.assertIn("自 v0.4.3 以来", notes)
        self.assertIn("- #17 呦呦音形", notes)
        self.assertIn("### 新功能\n\n- **chord:** add yoyo schemes", notes)
        self.assertIn("### 修复\n\n- keep the buffer link", notes)
        self.assertIn("### 文档\n\n- describe previews", notes)
        self.assertNotIn("initial import", notes)
        self.assertIn("compare/v0.4.3...v0.5.0-preview.1", notes)

    def test_notes_for_an_untagged_candidate(self):
        notes = tool.release_notes("v0.5.0-preview.2", ref="HEAD")
        self.assertIn("自 v0.5.0-preview.1 以来", notes)
        self.assertIn("### 其他\n\n- Shrink the capsule", notes)

    def test_changelog_lists_tags_newest_first(self):
        text = tool.render_changelog()
        self.assertLess(text.index("## [v0.5.0-preview.1]"), text.index("## [v0.4.3]"))
        self.assertIn("— 2026-09-01", text)

    def test_changelog_ignores_tags_that_origin_does_not_publish(self):
        text = tool.render_changelog(["v0.5.0-preview.1"])
        self.assertNotIn("## [v0.4.3]", text)
        self.assertIn("- **chord:** add yoyo schemes", text)
        self.assertIn("- initial import", text)
        with self.assertRaisesRegex(tool.ReleaseError, "本地缺少 origin 的 tag"):
            tool.render_changelog(["v0.5.0-preview.1", "v0.6.0-preview.1"])

    def test_lint_commits_flags_non_conventional_subjects(self):
        problems = tool.lint_commits("v0.4.3", "HEAD")
        self.assertEqual(len(problems), 1)
        self.assertIn("Shrink the capsule", problems[0])


class PlistTests(unittest.TestCase):
    def test_placeholder_is_required(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Info.plist"
            path.write_bytes(plistlib.dumps({"CFBundleShortVersionString": tool.DEV_PLACEHOLDER_VERSION}))
            self.assertIsNone(tool.check_plist(path))
            path.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.4.2"}))
            self.assertIn("0.4.2", tool.check_plist(path))


if __name__ == "__main__":
    unittest.main()
