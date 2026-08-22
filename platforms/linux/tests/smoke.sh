#!/usr/bin/env bash
set -euo pipefail

TEST_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PLATFORM_ROOT=$(CDPATH= cd -- "$TEST_DIR/.." && pwd -P)

fail() {
    printf 'smoke test failed: %s\n' "$*" >&2
    exit 1
}

assert_content() {
    local file=$1
    local expected=$2
    local actual

    [[ -f "$file" ]] || fail "missing sentinel: $file"
    IFS= read -r actual < "$file" || true
    [[ "$actual" == "$expected" ]] || fail "sentinel changed: $file"
}

temp_base=${TMPDIR:-/tmp}
temp_base=$(CDPATH= cd -- "$temp_base" && pwd -P)
tmp_root=$(mktemp -d "${temp_base%/}/rimes-linux-smoke.XXXXXX")
tmp_root=$(CDPATH= cd -- "$tmp_root" && pwd -P)
cleanup() {
    local status=$?

    if [[ "${RIMES_TEST_KEEP_TMP:-0}" == "1" ]]; then
        printf 'smoke test temp retained: %s\n' "$tmp_root" >&2
    else
        case "$tmp_root" in
            "${temp_base%/}"/rimes-linux-smoke.*) rm -rf "$tmp_root" ;;
            *) printf 'refusing unexpected cleanup path: %s\n' "$tmp_root" >&2 ;;
        esac
    fi
    return "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

mkdir -p "$tmp_root/work" "$tmp_root/release" "$tmp_root/extracted"
cd "$tmp_root/work"

common="$PLATFORM_ROOT/scripts/lib/common.sh"
resolved=$(HOME="$tmp_root/path-home" XDG_DATA_HOME="$tmp_root/path-data" \
    bash -c 'source "$1"; rimes_resolve_destination fcitx5 ""; printf "%s" "$RIMES_RESOLVED_TARGET"' \
    _ "$common")
[[ "$resolved" == "$tmp_root/path-data/fcitx5/rime" ]] ||
    fail "Fcitx5 XDG path resolution failed: $resolved"
resolved=$(HOME="$tmp_root/path-home" XDG_CONFIG_HOME="$tmp_root/path-config" \
    bash -c 'source "$1"; rimes_resolve_destination ibus ""; printf "%s" "$RIMES_RESOLVED_TARGET"' \
    _ "$common")
[[ "$resolved" == "$tmp_root/path-config/ibus/rime" ]] ||
    fail "IBus XDG path resolution failed: $resolved"
resolved=$(HOME="$tmp_root/path-home" XMODIFIERS='@im=fcitx' \
    bash -c 'source "$1"; rimes_resolve_destination auto ""; printf "%s\t%s" "$RIMES_RESOLVED_FRONTEND" "$RIMES_RESOLVED_TARGET"' \
    _ "$common")
[[ "$resolved" == $'fcitx5\t'"$tmp_root/path-home/.local/share/fcitx5/rime" ]] ||
    fail "automatic Fcitx5 selection failed: $resolved"

