#!/bin/bash
# =============================================================================
# Verify — and only on an explicit opt-in install — the exact formal RIMES
# package that a user would receive. This is intentionally separate from
# build_install.sh: development installs live in ~/Library/Input Methods while
# formal packages own /Library/Input Methods and retire the development copy.
#
# Usage:
#   scripts/rehearse-release-pkg.sh --pkg /absolute/path/RIMES-X.Y.Z.pkg
#   scripts/rehearse-release-pkg.sh --pkg /absolute/path/RIMES-X.Y.Z.pkg --install-gui
#   scripts/rehearse-release-pkg.sh --pkg /absolute/path/RIMES-X.Y.Z.pkg --install-packagekit
#
# The default is verification only. --install-gui opens the normal macOS
# Installer flow; --install-packagekit invokes the same PackageKit lifecycle
# deterministically with sudo. Both install modes are system-wide and can
# retire the current GUI user's per-user development install.
# =============================================================================
set -euo pipefail

readonly EXPECTED_BUNDLE_ID='com.scholay.inputmethod.isaac'
readonly EXPECTED_MODE_ID='com.scholay.inputmethod.isaac.Hans'
readonly MAX_PACKAGE_BYTES=$((512 * 1024 * 1024))

die() {
    echo "rehearse-release-pkg: $*" >&2
    exit 1
}

read_install_receipt() {
    /usr/sbin/pkgutil --pkg-info "$EXPECTED_BUNDLE_ID" 2>/dev/null || true
}

wait_for_install_receipt() {
    local before="$1" expected_version="$2" timeout_seconds="${3:-900}"
    local deadline=$((SECONDS + timeout_seconds)) current
    while (( SECONDS < deadline )); do
        current="$(read_install_receipt)"
        if [[ -n "$current" && "$current" != "$before" ]] \
            && printf '%s\n' "$current" | /usr/bin/grep -Fxq "version: $expected_version"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

usage() {
    cat <<'USAGE'
Usage:
  scripts/rehearse-release-pkg.sh --pkg /absolute/path/RIMES-X.Y.Z.pkg
  scripts/rehearse-release-pkg.sh --pkg /absolute/path/RIMES-X.Y.Z.pkg --install-gui
  scripts/rehearse-release-pkg.sh --pkg /absolute/path/RIMES-X.Y.Z.pkg --install-packagekit

Verify the exact signed and notarized formal package that users receive.
The default checks only and does not install. The two explicit install modes
are system-wide; they retire the current GUI user's per-user development copy.
USAGE
}

package_path=''
install_mode=''
while (( $# > 0 )); do
    case "$1" in
        --pkg)
            (( $# >= 2 )) || die '--pkg requires an absolute package path'
            package_path="$2"
            shift 2
            ;;
        --install-gui)
            [[ -z "$install_mode" ]] || die 'choose only one install mode'
            install_mode='gui'
            shift
            ;;
        --install-packagekit)
            [[ -z "$install_mode" ]] || die 'choose only one install mode'
            install_mode='packagekit'
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown option: $1"
            ;;
    esac
done

[[ -n "$package_path" ]] || die 'pass --pkg /absolute/path/RIMES-X.Y.Z.pkg'
[[ "$package_path" == /* ]] || die '--pkg must be an absolute path'
[[ -f "$package_path" && ! -L "$package_path" ]] \
    || die "package must be a regular non-symlink file: $package_path"

package_name="${package_path##*/}"
case "$package_name" in
    RIMES-*.pkg) version="${package_name#RIMES-}"; version="${version%.pkg}" ;;
    *) die 'package filename must be RIMES-X.Y.Z.pkg' ;;
esac
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "package must carry a formal X.Y.Z version, got: $package_name"

for required_command in codesign lipo pkgutil plutil spctl xcrun xar xmllint; do
    command -v "$required_command" >/dev/null 2>&1 \
        || die "required macOS tool is unavailable: $required_command"
done

package_bytes="$(/usr/bin/stat -f '%z' "$package_path")"
[[ "$package_bytes" =~ ^[0-9]+$ && "$package_bytes" -gt 0 \
    && "$package_bytes" -le "$MAX_PACKAGE_BYTES" ]] \
    || die 'package is empty or exceeds the 512 MiB release limit'

echo "==> verifying formal release package: $package_name"
package_signature="$(/usr/sbin/pkgutil --check-signature "$package_path" 2>&1)" \
    || die "pkgutil rejected the package:\n$package_signature"
printf '%s\n' "$package_signature"
printf '%s\n' "$package_signature" | /usr/bin/grep -Fq 'Developer ID Installer:' \
    || die 'package is not signed with a Developer ID Installer identity'
/usr/sbin/spctl --assess --type install --verbose=4 "$package_path"
/usr/bin/xcrun stapler validate -v "$package_path"

rehearsal_root="$(/usr/bin/mktemp -d /private/tmp/rimes-release-rehearsal.XXXXXX)"
/bin/chmod 700 "$rehearsal_root"
cleanup() {
    /bin/rm -rf "$rehearsal_root"
}
trap cleanup EXIT

expanded_package="$rehearsal_root/pkg"
/usr/sbin/pkgutil --expand-full "$package_path" "$expanded_package"
distribution="$expanded_package/Distribution"
component="$expanded_package/component.pkg"
payload_app="$component/Payload/RIMES.app"
[[ -f "$distribution" && -d "$component" && ! -L "$component" ]] \
    || die 'package is missing its verified Distribution/component layout'
[[ -d "$payload_app" && ! -L "$payload_app" ]] \
    || die 'package payload does not contain RIMES.app'

[[ "$(/usr/bin/xmllint --xpath \
    "count(/installer-gui-script/pkg-ref[@id='$EXPECTED_BUNDLE_ID' and @version='$version' and text()='#component.pkg'])" \
    "$distribution")" == '1' ]] \
    || die 'package Distribution does not bind the expected identifier/version'

payload_info="$payload_app/Contents/Info.plist"
payload_binary="$payload_app/Contents/MacOS/RIMES"
[[ -f "$payload_info" && -x "$payload_binary" ]] \
    || die 'payload RIMES.app is incomplete'
/usr/bin/plutil -lint "$payload_info" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$payload_info")" == "$EXPECTED_BUNDLE_ID" ]] \
    || die 'payload bundle identifier is unexpected'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$payload_info")" == "$version" ]] \
    || die 'payload app version does not match the package filename'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :TISInputSourceID' "$payload_info")" == "$EXPECTED_BUNDLE_ID" ]] \
    || die 'payload parent input-source identifier is unexpected'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :ComponentInputModeDict:tsVisibleInputModeOrderedArrayKey:0' "$payload_info")" == "$EXPECTED_MODE_ID" ]] \
    || die 'payload visible input-mode identifier is unexpected'
