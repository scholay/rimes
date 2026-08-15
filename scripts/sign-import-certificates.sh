#!/bin/bash
# Import the two Developer ID identities and stage the App Store Connect API
# key used by notarytool. This script is intentionally fail-closed: it is only
# used by a formal tag build, and every credential must be present.
set -euo pipefail

die() {
    echo "sign-import-certificates: $*" >&2
    exit 1
}

require_env() {
    local name="$1"
    [[ -n "${!name:-}" ]] || die "missing required environment variable: $name"
}

decode_base64() {
    local value="$1"
    local destination="$2"

    if ! printf '%s' "$value" | /usr/bin/base64 --decode >"$destination" 2>/dev/null; then
        # Older macOS releases document -D rather than --decode.
        printf '%s' "$value" | /usr/bin/base64 -D >"$destination"
    fi
}

emit_env() {
    local name="$1"
    local value="$2"

    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] \
        || die "refusing to emit a multiline value for $name"
    printf '%s=%s\n' "$name" "$value" >>"$RIMES_ENV_FILE"
}

for required_name in \
    RIMES_DEVELOPER_ID_APPLICATION_P12_BASE64 \
    RIMES_DEVELOPER_ID_APPLICATION_P12_PASSWORD \
    RIMES_DEVELOPER_ID_INSTALLER_P12_BASE64 \
    RIMES_DEVELOPER_ID_INSTALLER_P12_PASSWORD \
    RIMES_DEVELOPER_TEAM_ID \
    RIMES_NOTARY_KEY_P8_BASE64 \
    RIMES_NOTARY_KEY_ID \
    RIMES_NOTARY_ISSUER_ID; do
    require_env "$required_name"
done

[[ "$RIMES_DEVELOPER_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
    || die "RIMES_DEVELOPER_TEAM_ID must be a 10-character Apple Team ID"
[[ "$RIMES_NOTARY_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] \
    || die "RIMES_NOTARY_KEY_ID must be a 10-character App Store Connect key ID"
[[ "$RIMES_NOTARY_ISSUER_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    || die "RIMES_NOTARY_ISSUER_ID must be a UUID"

RIMES_ENV_FILE="${RIMES_ENV_FILE:-${GITHUB_ENV:-}}"
[[ -n "$RIMES_ENV_FILE" ]] \
    || die "set GITHUB_ENV (GitHub Actions) or RIMES_ENV_FILE (local use)"

signing_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
[[ "$signing_parent" == /* ]] || die "temporary directory must be an absolute path"
signing_dir="$signing_parent/rimes-signing"
keychain="$signing_dir/rimes-signing.keychain-db"
application_p12="$signing_dir/developer-id-application.p12"
installer_p12="$signing_dir/developer-id-installer.p12"
notary_key="$signing_dir/AuthKey_RIMES.p8"
marker="$signing_dir/.rimes-signing-material"

[[ ! -e "$signing_dir" ]] \
    || die "refusing to reuse an existing signing directory: $signing_dir"

umask 077
/bin/mkdir -p "$signing_dir"
: >"$marker"

completed=false
cleanup_failed_import() {
    local status=$?
    trap - EXIT
    if [[ "$completed" != true ]]; then
        /usr/bin/security delete-keychain "$keychain" >/dev/null 2>&1 || true
        /bin/rm -f "$application_p12" "$installer_p12" "$notary_key" "$marker" "$keychain"
        /bin/rmdir "$signing_dir" >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup_failed_import EXIT

decode_base64 "$RIMES_DEVELOPER_ID_APPLICATION_P12_BASE64" "$application_p12"
decode_base64 "$RIMES_DEVELOPER_ID_INSTALLER_P12_BASE64" "$installer_p12"
decode_base64 "$RIMES_NOTARY_KEY_P8_BASE64" "$notary_key"
/bin/chmod 600 "$application_p12" "$installer_p12" "$notary_key"
/usr/bin/grep -q -- 'BEGIN PRIVATE KEY' "$notary_key" \
    || die "decoded notary key is not a PEM private key"

keychain_password="$(/usr/bin/openssl rand -hex 32)"
/usr/bin/security create-keychain -p "$keychain_password" "$keychain"
/usr/bin/security set-keychain-settings -lut 21600 "$keychain"
/usr/bin/security unlock-keychain -p "$keychain_password" "$keychain"

/usr/bin/security import "$application_p12" \
    -k "$keychain" \
    -P "$RIMES_DEVELOPER_ID_APPLICATION_P12_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security >/dev/null
/usr/bin/security import "$installer_p12" \
    -k "$keychain" \
    -P "$RIMES_DEVELOPER_ID_INSTALLER_P12_PASSWORD" \
    -T /usr/bin/productbuild \
    -T /usr/bin/productsign \
    -T /usr/bin/security >/dev/null
/usr/bin/security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s -k "$keychain_password" "$keychain" >/dev/null

identity_output="$(/usr/bin/security find-identity -v "$keychain")"
application_identities=()
installer_identities=()
while IFS= read -r identity; do
    [[ -n "$identity" ]] && application_identities+=("$identity")
done < <(printf '%s\n' "$identity_output" \
    | /usr/bin/sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p')
while IFS= read -r identity; do
    [[ -n "$identity" ]] && installer_identities+=("$identity")
done < <(printf '%s\n' "$identity_output" \
    | /usr/bin/sed -n 's/.*"\(Developer ID Installer:[^"]*\)".*/\1/p')

[[ "${#application_identities[@]}" -eq 1 ]] \
    || die "expected exactly one valid Developer ID Application identity"
[[ "${#installer_identities[@]}" -eq 1 ]] \
    || die "expected exactly one valid Developer ID Installer identity"

application_identity="${application_identities[0]}"
installer_identity="${installer_identities[0]}"
case "$application_identity" in
    *"($RIMES_DEVELOPER_TEAM_ID)") ;;
    *) die "Developer ID Application certificate does not belong to the configured Team ID" ;;
esac
case "$installer_identity" in
    *"($RIMES_DEVELOPER_TEAM_ID)") ;;
    *) die "Developer ID Installer certificate does not belong to the configured Team ID" ;;
esac

# The private keys now live in the temporary keychain. Remove the source p12
# blobs immediately; only the notary API key must remain until both submissions
# have completed.
/bin/rm -f "$application_p12" "$installer_p12"

emit_env RIMES_SIGNING_TEMP_DIR "$signing_dir"
emit_env RIMES_SIGNING_KEYCHAIN "$keychain"
emit_env RIMES_APPLICATION_IDENTITY "$application_identity"
emit_env RIMES_INSTALLER_IDENTITY "$installer_identity"
emit_env RIMES_TEAM_ID "$RIMES_DEVELOPER_TEAM_ID"
emit_env RIMES_NOTARY_KEY_PATH "$notary_key"
emit_env RIMES_NOTARY_KEY_ID "$RIMES_NOTARY_KEY_ID"
emit_env RIMES_NOTARY_ISSUER_ID "$RIMES_NOTARY_ISSUER_ID"

completed=true
trap - EXIT
echo "Imported one Developer ID Application identity and one Developer ID Installer identity."
