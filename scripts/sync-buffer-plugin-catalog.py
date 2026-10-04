#!/usr/bin/env python3
"""Generate and verify the preset Buffer plug-in distribution catalog.

Migrated plugins take their content from the pinned OfficialPlugins dependency.
`Catalog/buffer-plugins.json` remains the host's distribution projection. This script derives the
optional download manifests, their immutable GitHub Release asset names and
SHA-256 pins, the Swift runtime data, and the tables in both README files.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
CATALOG_PATH = ROOT / "Catalog" / "buffer-plugins.json"
PLUGIN_MANIFEST_ROOT = ROOT / "Catalog" / "Plugins"
GENERATED_SWIFT_PATH = (
    ROOT / "Sources" / "RimeBuffer" / "PresetBufferPluginCatalog.generated.swift"
)

README_START = "<!-- BEGIN PRESET BUFFER PLUGINS -->"
README_END = "<!-- END PRESET BUFFER PLUGINS -->"
RELEASE_ASSET_PREFIX = "preset-plugin-"

PINNED_PACKAGES = [json.loads(p.read_bytes()) for p in sorted((ROOT / "OfficialPlugins/plugins").glob("*/plugin.json"))]
MACOS_PACKAGES = [p for p in PINNED_PACKAGES if "macos" in p["platforms"]]
EXPECTED_IDS = [p["id"] for p in MACOS_PACKAGES]
OPTIONAL_IDS = {p["id"] for p in MACOS_PACKAGES if p["platforms"]["macos"]["distribution"] == "download"}
DEFAULT_INSTALLED_IDS = set(EXPECTED_IDS) - OPTIONAL_IDS
DEFAULT_ENABLED_IDS = DEFAULT_INSTALLED_IDS - {"builtin.fly-chord-learning"}

ENTRY_KEYS = {
    "id",
    "nameZH",
    "nameEN",
    "version",
    "summaryZH",
    "summaryEN",
    "producerID",
    "defaultInstalled",
    "defaultEnabled",
    "downloadAssetName",
    "sha256",
}
MANIFEST_KEYS = [
    "schemaVersion",
    "id",
    "version",
    "nameZH",
    "nameEN",
    "summaryZH",
    "summaryEN",
]
IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
VERSION_PATTERN = re.compile(r"^[0-9]+(?:\.[0-9]+){1,2}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class CatalogError(RuntimeError):
    pass


def canonical_json_bytes(value: Any) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def read_catalog() -> dict[str, Any]:
    try:
        raw = CATALOG_PATH.read_bytes()
        catalog = json.loads(raw)
    except (OSError, json.JSONDecodeError) as error:
        raise CatalogError(f"cannot read {CATALOG_PATH.relative_to(ROOT)}: {error}")
    if not isinstance(catalog, dict):
        raise CatalogError("catalog root must be an object")
    if set(catalog) != {"schemaVersion", "plugins"}:
        raise CatalogError("catalog root keys must be exactly schemaVersion and plugins")
    if catalog["schemaVersion"] != 2:
        raise CatalogError("unsupported catalog schemaVersion")
    if not isinstance(catalog["plugins"], list):
        raise CatalogError("catalog plugins must be an array")
    return catalog


def require_nonempty_string(entry: dict[str, Any], key: str) -> str:
    value = entry.get(key)
    if not isinstance(value, str) or not value.strip():
        raise CatalogError(f"{entry.get('id', '<unknown>')}: {key} must be nonempty")
    if "\x00" in value:
        raise CatalogError(f"{entry.get('id', '<unknown>')}: {key} contains NUL")
    return value


def validate_catalog(catalog: dict[str, Any]) -> list[dict[str, Any]]:
    entries = catalog["plugins"]
    ids: list[str] = []
    for index, value in enumerate(entries):
        if not isinstance(value, dict):
            raise CatalogError(f"plugins[{index}] must be an object")
        if set(value) != ENTRY_KEYS:
            missing = sorted(ENTRY_KEYS - set(value))
            extra = sorted(set(value) - ENTRY_KEYS)
            raise CatalogError(
                f"plugins[{index}] keys drifted (missing={missing}, extra={extra})"
            )

        plugin_id = require_nonempty_string(value, "id")
        if not IDENTIFIER_PATTERN.fullmatch(plugin_id):
            raise CatalogError(f"invalid plug-in id: {plugin_id}")
        ids.append(plugin_id)
        for key in ("nameZH", "nameEN", "summaryZH", "summaryEN"):
            require_nonempty_string(value, key)
        producer_id = require_nonempty_string(value, "producerID")
        expected_producer = {
            "builtin.codex-cli": "openai",
            "builtin.claude-code-cli": "anthropic",
            "builtin.scholay": "scholay",
            "builtin.polisher": "scholay",
            "builtin.latex": "scholay",
        }.get(plugin_id, "official")
        if producer_id != expected_producer:
            raise CatalogError(f"{plugin_id}: unexpected producerID")
        version = require_nonempty_string(value, "version")
        if not VERSION_PATTERN.fullmatch(version):
            raise CatalogError(f"{plugin_id}: version must be numeric dotted notation")
        if not isinstance(value["defaultInstalled"], bool):
            raise CatalogError(f"{plugin_id}: defaultInstalled must be a boolean")
        if not isinstance(value["defaultEnabled"], bool):
            raise CatalogError(f"{plugin_id}: defaultEnabled must be a boolean")
        if value["defaultEnabled"] and not value["defaultInstalled"]:
            raise CatalogError(f"{plugin_id}: an uninstalled plug-in cannot be enabled")

        expected_asset_name = (
            f"{RELEASE_ASSET_PREFIX}{plugin_id}-{version}.json"
        )
        if value["downloadAssetName"] != expected_asset_name:
            raise CatalogError(f"{plugin_id}: invalid asset name")
        digest = value["sha256"]
        if not isinstance(digest, str) or not SHA256_PATTERN.fullmatch(digest):
            raise CatalogError(f"{plugin_id}: sha256 must be 64 lowercase hex digits")

    if ids != EXPECTED_IDS:
        raise CatalogError(
            "preset plug-in order/set drifted: " + ", ".join(ids)
        )
    if len(set(ids)) != len(ids):
        raise CatalogError("duplicate plug-in id")
    installed = {entry["id"] for entry in entries if entry["defaultInstalled"]}
    enabled = {entry["id"] for entry in entries if entry["defaultEnabled"]}
    optional = {entry["id"] for entry in entries if not entry["defaultInstalled"]}
    if installed != DEFAULT_INSTALLED_IDS:
        raise CatalogError(f"default-installed set drifted: {sorted(installed)}")
    if enabled != DEFAULT_ENABLED_IDS:
        raise CatalogError(f"default-enabled set drifted: {sorted(enabled)}")
    if optional != OPTIONAL_IDS:
        raise CatalogError(f"optional set drifted: {sorted(optional)}")
    return entries


def manifest_value(entry: dict[str, Any]) -> dict[str, Any]:
    resource = ROOT / "Sources/RimeBuffer/Resources/OfficialPlugins" / f"{entry['id']}.json"
    if resource.is_file():
        package = json.loads(resource.read_bytes())
        if any(package[key] != entry[key] for key in MANIFEST_KEYS if key != "schemaVersion"):
            raise CatalogError(f"{entry['id']}: host catalog differs from the pinned plugin package")
        return package
    return {
        "schemaVersion": 1,
        "id": entry["id"],
        "version": entry["version"],
        "nameZH": entry["nameZH"],
        "nameEN": entry["nameEN"],
        "summaryZH": entry["summaryZH"],
        "summaryEN": entry["summaryEN"],
    }


def sync_optional_manifests(
    entries: list[dict[str, Any]], *, check: bool
) -> None:
    expected_directories = set()
    for entry in entries:
        plugin_id = entry["id"]
        expected_directories.add(plugin_id)
        path = PLUGIN_MANIFEST_ROOT / plugin_id / "manifest.json"
        expected = canonical_json_bytes(manifest_value(entry))
        digest = hashlib.sha256(expected).hexdigest()
        if check:
            try:
                actual = path.read_bytes()
            except OSError as error:
                raise CatalogError(
                    f"cannot read {path.relative_to(ROOT)}: {error}"
                )
            if actual != expected:
                raise CatalogError(
                    f"{path.relative_to(ROOT)} is stale; run this script without --check"
                )
            if entry["sha256"] != digest:
                raise CatalogError(
                    f"{plugin_id}: catalog sha256 does not match manifest bytes"
                )
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            if not path.exists() or path.read_bytes() != expected:
                path.write_bytes(expected)
            entry["sha256"] = digest

    if PLUGIN_MANIFEST_ROOT.exists():
        actual_directories = {
            path.name
            for path in PLUGIN_MANIFEST_ROOT.iterdir()
            if path.is_dir() and not path.is_symlink()
        }
        unexpected = sorted(actual_directories - expected_directories)
        if unexpected:
            raise CatalogError(
                "unexpected optional manifest directories: " + ", ".join(unexpected)
            )


def swift_string(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\r", "\\r")
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )
    return f'"{escaped}"'


def swift_optional_string(value: str | None) -> str:
    return "nil" if value is None else swift_string(value)


def render_swift(entries: list[dict[str, Any]]) -> str:
    lines = [
        "// Generated by scripts/sync-buffer-plugin-catalog.py from",
        "// Catalog/buffer-plugins.json. Do not edit this file directly.",
        "",
        "enum PresetBufferPluginCatalog {",
        f"    static let releaseVersion = {swift_string((ROOT / 'OfficialPlugins/VERSION').read_text().strip())}",
        "    static let entries: [PresetBufferPluginCatalogEntry] = [",
    ]
    for entry in entries:
        lines.extend(
            [
                "        PresetBufferPluginCatalogEntry(",
                f"            id: {swift_string(entry['id'])},",
                f"            nameZH: {swift_string(entry['nameZH'])},",
                f"            nameEN: {swift_string(entry['nameEN'])},",
                f"            version: {swift_string(entry['version'])},",
                f"            summaryZH: {swift_string(entry['summaryZH'])},",
                f"            summaryEN: {swift_string(entry['summaryEN'])},",
                f"            producerID: {swift_string(entry['producerID'])},",
                "            defaultInstalled: "
                + str(entry["defaultInstalled"]).lower()
                + ",",
                "            defaultEnabled: "
                + str(entry["defaultEnabled"]).lower()
                + ",",
                "            downloadAssetName: "
                + swift_optional_string(entry["downloadAssetName"])
                + ",",
                "            sha256: "
                + swift_optional_string(entry["sha256"]),
                "        ),",
            ]
        )
    lines.extend(
        [
            "    ]",
            "",
            "    static func entry(id: String) -> PresetBufferPluginCatalogEntry? {",
            "        entries.first { $0.id == id }",
            "    }",
            "}",
            "",
        ]
    )
    return "\n".join(lines)


def markdown_cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")


def render_readme_section(entries: list[dict[str, Any]], language: str) -> str:
    if language == "zh":
        lines = [
            README_START,
            "## macOS 官方插件",
            "",
            "下表由 [`Catalog/buffer-plugins.json`](Catalog/buffer-plugins.json) 自动生成。更新插件时必须同步更新其版本，并运行 `python3 scripts/sync-buffer-plugin-catalog.py --check`。",
            "",
            "| 插件 | ID | 版本 | 默认安装 | 默认状态 |",
            "|---|---|---:|---|---|",
        ]
        for entry in entries:
            installation = (
                "随 RIMES 预装"
                if entry["defaultInstalled"]
                else "设置中按需下载"
            )
            state = "启用" if entry["defaultEnabled"] else "禁用"
            lines.append(
                f"| {markdown_cell(entry['nameZH'])} | `{entry['id']}` | "
                f"{entry['version']} | {installation} | {state} |"
            )
        lines.extend(
            [
                "",
                "预装插件在全新安装后按默认状态启用；选装插件下载后需手动启用。升级时保留已有插件状态。",
                README_END,
            ]
        )
        return "\n".join(lines)

    lines = [
        README_START,
        "## Official macOS plug-ins",
        "",
        "This table is generated from [`Catalog/buffer-plugins.json`](Catalog/buffer-plugins.json). Every plug-in update must also update its catalog version and pass `python3 scripts/sync-buffer-plugin-catalog.py --check`.",
        "",
        "| Plug-in | ID | Version | Default installation | Default state |",
        "|---|---|---:|---|---|",
    ]
    for entry in entries:
        installation = (
            "Bundled with RIMES"
            if entry["defaultInstalled"]
            else "On demand in Settings"
        )
        state = "Enabled" if entry["defaultEnabled"] else "Disabled"
        lines.append(
            f"| {markdown_cell(entry['nameEN'])} | `{entry['id']}` | "
            f"{entry['version']} | {installation} | {state} |"
        )
    lines.extend(
        [
            "",
            "Bundled plug-ins use the defaults above. Optional plug-ins require installation and explicit enablement. Upgrades preserve existing plugin state.",
            README_END,
        ]
    )
    return "\n".join(lines)


def replace_readme_section(path: Path, expected: str, *, check: bool) -> None:
    try:
        current = path.read_text(encoding="utf-8")
    except OSError as error:
        raise CatalogError(f"cannot read {path.relative_to(ROOT)}: {error}")
    start = current.find(README_START)
    end = current.find(README_END)
    if start < 0 or end < start:
        raise CatalogError(
            f"{path.relative_to(ROOT)} is missing preset plug-in markers"
        )
    end += len(README_END)
    actual = current[start:end]
    if check:
        if actual != expected:
            raise CatalogError(
                f"{path.relative_to(ROOT)} plug-in table is stale; "
                "run this script without --check"
            )
        return
    updated = current[:start] + expected + current[end:]
    if updated != current:
        path.write_text(updated, encoding="utf-8")


def check_or_write(path: Path, expected: bytes, *, check: bool) -> None:
    if check:
        try:
            actual = path.read_bytes()
        except OSError as error:
            raise CatalogError(f"cannot read {path.relative_to(ROOT)}: {error}")
        if actual != expected:
            raise CatalogError(
                f"{path.relative_to(ROOT)} is stale; run this script without --check"
            )
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_bytes() != expected:
        path.write_bytes(expected)


def sync_release_assets(
    entries: list[dict[str, Any]], output_dir: Path, *, check: bool
) -> None:
    if output_dir.is_symlink():
        raise CatalogError(f"release asset directory is a symlink: {output_dir}")
    expected: dict[str, bytes] = {}
    for entry in entries:
        asset_name = entry["downloadAssetName"]
        if asset_name is None:
            continue
        source = PLUGIN_MANIFEST_ROOT / entry["id"] / "manifest.json"
        try:
            expected[asset_name] = source.read_bytes()
        except OSError as error:
            raise CatalogError(
                f"cannot read {source.relative_to(ROOT)}: {error}"
            )

    if check:
        try:
            actual_names = {
                path.name
                for path in output_dir.iterdir()
                if path.is_file() and not path.is_symlink()
            }
        except OSError as error:
            raise CatalogError(f"cannot read release asset directory: {error}")
        if actual_names != set(expected):
            raise CatalogError(
                "release asset set drifted "
                f"(expected={sorted(expected)}, actual={sorted(actual_names)})"
            )
        for name, data in expected.items():
            path = output_dir / name
            if path.is_symlink() or path.read_bytes() != data:
                raise CatalogError(f"release asset is stale or unsafe: {path}")
        return

    output_dir.mkdir(parents=True, exist_ok=True)
    for name, data in expected.items():
        path = output_dir / name
        if path.is_symlink():
            raise CatalogError(f"release asset path is a symlink: {path}")
        if not path.exists() or path.read_bytes() != data:
            path.write_bytes(data)


def run(*, check: bool) -> None:
    catalog = read_catalog()
    projected = []
    for package in MACOS_PACKAGES:
        entry = {key: package[key] for key in MANIFEST_KEYS if key != "schemaVersion"}
        entry["producerID"] = {"builtin.codex-cli": "openai", "builtin.claude-code-cli": "anthropic",
                               "builtin.scholay": "scholay", "builtin.polisher": "scholay", "builtin.latex": "scholay"}.get(package["id"], "official")
        entry["defaultInstalled"] = package["id"] in DEFAULT_INSTALLED_IDS
        entry["defaultEnabled"] = package["id"] in DEFAULT_ENABLED_IDS
        entry["downloadAssetName"] = f"{RELEASE_ASSET_PREFIX}{package['id']}-{package['version']}.json"
        entry["sha256"] = hashlib.sha256(canonical_json_bytes(manifest_value(entry))).hexdigest()
        projected.append(entry)
    catalog["plugins"] = projected
    if check and read_catalog()["plugins"] != projected:
        raise CatalogError("host catalog projection differs from pinned official packages")
    entries = validate_catalog(catalog)
    sync_optional_manifests(entries, check=check)

    canonical_catalog = canonical_json_bytes(catalog)
    check_or_write(CATALOG_PATH, canonical_catalog, check=check)
    check_or_write(
        GENERATED_SWIFT_PATH,
        render_swift(entries).encode("utf-8"),
        check=check,
    )
    replace_readme_section(
        ROOT / "README.md",
        render_readme_section(entries, "zh"),
        check=check,
    )
    replace_readme_section(
        ROOT / "README.en.md",
        render_readme_section(entries, "en"),
        check=check,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify generated artifacts without changing files",
    )
    release_group = parser.add_mutually_exclusive_group()
    release_group.add_argument(
        "--stage-release-assets",
        type=Path,
        metavar="DIR",
        help="verify the catalog, then stage immutable optional manifests in DIR",
    )
    release_group.add_argument(
        "--check-release-assets",
        type=Path,
        metavar="DIR",
        help="verify the catalog and the exact immutable manifests already in DIR",
    )
    args = parser.parse_args()
    try:
        release_assets = args.stage_release_assets or args.check_release_assets
        if release_assets is not None:
            if args.check:
                raise CatalogError(
                    "--check cannot be combined with a release asset operation"
                )
            run(check=True)
            catalog = read_catalog()
            entries = validate_catalog(catalog)
            sync_release_assets(
                entries,
                release_assets,
                check=args.check_release_assets is not None,
            )
        else:
            run(check=args.check)
    except CatalogError as error:
        print(f"buffer plug-in catalog: {error}", file=sys.stderr)
        return 1
    if args.stage_release_assets is not None:
        action = "release assets staged"
    elif args.check_release_assets is not None:
        action = "release assets verified"
    else:
        action = "verified" if args.check else "synchronized"
    print(f"buffer plug-in catalog {action}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
