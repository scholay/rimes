#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
Uninstall a managed RIMES Linux data/input-schemes preview installation.

Usage:
  uninstall.sh [--frontend auto|fcitx5|fcitx5-flatpak|ibus]
               [--dest /absolute/path/to/rime] [--deploy]

Options:
  --frontend NAME  Select a known frontend when --dest is not used.
  --dest PATH      Uninstall from this absolute Rime user directory without
                   frontend detection. PATH must end in /rime.
  --deploy         Explicitly reload/restart the selected frontend afterward.
  --no-deploy      Explicitly retain the default no-restart behavior.
  -h, --help       Show this help.

Only unchanged files recorded by install.sh are removed. A file edited after
installation is preserved and causes a nonzero exit. There is no force mode.
Unmanaged files, build/, and userdb are never removed.
EOF
}

frontend=auto
requested_frontend=auto
dest=""
deploy=0

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
        --deploy)
            deploy=1
            shift
            ;;
        --no-deploy)
            deploy=0
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
locked_state_dir="$lock_dir/state"
recovery_dir="$lock_dir/recovery"
metadata="$state_dir/metadata.tsv"
manifest="$state_dir/manifest.tsv"
lock_acquired=0
state_guarded=0
state_moved=0
recovery_created=0
transaction_complete=0

cleanup_uninstall_transaction() {
    local status=$?
    local recovery_metadata="$recovery_dir/metadata.tsv"
    local recovery_manifest="$recovery_dir/manifest.tsv"

    set +e
    if (( transaction_complete == 0 )); then
        if (( state_moved == 1 )) && [[ -d "$locked_state_dir" && ! -L "$locked_state_dir" ]]; then
            chmod 0700 "$locked_state_dir" 2>/dev/null
            if (( recovery_created == 1 )) &&
                [[ -f "$recovery_metadata" && ! -L "$recovery_metadata" &&
                    -f "$recovery_manifest" && ! -L "$recovery_manifest" ]]; then
                rm -f "$locked_state_dir/metadata.tsv" "$locked_state_dir/manifest.tsv"
                cp -p "$recovery_metadata" "$locked_state_dir/metadata.tsv"
                cp -p "$recovery_manifest" "$locked_state_dir/manifest.tsv"
            fi
            chmod 0600 "$locked_state_dir/metadata.tsv" "$locked_state_dir/manifest.tsv" 2>/dev/null
            if [[ ! -e "$state_dir" && ! -L "$state_dir" ]]; then
                if mv "$locked_state_dir" "$state_dir"; then
                    state_moved=0
                    state_guarded=0
                else
                    rimes_warn "could not restore uninstall state from transaction lock: $locked_state_dir"
                fi
            else
                rimes_warn "could not restore uninstall state because its original path is occupied: $state_dir"
            fi
        elif (( state_guarded == 1 )) && [[ -d "$state_dir" && ! -L "$state_dir" ]]; then
            chmod 0600 "$state_dir/metadata.tsv" "$state_dir/manifest.tsv" 2>/dev/null
            chmod 0700 "$state_dir" 2>/dev/null
            state_guarded=0
        fi
    fi

    if (( recovery_created == 1 )) && [[ -d "$recovery_dir" && ! -L "$recovery_dir" ]]; then
        chmod 0700 "$recovery_dir" 2>/dev/null
        rm -f "$recovery_metadata" "$recovery_manifest"
        if rmdir "$recovery_dir" 2>/dev/null; then
            recovery_created=0
        else
            rimes_warn "preserving nonempty transaction recovery directory: $recovery_dir"
        fi
    fi
    if (( lock_acquired == 1 )); then
        if rmdir "$lock_dir" 2>/dev/null; then
            lock_acquired=0
        else
            rimes_warn "preserving nonempty preview transaction lock: $lock_dir"
        fi
    fi
    set -e
    return "$status"
}

