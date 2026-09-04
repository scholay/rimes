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
EXPECTED_PROMPT="$TEST_STATE_ROOT/expected-prompt.md"
EXPECTED_PROMPT_INDEX="$TEST_STATE_ROOT/expected-prompt-index.sqlite"
EXPECTED_MAILBOX_DIR="$TEST_STATE_ROOT/expected-mailbox"
EXPECTED_MARINE_DIR="$TEST_STATE_ROOT/expected-marine-chrome"
EXPECTED_CAPSULE_DIR="$TEST_STATE_ROOT/expected-capsule"
EXPECTED_CAPSULE_SYNC_DIR="$TEST_STATE_ROOT/expected-capsule-sync"
CAPSULE_ENTRY_ID='11111111-1111-4111-8111-111111111111'
CAPSULE_PASSWORD_ID='22222222-2222-4222-8222-222222222222'
CAPSULE_LIBRARY_ID='33333333-3333-4333-8333-333333333333'
CAPSULE_SYNC_CONFIG='config-v1.json'
MARINE_STATE_FILES=(
    marine-chrome-token
    marine-chrome-origin
    marine-chrome-generation
    marine-chrome-credential.lock
)
mkdir -p "$PROFILE_DIR/ai" "$PROFILE_DIR/plugins" "$PROFILE_DIR/preset-plugins" "$PROFILE_DIR/stats" \
         "$PROFILE_DIR/learning" "$PROFILE_DIR/my-prompt/library" \
         "$PROFILE_DIR/mailbox" \
         "$PROFILE_DIR/build" \
         "$PROFILE_DIR/plugin-config/builtin.remarkable" "$IMPORT_DIR/ai" \
         "$IMPORT_DIR/plugins" "$IMPORT_DIR/preset-plugins" "$IMPORT_DIR/stats" "$IMPORT_DIR/learning" \
         "$IMPORT_DIR/my-prompt" "$IMPORT_DIR/mailbox" \
         "$IMPORT_DIR/plugin-config/builtin.remarkable" \
         "$PROFILE_DIR/capsule/entries" "$PROFILE_DIR/capsule/passwords" \
         "$PROFILE_DIR/capsule/assets" "$PROFILE_DIR/capsule-sync" \
         "$EXPECTED_MARINE_DIR"

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

printf '%s\n' '# Research prompt' '' 'Summarize this paper.' > "$EXPECTED_PROMPT"
printf '%s\n' 'SQLite format 3 prompt-index-fixture' > "$EXPECTED_PROMPT_INDEX"
cp "$EXPECTED_PROMPT" "$PROFILE_DIR/my-prompt/library/research.md"
cp "$EXPECTED_PROMPT_INDEX" "$PROFILE_DIR/my-prompt/prompts.sqlite"
printf '%s\n' '{"schemaVersion":1,"nextSequence":2,"threads":[]}' \
    > "$PROFILE_DIR/mailbox/mailbox.json"
chmod 0700 "$PROFILE_DIR/mailbox"
chmod 0600 "$PROFILE_DIR/mailbox/mailbox.json"
cp -R "$PROFILE_DIR/mailbox" "$EXPECTED_MAILBOX_DIR"
printf '%s\n' 'installed-plugin' > "$PROFILE_DIR/plugins/marker"
printf '%s\n' 'installed-preset-plugin' > "$PROFILE_DIR/preset-plugins/marker"
printf '%s\n' 'stats-state' > "$PROFILE_DIR/stats/marker"
printf '%s\n' 'learning-state' > "$PROFILE_DIR/learning/marker"
printf '%s\n' 'gateway-state' > "$PROFILE_DIR/gateway-token"
printf '%s\n' 'identity-state' > "$PROFILE_DIR/remote_identity.key"
for state_file in "${MARINE_STATE_FILES[@]}"; do
    printf 'preserved-%s\n' "$state_file" > "$EXPECTED_MARINE_DIR/$state_file"
    cp "$EXPECTED_MARINE_DIR/$state_file" "$PROFILE_DIR/$state_file"
    chmod 0600 "$PROFILE_DIR/$state_file"
done

# Capsule and its sync controller live beside Rime schema data in the same
# profile, but they are product state. Keep an independent expected tree
# so both import and reset must preserve every byte and reject a same-named tree
# from the Squirrel import source.
cat > "$PROFILE_DIR/capsule/entries/$CAPSULE_ENTRY_ID.md" <<EOF
---
capsule: note
version: 1
id: "$CAPSULE_ENTRY_ID"
title: "Fixture note"
updated_at: "2026-09-01T00:00:00.000Z"
---

Capsule entry bytes must survive reseeding.
EOF
cat > "$PROFILE_DIR/capsule/passwords/$CAPSULE_PASSWORD_ID.md" <<EOF
---
capsule: password
version: 1
id: "$CAPSULE_PASSWORD_ID"
title: "Fixture password"
updated_at: "2026-09-01T00:00:00.000Z"
---

