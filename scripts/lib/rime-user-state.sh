#!/bin/bash

# RIMES keeps connector credentials and other product-owned state beside the
# Rime user data. Development reseeding may replace schemas and imported userdb
# files, but it must never replace or delete these durable paths.

_rimes_prepare_safe_user_state_dir() {
    local user_dir="${1:-}"

    if [ -z "$user_dir" ]; then
        echo "!! refusing to reset an empty Rime user directory" >&2
        return 1
    fi
    while [ "$user_dir" != "/" ] && [ "${user_dir%/}" != "$user_dir" ]; do
        user_dir="${user_dir%/}"
    done
    case "$user_dir" in
        /*) ;;
        *)
            echo "!! Rime user directory must be an absolute path: $user_dir" >&2
            return 1
            ;;
    esac
    case "/${user_dir#/}/" in
        *"/../"*|*"/./"*)
            echo "!! refusing a non-canonical Rime user directory: $user_dir" >&2
            return 1
            ;;
    esac
    if [ -L "$user_dir" ]; then
        echo "!! refusing to update symlinked Rime user directory: $user_dir" >&2
        return 1
    fi

    mkdir -p -- "$user_dir"
    if [ -L "$user_dir" ]; then
        echo "!! refusing to update symlinked Rime user directory: $user_dir" >&2
        return 1
    fi

    local physical_dir
    physical_dir="$(cd -P -- "$user_dir" && pwd -P)"
    if [ "$physical_dir" = "/" ]; then
        echo "!! refusing to reset the filesystem root" >&2
        return 1
    fi
    printf '%s\n' "$physical_dir"
}

reset_rime_user_dir_preserving_product_state() {
    local user_dir
    user_dir="$(_rimes_prepare_safe_user_state_dir "${1:-}")" || return 1

    # Only direct children are considered. Preserved paths are RIMES-owned
    # durable state and must survive schema/userdb reseeding byte-for-byte.
    find "$user_dir" -mindepth 1 -maxdepth 1 \
        ! -name plugins \
        ! -name preset-plugins \
        ! -name plugin-config \
        ! -name ai \
        ! -name stats \
        ! -name learning \
        ! -name my-prompt \
        ! -name gateway-token \
        ! -name marine-chrome-token \
        ! -name marine-chrome-origin \
        ! -name marine-chrome-generation \
        ! -name marine-chrome-credential.lock \
        ! -name remote_identity.key \
        -exec rm -rf -- {} +
}

import_rime_user_dir_preserving_product_state() {
    local source_dir="${1:-}"
    local user_dir

    if [ -z "$source_dir" ] || [ ! -d "$source_dir" ]; then
        echo "!! Rime import source is not a directory: $source_dir" >&2
        return 1
    fi
    case "$source_dir" in
        /*) ;;
        *)
            echo "!! Rime import source must be an absolute path: $source_dir" >&2
            return 1
            ;;
    esac

    source_dir="$(cd -P -- "$source_dir" && pwd -P)"
    user_dir="$(_rimes_prepare_safe_user_state_dir "${2:-}")" || return 1
    if [ "$source_dir" = "$user_dir" ]; then
        echo "!! refusing to reseed a Rime user directory from itself" >&2
        return 1
    fi
    case "$source_dir/" in
        "$user_dir/"*)
            echo "!! refusing to reseed from inside the destination directory" >&2
            return 1
            ;;
    esac
    case "$user_dir/" in
        "$source_dir/"*)
            echo "!! refusing to reseed into the import source directory" >&2
            return 1
            ;;
    esac

    reset_rime_user_dir_preserving_product_state "$user_dir"

    local -a import_excludes=(
        --exclude sync
        --exclude build
        --exclude '*.log'
        --exclude installation.yaml
        --exclude plugins
        --exclude preset-plugins
        --exclude plugin-config
        --exclude ai
        --exclude stats
        --exclude learning
        --exclude my-prompt
        --exclude gateway-token
        --exclude marine-chrome-token
        --exclude marine-chrome-origin
        --exclude marine-chrome-generation
        --exclude marine-chrome-credential.lock
        --exclude remote_identity.key
    )
    rsync -a "${import_excludes[@]}" "$source_dir/" "$user_dir/"
}