validate_exact_state_entries() {
    local directory=$1
    local state_entry
    local state_name
    local state_entries=0

    while IFS= read -r state_entry; do
        state_name=${state_entry#"$directory"/}
        case "$state_name" in
            metadata.tsv|manifest.tsv) ;;
            *) rimes_die "managed state contains unexpected entry: $state_entry" ;;
        esac
        [[ -f "$state_entry" && ! -L "$state_entry" ]] ||
            rimes_die "managed state entry is unsafe; no file was changed: $state_entry"
        state_entries=$((state_entries + 1))
    done < <(find -P "$directory" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)
    (( state_entries == 2 )) ||
        rimes_die "managed state must contain exactly metadata.tsv and manifest.tsv"
}

[[ -d "$target" && ! -L "$target" ]] ||
    rimes_die "managed installation target is missing or unsafe: $target"
if ! mkdir "$lock_dir"; then
    rimes_die "another preview install/uninstall transaction is active: $lock_dir"
fi
lock_acquired=1
trap cleanup_uninstall_transaction EXIT
trap 'exit 130' HUP INT TERM
chmod 0700 "$lock_dir"

[[ -d "$state_dir" && ! -L "$state_dir" ]] ||
    rimes_die "managed installation state not found: $state_dir"
[[ -f "$metadata" && ! -L "$metadata" ]] ||
    rimes_die "installation metadata is missing or unsafe"
[[ -f "$manifest" && ! -L "$manifest" ]] ||
    rimes_die "installation manifest is missing or unsafe"

# Freeze managed state before checking it. A cooperating process can no longer
# add an entry or rewrite the manifest between preflight and payload removal.
chmod 0500 "$state_dir"
state_guarded=1
chmod 0400 "$metadata" "$manifest"
validate_exact_state_entries "$state_dir"

# Keep a stable read-only snapshot under the exclusive transaction lock. If a
# later operation fails after payload removal starts, cleanup can reconstruct
# retry metadata from this snapshot instead of losing the installation state.
mkdir "$recovery_dir"
recovery_created=1
chmod 0700 "$recovery_dir"
cp -p "$metadata" "$recovery_dir/metadata.tsv"
cp -p "$manifest" "$recovery_dir/manifest.tsv"
chmod 0400 "$recovery_dir/metadata.tsv" "$recovery_dir/manifest.tsv"
chmod 0500 "$recovery_dir"
[[ "$(rimes_sha256_file "$metadata")" == "$(rimes_sha256_file "$recovery_dir/metadata.tsv")" ]] ||
    rimes_die "installation metadata changed while taking the transaction snapshot"
[[ "$(rimes_sha256_file "$manifest")" == "$(rimes_sha256_file "$recovery_dir/manifest.tsv")" ]] ||
    rimes_die "installation manifest changed while taking the transaction snapshot"
metadata="$recovery_dir/metadata.tsv"
manifest="$recovery_dir/manifest.tsv"

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
if (( deploy == 1 )) &&
    [[ "$installed_frontend" == "custom" || "$installed_frontend" == "fcitx5-flatpak" ]]; then
    rimes_die "--deploy is unavailable for frontend '$installed_frontend'; no file was changed"
fi

