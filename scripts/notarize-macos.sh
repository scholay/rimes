#!/bin/bash
# Submit an app (through a temporary ZIP) or installer package to Apple's
# notary service, wait for acceptance, and staple + validate the ticket.
set -euo pipefail

die() {
    echo "notarize-macos: $*" >&2
    exit 1
}

parse_boolean() {
    case "$1" in
        1|true|TRUE|yes|YES) printf 'true' ;;
        0|false|FALSE|no|NO|'') printf 'false' ;;
        *) die "invalid boolean value: $1" ;;
    esac
}

kind="${1:?usage: notarize-macos.sh <app|pkg> <path>}"
target="${2:?usage: notarize-macos.sh <app|pkg> <path>}"
case "$kind" in
    app) [[ -d "$target" ]] || die "app bundle not found: $target" ;;
    pkg) [[ -f "$target" ]] || die "installer package not found: $target" ;;
    *) die "first argument must be app or pkg" ;;
esac

require_notarization="$(parse_boolean "${RIMES_REQUIRE_NOTARIZATION:-0}")"
notary_key="${RIMES_NOTARY_KEY_PATH:-}"
notary_key_id="${RIMES_NOTARY_KEY_ID:-}"
notary_issuer_id="${RIMES_NOTARY_ISSUER_ID:-}"

if [[ -z "$notary_key" && -z "$notary_key_id" && -z "$notary_issuer_id" ]]; then
    if [[ "$require_notarization" == true ]]; then
        die "formal build is missing notarization credentials"
    fi
    echo "Skipping notarization (manual build without credentials)."
    exit 0
fi

[[ -f "$notary_key" ]] || die "RIMES_NOTARY_KEY_PATH does not point to a file"
[[ "$notary_key_id" =~ ^[A-Z0-9]{10}$ ]] || die "invalid RIMES_NOTARY_KEY_ID"
[[ "$notary_issuer_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] \
    || die "invalid RIMES_NOTARY_ISSUER_ID"

if [[ "$kind" == app ]]; then
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$target"
else
    signature_output="$(/usr/sbin/pkgutil --check-signature "$target" 2>&1)" \
        || die "pkg signature verification failed before notarization"
    printf '%s\n' "$signature_output" | /usr/bin/grep -Fq 'Developer ID Installer:' \
        || die "pkg is not signed with Developer ID Installer"
fi

temporary_parent="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
[[ "$temporary_parent" == /* ]] || die "temporary directory must be an absolute path"
temporary_dir="$(/usr/bin/mktemp -d "$temporary_parent/rimes-notary.XXXXXX")"
trap '/bin/rm -rf "$temporary_dir"' EXIT
result_json="$temporary_dir/notary-result.json"

submission="$target"
if [[ "$kind" == app ]]; then
    submission="$temporary_dir/$(/usr/bin/basename "$target").zip"
    /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$target" "$submission"
fi

set +e
/usr/bin/xcrun notarytool submit "$submission" \
    --key "$notary_key" \
    --key-id "$notary_key_id" \
    --issuer "$notary_issuer_id" \
    --wait \
    --output-format json >"$result_json"
submit_status=$?
set -e

notary_status="$(/usr/bin/plutil -extract status raw -o - "$result_json" 2>/dev/null || true)"
submission_id="$(/usr/bin/plutil -extract id raw -o - "$result_json" 2>/dev/null || true)"
if [[ "$submit_status" -ne 0 || "$notary_status" != Accepted ]]; then
    if [[ -n "$submission_id" ]]; then
        /usr/bin/xcrun notarytool log "$submission_id" \
            --key "$notary_key" \
            --key-id "$notary_key_id" \
            --issuer "$notary_issuer_id" || true
    fi
    die "notary submission was not accepted (status=${notary_status:-unknown}, id=${submission_id:-unknown})"
fi

/usr/bin/xcrun stapler staple -v "$target"
/usr/bin/xcrun stapler validate -v "$target"

if [[ "$kind" == app ]]; then
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$target"
else
    /usr/sbin/pkgutil --check-signature "$target"
fi

echo "Apple notarization accepted and stapled (id=$submission_id): $target"
