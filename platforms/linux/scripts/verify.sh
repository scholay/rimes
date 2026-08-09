#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
Verify a managed RIMES Linux data/input-schemes preview installation.

Usage:
  verify.sh [--frontend auto|fcitx5|fcitx5-flatpak|ibus]
            [--dest /absolute/path/to/rime] [--check-runtime]

Options:
  --frontend NAME  Select a known frontend when --dest is not used.
  --dest PATH      Verify this absolute Rime user directory without frontend
                   detection. PATH must end in /rime.
  --check-runtime  Also require the selected frontend commands to be installed.
                   File verification does not require a running input method.
  -h, --help       Show this help.
EOF
}

frontend=auto
requested_frontend=auto
dest=""
check_runtime=0

while (($# > 0)); do
    case "$1" in
        --frontend)
            (($# >= 2)) || rimes_die "--frontend requires a value"
            frontend=$2
            requested_frontend=$2
            shift 2
            ;;
        --frontend=*)
            frontend=${1#*=}
            requested_frontend=$frontend
            shift
            ;;
        --dest)
            (($# >= 2)) || rimes_die "--dest requires a value"
            dest=$2
            shift 2
            ;;
        --dest=*)
            dest=${1#*=}
            shift
            ;;
        --check-runtime)
            check_runtime=1
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

rimes_resolve_destination "$frontend" "$dest"
target=$RIMES_RESOLVED_TARGET
state_dir="$target/$RIMES_STATE_DIR_NAME"
lock_dir="$target/$RIMES_LOCK_DIR_NAME"
metadata="$state_dir/metadata.tsv"
manifest="$state_dir/manifest.tsv"

[[ -d "$target" && ! -L "$target" ]] ||
    rimes_die "managed installation target is missing or unsafe: $target"
if ! mkdir "$lock_dir"; then
    rimes_die "another preview install/uninstall transaction is active: $lock_dir"
fi
lock_acquired=1
cleanup_verify_lock() {
    local status=$?

    set +e
    if (( lock_acquired == 1 )); then
        rmdir "$lock_dir" 2>/dev/null
    fi
    set -e
    return "$status"
}
trap cleanup_verify_lock EXIT
trap 'exit 130' HUP INT TERM
chmod 0700 "$lock_dir"

[[ -d "$state_dir" && ! -L "$state_dir" ]] ||
    rimes_die "managed installation state not found: $state_dir"
[[ -f "$metadata" && ! -L "$metadata" ]] ||
    rimes_die "installation metadata is missing or unsafe"
[[ -f "$manifest" && ! -L "$manifest" ]] ||
    rimes_die "installation manifest is missing or unsafe"

format=$(rimes_metadata_value "$metadata" format) ||
    rimes_die "installation metadata has no format"
[[ "$format" == "$RIMES_STATE_FORMAT" ]] ||
    rimes_die "unsupported installation state format '$format'"
installed_frontend=$(rimes_metadata_value "$metadata" frontend) ||
    rimes_die "installation metadata has no frontend"
installed_target=$(rimes_metadata_value "$metadata" target) ||
    rimes_die "installation metadata has no target"
installed_version=$(rimes_metadata_value "$metadata" version) ||
    rimes_die "installation metadata has no version"

[[ "$installed_target" == "$target" ]] ||
    rimes_die "installation target mismatch: metadata says '$installed_target'"
if [[ "$requested_frontend" != "auto" && "$installed_frontend" != "$requested_frontend" ]]; then
    rimes_die "installation belongs to frontend '$installed_frontend', not '$requested_frontend'"
fi

status=0
entries=0
have_default=0
have_combo=0
have_double_pinyin=0
have_rime_ice=0
have_english=0

while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" != *$'\t'* ]]; then
        rimes_warn "invalid manifest line without a tab separator"
        status=1
        continue
    fi
    expected=${line%%$'\t'*}
    relative=${line#*$'\t'}
    if [[ "$relative" == *$'\t'* || ! "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then
        rimes_warn "invalid manifest entry"
        status=1
        continue
    fi
    if ! rimes_validate_relative_path "$relative" || rimes_path_is_reserved "$relative"; then
        rimes_warn "unsafe or reserved manifest path: $relative"
        status=1
        continue
    fi

    case "$relative" in
        default.yaml) have_default=1 ;;
        my_combo.schema.yaml) have_combo=1 ;;
        double_pinyin.schema.yaml) have_double_pinyin=1 ;;
        rime_ice.schema.yaml) have_rime_ice=1 ;;
        english.schema.yaml) have_english=1 ;;
    esac

    installed_file="$target/$relative"
    if ! rimes_path_has_no_symlink_components "$target" "$relative"; then
        rimes_warn "installed path crosses a symbolic link: $relative"
        status=1
        continue
    fi
    if [[ ! -f "$installed_file" || -L "$installed_file" ]]; then
        rimes_warn "missing or unsafe installed file: $relative"
        status=1
        continue
    fi
    actual=$(rimes_sha256_file "$installed_file")
    if [[ "$actual" != "$expected" ]]; then
        rimes_warn "modified installed file: $relative"
        status=1
    fi
    entries=$((entries + 1))
done < "$manifest"

(( entries > 0 )) || {
    rimes_warn "installation manifest is empty"
    status=1
}
for required_flag in \
    "$have_default" \
    "$have_combo" \
    "$have_double_pinyin" \
    "$have_rime_ice" \
    "$have_english"; do
    if (( required_flag == 0 )); then
        rimes_warn "installation manifest is missing a required schema/config file"
        status=1
        break
    fi
done

if (( check_runtime == 1 )); then
    if ! rimes_check_frontend_runtime "$installed_frontend"; then
        rimes_warn "frontend runtime check failed for '$installed_frontend'"
        status=1
    fi
fi

if (( status != 0 )); then
    rimes_die "verification failed; no file was changed"
fi

rmdir "$lock_dir"
lock_acquired=0
trap - EXIT HUP INT TERM

rimes_note "Verified RIMES Linux data/input-schemes preview $installed_version"
rimes_note "Frontend: $installed_frontend"
rimes_note "Rime user directory: $target"
rimes_note "Managed files checked: $entries"
if (( check_runtime == 0 )); then
    rimes_note "Runtime was not required. This verifies files, not a successful Rime compile or live typing."
fi
