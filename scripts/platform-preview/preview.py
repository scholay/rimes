#!/usr/bin/env python3
"""Validate and package RIMES's platform-neutral Rime preview data.

This tool intentionally packages data only.  It does not build or claim to
provide a native input-method application on any operating system.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
import zipfile


EXPECTED_SCHEMAS = ("my_combo", "double_pinyin", "rime_ice", "english")
MANIFEST_NAME = "MANIFEST.json"
NOTICE_NAME = "PREVIEW-NOTICE.txt"
MAX_FILE_BYTES = 128 * 1024 * 1024
MAX_TOTAL_BYTES = 256 * 1024 * 1024
ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)

SECRET_PATTERNS = (
    ("private key", re.compile(rb"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----")),
    ("AWS access key", re.compile(rb"\bAKIA[0-9A-Z]{16}\b")),
    ("GitHub token", re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{20,}\b")),
    ("API-style secret", re.compile(rb"\bsk-[A-Za-z0-9_-]{20,}\b")),
    (
        "assigned credential",
        re.compile(
            rb"(?i)(api[_-]?key|access[_-]?token|client[_-]?secret|password)"
            rb"\s*[\"']?\s*[:=]\s*[\"'][^\"'\r\n]{4,}[\"']"
        ),
    ),
)


class PreviewError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise PreviewError(message)


def canonical_relative_path(raw: object, context: str) -> str:
    if not isinstance(raw, str) or not raw:
        fail(f"{context}: expected a non-empty path string")
    if "\\" in raw or "\x00" in raw:
        fail(f"{context}: path must use safe forward slashes: {raw!r}")
    path = PurePosixPath(raw)
    if path.is_absolute() or any(part in ("", ".", "..") for part in path.parts):
        fail(f"{context}: unsafe relative path: {raw!r}")
    for part in path.parts:
        if part.endswith((" ", ".")) or ":" in part:
            fail(f"{context}: path is not portable to Windows: {raw!r}")
        stem = part.split(".", 1)[0].casefold()
        if stem in {"con", "prn", "aux", "nul"} or re.fullmatch(r"com[1-9]|lpt[1-9]", stem):
            fail(f"{context}: reserved Windows path component: {raw!r}")
    return path.as_posix()


def policy_path() -> Path:
    return Path(__file__).with_name("policy.json")


def load_policy() -> dict:
    try:
        policy = json.loads(policy_path().read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot read preview policy: {error}")
    if policy.get("formatVersion") != 1:
        fail("policy formatVersion must be 1")
    if tuple(policy.get("productSchemas", ())) != EXPECTED_SCHEMAS:
        fail(f"policy must freeze the four product schemas in order: {EXPECTED_SCHEMAS}")

    for key in ("sourceRoot", "archiveRoot"):
        policy[key] = canonical_relative_path(policy.get(key), f"policy {key}")

    for key in ("include", "seedFiles", "supplementalFiles", "externalRuntimeFiles"):
        values = policy.get(key)
        if not isinstance(values, list):
            fail(f"policy {key} must be an array")
        policy[key] = [canonical_relative_path(value, f"policy {key}") for value in values]

    excluded: list[str] = []
    groups = policy.get("exclude")
    if not isinstance(groups, dict):
        fail("policy exclude must be an object of reviewed path groups")
    for group, values in groups.items():
        if not isinstance(group, str) or not isinstance(values, list):
            fail("policy exclusion groups must map names to arrays")
        excluded.extend(canonical_relative_path(value, f"policy exclude.{group}") for value in values)
    policy["excludedFiles"] = excluded

    static_dicts = policy.get("staticUserDictionaries")
    if not isinstance(static_dicts, dict):
        fail("policy staticUserDictionaries must be an object")
    policy["staticUserDictionaries"] = {
        str(name): canonical_relative_path(path, f"static user dictionary {name}")
        for name, path in static_dicts.items()
    }
    optional_dicts = policy.get("optionalUserDictionaries")
    if not isinstance(optional_dicts, list) or not all(isinstance(item, str) for item in optional_dicts):
        fail("policy optionalUserDictionaries must be an array of names")

    include = set(policy["include"])
    excluded_set = set(excluded)
    if len(include) != len(policy["include"]):
        fail("policy include contains duplicate paths")
    if len(excluded_set) != len(excluded):
        fail("policy exclude contains duplicate paths")
    overlap = include & excluded_set
    if overlap:
        fail(f"policy includes and excludes the same paths: {sorted(overlap)}")
    for key in ("seedFiles", "supplementalFiles"):
        missing = set(policy[key]) - include
        if missing:
            fail(f"policy {key} contains paths absent from include: {sorted(missing)}")

    provenance = policy.get("provenanceGroups")
    if not isinstance(provenance, dict) or not provenance:
        fail("policy provenanceGroups must be a non-empty object")
    provenance_paths: dict[str, str] = {}
    normalized_provenance: dict[str, dict] = {}
    for group_name, metadata in provenance.items():
        if not isinstance(group_name, str) or not group_name or not isinstance(metadata, dict):
            fail("policy provenance groups must have non-empty names and object values")
        license_name = metadata.get("license")
        source = metadata.get("source")
        files = metadata.get("files")
        if not isinstance(license_name, str) or not license_name:
            fail(f"policy provenanceGroups.{group_name}.license must be non-empty")
        if not isinstance(source, str) or not source:
            fail(f"policy provenanceGroups.{group_name}.source must be non-empty")
        if not isinstance(files, list) or not files:
            fail(f"policy provenanceGroups.{group_name}.files must be non-empty")
        normalized_files = [
            canonical_relative_path(value, f"policy provenanceGroups.{group_name}.files")
            for value in files
        ]
        for relative in normalized_files:
            if relative in provenance_paths:
                fail(
                    f"policy provenance assigns {relative} more than once "
                    f"({provenance_paths[relative]}, {group_name})"
                )
            provenance_paths[relative] = group_name
        normalized_provenance[group_name] = {
            "license": license_name,
            "source": source,
            "files": normalized_files,
        }
    if set(provenance_paths) != include:
        fail(
            "policy provenance must classify every included file exactly once; "
            f"missing={sorted(include - set(provenance_paths))}, "
            f"extra={sorted(set(provenance_paths) - include)}"
        )
    policy["provenanceGroups"] = normalized_provenance

    folded: dict[str, str] = {}
    for value in include | excluded_set:
        previous = folded.setdefault(value.casefold(), value)
        if previous != value:
            fail(f"policy has a case-colliding path pair: {previous!r}, {value!r}")
    return policy


def forbidden_path_reason(relative: str) -> str | None:
    path = PurePosixPath(relative)
    parts = [part.casefold() for part in path.parts]
    name = parts[-1]
    forbidden_directories = {
        ".build", "build", "dist", "out", "output", "deriveddata",
        "__pycache__", "cache", "logs", "sync", "userdb",
    }
    if any(part in forbidden_directories for part in parts[:-1]):
        return "build, cache, log, sync, or user database directory"
    if name in {".ds_store", "thumbs.db", ".env", "installation.yaml", "user.yaml"}:
        return "host or user state file"
    if name in {"rime_ai.example.json", "rime_ai.local.json"}:
        return "AI configuration/example"
    if name.startswith(("id_rsa", "id_ed25519")) or any(
        marker in name for marker in ("credential", "secret", "token", "private-key")
    ):
        return "credential-like filename"
    if name.endswith((
        ".userdb", ".userdb.kct", ".bin", ".log", ".lock", ".tmp",
        ".temp", ".bak", ".old", ".swp", ".pyc",
    )):
        return "compiled, transient, backup, log, or user database file"
    return None


def scan_source_tree(data_root: Path) -> tuple[set[str], list[str]]:
    if not data_root.is_dir():
        fail(f"missing data root: {data_root}")
    files: set[str] = set()
    symlinks: list[str] = []
    for directory, directory_names, file_names in os.walk(data_root, followlinks=False):
        base = Path(directory)
        for name in list(directory_names):
            candidate = base / name
            if candidate.is_symlink():
                symlinks.append(candidate.relative_to(data_root).as_posix() + "/")
                directory_names.remove(name)
        for name in file_names:
            candidate = base / name
            relative = canonical_relative_path(
                candidate.relative_to(data_root).as_posix(), "source tree"
            )
            if candidate.is_symlink():
                symlinks.append(relative)
                continue
            try:
                mode = candidate.stat().st_mode
            except OSError as error:
                fail(f"cannot stat {candidate}: {error}")
            if not stat.S_ISREG(mode):
                fail(f"source data is not a regular file: {candidate}")
            files.add(relative)
    return files, symlinks


def strip_yaml_comment(line: str) -> str:
    single = False
    double = False
    escaped = False
    for index, character in enumerate(line):
        if character == "\\" and double and not escaped:
            escaped = True
            continue
        if character == "'" and not double and not escaped:
            single = not single
        elif character == '"' and not single and not escaped:
            double = not double
        elif character == "#" and not single and not double:
            return line[:index].rstrip()
        escaped = False
    return line.rstrip()


def active_yaml_lines(text: str) -> list[str]:
    return [line for raw in text.splitlines() if (line := strip_yaml_comment(raw)).strip()]


def scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def list_values(lines: list[str], key: str) -> list[str]:
    results: list[str] = []
    for index, line in enumerate(lines):
        match = re.match(rf"^(\s*){re.escape(key)}:\s*$", line)
        if not match:
            continue
        base_indent = len(match.group(1))
        for child in lines[index + 1 :]:
            indent = len(child) - len(child.lstrip())
            if indent <= base_indent:
                break
            item = re.match(r"^\s*-\s*([A-Za-z0-9_./-]+)", child)
            if item:
                results.append(item.group(1))
    return results


def scalar_values(lines: list[str], key: str) -> list[str]:
    pattern = re.compile(rf"^\s*{re.escape(key)}:\s*(.+?)\s*$")
    return [scalar(match.group(1)) for line in lines if (match := pattern.match(line))]


def top_level_block(text: str, key: str) -> str:
    lines = active_yaml_lines(text)
    start = None
    for index, line in enumerate(lines):
        if re.match(rf"^{re.escape(key)}:\s*$", line):
            start = index
            break
    if start is None:
        return ""
    selected = [lines[start]]
    for line in lines[start + 1 :]:
        if line and not line[0].isspace():
            break
        selected.append(line)
    return "\n".join(selected)


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8-sig")
    except (OSError, UnicodeDecodeError) as error:
        fail(f"cannot read UTF-8 source data {path}: {error}")


def validate_product_schemas(data_root: Path) -> None:
    for filename in ("default.yaml", "default.custom.yaml"):
        lines = active_yaml_lines(read_text(data_root / filename))
        schema_ids = [
            match.group(1)
            for line in lines
            if (match := re.match(r"^\s*-\s*schema:\s*([A-Za-z0-9_-]+)\s*$", line))
        ]
        if tuple(schema_ids) != EXPECTED_SCHEMAS:
            fail(f"{filename} must list exactly {EXPECTED_SCHEMAS}, found {tuple(schema_ids)}")

    for schema_id in EXPECTED_SCHEMAS:
        path = data_root / f"{schema_id}.schema.yaml"
        values = scalar_values(active_yaml_lines(read_text(path)), "schema_id")
        if values != [schema_id]:
            fail(f"{path.name} must declare schema_id {schema_id!r}, found {values}")


def validate_my_combo_v(data_root: Path) -> None:
    path = data_root / "my_combo.schema.yaml"
    text = read_text(path)
    active = "\n".join(active_yaml_lines(text))
    identity = re.search(r"xform/\^\(\[([a-z,.]+)\]\)\$/\$1/", active)
    if not identity or "v" not in identity.group(1):
        fail("my_combo must preserve single physical v through the chord identity rule")
    if re.search(r"lua_filter@[^\s]+v_filter", active):
        fail("my_combo must not activate v_filter")
    if re.search(r"symbols_(?:caps_)?v(?::|/)", active):
        fail("my_combo must not include the v-triggered symbols tables")

    recognizer = top_level_block(text, "recognizer")
    if "^$" not in scalar_values(active_yaml_lines(recognizer), "punct"):
        fail("my_combo recognizer must disable its inherited symbols route with punct: ^$")
    speller = top_level_block(text, "speller")
    for key in ("alphabet", "initials"):
        values = scalar_values(active_yaml_lines(speller), key)
        if len(values) != 1 or "v" not in values[0]:
            fail(f"my_combo speller {key} must contain literal v")


def lua_module_path(module: str) -> str:
    return "lua/" + module.replace(".", "/") + ".lua"


def discover_closure(data_root: Path, policy: dict) -> tuple[set[str], set[str]]:
    included = set(policy["include"])
    external_allowed = set(policy["externalRuntimeFiles"])
    static_user_dicts = policy["staticUserDictionaries"]
    optional_user_dicts = set(policy["optionalUserDictionaries"])
    reachable: set[str] = set()
    external_seen: set[str] = set()
    queue = list(policy["seedFiles"])

    def require(relative: str, source: str) -> None:
        relative = canonical_relative_path(relative, f"dependency from {source}")
        if relative in included:
            if relative not in reachable:
                queue.append(relative)
            return
        if relative in external_allowed:
            external_seen.add(relative)
            return
        fail(f"unresolved or unapproved dependency from {source}: {relative}")

    while queue:
        relative = queue.pop(0)
        if relative in reachable:
            continue
        if relative not in included:
            fail(f"closure seed is not package-approved: {relative}")
        reachable.add(relative)
        path = data_root / PurePosixPath(relative)

        if relative.endswith((".yaml", ".yml")):
            lines = active_yaml_lines(read_text(path))
            for dependency in list_values(lines, "dependencies"):
                require(f"{dependency}.schema.yaml", relative)
            for table in list_values(lines, "import_tables"):
                require(f"{table}.dict.yaml", relative)
            for value in scalar_values(lines, "__include"):
                if ":" not in value:
                    continue
                preset = value.split(":", 1)[0]
                target = f"{preset}.yaml" if preset.endswith(".schema") else f"{preset}.yaml"
                require(target, relative)
            for preset in scalar_values(lines, "import_preset"):
                require(f"{preset}.yaml", relative)
            for dictionary in scalar_values(lines, "dictionary"):
                if dictionary:
                    require(f"{dictionary}.dict.yaml", relative)
            for user_dict in scalar_values(lines, "user_dict"):
                if user_dict in static_user_dicts:
                    require(static_user_dicts[user_dict], relative)
                elif user_dict not in optional_user_dicts:
                    fail(f"unclassified user_dict in {relative}: {user_dict}")
            for config in scalar_values(lines, "opencc_config"):
                require(f"opencc/{config}", relative)

            active = "\n".join(lines)
            for match in re.finditer(
                r"lua_(?:processor|segmentor|translator|filter)@\*?([A-Za-z0-9_./-]+)",
                active,
            ):
                require(lua_module_path(match.group(1)), relative)

        elif relative.endswith(".json"):
            try:
                value = json.loads(read_text(path))
            except json.JSONDecodeError as error:
                fail(f"invalid JSON dependency file {relative}: {error}")

            def visit(node: object) -> None:
                if isinstance(node, dict):
                    for key, child in node.items():
                        if key == "file" and isinstance(child, str):
                            require(str(PurePosixPath(relative).parent / child), relative)
                        else:
                            visit(child)
                elif isinstance(node, list):
                    for child in node:
                        visit(child)

            visit(value)

        elif relative.endswith(".lua"):
            active = read_text(path)
            patterns = (
                r"require\s*\(?\s*[\"']([^\"']+)[\"']",
                r"pcall\s*\(\s*require\s*,\s*[\"']([^\"']+)[\"']",
            )
            for pattern in patterns:
                for match in re.finditer(pattern, active):
                    require(lua_module_path(match.group(1)), relative)

    expected = included - set(policy["supplementalFiles"])
    if reachable != expected:
        fail(
            "package policy is not the exact dependency closure; "
            f"unreachable={sorted(expected - reachable)}, "
            f"unexpected={sorted(reachable - expected)}"
        )
    if external_seen != external_allowed:
        fail(
            "external runtime policy is not the exact dependency boundary; "
            f"undeclared={sorted(external_seen - external_allowed)}, "
            f"unused={sorted(external_allowed - external_seen)}"
        )
    return reachable, external_seen


def scan_sensitive_content(path: Path, relative: str) -> None:
    overlap = 512
    tail = b""
    try:
        with path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                if b"\x00" in chunk:
                    fail(f"package source must be text, found NUL bytes in {relative}")
                candidate = tail + chunk
                for label, pattern in SECRET_PATTERNS:
                    if pattern.search(candidate):
                        fail(f"possible {label} in package source {relative}")
                tail = candidate[-overlap:]
    except OSError as error:
        fail(f"cannot scan {relative}: {error}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def validate_repo(repo_root: Path) -> dict:
    repo_root = repo_root.resolve()
    policy = load_policy()
    data_root = repo_root / PurePosixPath(policy["sourceRoot"])
    actual, symlinks = scan_source_tree(data_root)
    if symlinks:
        fail(f"rime-data must not contain symlinks: {sorted(symlinks)}")

    included = set(policy["include"])
    excluded = set(policy["excludedFiles"])
    missing = included - actual
    if missing:
        fail(f"policy-approved source files are missing: {sorted(missing)}")
    unclassified = actual - included - excluded
    if unclassified:
        details = [
            f"{path} ({forbidden_path_reason(path) or 'requires policy review'})"
            for path in sorted(unclassified)
        ]
        fail("unclassified rime-data files cannot enter a preview: " + ", ".join(details))

    total_bytes = 0
    for relative in sorted(included):
        reason = forbidden_path_reason(relative)
        if reason:
            fail(f"package policy includes forbidden path {relative}: {reason}")
        path = data_root / PurePosixPath(relative)
        size = path.stat().st_size
        if size > MAX_FILE_BYTES:
            fail(f"package source exceeds {MAX_FILE_BYTES} bytes: {relative}")
        total_bytes += size
        scan_sensitive_content(path, relative)
    if total_bytes > MAX_TOTAL_BYTES:
        fail(f"preview data exceeds {MAX_TOTAL_BYTES} bytes")

    validate_product_schemas(data_root)
    validate_my_combo_v(data_root)
    reachable, external = discover_closure(data_root, policy)
    result = {
        "repoRoot": repo_root,
        "dataRoot": data_root,
        "policy": policy,
        "included": sorted(included),
        "excludedPresent": sorted(actual & excluded),
        "reachable": sorted(reachable),
        "external": sorted(external),
        "totalBytes": total_bytes,
    }
    print(
        "platform-preview verify OK: "
        f"schemas={','.join(EXPECTED_SCHEMAS)} files={len(included)} "
        f"bytes={total_bytes} excluded={len(result['excludedPresent'])} "
        f"external={','.join(result['external']) or 'none'}"
    )
    return result


def manifest_for(result: dict) -> dict:
    policy = result["policy"]
    data_root: Path = result["dataRoot"]
    files = []
    for relative in result["included"]:
        path = data_root / PurePosixPath(relative)
        files.append(
            {
                "path": f"SharedSupport/{relative}",
                "source": f"{policy['sourceRoot']}/{relative}",
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
            }
        )
    return {
        "formatVersion": 1,
        "kind": "rimes-platform-preview-data-only",
        "nativeApplicationIncluded": False,
        "productSchemas": list(EXPECTED_SCHEMAS),
        "policySha256": sha256_file(policy_path()),
        "externalRuntimeFiles": policy["externalRuntimeFiles"],
        "runtimeRequirements": policy["runtimeRequirements"],
        "provenanceGroups": policy["provenanceGroups"],
        "files": files,
    }


def stage_preview(repo_root: Path, output_dir: Path) -> Path:
    """Copy only the validated policy closure into an empty SharedSupport root."""
    result = validate_repo(repo_root)
    if output_dir.is_symlink():
        fail(f"stage output must not be a symlink: {output_dir}")
    if output_dir.exists():
        if not output_dir.is_dir():
            fail(f"stage output exists and is not a directory: {output_dir}")
        try:
            if next(output_dir.iterdir(), None) is not None:
                fail(f"stage output directory must be empty: {output_dir}")
        except OSError as error:
            fail(f"cannot inspect stage output {output_dir}: {error}")
    else:
        try:
            output_dir.mkdir(parents=True)
        except OSError as error:
            fail(f"cannot create stage output {output_dir}: {error}")

    stage_root = output_dir.resolve()
    copied_bytes = 0
    for relative in result["included"]:
        source = result["dataRoot"] / PurePosixPath(relative)
        destination = output_dir / PurePosixPath(relative)
        resolved_destination = destination.resolve(strict=False)
        if not resolved_destination.is_relative_to(stage_root):
            fail(f"stage destination escaped its output root: {relative}")
        try:
            destination.parent.mkdir(parents=True, exist_ok=True)
            if destination.is_symlink():
                fail(f"stage destination must not be a symlink: {destination}")
            if not destination.resolve(strict=False).is_relative_to(stage_root):
                fail(f"stage destination escaped after directory creation: {relative}")
            shutil.copyfile(source, destination, follow_symlinks=False)
            copied_bytes += destination.stat().st_size
        except OSError as error:
            fail(f"cannot stage {relative}: {error}")

    staged, symlinks = scan_source_tree(output_dir)
    expected = set(result["included"])
    if symlinks or staged != expected:
        fail(
            "staged closure verification failed; "
            f"symlinks={sorted(symlinks)}, missing={sorted(expected - staged)}, "
            f"extra={sorted(staged - expected)}"
        )
    print(
        f"platform-preview stage OK: {output_dir} "
        f"files={len(staged)} bytes={copied_bytes}"
    )
    return output_dir


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def zip_entry(archive: zipfile.ZipFile, name: str, data: bytes) -> None:
    info = zipfile.ZipInfo(name, ZIP_TIMESTAMP)
    info.compress_type = zipfile.ZIP_DEFLATED
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | 0o644) << 16
    info.flag_bits |= 0x800
    archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def package_preview(repo_root: Path, output_dir: Path, label: str) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9._-]+", label):
        fail("label may contain only letters, numbers, dot, underscore, and hyphen")
    result = validate_repo(repo_root)
    policy = result["policy"]
    manifest = manifest_for(result)
    manifest_data = json_bytes(manifest)
    notice = (
        "RIMES cross-platform preview data\n"
        "\n"
        "This archive contains a reviewed Rime SharedSupport data overlay only.\n"
        "It does not contain librime, a native input-method shell, UI, installer,\n"
        "or a complete Windows, Linux, or macOS application. See MANIFEST.json\n"
        "for content hashes and external runtime requirements.\n"
    ).encode("utf-8")

    output_dir.mkdir(parents=True, exist_ok=True)
    base = f"RIMES-platform-preview-data-{label}"
    archive_path = output_dir / f"{base}.zip"
    root = policy["archiveRoot"]
    with zipfile.ZipFile(archive_path, "w", allowZip64=True) as archive:
        zip_entry(archive, f"{root}/{MANIFEST_NAME}", manifest_data)
        zip_entry(archive, f"{root}/{NOTICE_NAME}", notice)
        for relative in result["included"]:
            source = result["dataRoot"] / PurePosixPath(relative)
            zip_entry(archive, f"{root}/SharedSupport/{relative}", source.read_bytes())

    sidecar_manifest = output_dir / f"{base}.manifest.json"
    sidecar_manifest.write_bytes(manifest_data)
    archive_digest = sha256_file(archive_path)
    checksum = output_dir / f"{base}.zip.sha256"
    checksum.write_text(f"{archive_digest}  {archive_path.name}\n", encoding="ascii", newline="\n")
    inspect_archive(archive_path)
    print(f"platform-preview package OK: {archive_path} sha256={archive_digest}")
    return archive_path


def inspect_archive(archive_path: Path) -> None:
    try:
        with zipfile.ZipFile(archive_path, "r") as archive:
            infos = archive.infolist()
            names = [info.filename for info in infos]
            if len(names) != len(set(names)):
                fail("preview archive contains duplicate member names")
            folded: dict[str, str] = {}
            total = 0
            for info in infos:
                name = canonical_relative_path(info.filename, "archive member")
                previous = folded.setdefault(name.casefold(), name)
                if previous != name:
                    fail(f"preview archive contains case-colliding members: {previous}, {name}")
                if info.is_dir():
                    fail(f"preview archive contains an unexpected directory entry: {name}")
                archived_mode = (info.external_attr >> 16) & 0xFFFF
                if archived_mode and not stat.S_ISREG(archived_mode):
                    fail(f"preview archive member is not a regular file: {name}")
                total += info.file_size
                if info.file_size > MAX_FILE_BYTES or total > MAX_TOTAL_BYTES:
                    fail("preview archive exceeds reviewed size limits")

            manifest_names = [name for name in names if name.endswith("/" + MANIFEST_NAME)]
            if len(manifest_names) != 1:
                fail("preview archive must contain exactly one MANIFEST.json")
            manifest_name = manifest_names[0]
            root = manifest_name[: -(len(MANIFEST_NAME) + 1)]
            manifest = json.loads(archive.read(manifest_name).decode("utf-8"))
            if manifest.get("kind") != "rimes-platform-preview-data-only":
                fail("preview manifest has the wrong artifact kind")
            if manifest.get("nativeApplicationIncluded") is not False:
                fail("preview manifest must explicitly state that no native app is included")
            if tuple(manifest.get("productSchemas", ())) != EXPECTED_SCHEMAS:
                fail("preview manifest schema list drifted")

            expected = {f"{root}/{MANIFEST_NAME}", f"{root}/{NOTICE_NAME}"}
            manifest_members: set[str] = set()
            for entry in manifest.get("files", []):
                if not isinstance(entry, dict):
                    fail("preview manifest file entry is not an object")
                relative = canonical_relative_path(entry.get("path"), "manifest file")
                if not relative.startswith("SharedSupport/"):
                    fail(f"preview data escaped SharedSupport: {relative}")
                source_relative = relative.removeprefix("SharedSupport/")
                reason = forbidden_path_reason(source_relative)
                if reason:
                    fail(f"preview archive contains forbidden data {source_relative}: {reason}")
                member = f"{root}/{relative}"
                if member.casefold() in manifest_members:
                    fail(f"preview manifest repeats or case-collides at: {member}")
                manifest_members.add(member.casefold())
                expected.add(member)
                data = archive.read(member)
                if len(data) != entry.get("bytes"):
                    fail(f"preview member size mismatch: {member}")
                if hashlib.sha256(data).hexdigest() != entry.get("sha256"):
                    fail(f"preview member hash mismatch: {member}")
            if set(names) != expected:
                fail(
                    "preview archive members do not match its manifest; "
                    f"missing={sorted(expected - set(names))}, extra={sorted(set(names) - expected)}"
                )
    except (OSError, zipfile.BadZipFile, UnicodeDecodeError, json.JSONDecodeError, KeyError) as error:
        fail(f"cannot inspect preview archive {archive_path}: {error}")
    print(f"platform-preview inspect OK: {archive_path}")


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)

    verify = commands.add_parser("verify", help="validate source data and packaging policy")
    verify.add_argument("--repo-root", type=Path, default=Path.cwd())

    package = commands.add_parser("package", help="validate and build a data-only preview ZIP")
    package.add_argument("--repo-root", type=Path, default=Path.cwd())
    package.add_argument("--output-dir", type=Path, required=True)
    package.add_argument("--label", default="local")

    stage = commands.add_parser(
        "stage", help="validate and copy the exact data closure into an empty directory"
    )
    stage.add_argument("--repo-root", type=Path, default=Path.cwd())
    stage.add_argument("--output-dir", type=Path, required=True)

    inspect = commands.add_parser("inspect", help="verify an already-built preview ZIP")
    inspect.add_argument("--archive", type=Path, required=True)
    return result


def main() -> int:
    arguments = parser().parse_args()
    try:
        if arguments.command == "verify":
            validate_repo(arguments.repo_root)
        elif arguments.command == "package":
            package_preview(arguments.repo_root, arguments.output_dir, arguments.label)
        elif arguments.command == "stage":
            stage_preview(arguments.repo_root, arguments.output_dir)
        else:
            inspect_archive(arguments.archive)
    except PreviewError as error:
        print(f"platform-preview ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
