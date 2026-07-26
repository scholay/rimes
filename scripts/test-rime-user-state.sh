#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/lib/rime-user-state.sh

TEST_STATE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rimes-user-state-test.XXXXXX")"
cleanup_test_state() {
    if [ -n "${TEST_STATE_ROOT:-}" ] && [ -d "$TEST_STATE_ROOT" ]; then
        rm -rf -- "$TEST_STATE_ROOT"
    fi
}
trap cleanup_test_state EXIT

PROFILE_DIR="$TEST_STATE_ROOT/profile"
IMPORT_DIR="$TEST_STATE_ROOT/import"
EXPECTED_CONFIG="$TEST_STATE_ROOT/expected-openai-compatible.json"
EXPECTED_PLUGIN_CONFIG="$TEST_STATE_ROOT/expected-remarkable-credentials.json"
mkdir -p "$PROFILE_DIR/ai" "$PROFILE_DIR/plugins" "$PROFILE_DIR/stats" \
         "$PROFILE_DIR/learning" "$PROFILE_DIR/build" \
         "$PROFILE_DIR/plugin-config/builtin.remarkable" "$IMPORT_DIR/ai" \
         "$IMPORT_DIR/plugins" "$IMPORT_DIR/stats" "$IMPORT_DIR/learning" \
         "$IMPORT_DIR/plugin-config/builtin.remarkable"

# This is an inert fixture, never a credential read from the developer's
# profile. Keeping it outside PROFILE_DIR gives cmp an independent reference.
printf '%s\n' \
    '{"baseURL":"https://example.invalid/v1","model":"deepseek-v4-flash","apiKey":"test-only-token"}' \
    > "$EXPECTED_CONFIG"
cp "$EXPECTED_CONFIG" "$PROFILE_DIR/ai/openai-compatible.json"
chmod 0700 "$PROFILE_DIR/ai"
chmod 0600 "$PROFILE_DIR/ai/openai-compatible.json"
printf '%s\n' \
    '{"schemaVersion":1,"host":"device.invalid","username":"root","password":"test-only-password"}' \
    > "$EXPECTED_PLUGIN_CONFIG"
cp "$EXPECTED_PLUGIN_CONFIG" \
    "$PROFILE_DIR/plugin-config/builtin.remarkable/credentials.json"
chmod 0700 "$PROFILE_DIR/plugin-config" \
    "$PROFILE_DIR/plugin-config/builtin.remarkable"
chmod 0600 \
    "$PROFILE_DIR/plugin-config/builtin.remarkable/credentials.json"

printf '%s\n' 'installed-plugin' > "$PROFILE_DIR/plugins/marker"
printf '%s\n' 'stats-state' > "$PROFILE_DIR/stats/marker"
printf '%s\n' 'learning-state' > "$PROFILE_DIR/learning/marker"
printf '%s\n' 'gateway-state' > "$PROFILE_DIR/gateway-token"
printf '%s\n' 'identity-state' > "$PROFILE_DIR/remote_identity.key"
printf '%s\n' 'discard-me' > "$PROFILE_DIR/build/cache"
printf '%s\n' 'discard-me' > "$PROFILE_DIR/installation.yaml"
printf '%s\n' 'discard-me' > "$PROFILE_DIR/old.schema.yaml"

# The import source deliberately contains conflicting durable paths. They must
# be excluded while normal Rime files are reseeded.
printf '%s\n' \
    '{"baseURL":"https://wrong.invalid/v1","model":"wrong-model","apiKey":"must-not-win"}' \
    > "$IMPORT_DIR/ai/openai-compatible.json"
printf '%s\n' 'must-not-replace-installed-plugin' > "$IMPORT_DIR/plugins/marker"
printf '%s\n' '{"password":"must-not-replace"}' \
    > "$IMPORT_DIR/plugin-config/builtin.remarkable/credentials.json"
printf '%s\n' 'must-not-replace-stats' > "$IMPORT_DIR/stats/marker"
printf '%s\n' 'must-not-replace-learning' > "$IMPORT_DIR/learning/marker"
printf '%s\n' 'must-not-replace-gateway' > "$IMPORT_DIR/gateway-token"
printf '%s\n' 'must-not-replace-identity' > "$IMPORT_DIR/remote_identity.key"
printf '%s\n' 'new-schema' > "$IMPORT_DIR/default.yaml"

mode_of() {
    case "$(uname -s)" in
        Darwin) stat -f '%Lp' "$1" ;;
        *) stat -c '%a' "$1" ;;
    esac
}

