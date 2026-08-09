#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
Install the RIMES Linux data/input-schemes preview.

Usage:
  install.sh [--frontend auto|fcitx5|fcitx5-flatpak|ibus]
             [--dest /absolute/path/to/rime] [--deploy]

Options:
  --frontend NAME  Select a known Rime frontend. Default: auto-detect.
  --dest PATH      Install into this absolute Rime user directory and skip
                   frontend detection. PATH must end in /rime. Intended for CI
                   as well as nonstandard layouts.
  --deploy         Explicitly reload/restart the selected frontend after the
                   file transaction. Never enabled by default.
  --no-deploy      Explicitly retain the default no-restart behavior.
  -h, --help       Show this help.

Existing destination files are never overwritten. A collision aborts before
any payload file is copied. build/, userdb, generated *.bin files, and Rime
runtime state are not part of this preview.
EOF
}

frontend=auto
dest=""
deploy=0

while (($# > 0)); do
    case "$1" in
        --frontend)
            (($# >= 2)) || rimes_die "--frontend requires a value"
            frontend=$2
            shift 2
            ;;
        --frontend=*)
            frontend=${1#*=}
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
frontend=$RIMES_RESOLVED_FRONTEND
target=$RIMES_RESOLVED_TARGET
if (( deploy == 1 )) && [[ "$frontend" == "custom" || "$frontend" == "fcitx5-flatpak" ]]; then
    rimes_die "--deploy is unavailable for frontend '$frontend'; no file was changed"
fi
packaged_payload=0
if [[ -d "$SCRIPT_DIR/../data/rime-data" ]]; then
    packaged_payload=1
fi
payload_dir=$(rimes_find_payload_dir "$SCRIPT_DIR")

cleanup_payload_on_early_exit() {
    local status=$?
    rimes_cleanup_ephemeral_payload "$payload_dir"
    return "$status"
}
trap cleanup_payload_on_early_exit EXIT

version=$(rimes_read_version "$SCRIPT_DIR")
state_dir="$target/$RIMES_STATE_DIR_NAME"
lock_dir="$target/$RIMES_LOCK_DIR_NAME"

for required in \
    default.yaml \
    default.custom.yaml \
    my_combo.schema.yaml \
    double_pinyin.schema.yaml \
    rime_ice.schema.yaml \
    english.schema.yaml; do
    [[ -f "$payload_dir/$required" && ! -L "$payload_dir/$required" ]] ||
        rimes_die "required payload file is missing or unsafe: $required"
done

if find -P "$payload_dir" -type l -print -quit | grep -q .; then
    rimes_die "payload contains a symbolic link; refusing installation"
fi
if find -P "$payload_dir" ! -type d ! -type f -print -quit | grep -q .; then
    rimes_die "payload contains a non-regular filesystem entry"
fi

rimes_verify_packaged_payload "$payload_dir" "$packaged_payload"

while IFS= read -r -d '' source; do
    relative=${source#"$payload_dir"/}
    rimes_validate_relative_path "$relative" ||
        rimes_die "unsafe payload path: $relative"
    rimes_path_is_reserved "$relative" &&
        rimes_die "payload contains reserved Rime runtime path: $relative"
done < <(find -P "$payload_dir" -type f -print0)

target_created=0
if [[ ! -d "$target" ]]; then
    target_created=1
    mkdir -p "$target"
    chmod 0700 "$target"
fi
[[ ! -L "$target" ]] || rimes_die "destination became a symlink: $target"

[[ ! -e "$lock_dir" && ! -L "$lock_dir" ]] ||
    rimes_die "another preview install/uninstall transaction is active: $lock_dir"
if ! mkdir "$lock_dir"; then
    rimes_die "could not acquire preview transaction lock: $lock_dir"
fi
chmod 0700 "$lock_dir"
lock_acquired=1

cleanup_lock_on_early_exit() {
    local status=$?

    set +e
    if (( lock_acquired == 1 )); then
        rmdir "$lock_dir" 2>/dev/null
    fi
    if (( target_created == 1 )); then
        rmdir "$target" 2>/dev/null
    fi
    set -e
    rimes_cleanup_ephemeral_payload "$payload_dir"
    return "$status"
}
trap cleanup_lock_on_early_exit EXIT

[[ ! -e "$state_dir" && ! -L "$state_dir" ]] ||
    rimes_die "a managed preview installation already exists at $state_dir; run verify.sh or uninstall.sh"

state_tmp=$(mktemp -d "$target/.rimes-linux-data-preview.tmp.XXXXXX")
source_manifest="$state_tmp/source-manifest.tsv"
journal="$state_tmp/journal"
active_temp_dest=""
active_commit_relative=""
active_expected_digest=""
state_claimed=0
committed=0

rollback_install() {
    local status=$?
    local relative_path
    local active_relative
    local active_destination
    local state_name
    local state_source
    local state_destination
    local expected_digest
    local anchor_relative
    local anchor_path
    local anchor_digest
    local extra_field

    if (( committed == 0 )); then
        set +e
        if [[ -n "$active_temp_dest" ]]; then
            active_relative=${active_temp_dest#"$target"/}
            if [[ -n "$active_commit_relative" ]] &&
                rimes_validate_relative_path "$active_commit_relative" &&
                rimes_path_has_no_symlink_components "$target" "$active_commit_relative"; then
                active_destination="$target/$active_commit_relative"
                if [[ -f "$active_temp_dest" && ! -L "$active_temp_dest" &&
                    -f "$active_destination" && ! -L "$active_destination" &&
                    "$active_temp_dest" -ef "$active_destination" ]]; then
                    anchor_digest=$(rimes_sha256_file "$active_temp_dest")
                    if [[ -n "$active_expected_digest" &&
                        "$anchor_digest" == "$active_expected_digest" ]]; then
                        rm -f "$active_destination"
                    else
                        rimes_warn "rollback preserved a concurrently edited path: $active_commit_relative"
                    fi
                fi
            fi
            if rimes_validate_relative_path "$active_relative" &&
                rimes_path_has_no_symlink_components "$target" "$active_relative"; then
                if [[ -f "$active_temp_dest" && ! -L "$active_temp_dest" ]]; then
                    if [[ -n "$active_commit_relative" &&
                        -f "$active_destination" && ! -L "$active_destination" &&
                        "$active_temp_dest" -ef "$active_destination" ]]; then
                        # Removing the installer-owned anchor cannot remove the
                        # user's destination, even when that shared inode was
                        # edited in place after the link commit.
                        rm -f "$active_temp_dest"
                    else
                        anchor_digest=$(rimes_sha256_file "$active_temp_dest")
                        if [[ -n "$active_expected_digest" &&
                            "$anchor_digest" == "$active_expected_digest" ]]; then
                            rm -f "$active_temp_dest"
                        else
                            rimes_warn "rollback preserved a changed temporary anchor: $active_temp_dest"
                        fi
                    fi
                fi
            else
                rimes_warn "rollback preserved an unsafe temporary path: $active_temp_dest"
            fi
        fi
        if [[ -f "$journal" ]]; then
            while IFS=$'\t' read -r expected_digest relative_path anchor_relative extra_field; do
                [[ -z "${extra_field:-}" && "$expected_digest" =~ ^[0-9a-fA-F]{64}$ ]] || continue
                rimes_validate_relative_path "$relative_path" || continue
                rimes_validate_relative_path "$anchor_relative" || continue
                active_destination="$target/$relative_path"
                anchor_path="$target/$anchor_relative"
                if ! rimes_path_has_no_symlink_components "$target" "$relative_path" ||
                    ! rimes_path_has_no_symlink_components "$target" "$anchor_relative"; then
                    rimes_warn "rollback preserved a path behind a symbolic link: $relative_path"
                    continue
                fi
                if [[ -f "$anchor_path" && ! -L "$anchor_path" ]]; then
                    anchor_digest=$(rimes_sha256_file "$anchor_path")
                    if [[ -f "$active_destination" && ! -L "$active_destination" &&
                        "$anchor_path" -ef "$active_destination" ]]; then
                        if [[ "$anchor_digest" == "$expected_digest" ]]; then
                            rm -f "$active_destination"
                        else
                            rimes_warn "rollback preserved a managed path edited during installation: $relative_path"
                        fi
                        rm -f "$anchor_path"
                    elif [[ "$anchor_digest" == "$expected_digest" ]]; then
                        rm -f "$anchor_path"
                    else
                        rimes_warn "rollback preserved a changed temporary anchor: $anchor_relative"
                    fi
                fi
            done < "$journal"
        fi
        if (( state_claimed == 1 )) && [[ -d "$state_dir" && ! -L "$state_dir" ]]; then
            for state_name in metadata.tsv manifest.tsv; do
                state_source="$state_tmp/$state_name"
                state_destination="$state_dir/$state_name"
                if [[ -f "$state_source" && ! -L "$state_source" &&
                    -f "$state_destination" && ! -L "$state_destination" &&
                    "$state_source" -ef "$state_destination" ]]; then
                    rm -f "$state_destination"
                fi
            done
            if ! rmdir "$state_dir" 2>/dev/null; then
                rimes_warn "preserving nonempty state directory after rollback: $state_dir"
            fi
        fi
        rm -f "$source_manifest" "$journal" "$state_tmp/metadata.tsv" "$state_tmp/manifest.tsv"
        rmdir "$state_tmp" 2>/dev/null || true
        if (( lock_acquired == 1 )); then
            rmdir "$lock_dir" 2>/dev/null || true
            lock_acquired=0
        fi
        if (( target_created == 1 )); then
            rmdir "$target" 2>/dev/null || true
        fi
        set -e
    fi
    rimes_cleanup_ephemeral_payload "$payload_dir"
    return "$status"
}

trap rollback_install EXIT
trap 'exit 130' HUP INT TERM

while IFS= read -r source; do
    relative=${source#"$payload_dir"/}
    digest=$(rimes_sha256_file "$source")
    printf '%s\t%s\n' "$digest" "$relative" >> "$source_manifest"
done < <(find -P "$payload_dir" -type f -print | LC_ALL=C sort)

while IFS=$'\t' read -r digest relative; do
    rimes_validate_relative_path "$relative" ||
        rimes_die "unsafe path in generated source manifest: $relative"
    rimes_assert_no_symlink_components "$target" "$relative"
    destination="$target/$relative"
    if [[ -e "$destination" || -L "$destination" ]]; then
        rimes_die "destination collision (nothing was installed): $destination"
    fi
done < "$source_manifest"

: > "$journal"
while IFS=$'\t' read -r digest relative; do
    source="$payload_dir/$relative"
    destination="$target/$relative"
    destination_parent=${destination%/*}
    mkdir -p "$destination_parent"
    rimes_assert_no_symlink_components "$target" "$relative"
    active_temp_dest=$(mktemp "$destination.rimes-tmp.XXXXXX")
    active_expected_digest=$digest
    cp -p "$source" "$active_temp_dest"
    copied_digest=$(rimes_sha256_file "$active_temp_dest")
    [[ "$copied_digest" == "$digest" ]] ||
        rimes_die "copy verification failed: $relative"
    rimes_assert_no_symlink_components "$target" "$relative"
    active_commit_relative=$relative
    if ! rimes_link_exact_no_replace "$active_temp_dest" "$destination"; then
        if [[ -e "$destination" || -L "$destination" ]]; then
            rimes_die "destination appeared during installation; concurrent file was preserved: $destination"
        fi
        rimes_die "could not atomically commit '$relative'; need GNU/BusyBox ln -T or python3 and a filesystem with hard-link support"
    fi
    [[ -f "$destination" && ! -L "$destination" &&
        "$active_temp_dest" -ef "$destination" ]] ||
        rimes_die "atomic commit did not create the exact destination: $relative"
    anchor_relative=${active_temp_dest#"$target"/}
    rimes_validate_relative_path "$anchor_relative" ||
        rimes_die "unsafe temporary anchor path: $anchor_relative"
    printf '%s\t%s\t%s\n' "$digest" "$relative" "$anchor_relative" >> "$journal"
    active_temp_dest=""
    active_commit_relative=""
    active_expected_digest=""
done < "$source_manifest"

# Every committed destination must still be the exact hard link owned by this
# transaction before installation state can be published. The anchors remain
# until state commit so rollback never deletes a concurrent replacement.
while IFS=$'\t' read -r expected_digest relative anchor_relative extra_field; do
    [[ -z "${extra_field:-}" && "$expected_digest" =~ ^[0-9a-fA-F]{64}$ ]] ||
        rimes_die "invalid installation journal entry"
    rimes_validate_relative_path "$relative" || rimes_die "unsafe installation journal path"
    rimes_validate_relative_path "$anchor_relative" || rimes_die "unsafe installation anchor path"
    destination="$target/$relative"
    anchor_path="$target/$anchor_relative"
    rimes_path_has_no_symlink_components "$target" "$relative" &&
        rimes_path_has_no_symlink_components "$target" "$anchor_relative" &&
        [[ -f "$destination" && ! -L "$destination" &&
            -f "$anchor_path" && ! -L "$anchor_path" &&
            "$destination" -ef "$anchor_path" ]] ||
        rimes_die "managed destination changed during installation: $relative"
    [[ "$(rimes_sha256_file "$anchor_path")" == "$expected_digest" ]] ||
        rimes_die "managed destination was edited during installation: $relative"
done < "$journal"

mv "$source_manifest" "$state_tmp/manifest.tsv"
cat > "$state_tmp/metadata.tsv" <<EOF
format	$RIMES_STATE_FORMAT
version	$version
frontend	$frontend
target	$target
installed_at	$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
chmod 0600 "$state_tmp/manifest.tsv" "$state_tmp/metadata.tsv" "$journal"

# Claim the final state path with mkdir, whose fail-if-exists behavior is
# atomic. Moving a directory to an existing directory would instead nest it
# and falsely report success, so state files use the same no-replace hard-link
# commit as payload files.
if ! mkdir "$state_dir" 2>/dev/null; then
    rimes_die "managed state appeared during installation; concurrent state was preserved: $state_dir"
fi
state_claimed=1
chmod 0700 "$state_dir"
for state_name in manifest.tsv metadata.tsv; do
    state_source="$state_tmp/$state_name"
    state_destination="$state_dir/$state_name"
    [[ -d "$state_dir" && ! -L "$state_dir" ]] ||
        rimes_die "managed state path changed during installation: $state_dir"
    if ! rimes_link_exact_no_replace "$state_source" "$state_destination"; then
        if [[ -e "$state_destination" || -L "$state_destination" ]]; then
            rimes_die "managed state file appeared during installation; concurrent file was preserved: $state_destination"
        fi
        rimes_die "could not atomically commit state; need GNU/BusyBox ln -T or python3 and a filesystem with hard-link support"
    fi
    [[ -f "$state_destination" && ! -L "$state_destination" &&
        "$state_source" -ef "$state_destination" ]] ||
        rimes_die "atomic state commit did not create the exact destination: $state_destination"
done

state_entries=0
while IFS= read -r state_entry; do
    state_name=${state_entry#"$state_dir"/}
    case "$state_name" in
        metadata.tsv|manifest.tsv) ;;
        *) rimes_die "unexpected entry appeared in managed state during installation: $state_entry" ;;
    esac
    state_source="$state_tmp/$state_name"
    [[ -f "$state_entry" && ! -L "$state_entry" && "$state_source" -ef "$state_entry" ]] ||
        rimes_die "managed state file changed during installation: $state_entry"
    state_entries=$((state_entries + 1))
done < <(find -P "$state_dir" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)
(( state_entries == 2 )) || rimes_die "managed state commit is incomplete"

# The state transaction is now valid. Remove only anchors that still identify
# the exact managed destinations; any concurrent replacement aborts through the
# rollback path and is preserved.
while IFS=$'\t' read -r expected_digest relative anchor_relative extra_field; do
    [[ -z "${extra_field:-}" ]] || rimes_die "invalid installation journal entry"
    destination="$target/$relative"
    anchor_path="$target/$anchor_relative"
    [[ -f "$destination" && ! -L "$destination" &&
        -f "$anchor_path" && ! -L "$anchor_path" &&
        "$destination" -ef "$anchor_path" &&
        "$(rimes_sha256_file "$anchor_path")" == "$expected_digest" ]] ||
        rimes_die "managed destination changed before transaction commit: $relative"
    rm -f "$anchor_path"
done < "$journal"

rm -f "$state_tmp/manifest.tsv" "$state_tmp/metadata.tsv" "$journal"
rmdir "$state_tmp"
committed=1
rmdir "$lock_dir"
lock_acquired=0
trap - EXIT HUP INT TERM
rimes_cleanup_ephemeral_payload "$payload_dir"

rimes_note "Installed RIMES Linux data/input-schemes preview $version"
rimes_note "Frontend: $frontend"
rimes_note "Rime user directory: $target"
rimes_note "No existing file was overwritten. build/ and userdb were not read or changed."
rimes_note "This package does not contain the RIMES Buffer/AI/workbench UI."

if (( deploy == 1 )); then
    rimes_deploy_frontend "$frontend" "$target"
else
    rimes_note "Frontend was not restarted. Run the frontend's Rime Deploy action when ready."
fi
