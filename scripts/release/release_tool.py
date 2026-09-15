#!/usr/bin/env python3
"""Version, release-note, and commit-message rules for RIMES releases.

A pushed tag is the only record of a version. Everything here is derived from
tags and commit history, so it can run identically on a laptop, in CI, and in
the release workflow. Only the Python standard library is used.

Subcommands:
  next {preview,stable,platform} [patch|minor|major|X.Y.Z]
      Print TAG=, VERSION=, PREVIOUS= and optional WARNING= lines for the next
      release of that kind. Tags are read from stdin, one per line, either as
      bare names or as `git ls-remote --tags --refs` output.
  rehearsal-version
      Print the version the next preview would get. Non-publishing builds use
      it, so a rehearsal exercises the exact version string of the next release.
  latest-release [--exclude VERSION]
      Read `gh release list --json tagName,isDraft` from stdin and print the
      highest published macOS version.
  notes --tag TAG [--from TAG] [--ref REF]
      Print grouped release notes for TAG from local git history.
  changelog [--write | --check]
      Regenerate CHANGELOG.md from every macOS tag in local git history.
  lint-commits BASE HEAD
      Fail when a non-merge commit in BASE..HEAD is not a Conventional Commit.
  check-plist [PATH]
      Fail unless Info.plist carries the development placeholder version.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO = "scholay/rimes"
REPO_ROOT = Path(__file__).resolve().parents[2]
CHANGELOG = REPO_ROOT / "CHANGELOG.md"
DEV_PLACEHOLDER_VERSION = "0.0.0-dev"

_NUM = r"(0|[1-9][0-9]*)"
MAC_TAG = re.compile(rf"^v{_NUM}\.{_NUM}\.{_NUM}(?:-preview\.([1-9][0-9]*))?$")
PLATFORM_TAG = re.compile(rf"^platform-preview-v{_NUM}\.{_NUM}\.{_NUM}$")
CORE = re.compile(rf"^{_NUM}\.{_NUM}\.{_NUM}$")
BUMPS = ("patch", "minor", "major")

CONVENTIONAL = re.compile(
    r"^(?P<type>[a-z]+)(?:\((?P<scope>[^()\r\n]+)\))?(?P<bang>!)?: (?P<desc>\S.*)$"
)
ALLOWED_TYPES = (
    "feat", "fix", "perf", "refactor", "docs", "test",
    "build", "ci", "chore", "style", "revert",
)
SECTIONS = (
    ("breaking", "不兼容变更"),
    ("feat", "新功能"),
    ("fix", "修复"),
    ("perf", "性能"),
    ("refactor", "重构"),
    ("docs", "文档"),
    ("maintenance", "维护"),
    ("other", "其他"),
)
MAINTENANCE_TYPES = {"test", "build", "ci", "chore", "style", "revert"}
MERGE_SUBJECT = re.compile(r"^Merge (?:pull request )?#(?P<number>\d+)(?::\s*(?P<title>.+))?")


class ReleaseError(Exception):
    """A release rule refused the request; the message is shown to the user."""


Core = tuple[int, int, int]


@dataclass(frozen=True)
class MacVersion:
    core: Core
    preview: int | None = None

    @property
    def key(self) -> tuple[Core, int, int]:
        # A preview sorts before the stable release of the same core.
        return (self.core, 0 if self.preview is not None else 1, self.preview or 0)

    @property
    def tag(self) -> str:
        return f"v{self}"

    def __str__(self) -> str:
        base = ".".join(str(part) for part in self.core)
        return base if self.preview is None else f"{base}-preview.{self.preview}"


def parse_mac_tag(name: str) -> MacVersion | None:
    match = MAC_TAG.match(name)
    if not match:
        return None
    major, minor, patch, preview = match.groups()
    return MacVersion(
        (int(major), int(minor), int(patch)),
        int(preview) if preview else None,
    )


def parse_platform_tag(name: str) -> Core | None:
    match = PLATFORM_TAG.match(name)
    return tuple(int(part) for part in match.groups()) if match else None  # type: ignore[return-value]


def parse_core(value: str) -> Core:
    match = CORE.match(value)
    if not match:
        raise ReleaseError(f"版本号格式应为 X.Y.Z（不允许前导零）：{value}")
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def format_core(core: Core) -> str:
    return ".".join(str(part) for part in core)


def bump(core: Core, kind: str) -> Core:
    major, minor, patch = core
    if kind == "major":
        return (major + 1, 0, 0)
    if kind == "minor":
        return (major, minor + 1, 0)
    if kind == "patch":
        return (major, minor, patch + 1)
    raise ReleaseError(f"未知的版本升级类型：{kind}")


def tag_names(lines: list[str]) -> list[str]:
    """Accept bare tag names or `git ls-remote --tags --refs` lines."""
    names = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        ref = line.split()[-1]
        names.append(ref.removeprefix("refs/tags/"))
    return names


@dataclass(frozen=True)
class Plan:
    tag: str
    version: str
    previous: str | None
    warnings: tuple[str, ...] = ()

    def lines(self) -> list[str]:
        out = [f"TAG={self.tag}", f"VERSION={self.version}", f"PREVIOUS={self.previous or ''}"]
        out.extend(f"WARNING={warning}" for warning in self.warnings)
        return out


class TagSet:
    def __init__(self, names: list[str]):
        self.mac = sorted(
            (version for version in map(parse_mac_tag, names) if version),
            key=lambda version: version.key,
        )
        self.platform = sorted(core for core in map(parse_platform_tag, names) if core)

    @property
    def highest_stable(self) -> Core:
        stables = [version.core for version in self.mac if version.preview is None]
        return max(stables, default=(0, 0, 0))

    def is_released(self, core: Core) -> bool:
        return any(version.core == core and version.preview is None for version in self.mac)

    @property
    def open_line(self) -> Core | None:
        """The highest preview line that has not been promoted to stable."""
        lines = {
            version.core
            for version in self.mac
            if version.preview is not None
            and version.core > self.highest_stable
            and not self.is_released(version.core)
        }
        return max(lines, default=None)

    def next_preview_number(self, core: Core) -> int:
        numbers = [v.preview for v in self.mac if v.core == core and v.preview is not None]
        return max(numbers, default=0) + 1

    def previous_for(self, candidate: MacVersion) -> str | None:
        """Previews list changes since the last tag; stable releases since the last stable."""
        earlier = [
            version for version in self.mac
            if version.key < candidate.key
            and (candidate.preview is not None or version.preview is None)
        ]
        return earlier[-1].tag if earlier else None

    def exists(self, version: MacVersion) -> bool:
        return any(existing == version for existing in self.mac)


def plan_preview(tags: TagSet, arg: str | None) -> Plan:
    warnings: list[str] = []
    line = tags.open_line
    if arg is None:
        if line is None:
            raise ReleaseError(
                "没有进行中的预览线。请用 `preview patch|minor|major` 或 `preview X.Y.Z` 开始一条新预览线。"
            )
        core = line
    else:
        core = bump(tags.highest_stable, arg) if arg in BUMPS else parse_core(arg)
        if tags.is_released(core):
            raise ReleaseError(f"v{format_core(core)} 已经正式发布，不能再发布它的预览版。")
        if core <= tags.highest_stable:
            raise ReleaseError(
                f"预览线 {format_core(core)} 不高于最新正式版 v{format_core(tags.highest_stable)}。"
            )
        if line is not None and core < line:
            raise ReleaseError(
                f"预览线 {format_core(core)} 低于进行中的预览线 {format_core(line)}；禁止版本回退。"
            )
        if line is not None and core > line:
            warnings.append(f"进行中的预览线 {format_core(line)} 将被新预览线 {format_core(core)} 取代。")
    candidate = MacVersion(core, tags.next_preview_number(core))
    return Plan(candidate.tag, str(candidate), tags.previous_for(candidate), tuple(warnings))


def plan_stable(tags: TagSet, arg: str | None) -> Plan:
    warnings: list[str] = []
    line = tags.open_line
    if arg is None:
        if line is None:
            raise ReleaseError("没有可转正的预览线。请用 `patch|minor|major|X.Y.Z` 直接指定正式版本。")
        core = line
    else:
        core = bump(tags.highest_stable, arg) if arg in BUMPS else parse_core(arg)
        if line is not None and core != line:
            warnings.append(f"进行中的预览线 {format_core(line)} 不会随本次正式版发布。")
    candidate = MacVersion(core)
    if tags.exists(candidate):
        raise ReleaseError(f"{candidate.tag} 已存在；发布脚本绝不会覆盖已发布版本。")
    if core <= tags.highest_stable:
        raise ReleaseError(
            f"{candidate.tag} 不高于最新正式版 v{format_core(tags.highest_stable)}；禁止版本回退。"
        )
    return Plan(candidate.tag, str(candidate), tags.previous_for(candidate), tuple(warnings))


def plan_platform(tags: TagSet, arg: str | None) -> Plan:
    if arg is None:
        raise ReleaseError("跨平台预览需要 `platform patch|minor|major` 或 `platform X.Y.Z`。")
    latest = tags.platform[-1] if tags.platform else None
    core = bump(latest or (0, 0, 0), arg) if arg in BUMPS else parse_core(arg)
    if latest is not None and core <= latest:
        raise ReleaseError(
            f"platform-preview-v{format_core(core)} 不高于最新跨平台预览 "
            f"platform-preview-v{format_core(latest)}；禁止覆盖或回退。"
        )
    previous = f"platform-preview-v{format_core(latest)}" if latest else None
    return Plan(f"platform-preview-v{format_core(core)}", format_core(core), previous)


def plan(kind: str, names: list[str], arg: str | None) -> Plan:
    tags = TagSet(names)
    if kind == "preview":
        return plan_preview(tags, arg)
    if kind == "stable":
        return plan_stable(tags, arg)
    if kind == "platform":
        return plan_platform(tags, arg)
    raise ReleaseError(f"未知的发布类型：{kind}")


def rehearsal_version(names: list[str]) -> str:
    tags = TagSet(names)
    try:
        return plan_preview(tags, None).version
    except ReleaseError:
        return plan_preview(tags, "patch").version


def latest_release(releases: list[dict], exclude: str | None = None) -> str:
    versions = [
        version
        for release in releases
        if not release.get("isDraft")
        for version in [parse_mac_tag(str(release.get("tagName", "")))]
        if version and str(version) != exclude
    ]
    if not versions:
        raise ReleaseError("没有已发布的 macOS Release。")
    return str(max(versions, key=lambda version: version.key))


# ---------------------------------------------------------------------------
# Git history

def git(*args: str) -> str:
    result = subprocess.run(
        ["git", *args], cwd=REPO_ROOT, check=True, capture_output=True, text=True
    )
    return result.stdout


@dataclass(frozen=True)
class Commit:
    sha: str
    subject: str
    body: str

    @property
    def parsed(self) -> re.Match[str] | None:
        return CONVENTIONAL.match(self.subject)

    @property
    def section(self) -> str:
        match = self.parsed
        if match is None:
            return "other"
        if match["bang"] or "BREAKING CHANGE:" in self.body:
            return "breaking"
        kind = match["type"]
        if kind in ("feat", "fix", "perf", "refactor", "docs"):
            return kind
        if kind in MAINTENANCE_TYPES:
            return "maintenance"
        return "other"

    def entry(self) -> str:
        match = self.parsed
        if match is None:
            return f"- {self.subject} ({self.sha})"
        scope = f"**{match['scope']}:** " if match["scope"] else ""
        return f"- {scope}{match['desc']} ({self.sha})"


def commits_between(start: str | None, end: str) -> list[Commit]:
    revision = f"{start}..{end}" if start else end
    raw = git("log", "--no-merges", "--format=%h%x1f%s%x1f%b%x1e", revision)
    commits = []
    for record in raw.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        sha, subject, body = (record.split("\x1f") + ["", ""])[:3]
        commits.append(Commit(sha.strip(), subject.strip(), body))
    return commits


def merged_pull_requests(start: str | None, end: str) -> list[str]:
    revision = f"{start}..{end}" if start else end
    entries = []
    for subject in git("log", "--merges", "--first-parent", "--format=%s", revision).splitlines():
        match = MERGE_SUBJECT.match(subject)
        if match:
            title = match["title"] or ""
            entries.append(f"- #{match['number']} {title}".rstrip())
    return entries


def render_changes(start: str | None, end: str, heading_level: int = 3) -> str:
    commits = commits_between(start, end)
    hashes = "#" * heading_level
    blocks = []
    pulls = merged_pull_requests(start, end)
    if pulls:
        blocks.append(f"{hashes} 合并的 PR\n\n" + "\n".join(pulls))
    for key, title in SECTIONS:
        entries = [commit.entry() for commit in commits if commit.section == key]
        if entries:
            blocks.append(f"{hashes} {title}\n\n" + "\n".join(entries))
    if not blocks:
        blocks.append("没有新的提交。")
    return "\n\n".join(blocks)


def local_mac_tags() -> list[MacVersion]:
    versions = [parse_mac_tag(name) for name in git("tag", "--list", "v*").split()]
    return sorted((version for version in versions if version), key=lambda version: version.key)


def release_notes(tag: str, start: str | None = None, ref: str | None = None) -> str:
    candidate = parse_mac_tag(tag)
    if candidate is None:
        raise ReleaseError(f"不是 macOS 发布 tag：{tag}")
    if start is None:
        names = [version.tag for version in local_mac_tags() if version != candidate]
        start = TagSet(names).previous_for(candidate)
    end = ref or tag
    compare = (
        f"https://github.com/{REPO}/compare/{start}...{tag}" if start
        else f"https://github.com/{REPO}/commits/{tag}"
    )
    since = f"自 {start} 以来" if start else "首个版本"
    return f"## 变更（{since}）\n\n{render_changes(start, end)}\n\n**完整对比**：{compare}\n"


def render_changelog() -> str:
    tags = local_mac_tags()
    sections = []
    for index, version in enumerate(tags):
        previous = tags[index - 1].tag if index else None
        date = git("log", "-1", "--format=%cs", version.tag).strip()
        sections.append(
            f"## [{version.tag}](https://github.com/{REPO}/releases/tag/{version.tag}) — {date}\n\n"
            + render_changes(previous, version.tag, heading_level=3)
        )
    header = (
        "# 更新日志\n\n"
        "本文件由 `python3 scripts/release/release_tool.py changelog --write` 根据发布 tag 与\n"
        "[Conventional Commits](https://www.conventionalcommits.org/zh-hans/v1.0.0/) 生成，请勿手工编辑。\n"
        "每个版本的安装方式与校验和见 [GitHub Releases](https://github.com/scholay/rimes/releases)。\n"
    )
    return header + "\n" + "\n\n".join(reversed(sections)) + "\n"


def lint_commits(base: str, head: str) -> list[str]:
    problems = []
    for commit in commits_between(base, head):
        if commit.subject.startswith('Revert "'):
            continue
        match = commit.parsed
        if match is None:
            problems.append(f"{commit.sha} {commit.subject}")
        elif match["type"] not in ALLOWED_TYPES:
            problems.append(f"{commit.sha} {commit.subject}（未知类型 {match['type']}）")
    return problems


def check_plist(path: Path) -> str | None:
    with path.open("rb") as handle:
        version = plistlib.load(handle).get("CFBundleShortVersionString")
    if version != DEV_PLACEHOLDER_VERSION:
        return (
            f"{path.name} 的 CFBundleShortVersionString 必须保持为 {DEV_PLACEHOLDER_VERSION}，"
            f"实际为 {version!r}。版本号只来自发布 tag，由 CI 在构建时写入。"
        )
    return None


# ---------------------------------------------------------------------------
# CLI

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    next_parser = commands.add_parser("next")
    next_parser.add_argument("kind", choices=("preview", "stable", "platform"))
    next_parser.add_argument("arg", nargs="?")

    commands.add_parser("rehearsal-version")

    latest_parser = commands.add_parser("latest-release")
    latest_parser.add_argument("--exclude")

    notes_parser = commands.add_parser("notes")
    notes_parser.add_argument("--tag", required=True)
    notes_parser.add_argument("--from", dest="start")
    notes_parser.add_argument("--ref")

    changelog_parser = commands.add_parser("changelog")
    mode = changelog_parser.add_mutually_exclusive_group()
    mode.add_argument("--write", action="store_true")
    mode.add_argument("--check", action="store_true")

    lint_parser = commands.add_parser("lint-commits")
    lint_parser.add_argument("base")
    lint_parser.add_argument("head")

    plist_parser = commands.add_parser("check-plist")
    plist_parser.add_argument("path", nargs="?", default=str(REPO_ROOT / "Info.plist"))

    args = parser.parse_args(argv)
    try:
        if args.command == "next":
            print("\n".join(plan(args.kind, tag_names(sys.stdin.read().splitlines()), args.arg).lines()))
        elif args.command == "rehearsal-version":
            print(rehearsal_version(tag_names(sys.stdin.read().splitlines())))
        elif args.command == "latest-release":
            print(latest_release(json.load(sys.stdin), args.exclude))
        elif args.command == "notes":
            sys.stdout.write(release_notes(args.tag, args.start, args.ref))
        elif args.command == "changelog":
            text = render_changelog()
            if args.check:
                current = CHANGELOG.read_text(encoding="utf-8") if CHANGELOG.exists() else ""
                if current != text:
                    print(
                        "CHANGELOG.md 未包含最新发布；运行 "
                        "`python3 scripts/release/release_tool.py changelog --write` 后随下一个 PR 提交。",
                        file=sys.stderr,
                    )
                    return 1
            elif args.write:
                CHANGELOG.write_text(text, encoding="utf-8")
            else:
                sys.stdout.write(text)
        elif args.command == "lint-commits":
            problems = lint_commits(args.base, args.head)
            if problems:
                print(
                    "以下提交不符合 Conventional Commits（type(scope): 描述，type 取 "
                    + ", ".join(ALLOWED_TYPES) + "）：",
                    file=sys.stderr,
                )
                print("\n".join(f"  {problem}" for problem in problems), file=sys.stderr)
                return 1
        elif args.command == "check-plist":
            problem = check_plist(Path(args.path))
            if problem:
                print(problem, file=sys.stderr)
                return 1
    except ReleaseError as error:
        print(error, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
