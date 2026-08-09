#!/usr/bin/env bash

# Shared helpers for the RIMES Linux data/input-schemes preview.
# This file is sourced by the command scripts and is not an entry point.

RIMES_STATE_DIR_NAME=".rimes-linux-data-preview"
RIMES_LOCK_DIR_NAME=".rimes-linux-data-preview.lock"
RIMES_STATE_FORMAT="1"

rimes_die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

rimes_warn() {
    printf 'warning: %s\n' "$*" >&2
}

rimes_note() {
    printf '%s\n' "$*"
}

rimes_command_exists() {
    command -v "$1" >/dev/null 2>&1
}

rimes_sha256_file() {
    local file=$1

    if rimes_command_exists sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    elif rimes_command_exists shasum; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif rimes_command_exists openssl; then
        openssl dgst -sha256 "$file" | awk '{print $NF}'
    else
        rimes_die "SHA-256 tool not found (need sha256sum, shasum, or openssl)"
    fi
}

rimes_require_safe_home() {
    if [[ -z "${HOME:-}" || "$HOME" != /* || "$HOME" == "/" ]]; then
        rimes_die "HOME must be an absolute, non-root directory"
    fi
    if [[ "$HOME" == *$'\n'* || "$HOME" == *$'\r'* || "$HOME" == *$'\t'* ]]; then
        rimes_die "HOME contains an unsupported control character"
    fi
}

rimes_xdg_data_home() {
    local value

    rimes_require_safe_home
    value=${XDG_DATA_HOME:-"$HOME/.local/share"}
    [[ "$value" == /* ]] || rimes_die "XDG_DATA_HOME must be absolute"
    printf '%s\n' "${value%/}"
}

rimes_xdg_config_home() {
    local value

    rimes_require_safe_home
    value=${XDG_CONFIG_HOME:-"$HOME/.config"}
    [[ "$value" == /* ]] || rimes_die "XDG_CONFIG_HOME must be absolute"
    printf '%s\n' "${value%/}"
}

rimes_path_for_frontend() {
    local frontend=$1
    local base

    case "$frontend" in
        fcitx5)
            base=$(rimes_xdg_data_home)
            printf '%s/fcitx5/rime\n' "$base"
            ;;
        fcitx5-flatpak)
            rimes_require_safe_home
            printf '%s/.var/app/org.fcitx.Fcitx5/data/fcitx5/rime\n' "$HOME"
            ;;
        ibus)
            base=$(rimes_xdg_config_home)
            printf '%s/ibus/rime\n' "$base"
            ;;
        *)
            rimes_die "unsupported frontend '$frontend'"
            ;;
    esac
}

rimes_add_unique_candidate() {
    local value=$1
    local existing

    for existing in "${RIMES_CANDIDATES[@]:-}"; do
        [[ "$existing" == "$value" ]] && return 0
    done
    RIMES_CANDIDATES+=("$value")
}

rimes_auto_detect_frontend() {
    local modules
    local standard_fcitx
    local flatpak_fcitx
    local ibus_path
    local have_native_fcitx=0
    local have_flatpak_fcitx=0
    local have_ibus=0

    RIMES_CANDIDATES=()
    modules="${XMODIFIERS:-} ${GTK_IM_MODULE:-} ${QT_IM_MODULE:-}"

    if [[ "$modules" == *fcitx* ]]; then
        rimes_add_unique_candidate fcitx5
    fi
    if [[ "$modules" == *ibus* ]]; then
        rimes_add_unique_candidate ibus
    fi
    if (( ${#RIMES_CANDIDATES[@]} > 1 )); then
        rimes_die "environment points to both Fcitx and IBus; pass --frontend"
    fi

    standard_fcitx=$(rimes_path_for_frontend fcitx5)
    flatpak_fcitx=$(rimes_path_for_frontend fcitx5-flatpak)
    ibus_path=$(rimes_path_for_frontend ibus)

    if [[ -d "$standard_fcitx" ]]; then
        rimes_add_unique_candidate fcitx5
    fi
    if [[ -d "$flatpak_fcitx" ]]; then
        rimes_add_unique_candidate fcitx5-flatpak
    fi
    if [[ -d "$ibus_path" ]]; then
        rimes_add_unique_candidate ibus
    fi

    if (( ${#RIMES_CANDIDATES[@]} == 0 )); then
        rimes_command_exists fcitx5 && have_native_fcitx=1
        rimes_command_exists ibus-daemon && have_ibus=1
        if rimes_command_exists flatpak &&
            flatpak info --user org.fcitx.Fcitx5 >/dev/null 2>&1; then
            have_flatpak_fcitx=1
        fi

        (( have_native_fcitx == 1 )) && rimes_add_unique_candidate fcitx5
        (( have_flatpak_fcitx == 1 )) && rimes_add_unique_candidate fcitx5-flatpak
        (( have_ibus == 1 )) && rimes_add_unique_candidate ibus
    fi

    case ${#RIMES_CANDIDATES[@]} in
        1)
            printf '%s\n' "${RIMES_CANDIDATES[0]}"
            ;;
        0)
            rimes_die "could not detect Fcitx5 Rime or IBus Rime; pass --frontend or --dest"
            ;;
        *)
            rimes_die "multiple Linux input frontends detected; pass --frontend or --dest"
            ;;
    esac
}

rimes_validate_destination() {
    local target=${1%/}
    local probe
    local suffix=""
    local component
    local physical_base

    [[ "$target" == /* ]] || rimes_die "--dest must be an absolute path"
    [[ "$target" != "/" && "$target" != "/rime" ]] ||
        rimes_die "refusing unsafe destination '$target'"
    [[ "$target" != *$'\n'* && "$target" != *$'\r'* && "$target" != *$'\t'* ]] ||
        rimes_die "destination contains an unsupported control character"
    [[ "$target" != *"/../"* && "$target" != */.. ]] ||
        rimes_die "destination must not contain a '..' path component"
    while [[ "$target" == *"//"* ]]; do
        target=${target//\/\//\/}
    done
    while [[ "$target" == *"/./"* ]]; do
        target=${target//\/.\//\/}
    done
    target=${target%/.}
    [[ "$target" != "/" && "$target" != "/rime" ]] ||
        rimes_die "refusing unsafe destination '$target'"
    [[ "$target" != *"/../"* && "$target" != */.. ]] ||
        rimes_die "destination must not contain a '..' path component"
    [[ "${target##*/}" == "rime" ]] ||
        rimes_die "destination must name a Rime user directory (its final component must be 'rime')"
    [[ ! -L "$target" ]] || rimes_die "refusing symlink destination '$target'"
    if [[ -e "$target" && ! -d "$target" ]]; then
        rimes_die "destination exists but is not a directory: $target"
    fi

    # Resolve existing parent symlinks (for example macOS /var -> /private/var)
    # while retaining not-yet-created suffix components. This keeps metadata
    # stable across install/verify/uninstall without permitting '..'.
    probe=$target
    while [[ ! -d "$probe" ]]; do
        component=${probe##*/}
        suffix="/$component$suffix"
        probe=${probe%/*}
        [[ -n "$probe" ]] || probe=/
    done
    physical_base=$(CDPATH= cd -- "$probe" && pwd -P)
    target="${physical_base%/}$suffix"

    printf '%s\n' "$target"
}

rimes_resolve_destination() {
    local requested_frontend=$1
    local requested_dest=$2
    local frontend
    local target

    case "$requested_frontend" in
        auto|fcitx5|fcitx5-flatpak|ibus) ;;
        *) rimes_die "--frontend must be auto, fcitx5, fcitx5-flatpak, or ibus" ;;
    esac

    if [[ -n "$requested_dest" ]]; then
        target=$(rimes_validate_destination "$requested_dest")
        if [[ "$requested_frontend" == "auto" ]]; then
            frontend=custom
        else
            frontend=$requested_frontend
        fi
    else
        frontend=$requested_frontend
        if [[ "$frontend" == "auto" ]]; then
            frontend=$(rimes_auto_detect_frontend)
        fi
        target=$(rimes_path_for_frontend "$frontend")
        target=$(rimes_validate_destination "$target")
    fi

    RIMES_RESOLVED_FRONTEND=$frontend
    RIMES_RESOLVED_TARGET=$target
}

rimes_validate_relative_path() {
    local relative=$1

    [[ -n "$relative" && "$relative" != /* ]] || return 1
    [[ "$relative" != *$'\n'* && "$relative" != *$'\r'* &&
        "$relative" != *$'\t'* && "$relative" != *\\* ]] || return 1
    [[ "$relative" != *"//"* && "$relative" != ".." &&
        "$relative" != ../* && "$relative" != */../* && "$relative" != */.. &&
        "$relative" != "." && "$relative" != ./* &&
        "$relative" != */./* && "$relative" != */. ]] || return 1
    return 0
}

rimes_path_is_reserved() {
    local relative=$1

    case "/$relative/" in
        */build/*|*/userdb/*|*/sync/*|*/trash/*|*.userdb/*)
            return 0
            ;;
    esac
    case "$relative" in
        installation.yaml|user.yaml|*.userdb|*.bin|*.log|*.lock|*.LOCK)
            return 0
            ;;
    esac
    return 1
}

rimes_path_has_no_symlink_components() {
    local target=$1
    local relative=$2
    local current=$target
    local old_ifs=$IFS
    local component
    local -a components

    [[ ! -L "$current" ]] || return 1

    IFS='/'
    read -r -a components <<< "$relative"
    IFS=$old_ifs
    for component in "${components[@]}"; do
        current="$current/$component"
        [[ ! -L "$current" ]] || return 1
    done
    return 0
}

rimes_assert_no_symlink_components() {
    local target=$1
    local relative=$2

    rimes_path_has_no_symlink_components "$target" "$relative" ||
        rimes_die "refusing destination path through a symbolic link: $target/$relative"
}

rimes_link_exact_no_replace() {
    local source=$1
    local destination=$2

    # GNU coreutils and BusyBox provide -T, which makes LINK_NAME an exact
    # leaf instead of treating a directory (or a symlink to one) as a target
    # directory. BSD ln lacks that flag, so use Python's link(2) wrapper as a
    # safe fallback for macOS smoke tests and non-coreutils Linux systems.
    # Both paths fail atomically when any filesystem entry already exists.
    if ln -T -- "$source" "$destination" 2>/dev/null; then
        return 0
    fi
    if rimes_command_exists python3 &&
        python3 -c 'import os, sys; os.link(sys.argv[1], sys.argv[2], follow_symlinks=False)' \
            "$source" "$destination" 2>/dev/null; then
        return 0
    fi
    return 1
}

rimes_find_payload_dir() {
    local script_dir=$1
    local packaged="$script_dir/../data/rime-data"
    local repository="$script_dir/../../../rime-data"
    local repo_root="$script_dir/../../.."
    local preview_tool="$script_dir/../../../scripts/platform-preview/preview.py"
    local staging_root
    local temp_base=${TMPDIR:-/tmp}

    if [[ -d "$packaged" ]]; then
        (CDPATH= cd -- "$packaged" && pwd -P)
    elif [[ -d "$repository" ]]; then
        rimes_command_exists python3 ||
            rimes_die "python3 is required to stage the reviewed repository payload"
        [[ -f "$preview_tool" ]] ||
            rimes_die "reviewed platform-preview staging tool not found: $preview_tool"
        repo_root=$(CDPATH= cd -- "$repo_root" && pwd -P)
        staging_root=$(mktemp -d "${temp_base%/}/rimes-linux-payload.XXXXXX")
        if ! python3 "$preview_tool" stage \
            --repo-root "$repo_root" \
            --output-dir "$staging_root/rime-data" >&2; then
            rimes_cleanup_ephemeral_payload "$staging_root/rime-data"
            rimes_die "reviewed platform-preview staging failed"
        fi
        printf '%s/rime-data\n' "$staging_root"
    else
        rimes_die "rime-data payload not found beside the package or in the repository"
    fi
}

rimes_cleanup_ephemeral_payload() {
    local payload_dir=$1
    local staging_root=${payload_dir%/rime-data}
    local temp_base=${TMPDIR:-/tmp}

    case "$staging_root" in
        "${temp_base%/}"/rimes-linux-payload.*)
            rm -rf "$staging_root"
            ;;
    esac
}

rimes_find_version_file() {
    local script_dir=$1
    local file="$script_dir/../VERSION"

    [[ -f "$file" ]] || rimes_die "VERSION file not found"
    printf '%s\n' "$file"
}

rimes_read_version() {
    local script_dir=$1
    local file
    local version

    file=$(rimes_find_version_file "$script_dir")
    IFS= read -r version < "$file" || true
    [[ "$version" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] ||
        rimes_die "invalid preview version in $file"
    printf '%s\n' "$version"
}

rimes_verify_packaged_payload() {
    local payload_dir=$1
    local require_manifest=${2:-0}
    local package_manifest="${payload_dir%/}/../PAYLOAD-MANIFEST.tsv"
    local expected
    local relative
    local extra
    local actual
    local line
    local entries=0
    local actual_count
    local matches

    if [[ ! -f "$package_manifest" || -L "$package_manifest" ]]; then
        if [[ "$require_manifest" == "1" ]]; then
            rimes_die "packaged payload manifest is missing or unsafe"
        fi
        return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *$'\t'* ]] || rimes_die "invalid packaged payload manifest"
        expected=${line%%$'\t'*}
        relative=${line#*$'\t'}
        extra=${relative#*$'\t'}
        [[ "$extra" == "$relative" ]] || rimes_die "invalid packaged payload manifest entry"
        [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] ||
            rimes_die "invalid SHA-256 in packaged payload manifest"
        rimes_validate_relative_path "$relative" ||
            rimes_die "unsafe path in packaged payload manifest: $relative"
        rimes_path_is_reserved "$relative" &&
            rimes_die "reserved Rime runtime path in packaged payload: $relative"
        [[ -f "$payload_dir/$relative" && ! -L "$payload_dir/$relative" ]] ||
            rimes_die "packaged payload file is missing or unsafe: $relative"
        actual=$(rimes_sha256_file "$payload_dir/$relative")
        [[ "$actual" == "$expected" ]] ||
            rimes_die "packaged payload checksum mismatch: $relative"
        entries=$((entries + 1))
    done < "$package_manifest"

    actual_count=$(find -P "$payload_dir" -type f | wc -l | tr -d '[:space:]')
    [[ "$entries" == "$actual_count" ]] ||
        rimes_die "packaged payload manifest does not cover every file"
    while IFS= read -r actual; do
        relative=${actual#"$payload_dir"/}
        matches=$(awk -F '\t' -v wanted="$relative" \
            '$2 == wanted { count += 1 } END { print count + 0 }' \
            "$package_manifest")
        [[ "$matches" == "1" ]] ||
            rimes_die "packaged payload manifest is missing or duplicates: $relative"
    done < <(find -P "$payload_dir" -type f -print | LC_ALL=C sort)
}

rimes_metadata_value() {
    local metadata=$1
    local wanted=$2
    local key
    local value

    while IFS=$'\t' read -r key value; do
        if [[ "$key" == "$wanted" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done < "$metadata"
    return 1
}

rimes_deploy_frontend() {
    local frontend=$1
    local target=$2

    case "$frontend" in
        fcitx5)
            rimes_command_exists fcitx5-remote ||
                rimes_die "fcitx5-remote is unavailable; data is installed but not deployed"
            rimes_note "Reloading Fcitx5; this asks fcitx5-rime to re-read changed data..."
            fcitx5-remote -r
            ;;
        ibus)
            rimes_command_exists ibus ||
                rimes_die "ibus command is unavailable; data is installed but not deployed"
            [[ -d "$target" && ! -L "$target" ]] ||
                rimes_die "IBus Rime user directory is missing or unsafe: $target"
            rimes_note "Restarting IBus to trigger Rime deployment..."
            touch "$target"
            ibus restart
            ;;
        fcitx5-flatpak)
            rimes_die "automatic Flatpak Fcitx5 restart is intentionally disabled; use the Rime Deploy action in the Fcitx5 UI"
            ;;
        custom)
            rimes_die "cannot deploy an arbitrary --dest; deploy from the selected Rime frontend"
            ;;
        *)
            rimes_die "unknown installed frontend '$frontend'"
            ;;
    esac
}

rimes_check_frontend_runtime() {
    local frontend=$1

    case "$frontend" in
        fcitx5)
            rimes_command_exists fcitx5 || return 1
            rimes_command_exists fcitx5-remote || return 1
            ;;
        fcitx5-flatpak)
            rimes_command_exists flatpak || return 1
            flatpak info --user org.fcitx.Fcitx5 >/dev/null 2>&1 || return 1
            ;;
        ibus)
            rimes_command_exists ibus-daemon || return 1
            rimes_command_exists ibus || return 1
            ;;
        custom)
            return 1
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}
