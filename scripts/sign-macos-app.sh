#!/bin/bash
# Sign every bundled Mach-O with one identity before sealing the app bundle.
# Formal builds use Developer ID + hardened runtime + a trusted timestamp;
# non-release/manual builds fall back to an ad-hoc signature.
set -euo pipefail

die() {
    echo "sign-macos-app: $*" >&2
    exit 1
}

parse_boolean() {
    case "$1" in
        1|true|TRUE|yes|YES) printf 'true' ;;
        0|false|FALSE|no|NO|'') printf 'false' ;;
        *) die "invalid boolean value: $1" ;;
    esac
}

app="${1:?usage: sign-macos-app.sh <ETInput.app>}"
[[ -d "$app" ]] || die "app bundle not found: $app"
main_executable="$app/Contents/MacOS/ETInput"
frameworks="$app/Contents/Frameworks"
[[ -f "$main_executable" && -x "$main_executable" ]] \
    || die "missing executable: $main_executable"
[[ -d "$frameworks" ]] || die "missing bundled frameworks directory: $frameworks"

require_signing="$(parse_boolean "${RIMES_REQUIRE_SIGNING:-0}")"
application_identity="${RIMES_APPLICATION_IDENTITY:-}"
formal=false
if [[ -n "$application_identity" ]]; then
    formal=true
fi
if [[ "$require_signing" == true && "$formal" != true ]]; then
    die "formal build requires RIMES_APPLICATION_IDENTITY"
fi

sign_args=(--force)
if [[ "$formal" == true ]]; then
    [[ "$application_identity" == "Developer ID Application:"* ]] \
        || die "refusing non-Developer-ID Application identity: $application_identity"
    [[ -n "${RIMES_SIGNING_KEYCHAIN:-}" && -f "$RIMES_SIGNING_KEYCHAIN" ]] \
        || die "formal build requires a valid RIMES_SIGNING_KEYCHAIN"
    [[ "${RIMES_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] \
        || die "formal build requires a valid RIMES_TEAM_ID"
    case "$application_identity" in
        *"($RIMES_TEAM_ID)") ;;
        *) die "Application identity does not match RIMES_TEAM_ID" ;;
    esac
    sign_args+=(--options runtime --timestamp --keychain "$RIMES_SIGNING_KEYCHAIN" --sign "$application_identity")
else
    sign_args+=(--sign -)
fi

sign_one() {
    /usr/bin/codesign "${sign_args[@]}" "$1"
}

verify_one() {
    local path="$1"
    local details

    /usr/bin/codesign --verify --strict --verbose=2 "$path"
    if [[ "$formal" == true ]]; then
        details="$(/usr/bin/codesign --display --verbose=4 "$path" 2>&1)"
        printf '%s\n' "$details" | /usr/bin/grep -Fq "Authority=$application_identity" \
            || die "unexpected signing authority: $path"
        printf '%s\n' "$details" | /usr/bin/grep -Fq "TeamIdentifier=$RIMES_TEAM_ID" \
            || die "unexpected Team ID: $path"
        printf '%s\n' "$details" | /usr/bin/grep -Eq 'flags=.*runtime' \
            || die "hardened runtime is missing: $path"
    fi
}

# Extended attributes that cannot ship are removed before signing. Never clear
# them after stapling, because the notarization ticket must survive packaging.
/usr/bin/xattr -cr "$app"

mach_o_count=0
while IFS= read -r -d '' candidate; do
    description="$(/usr/bin/file -b "$candidate")"
    if [[ "$description" == *Mach-O* ]]; then
        sign_one "$candidate"
        mach_o_count=$((mach_o_count + 1))
    elif [[ "$candidate" == *.dylib ]]; then
        die "bundled dylib is not a Mach-O file: $candidate"
    fi
done < <(/usr/bin/find "$frameworks" -type f -print0)
[[ "$mach_o_count" -gt 0 ]] || die "no bundled Mach-O runtime was found"

# Sign the executable after its dynamically loaded libraries, then seal the
# outer app last. Deliberately avoid --deep for signing: it can conceal a
# missed or incorrectly signed nested binary.
sign_one "$main_executable"
sign_one "$app"

while IFS= read -r -d '' candidate; do
    description="$(/usr/bin/file -b "$candidate")"
    [[ "$description" == *Mach-O* ]] && verify_one "$candidate"
done < <(/usr/bin/find "$frameworks" -type f -print0)
verify_one "$main_executable"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
verify_one "$app"

if [[ "$formal" == true ]]; then
    echo "Signed $mach_o_count bundled Mach-O files and ETInput.app with $application_identity."
else
    echo "Ad-hoc signed $mach_o_count bundled Mach-O files and ETInput.app (manual build only)."
fi
