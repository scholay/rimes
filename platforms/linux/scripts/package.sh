#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
Build the distributable RIMES Linux data/input-schemes preview archive.

Usage:
  package.sh [--output-dir PATH] [--version VERSION]

Options:
  --output-dir PATH  Archive destination. Default: platforms/linux/dist.
  --version VERSION  Override VERSION for a release build.
  -h, --help         Show this help.

The archive contains the current repository rime-data payload, Linux scripts,
the platform README, a payload SHA-256 manifest, and the project license. It
does not contain a Linux RIMES executable or Buffer/AI/workbench UI.
EOF
}

caller_pwd=$PWD
platform_root=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)
repo_root=$(CDPATH= cd -- "$platform_root/../.." && pwd -P)
output_dir="$platform_root/dist"
version=$(rimes_read_version "$SCRIPT_DIR")

while (($# > 0)); do
    case "$1" in
        --output-dir)
            (($# >= 2)) || rimes_die "--output-dir requires a value"
            output_dir=$2
            shift 2
            ;;
        --output-dir=*)
            output_dir=${1#*=}
            shift
            ;;
        --version)
            (($# >= 2)) || rimes_die "--version requires a value"
            version=$2
            shift 2
            ;;
        --version=*)
            version=${1#*=}
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            (($# == 0)) || rimes_die "unexpected positional arguments: $*"
            ;;
        *)
            rimes_die "unknown argument '$1'"
            ;;
    esac
done

[[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] ||
    rimes_die "version contains unsupported characters"
[[ "$output_dir" != *$'\n'* && "$output_dir" != *$'\r'* && "$output_dir" != *$'\t'* ]] ||
    rimes_die "output directory contains an unsupported control character"
if [[ "$output_dir" != /* ]]; then
    output_dir="$caller_pwd/$output_dir"
fi

[[ -d "$repo_root/rime-data" ]] ||
    rimes_die "repository rime-data directory not found; package.sh must run from a source checkout"
[[ -f "$repo_root/LICENSE" ]] || rimes_die "project LICENSE not found"
preview_tool="$repo_root/scripts/platform-preview/preview.py"
rimes_command_exists python3 ||
    rimes_die "python3 is required to stage the reviewed preview payload"
[[ -f "$preview_tool" ]] ||
    rimes_die "reviewed platform-preview staging tool not found: $preview_tool"

mkdir -p "$output_dir"
output_dir=$(CDPATH= cd -- "$output_dir" && pwd -P)
package_name="RIMES-Linux-Data-Preview-$version"
archive="$output_dir/$package_name.tar.gz"
checksum="$archive.sha256"
[[ ! -e "$archive" && ! -e "$checksum" ]] ||
    rimes_die "release artifact already exists: $archive"

temp_base=${TMPDIR:-/tmp}
staging=$(mktemp -d "${temp_base%/}/rimes-linux-package.XXXXXX")
package_root="$staging/$package_name"

cleanup_staging() {
    local status=$?

    case "$staging" in
        "${temp_base%/}"/rimes-linux-package.*)
            rm -rf "$staging"
            ;;
        *)
            rimes_warn "refusing to clean unexpected staging path: $staging"
            ;;
    esac
    return "$status"
}
trap cleanup_staging EXIT
trap 'exit 130' HUP INT TERM

mkdir -p "$package_root/data"
python3 "$preview_tool" stage \
    --repo-root "$repo_root" \
    --output-dir "$package_root/data/rime-data"
cp "$platform_root/README.md" "$package_root/README.md"
printf '%s\n' "$version" > "$package_root/VERSION"
cp "$repo_root/LICENSE" "$package_root/LICENSE"
cp "$repo_root/THIRD_PARTY_NOTICES.md" "$package_root/THIRD_PARTY_NOTICES.md"
cp -R "$platform_root/scripts" "$package_root/scripts"

if find -P "$package_root/data/rime-data" -type l -print -quit | grep -q .; then
    rimes_die "rime-data contains a symbolic link; refusing to package"
fi
if find -P "$package_root/data/rime-data" ! -type d ! -type f -print -quit | grep -q .; then
    rimes_die "rime-data contains a non-regular filesystem entry"
fi

while IFS= read -r -d '' file; do
    relative=${file#"$package_root/data/rime-data"/}
    rimes_validate_relative_path "$relative" ||
        rimes_die "unsafe rime-data path: $relative"
    rimes_path_is_reserved "$relative" &&
        rimes_die "rime-data contains reserved runtime path: $relative"
done < <(find -P "$package_root/data/rime-data" -type f -print0)

staged_count=$(find -P "$package_root/data/rime-data" -type f | wc -l | tr -d '[:space:]')
[[ "$staged_count" == "46" ]] ||
    rimes_die "reviewed payload must contain exactly 46 files, found $staged_count"
[[ ! -e "$package_root/data/rime-data/rime_ai.example.json" ]] ||
    rimes_die "legacy AI example unexpectedly entered the reviewed payload"
if find -P "$package_root/data/rime-data/lua" -type f -name 'ai_*.lua' -print -quit | grep -q .; then
    rimes_die "legacy AI Lua unexpectedly entered the reviewed payload"
fi

payload_manifest="$package_root/data/PAYLOAD-MANIFEST.tsv"
while IFS= read -r file; do
    relative=${file#"$package_root/data/rime-data"/}
    digest=$(rimes_sha256_file "$file")
    printf '%s\t%s\n' "$digest" "$relative" >> "$payload_manifest"
done < <(find -P "$package_root/data/rime-data" -type f -print | LC_ALL=C sort)
chmod 0644 "$payload_manifest"
find "$package_root/scripts" -type f -name '*.sh' -exec chmod 0755 {} +

# BSD tar on macOS otherwise synthesizes AppleDouble `._*` members from xattrs,
# which are not part of the reviewed payload and break cross-platform hashes.
(CDPATH= cd -- "$staging" && COPYFILE_DISABLE=1 tar -czf "$archive" "$package_name")
archive_digest=$(rimes_sha256_file "$archive")
printf '%s  %s\n' "$archive_digest" "${archive##*/}" > "$checksum"

trap - EXIT HUP INT TERM
cleanup_staging

rimes_note "Created: $archive"
rimes_note "Created: $checksum"
rimes_note "Package type: data/input-schemes preview (no Linux RIMES application UI)"