"$PLATFORM_ROOT/scripts/package.sh" --output-dir "$tmp_root/release"
archive=$(find "$tmp_root/release" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
[[ -n "$archive" ]] || fail "package archive was not created"
[[ -f "$archive.sha256" ]] || fail "package checksum was not created"
if tar -tzf "$archive" | grep -Eq '(^|/)\._'; then
    fail "package contains macOS AppleDouble metadata"
fi
tar -xzf "$archive" -C "$tmp_root/extracted"
package_root=$(find "$tmp_root/extracted" -mindepth 1 -maxdepth 1 -type d -print -quit)
[[ -n "$package_root" ]] || fail "package did not extract"
[[ -f "$package_root/THIRD_PARTY_NOTICES.md" ]] || fail "package omitted third-party notices"

payload="$package_root/data/rime-data"
payload_count=$(find -P "$payload" -type f | wc -l | tr -d '[:space:]')
[[ "$payload_count" == "52" ]] || fail "expected 52 reviewed payload files, got $payload_count"
[[ -f "$payload/licenses/GPL-3.0.txt" ]] || fail "package omitted GPL-3.0 text"
[[ -f "$payload/licenses/rime-ice-SOURCE.md" ]] || fail "package omitted Rime Ice source notice"
[[ -f "$payload/licenses/rime-wubi-LICENSE" ]] || fail "package omitted Rime Wubi license"
[[ -f "$payload/licenses/rime-wubi-SOURCE.md" ]] || fail "package omitted Rime Wubi source notice"
[[ ! -e "$payload/rime_ai.example.json" ]] || fail "legacy AI example entered package"
if find -P "$payload/lua" -type f -name 'ai_*.lua' -print -quit | grep -q .; then
    fail "legacy AI Lua entered package"
fi

install="$package_root/scripts/install.sh"
verify="$package_root/scripts/verify.sh"
uninstall="$package_root/scripts/uninstall.sh"

# Successful transaction with unmanaged runtime sentinels already present.
target_a="$tmp_root/home-a/.local/share/fcitx5/rime"
mkdir -p "$target_a/build" "$target_a/demo.userdb"
printf '%s\n' 'keep-build' > "$target_a/build/sentinel"
printf '%s\n' 'keep-userdb' > "$target_a/demo.userdb/sentinel"
printf '%s\n' 'keep-user-yaml' > "$target_a/user.yaml"

"$install" --dest "$target_a"
"$verify" --dest "$target_a"
[[ -f "$target_a/my_combo.schema.yaml" ]] || fail "schema was not installed"
assert_content "$target_a/build/sentinel" 'keep-build'
assert_content "$target_a/demo.userdb/sentinel" 'keep-userdb'
assert_content "$target_a/user.yaml" 'keep-user-yaml'

"$uninstall" --dest "$target_a"
[[ ! -e "$target_a/my_combo.schema.yaml" ]] || fail "managed schema survived uninstall"
assert_content "$target_a/build/sentinel" 'keep-build'
assert_content "$target_a/demo.userdb/sentinel" 'keep-userdb'
assert_content "$target_a/user.yaml" 'keep-user-yaml'

# A single collision must abort before any managed file or state is installed.
target_b="$tmp_root/home-b/.config/ibus/rime"
mkdir -p "$target_b/build"
printf '%s\n' 'user-owned-default' > "$target_b/default.yaml"
printf '%s\n' 'keep-build-b' > "$target_b/build/sentinel"
if "$install" --dest "$target_b"; then
    fail "collision install unexpectedly succeeded"
fi
assert_content "$target_b/default.yaml" 'user-owned-default'
assert_content "$target_b/build/sentinel" 'keep-build-b'
[[ ! -e "$target_b/my_combo.schema.yaml" ]] || fail "partial file survived collision"
[[ ! -e "$target_b/.rimes-linux-data-preview" ]] || fail "state survived collision"

# Edited managed files are preserved; removing the edited file allows a retry.
target_c="$tmp_root/home-c/rime"
"$install" --dest "$target_c"
printf '%s\n' 'locally edited' > "$target_c/default.yaml"
if "$uninstall" --dest "$target_c"; then
    fail "uninstall unexpectedly removed an edited managed file"
fi
assert_content "$target_c/default.yaml" 'locally edited'
[[ -d "$target_c/.rimes-linux-data-preview" ]] || fail "state not retained after preservation"
[[ -f "$target_c/rime_ice.schema.yaml" ]] || fail "failed uninstall partially removed managed files"
rm -f "$target_c/default.yaml"
"$uninstall" --dest "$target_c"
[[ ! -e "$target_c/.rimes-linux-data-preview" ]] || fail "state survived completed retry"

# Unexpected state must fail before any managed file or retry metadata is
# removed. Once the unrelated entry is moved away, uninstall remains retryable.
target_d="$tmp_root/home-d/rime"
"$install" --dest "$target_d"
printf '%s\n' 'unrelated state' > "$target_d/.rimes-linux-data-preview/unexpected"
if "$uninstall" --dest "$target_d"; then
    fail "uninstall accepted unexpected state content"
fi
[[ -f "$target_d/my_combo.schema.yaml" ]] || fail "state preflight failure removed managed files"
[[ -f "$target_d/.rimes-linux-data-preview/metadata.tsv" ]] || fail "state preflight failure removed retry metadata"
rm -f "$target_d/.rimes-linux-data-preview/unexpected"
"$uninstall" --dest "$target_d"

# Replacing a managed parent directory with a symlink must abort the complete
# uninstall before any local or external managed file is removed.
target_symlink="$tmp_root/home-symlink/rime"
external_lua="$tmp_root/external-lua"
"$install" --dest "$target_symlink"
mv "$target_symlink/lua" "$external_lua"
ln -s "$external_lua" "$target_symlink/lua"
if "$verify" --dest "$target_symlink"; then
    fail "verification accepted a managed parent-directory symlink"
fi
if "$uninstall" --dest "$target_symlink"; then
    fail "uninstall followed a managed parent-directory symlink"
fi
[[ -f "$external_lua/v_filter.lua" ]] || fail "uninstall deleted a file through a parent symlink"
[[ -f "$target_symlink/default.yaml" ]] || fail "symlink preflight partially removed managed files"
[[ -f "$target_symlink/.rimes-linux-data-preview/metadata.tsv" ]] ||
    fail "symlink preflight removed retry metadata"
rm -f "$target_symlink/lua"
mv "$external_lua" "$target_symlink/lua"
"$uninstall" --dest "$target_symlink"

# All preview commands must honor the transaction lock. The lock is caller
# visible and must not be removed by a command that did not acquire it.
target_lock="$tmp_root/home-lock/rime"
"$install" --dest "$target_lock"
mkdir "$target_lock/.rimes-linux-data-preview.lock"
if "$verify" --dest "$target_lock"; then
    fail "verification ignored an active transaction lock"
fi
if "$uninstall" --dest "$target_lock"; then
    fail "uninstall ignored an active transaction lock"
fi
if "$install" --dest "$target_lock"; then
    fail "install ignored an active transaction lock"
fi
[[ -d "$target_lock/.rimes-linux-data-preview.lock" ]] ||
    fail "command removed a transaction lock it did not own"
[[ -f "$target_lock/default.yaml" ]] || fail "lock refusal partially removed managed files"
[[ -f "$target_lock/.rimes-linux-data-preview/metadata.tsv" ]] ||
    fail "lock refusal removed retry metadata"
rmdir "$target_lock/.rimes-linux-data-preview.lock"
"$uninstall" --dest "$target_lock"

# A file created after the collision preflight but immediately before commit
# must win atomically. Install must preserve it and roll back earlier payload.
target_file_race="$tmp_root/home-file-race/rime"
file_race_bin="$tmp_root/file-race-bin"
file_race_dest="$target_file_race/lua/v_filter.lua"
real_ln=$(command -v ln)
mkdir "$file_race_bin"
cp "$TEST_DIR/helpers/ln-collision.sh" "$file_race_bin/ln"
chmod 0755 "$file_race_bin/ln"
if PATH="$file_race_bin:$PATH" \
    RIMES_TEST_REAL_LN="$real_ln" \
    RIMES_TEST_COLLISION_DEST="$file_race_dest" \
    "$install" --dest "$target_file_race"; then
    fail "install overwrote a file created between preflight and commit"
fi
assert_content "$file_race_dest" concurrent-user-file
[[ ! -e "$target_file_race/default.yaml" ]] || fail "atomic file collision left earlier payload"
[[ ! -e "$target_file_race/.rimes-linux-data-preview" ]] || fail "atomic file collision left managed state"
[[ ! -e "$target_file_race/.rimes-linux-data-preview.lock" ]] || fail "atomic file collision left transaction lock"

# A directory at the exact destination must be an atomic collision, not an
# instruction for ln to create the temporary hard link inside that directory.
target_dir_race="$tmp_root/home-dir-race/rime"
dir_race_bin="$tmp_root/dir-race-bin"
dir_race_dest="$target_dir_race/cn_dicts/8105.dict.yaml"
real_mkdir=$(command -v mkdir)
mkdir "$dir_race_bin"
cp "$TEST_DIR/helpers/ln-collision.sh" "$dir_race_bin/ln"
chmod 0755 "$dir_race_bin/ln"
if PATH="$dir_race_bin:$PATH" \
    RIMES_TEST_REAL_LN="$real_ln" \
    RIMES_TEST_REAL_MKDIR="$real_mkdir" \
    RIMES_TEST_COLLISION_KIND=directory \
    RIMES_TEST_COLLISION_DEST="$dir_race_dest" \
    "$install" --dest "$target_dir_race"; then
    fail "install treated a concurrent destination directory as an ln target directory"
fi
assert_content "$dir_race_dest/sentinel" concurrent-user-directory
if find -P "$dir_race_dest" -mindepth 1 -maxdepth 1 -type f -name '*.rimes-tmp.*' -print -quit | grep -q .; then
    fail "atomic directory collision wrote a temporary link inside the user directory"
fi
[[ ! -e "$target_dir_race/default.yaml" ]] || fail "atomic directory collision left managed payload"
[[ ! -e "$target_dir_race/.rimes-linux-data-preview" ]] || fail "atomic directory collision left managed state"
[[ ! -e "$target_dir_race/.rimes-linux-data-preview.lock" ]] || fail "atomic directory collision left transaction lock"

# A symlink to an external directory is also an exact-name collision. Nothing
# may be linked through it into the external directory.
target_link_race="$tmp_root/home-link-race/rime"
link_race_bin="$tmp_root/link-race-bin"
link_race_dest="$target_link_race/cn_dicts/8105.dict.yaml"
link_race_external="$tmp_root/link-race-external"
mkdir "$link_race_bin" "$link_race_external"
printf '%s\n' external-directory-sentinel > "$link_race_external/sentinel"
cp "$TEST_DIR/helpers/ln-collision.sh" "$link_race_bin/ln"
chmod 0755 "$link_race_bin/ln"
if PATH="$link_race_bin:$PATH" \
    RIMES_TEST_REAL_LN="$real_ln" \
    RIMES_TEST_COLLISION_KIND=symlink-directory \
    RIMES_TEST_COLLISION_DEST="$link_race_dest" \
    RIMES_TEST_EXTERNAL_DIR="$link_race_external" \
    "$install" --dest "$target_link_race"; then
    fail "install followed a concurrent destination symlink"
fi
[[ -L "$link_race_dest" ]] || fail "atomic symlink collision removed the user symlink"
assert_content "$link_race_external/sentinel" external-directory-sentinel
external_count=$(find -P "$link_race_external" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d '[:space:]')
[[ "$external_count" == "1" ]] || fail "atomic symlink collision wrote into the external directory"
[[ ! -e "$target_link_race/default.yaml" ]] || fail "atomic symlink collision left managed payload"
[[ ! -e "$target_link_race/.rimes-linux-data-preview" ]] || fail "atomic symlink collision left managed state"
[[ ! -e "$target_link_race/.rimes-linux-data-preview.lock" ]] || fail "atomic symlink collision left transaction lock"

# Rollback must remove only destinations still linked to transaction anchors.
# Preserve both an editor-style atomic replacement and an in-place edit when a
# later collision aborts the install.
target_replace_race="$tmp_root/home-replace-race/rime"
replace_race_bin="$tmp_root/replace-race-bin"
replace_race_trigger="$target_replace_race/lua/v_filter.lua"
replace_race_dest="$target_replace_race/cn_dicts/8105.dict.yaml"
edit_race_dest="$target_replace_race/cn_dicts/base.dict.yaml"
mkdir "$replace_race_bin"
cp "$TEST_DIR/helpers/ln-collision.sh" "$replace_race_bin/ln"
chmod 0755 "$replace_race_bin/ln"
if PATH="$replace_race_bin:$PATH" \
    RIMES_TEST_REAL_LN="$real_ln" \
    RIMES_TEST_COLLISION_KIND=replace-and-edit \
    RIMES_TEST_COLLISION_DEST="$replace_race_trigger" \
    RIMES_TEST_REPLACE_DEST="$replace_race_dest" \
    RIMES_TEST_EDIT_DEST="$edit_race_dest" \
    "$install" --dest "$target_replace_race"; then
    fail "install accepted a later collision after concurrent managed-file edits"
fi
assert_content "$replace_race_dest" concurrent-atomic-replacement
assert_content "$edit_race_dest" concurrent-in-place-edit
assert_content "$replace_race_trigger" later-concurrent-collision
[[ ! -e "$target_replace_race/default.yaml" ]] || fail "rollback left an unchanged managed payload file"
if find -P "$target_replace_race" -type f -name '*.rimes-tmp.*' -print -quit | grep -q .; then
    fail "rollback left an installer-owned hard-link anchor"
fi
[[ ! -e "$target_replace_race/.rimes-linux-data-preview" ]] || fail "edited rollback left managed state"
[[ ! -e "$target_replace_race/.rimes-linux-data-preview.lock" ]] || fail "edited rollback left transaction lock"

# A state directory created after initial preflight must never receive a nested
# temporary state directory. Preserve the external sentinel and roll back the
# complete payload transaction.
target_state_race="$tmp_root/home-state-race/rime"
state_race_bin="$tmp_root/state-race-bin"
state_race_dest="$target_state_race/.rimes-linux-data-preview"
real_mkdir=$(command -v mkdir)
mkdir "$state_race_bin"
cp "$TEST_DIR/helpers/mkdir-state-collision.sh" "$state_race_bin/mkdir"
chmod 0755 "$state_race_bin/mkdir"
if PATH="$state_race_bin:$PATH" \
    RIMES_TEST_REAL_MKDIR="$real_mkdir" \
    RIMES_TEST_STATE_DEST="$state_race_dest" \
    "$install" --dest "$target_state_race"; then
    fail "install accepted a state directory created after preflight"
fi
assert_content "$state_race_dest/external-sentinel" concurrent-user-state
[[ ! -e "$target_state_race/default.yaml" ]] || fail "atomic state collision left managed payload"
[[ ! -e "$state_race_dest/metadata.tsv" ]] || fail "atomic state collision wrote metadata into external state"
if find -P "$state_race_dest" -mindepth 1 -maxdepth 1 -type d -name '.rimes-linux-data-preview.tmp.*' -print -quit | grep -q .; then
    fail "atomic state collision nested temporary state"
fi
[[ ! -e "$target_state_race/.rimes-linux-data-preview.lock" ]] || fail "atomic state collision left transaction lock"

# Try to add an unexpected entry after state has moved under the active lock,
# which is the old preflight/deletion race. The locked state must stay
# read-only, and uninstall must finish without a partial state failure.
target_race="$tmp_root/home-race/rime"
race_status="$tmp_root/state-writer-status"
race_lock="$target_race/.rimes-linux-data-preview.lock"
race_state="$target_race/.rimes-linux-data-preview"
"$install" --dest "$target_race"
(
    deadline=$((SECONDS + 20))
    while [[ ! -d "$race_lock" ]]; do
        if (( SECONDS >= deadline )); then
            printf '%s\n' timeout-lock > "$race_status"
            exit 0
        fi
        sleep 0.001
    done
    deadline=$((SECONDS + 20))
    while [[ ! -d "$race_lock/state" && -d "$race_lock" ]]; do
        if (( SECONDS >= deadline )); then
            printf '%s\n' timeout-state > "$race_status"
            exit 0
        fi
        sleep 0.001
    done
    deadline=$((SECONDS + 20))
    while [[ -e "$target_race/default.yaml" && -d "$race_lock" ]]; do
        if (( SECONDS >= deadline )); then
            printf '%s\n' timeout-payload > "$race_status"
            exit 0
        fi
        sleep 0.001
    done
    if { printf '%s\n' 'concurrent state entry' > "$race_lock/state/unexpected"; } 2>/dev/null; then
        printf '%s\n' wrote > "$race_status"
    else
        printf '%s\n' blocked > "$race_status"
    fi
) &
writer_pid=$!
race_uninstalled=0
if "$uninstall" --dest "$target_race"; then
    race_uninstalled=1
fi
wait "$writer_pid"
[[ -f "$race_status" ]] || fail "concurrent state writer produced no result"
IFS= read -r race_result < "$race_status" || true
case "$race_result" in
    blocked)
        (( race_uninstalled == 1 )) || fail "blocked state writer still caused uninstall failure"
        [[ ! -e "$target_race/default.yaml" ]] || fail "successful raced uninstall retained payload"
        [[ ! -e "$race_state" ]] || fail "successful raced uninstall retained state"
        ;;
    wrote)
        (( race_uninstalled == 0 )) || fail "uninstall accepted a concurrent unexpected state entry"
        [[ ! -e "$target_race/default.yaml" ]] || fail "race writer ran before payload removal started"
        [[ -f "$race_state/metadata.tsv" ]] || fail "raced abort lost retry metadata"
        [[ -f "$race_state/manifest.tsv" ]] || fail "raced abort lost retry manifest"
        rm -f "$race_state/unexpected"
        "$uninstall" --dest "$target_race"
        ;;
    timeout-lock)
        fail "concurrent state writer timed out waiting for the transaction lock"
        ;;
    timeout-state)
        fail "concurrent state writer timed out waiting for locked state"
        ;;
    timeout-payload)
        fail "concurrent state writer timed out waiting for payload removal"
        ;;
    *)
        fail "unexpected concurrent state writer result: $race_result"
        ;;
esac

# The package payload manifest must reject post-package tampering before the
# destination is created.
printf '%s\n' '# tampered' >> "$payload/default.yaml"
target_e="$tmp_root/home-e/rime"
if "$install" --dest "$target_e"; then
    fail "tampered package payload unexpectedly installed"
fi
[[ ! -e "$target_e" ]] || fail "tampered payload created a destination"

printf '%s\n' 'RIMES Linux data/input-schemes preview smoke test passed'
