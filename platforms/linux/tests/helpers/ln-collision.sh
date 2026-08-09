#!/usr/bin/env bash
set -euo pipefail

: "${RIMES_TEST_REAL_LN:?RIMES_TEST_REAL_LN is required}"
: "${RIMES_TEST_COLLISION_DEST:?RIMES_TEST_COLLISION_DEST is required}"

destination=${!#}
if [[ "$destination" == "$RIMES_TEST_COLLISION_DEST" &&
    ! -e "$destination" && ! -L "$destination" ]]; then
    case "${RIMES_TEST_COLLISION_KIND:-file}" in
        file)
            printf '%s\n' 'concurrent-user-file' > "$destination"
            ;;
        directory)
            "$RIMES_TEST_REAL_MKDIR" "$destination"
            printf '%s\n' 'concurrent-user-directory' > "$destination/sentinel"
            ;;
        symlink-directory)
            : "${RIMES_TEST_EXTERNAL_DIR:?RIMES_TEST_EXTERNAL_DIR is required}"
            "$RIMES_TEST_REAL_LN" -s "$RIMES_TEST_EXTERNAL_DIR" "$destination"
            ;;
        replace-and-edit)
            : "${RIMES_TEST_REPLACE_DEST:?RIMES_TEST_REPLACE_DEST is required}"
            : "${RIMES_TEST_EDIT_DEST:?RIMES_TEST_EDIT_DEST is required}"
            printf '%s\n' 'concurrent-atomic-replacement' > "$RIMES_TEST_REPLACE_DEST.user-tmp"
            mv "$RIMES_TEST_REPLACE_DEST.user-tmp" "$RIMES_TEST_REPLACE_DEST"
            printf '%s\n' 'concurrent-in-place-edit' > "$RIMES_TEST_EDIT_DEST"
            printf '%s\n' 'later-concurrent-collision' > "$destination"
            ;;
        *)
            printf 'unsupported test collision kind: %s\n' "$RIMES_TEST_COLLISION_KIND" >&2
            exit 2
            ;;
    esac
fi

exec "$RIMES_TEST_REAL_LN" "$@"