# Validate every manifest entry and every parent component before deleting the
# first file. A directory replaced by a symbolic link is a changed managed path
# even when the leaf still appears to be a regular file.
manifest_entries=0
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *$'\t'* ]] || rimes_die "invalid installation manifest"
    expected=${line%%$'\t'*}
    relative=${line#*$'\t'}
    [[ "$relative" != *$'\t'* && "$expected" =~ ^[0-9a-fA-F]{64}$ ]] ||
        rimes_die "invalid installation manifest entry"
    rimes_validate_relative_path "$relative" ||
        rimes_die "unsafe path in installation manifest: $relative"
    ! rimes_path_is_reserved "$relative" ||
        rimes_die "reserved Rime runtime path in installation manifest: $relative"
    rimes_path_has_no_symlink_components "$target" "$relative" ||
        rimes_die "managed path crosses a symbolic link; no file was changed: $relative"
    manifest_entries=$((manifest_entries + 1))
done < "$manifest"
(( manifest_entries > 0 )) || rimes_die "installation manifest is empty"

# Refuse the entire uninstall before deleting anything if a managed path was
# edited or replaced. Missing files are safe and treated as already removed.
modified=0
while IFS=$'\t' read -r expected relative; do
    installed_file="$target/$relative"
    if ! rimes_path_has_no_symlink_components "$target" "$relative"; then
        rimes_warn "preserving path behind a symbolic link: $relative"
        modified=$((modified + 1))
        continue
    fi
    if [[ ! -e "$installed_file" && ! -L "$installed_file" ]]; then
        continue
    fi
    if [[ ! -f "$installed_file" || -L "$installed_file" ]]; then
        rimes_warn "preserving changed or unsafe path: $relative"
        modified=$((modified + 1))
        continue
    fi
    actual=$(rimes_sha256_file "$installed_file")
    if [[ "$actual" != "$expected" ]]; then
        rimes_warn "preserving file modified after installation: $relative"
        modified=$((modified + 1))
    fi
done < "$manifest"

if (( modified > 0 )); then
    rimes_warn "$modified managed file(s) were modified; uninstall made no changes"
    rimes_warn "move or restore those files, then run uninstall.sh again"
    exit 1
fi

# Move the frozen state atomically under the lock before changing the payload.
# Any later failure restores it from the recovery snapshot.
state_moved=1
chmod 0700 "$state_dir"
mv "$state_dir" "$locked_state_dir"
chmod 0500 "$locked_state_dir"
validate_exact_state_entries "$locked_state_dir"

removed=0
missing=0

while IFS=$'\t' read -r expected relative; do
    installed_file="$target/$relative"
    rimes_path_has_no_symlink_components "$target" "$relative" ||
        rimes_die "managed path gained a symbolic-link component during uninstall: $relative"
    if [[ ! -e "$installed_file" && ! -L "$installed_file" ]]; then
        missing=$((missing + 1))
    else
        [[ -f "$installed_file" && ! -L "$installed_file" ]] ||
            rimes_die "managed path changed during uninstall: $relative"
        actual=$(rimes_sha256_file "$installed_file")
        [[ "$actual" == "$expected" ]] ||
            rimes_die "managed file changed during uninstall: $relative"
        rimes_path_has_no_symlink_components "$target" "$relative" ||
            rimes_die "managed path gained a symbolic-link component during uninstall: $relative"
        [[ -f "$installed_file" && ! -L "$installed_file" ]] ||
            rimes_die "managed path changed immediately before removal: $relative"
        rm -f "$installed_file"
        removed=$((removed + 1))
    fi

done < "$manifest"

# The locked state must still contain exactly the two frozen files. If an entry
# appeared despite the permission guard, fail and restore state without
# deleting that unexpected entry.
validate_exact_state_entries "$locked_state_dir"
chmod 0700 "$locked_state_dir"
chmod 0600 "$locked_state_dir/manifest.tsv" "$locked_state_dir/metadata.tsv"
rm -f "$locked_state_dir/manifest.tsv" "$locked_state_dir/metadata.tsv"
rmdir "$locked_state_dir"
state_moved=0
state_guarded=0
transaction_complete=1

chmod 0700 "$recovery_dir"
chmod 0600 "$recovery_dir/manifest.tsv" "$recovery_dir/metadata.tsv"
rm -f "$recovery_dir/manifest.tsv" "$recovery_dir/metadata.tsv"
rmdir "$recovery_dir"
recovery_created=0
rmdir "$lock_dir"
lock_acquired=0
trap - EXIT HUP INT TERM

rimes_note "Uninstalled RIMES Linux data/input-schemes preview $installed_version"
rimes_note "Removed unchanged managed files: $removed; already missing: $missing"
rimes_note "Unmanaged files, build/, and userdb were not removed."

if (( deploy == 1 )); then
    rimes_deploy_frontend "$installed_frontend" "$target"
else
    rimes_note "Frontend was not restarted. Run the frontend's Rime Deploy action when ready."
fi
