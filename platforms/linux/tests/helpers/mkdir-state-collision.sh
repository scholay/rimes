#!/usr/bin/env bash
set -euo pipefail

: "${RIMES_TEST_REAL_MKDIR:?RIMES_TEST_REAL_MKDIR is required}"
: "${RIMES_TEST_STATE_DEST:?RIMES_TEST_STATE_DEST is required}"

if (($# == 1)) && [[ "$1" == "$RIMES_TEST_STATE_DEST" && ! -e "$1" && ! -L "$1" ]]; then
    "$RIMES_TEST_REAL_MKDIR" "$1"
    printf '%s\n' 'concurrent-user-state' > "$1/external-sentinel"
fi

exec "$RIMES_TEST_REAL_MKDIR" "$@"