/usr/bin/lipo "$payload_binary" -verify_arch arm64 x86_64
/usr/bin/codesign --verify --deep --strict --verbose=2 "$payload_app"
payload_signature="$(/usr/bin/codesign --display --verbose=4 "$payload_app" 2>&1)"
printf '%s\n' "$payload_signature" | /usr/bin/grep -Fq 'Authority=Developer ID Application:' \
    || die 'payload app is not signed with a Developer ID Application identity'
printf '%s\n' "$payload_signature" | /usr/bin/grep -Eq 'flags=.*runtime' \
    || die 'payload app is missing the hardened runtime'
payload_team_id="$(printf '%s\n' "$payload_signature" \
    | /usr/bin/sed -nE 's/^TeamIdentifier=([A-Z0-9]{10})$/\1/p' | /usr/bin/head -n 1)"
[[ "$payload_team_id" =~ ^[A-Z0-9]{10}$ ]] \
    || die 'payload app does not expose a valid signing Team ID'
printf '%s\n' "$package_signature" | /usr/bin/grep -Fq "($payload_team_id)" \
    || die 'installer and application certificates do not share one Team ID'
/usr/bin/xcrun stapler validate -v "$payload_app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$payload_app"

echo "==> verified Developer ID + notarization for team $payload_team_id"
if [[ -z "$install_mode" ]]; then
    echo '==> verification completed; no system installation was requested.'
    exit 0
fi

cat <<'WARNING'
==> installing the same system-wide package that end users receive
    This may retire the current GUI user's per-user development RIMES install.
    Do not use it with unsaved input-method work or on a Mac where a different
    user depends on a development installation.
WARNING
receipt_before="$(read_install_receipt)"
case "$install_mode" in
    gui)
        /usr/bin/open "$package_path" \
            || die 'could not open the package in macOS Installer'
        # Installer can remain running after its wizard closes. Observe the
        # committed PackageKit receipt instead of waiting for the app to quit.
        echo '==> waiting up to 15 minutes for the updated PackageKit receipt'
        echo '    Complete Installer normally; after cancelling, press Ctrl-C to stop this verification.'
        wait_for_install_receipt "$receipt_before" "$version" \
            || die 'no updated receipt appeared; installation was cancelled, failed, or timed out'
        ;;
    packagekit)
        /usr/bin/sudo /usr/sbin/installer -pkg "$package_path" -target /
        ;;
esac

installed_app='/Library/Input Methods/RIMES.app'
installed_info="$installed_app/Contents/Info.plist"
installed_binary="$installed_app/Contents/MacOS/RIMES"
[[ -d "$installed_app" && ! -L "$installed_app" && -f "$installed_info" && -x "$installed_binary" ]] \
    || die 'Installer did not leave the canonical RIMES.app payload in /Library/Input Methods'
/usr/bin/plutil -lint "$installed_info" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$installed_info")" == "$EXPECTED_BUNDLE_ID" ]] \
    || die 'installed bundle identifier is unexpected'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$installed_info")" == "$version" ]] \
    || die 'installed app version does not match the rehearsed package'
/usr/bin/codesign --verify --deep --strict --verbose=2 "$installed_app"
installed_signature="$(/usr/bin/codesign --display --verbose=4 "$installed_app" 2>&1)"
printf '%s\n' "$installed_signature" | /usr/bin/grep -Fq 'Authority=Developer ID Application:' \
    || die 'installed app is not Developer ID Application signed'
printf '%s\n' "$installed_signature" | /usr/bin/grep -Fq "TeamIdentifier=$payload_team_id" \
    || die 'installed app signing Team ID differs from the verified package payload'
/usr/bin/xcrun stapler validate -v "$installed_app"
/usr/sbin/spctl --assess --type execute --verbose=4 "$installed_app"
receipt="$(/usr/sbin/pkgutil --pkg-info "$EXPECTED_BUNDLE_ID")" \
    || die 'PackageKit receipt is missing after installation'
[[ "$receipt" != "$receipt_before" ]] \
    || die 'PackageKit receipt did not change; the installer may have been cancelled'
printf '%s\n' "$receipt" | /usr/bin/grep -Fq "version: $version" \
    || die 'PackageKit receipt version differs from the rehearsed package'
printf '%s\n' "$receipt" | /usr/bin/grep -Fq 'location: Library/Input Methods' \
    || die 'PackageKit receipt location is unexpected'
"$installed_binary" input-source-install-smoke

echo "==> formal user-path rehearsal passed for RIMES $version"