CONFIG_MODE_BEFORE="$(mode_of "$PROFILE_DIR/ai/openai-compatible.json")"
AI_DIR_MODE_BEFORE="$(mode_of "$PROFILE_DIR/ai")"
PLUGIN_CONFIG_MODE_BEFORE="$(
    mode_of "$PROFILE_DIR/plugin-config/builtin.remarkable/credentials.json"
)"
PLUGIN_CONFIG_DIR_MODE_BEFORE="$(
    mode_of "$PROFILE_DIR/plugin-config/builtin.remarkable"
)"

import_rime_user_dir_preserving_product_state "$IMPORT_DIR" "$PROFILE_DIR"

cmp -s "$EXPECTED_CONFIG" "$PROFILE_DIR/ai/openai-compatible.json"
test "$(mode_of "$PROFILE_DIR/ai/openai-compatible.json")" = "$CONFIG_MODE_BEFORE"
test "$(mode_of "$PROFILE_DIR/ai")" = "$AI_DIR_MODE_BEFORE"
cmp -s "$EXPECTED_PLUGIN_CONFIG" \
    "$PROFILE_DIR/plugin-config/builtin.remarkable/credentials.json"
test "$(
    mode_of "$PROFILE_DIR/plugin-config/builtin.remarkable/credentials.json"
)" = "$PLUGIN_CONFIG_MODE_BEFORE"
test "$(mode_of "$PROFILE_DIR/plugin-config/builtin.remarkable")" = \
    "$PLUGIN_CONFIG_DIR_MODE_BEFORE"
test "$(cat "$PROFILE_DIR/plugins/marker")" = 'installed-plugin'
test "$(cat "$PROFILE_DIR/stats/marker")" = 'stats-state'
test "$(cat "$PROFILE_DIR/learning/marker")" = 'learning-state'
test "$(cat "$PROFILE_DIR/gateway-token")" = 'gateway-state'
test "$(cat "$PROFILE_DIR/remote_identity.key")" = 'identity-state'
test "$(cat "$PROFILE_DIR/default.yaml")" = 'new-schema'
test ! -e "$PROFILE_DIR/build"
test ! -e "$PROFILE_DIR/installation.yaml"
test ! -e "$PROFILE_DIR/old.schema.yaml"

# The no-import branch uses the same reset helper. Exercise it separately so a
# machine without Squirrel gets the same persistence guarantee.
mkdir -p "$PROFILE_DIR/build"
printf '%s\n' 'discard-again' > "$PROFILE_DIR/build/cache"
reset_rime_user_dir_preserving_product_state "$PROFILE_DIR"

cmp -s "$EXPECTED_CONFIG" "$PROFILE_DIR/ai/openai-compatible.json"
test "$(mode_of "$PROFILE_DIR/ai/openai-compatible.json")" = "$CONFIG_MODE_BEFORE"
test "$(mode_of "$PROFILE_DIR/ai")" = "$AI_DIR_MODE_BEFORE"
cmp -s "$EXPECTED_PLUGIN_CONFIG" \
    "$PROFILE_DIR/plugin-config/builtin.remarkable/credentials.json"
test "$(
    mode_of "$PROFILE_DIR/plugin-config/builtin.remarkable/credentials.json"
)" = "$PLUGIN_CONFIG_MODE_BEFORE"
test "$(mode_of "$PROFILE_DIR/plugin-config/builtin.remarkable")" = \
    "$PLUGIN_CONFIG_DIR_MODE_BEFORE"
test ! -e "$PROFILE_DIR/build"
test ! -e "$PROFILE_DIR/default.yaml"

SYMLINK_DIR="$TEST_STATE_ROOT/profile-link"
ln -s "$PROFILE_DIR" "$SYMLINK_DIR"
if reset_rime_user_dir_preserving_product_state "$SYMLINK_DIR" 2>/dev/null; then
    echo 'reset unexpectedly accepted a symlinked user directory' >&2
    exit 1
fi

# Keep the regression tied to the live installer entry points, not only to a
# helper that could accidentally become unused later.
grep -Fq 'source scripts/lib/rime-user-state.sh' build_install.sh
grep -Fq 'import_rime_user_dir_preserving_product_state "$HOME/Library/Rime" "$RB_USER"' build_install.sh
grep -Fq 'reset_rime_user_dir_preserving_product_state "$RB_USER"' build_install.sh

echo 'rime-user-state: durable config preserved across import and reset'