\`\`\`capsule-password
dGVzdC1vbmx5LWNpcGhlcnRleHQ=
\`\`\`
EOF
printf '0123456789abcdef0123456789abcdef' \
    > "$PROFILE_DIR/capsule/master-key"
printf '%s\n' 'seeded' > "$PROFILE_DIR/capsule/content-seed-v1"
printf '%s\n' \
    "{\"version\":1,\"libraryID\":\"$CAPSULE_LIBRARY_ID\"}" \
    > "$PROFILE_DIR/capsule/content-library-v1.json"
printf '%s' 'fixture-image-bytes' \
    > "$PROFILE_DIR/capsule/assets/fixture.png"
printf '%s\n' \
    "{\"version\":1,\"enabled\":true,\"libraryID\":\"$CAPSULE_LIBRARY_ID\",\"folderPath\":\"/fixture/iCloud\",\"bookmark\":\"dGVzdA==\"}" \
    > "$PROFILE_DIR/capsule-sync/$CAPSULE_SYNC_CONFIG"
printf '%s\n' \
    "{\"version\":1,\"libraryID\":\"$CAPSULE_LIBRARY_ID\",\"entries\":{}}" \
    > "$PROFILE_DIR/capsule-sync/state-$CAPSULE_LIBRARY_ID.json"
chmod 0700 "$PROFILE_DIR/capsule" "$PROFILE_DIR/capsule/entries" \
    "$PROFILE_DIR/capsule/passwords" "$PROFILE_DIR/capsule/assets" \
    "$PROFILE_DIR/capsule-sync"
chmod 0600 "$PROFILE_DIR/capsule/entries/$CAPSULE_ENTRY_ID.md" \
    "$PROFILE_DIR/capsule/passwords/$CAPSULE_PASSWORD_ID.md" \
    "$PROFILE_DIR/capsule/master-key" \
    "$PROFILE_DIR/capsule/content-seed-v1" \
    "$PROFILE_DIR/capsule/content-library-v1.json" \
    "$PROFILE_DIR/capsule/assets/fixture.png" \
    "$PROFILE_DIR/capsule-sync/$CAPSULE_SYNC_CONFIG" \
    "$PROFILE_DIR/capsule-sync/state-$CAPSULE_LIBRARY_ID.json"
cp -R "$PROFILE_DIR/capsule" "$EXPECTED_CAPSULE_DIR"
cp -R "$PROFILE_DIR/capsule-sync" "$EXPECTED_CAPSULE_SYNC_DIR"

printf '%s\n' 'discard-me' > "$PROFILE_DIR/build/cache"
printf '%s\n' 'discard-me' > "$PROFILE_DIR/installation.yaml"
printf '%s\n' 'discard-me' > "$PROFILE_DIR/old.schema.yaml"

# The import source deliberately contains conflicting durable paths. They must
# be excluded while normal Rime files are reseeded.
printf '%s\n' \
    '{"baseURL":"https://wrong.invalid/v1","model":"wrong-model","apiKey":"must-not-win"}' \
    > "$IMPORT_DIR/ai/openai-compatible.json"
printf '%s\n' 'must-not-replace-installed-plugin' > "$IMPORT_DIR/plugins/marker"
printf '%s\n' 'must-not-replace-installed-preset-plugin' > "$IMPORT_DIR/preset-plugins/marker"
printf '%s\n' '{"password":"must-not-replace"}' \
    > "$IMPORT_DIR/plugin-config/builtin.remarkable/credentials.json"
printf '%s\n' 'must-not-replace-stats' > "$IMPORT_DIR/stats/marker"
printf '%s\n' 'must-not-replace-learning' > "$IMPORT_DIR/learning/marker"
mkdir -p "$IMPORT_DIR/my-prompt/library"
printf '%s\n' 'must-not-replace-prompt' \
    > "$IMPORT_DIR/my-prompt/library/research.md"
printf '%s\n' 'must-not-replace-prompt-index' \
    > "$IMPORT_DIR/my-prompt/prompts.sqlite"
printf '%s\n' 'must-not-replace-mailbox' \
    > "$IMPORT_DIR/mailbox/mailbox.json"
printf '%s\n' 'must-not-add-mailbox-file' \
    > "$IMPORT_DIR/mailbox/import-only.json"
printf '%s\n' 'must-not-replace-gateway' > "$IMPORT_DIR/gateway-token"
printf '%s\n' 'must-not-replace-identity' > "$IMPORT_DIR/remote_identity.key"
for state_file in "${MARINE_STATE_FILES[@]}"; do
    printf 'must-not-replace-%s\n' "$state_file" > "$IMPORT_DIR/$state_file"
done
mkdir -p "$IMPORT_DIR/capsule/entries" "$IMPORT_DIR/capsule/passwords" \
    "$IMPORT_DIR/capsule-sync"
printf '%s\n' 'must-not-replace-capsule-entry' \
    > "$IMPORT_DIR/capsule/entries/$CAPSULE_ENTRY_ID.md"
printf '%s\n' 'must-not-replace-password-document' \
    > "$IMPORT_DIR/capsule/passwords/$CAPSULE_PASSWORD_ID.md"
printf '%s\n' 'must-not-replace-master-key' \
    > "$IMPORT_DIR/capsule/master-key"
printf '%s\n' 'must-not-replace-content-library-marker' \
    > "$IMPORT_DIR/capsule/content-library-v1.json"
printf '%s\n' 'must-not-add-capsule-file' \
    > "$IMPORT_DIR/capsule/import-only.md"
printf '%s\n' 'must-not-replace-sync-config' \
    > "$IMPORT_DIR/capsule-sync/$CAPSULE_SYNC_CONFIG"
printf '%s\n' 'must-not-replace-sync-state' \
    > "$IMPORT_DIR/capsule-sync/state-$CAPSULE_LIBRARY_ID.json"
printf '%s\n' 'must-not-add-sync-file' \
    > "$IMPORT_DIR/capsule-sync/import-only.json"
printf '%s\n' 'new-schema' > "$IMPORT_DIR/default.yaml"

mode_of() {
    case "$(uname -s)" in
        Darwin) stat -f '%Lp' "$1" ;;
        *) stat -c '%a' "$1" ;;
    esac
}

assert_marine_chrome_state_preserved() {
    local state_file
    for state_file in "${MARINE_STATE_FILES[@]}"; do
        cmp -s "$EXPECTED_MARINE_DIR/$state_file" "$PROFILE_DIR/$state_file"
        test "$(mode_of "$PROFILE_DIR/$state_file")" = '600'
    done
}

assert_capsule_state_preserved() {
    diff -r "$EXPECTED_CAPSULE_DIR" "$PROFILE_DIR/capsule"
    diff -r "$EXPECTED_CAPSULE_SYNC_DIR" "$PROFILE_DIR/capsule-sync"
    test "$(mode_of "$PROFILE_DIR/capsule")" = '700'
    test "$(mode_of "$PROFILE_DIR/capsule/entries/$CAPSULE_ENTRY_ID.md")" = '600'
    test "$(mode_of "$PROFILE_DIR/capsule/passwords/$CAPSULE_PASSWORD_ID.md")" = '600'
    test "$(mode_of "$PROFILE_DIR/capsule/master-key")" = '600'
    test "$(mode_of "$PROFILE_DIR/capsule/content-library-v1.json")" = '600'
    test "$(mode_of "$PROFILE_DIR/capsule-sync")" = '700'
    test "$(mode_of "$PROFILE_DIR/capsule-sync/$CAPSULE_SYNC_CONFIG")" = '600'
    test "$(mode_of "$PROFILE_DIR/capsule-sync/state-$CAPSULE_LIBRARY_ID.json")" = '600'
    test "$(wc -c < "$PROFILE_DIR/capsule/master-key" | tr -d ' ')" = '32'
    test ! -e "$PROFILE_DIR/capsule/import-only.md"
    test ! -e "$PROFILE_DIR/capsule-sync/import-only.json"
}

assert_mailbox_state_preserved() {
    diff -r "$EXPECTED_MAILBOX_DIR" "$PROFILE_DIR/mailbox"
    test "$(mode_of "$PROFILE_DIR/mailbox")" = '700'
    test "$(mode_of "$PROFILE_DIR/mailbox/mailbox.json")" = '600'
    test ! -e "$PROFILE_DIR/mailbox/import-only.json"
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
test "$(cat "$PROFILE_DIR/preset-plugins/marker")" = 'installed-preset-plugin'
test "$(cat "$PROFILE_DIR/stats/marker")" = 'stats-state'
test "$(cat "$PROFILE_DIR/learning/marker")" = 'learning-state'
cmp -s "$EXPECTED_PROMPT" "$PROFILE_DIR/my-prompt/library/research.md"
cmp -s "$EXPECTED_PROMPT_INDEX" "$PROFILE_DIR/my-prompt/prompts.sqlite"
test "$(cat "$PROFILE_DIR/gateway-token")" = 'gateway-state'
test "$(cat "$PROFILE_DIR/remote_identity.key")" = 'identity-state'
assert_marine_chrome_state_preserved
assert_mailbox_state_preserved
assert_capsule_state_preserved
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
cmp -s "$EXPECTED_PROMPT" "$PROFILE_DIR/my-prompt/library/research.md"
cmp -s "$EXPECTED_PROMPT_INDEX" "$PROFILE_DIR/my-prompt/prompts.sqlite"
cmp -s "$EXPECTED_PLUGIN_CONFIG" \
    "$PROFILE_DIR/plugin-config/builtin.remarkable/credentials.json"
test "$(
    mode_of "$PROFILE_DIR/plugin-config/builtin.remarkable/credentials.json"
)" = "$PLUGIN_CONFIG_MODE_BEFORE"
test "$(mode_of "$PROFILE_DIR/plugin-config/builtin.remarkable")" = \
    "$PLUGIN_CONFIG_DIR_MODE_BEFORE"
test "$(cat "$PROFILE_DIR/plugins/marker")" = 'installed-plugin'
test "$(cat "$PROFILE_DIR/preset-plugins/marker")" = 'installed-preset-plugin'
assert_marine_chrome_state_preserved
assert_mailbox_state_preserved
assert_capsule_state_preserved
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

echo 'rime-user-state: durable config, Mailbox, and Capsule state preserved across import and reset'
