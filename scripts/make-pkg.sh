#!/bin/bash
# =============================================================================
# 打包「RIMES」为向导式 .pkg 安装器（装到 /Library/Input Methods 并自动注册）。
#
#   ./scripts/make-pkg.sh <version> <path-to-ETInput.app> [output.pkg]
#
# 与 build_install.sh / CI 组装出来的 ETInput.app 配套使用。正式发布由
# RIMES_INSTALLER_IDENTITY + RIMES_SIGNING_KEYCHAIN 签署最终 product archive；
# 手动演练未提供 identity 时仍可生成 unsigned pkg。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

die() {
    echo "make-pkg: $*" >&2
    exit 1
}

parse_boolean() {
    case "$1" in
        1|true|TRUE|yes|YES) printf 'true' ;;
        0|false|FALSE|no|NO|'') printf 'false' ;;
        *) die "invalid boolean value: $1" ;;
    esac
}

VERSION="${1:?用法: make-pkg.sh <version> <ETInput.app> [out.pkg]}"
APP="${2:?缺少 ETInput.app 路径}"
OUT="${3:-RIMES-${VERSION}.pkg}"
IDENT="com.isaac.inputmethod.RimeBuffer"
MAX_PACKAGE_BYTES=$((512 * 1024 * 1024))

[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] \
    || die "version must be a strict semantic X.Y.Z value"

[[ -d "$APP" ]] || die "找不到 $APP"
[[ -f "$APP/Contents/Info.plist" ]] || die "app is missing Contents/Info.plist"
/usr/bin/plutil -lint "$APP/Contents/Info.plist" >/dev/null
app_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
app_short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$app_bundle_id" == "$IDENT" ]] \
    || die "app bundle id ($app_bundle_id) does not match package identifier ($IDENT)"
[[ "$app_short_version" == "$VERSION" ]] \
    || die "app version ($app_short_version) does not match package version ($VERSION)"

require_signing="$(parse_boolean "${RIMES_REQUIRE_SIGNING:-0}")"
require_notarization="$(parse_boolean "${RIMES_REQUIRE_NOTARIZATION:-0}")"
installer_identity="${RIMES_INSTALLER_IDENTITY:-}"
signed_package=false
if [[ -n "$installer_identity" ]]; then
    signed_package=true
fi
if [[ "$require_signing" == true && "$signed_package" != true ]]; then
    die "formal build requires RIMES_INSTALLER_IDENTITY"
fi

if [[ "$signed_package" == true ]]; then
    [[ "$installer_identity" == "Developer ID Installer:"* ]] \
        || die "refusing non-Developer-ID Installer identity: $installer_identity"
    [[ -n "${RIMES_SIGNING_KEYCHAIN:-}" && -f "$RIMES_SIGNING_KEYCHAIN" ]] \
        || die "signed package requires a valid RIMES_SIGNING_KEYCHAIN"
    [[ "${RIMES_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] \
        || die "signed package requires a valid RIMES_TEAM_ID"
    case "$installer_identity" in
        *"($RIMES_TEAM_ID)") ;;
        *) die "Installer identity does not match RIMES_TEAM_ID" ;;
    esac
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
fi

if [[ "$require_notarization" == true ]]; then
    [[ "$signed_package" == true ]] \
        || die "a notarized release app cannot be placed in an unsigned package"
    /usr/bin/xcrun stapler validate -v "$APP"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build two dependency-free, universal helpers from reviewed source. The
# timeout helper owns a fresh process group so PackageKit cannot be held open by
# orphaned launchctl/sudo descendants. The handoff helper switches away from an
# active legacy RIMES before its old bundle is replaced.
SCRIPT_STAGE="$TMP/scripts"
/usr/bin/ditto --norsrc --noextattr scripts/pkg/scripts "$SCRIPT_STAGE"
helper_build="$TMP/helper-build"
mkdir -p "$helper_build"
for arch in arm64 x86_64; do
    /usr/bin/xcrun --sdk macosx clang \
        -std=c11 -Wall -Wextra -Werror \
        -arch "$arch" -mmacosx-version-min=13.0 \
        scripts/pkg/helpers/rimes-timeout.c \
        -o "$helper_build/rimes-timeout-$arch"
    /usr/bin/xcrun --sdk macosx clang \
        -std=c11 -Wall -Wextra -Werror \
        -arch "$arch" -mmacosx-version-min=13.0 \
        -framework Carbon -framework CoreFoundation \
        scripts/pkg/helpers/rimes-update-handoff.c \
        -o "$helper_build/rimes-update-handoff-$arch"
done
/usr/bin/lipo -create \
    "$helper_build/rimes-timeout-arm64" \
    "$helper_build/rimes-timeout-x86_64" \
    -output "$SCRIPT_STAGE/rimes-timeout"
/usr/bin/lipo -create \
    "$helper_build/rimes-update-handoff-arm64" \
    "$helper_build/rimes-update-handoff-x86_64" \
    -output "$SCRIPT_STAGE/rimes-update-handoff"

application_identity="${RIMES_APPLICATION_IDENTITY:-}"
helper_sign_args=(--force)
if [[ -n "$application_identity" ]]; then
    [[ "$application_identity" == "Developer ID Application:"* ]] \
        || die "refusing non-Developer-ID Application helper identity"
    [[ -n "${RIMES_SIGNING_KEYCHAIN:-}" && -f "$RIMES_SIGNING_KEYCHAIN" ]] \
        || die "signed helpers require a valid RIMES_SIGNING_KEYCHAIN"
    [[ "${RIMES_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] \
        || die "signed helpers require a valid RIMES_TEAM_ID"
    case "$application_identity" in
        *"($RIMES_TEAM_ID)") ;;
        *) die "helper Application identity does not match RIMES_TEAM_ID" ;;
    esac
    helper_sign_args+=(
        --options runtime
        --timestamp
        --keychain "$RIMES_SIGNING_KEYCHAIN"
        --sign "$application_identity"
    )
elif [[ "$require_signing" == true ]]; then
    die "formal build requires RIMES_APPLICATION_IDENTITY for installer helpers"
else
    helper_sign_args+=(--sign -)
fi

for helper in rimes-timeout rimes-update-handoff; do
    helper_path="$SCRIPT_STAGE/$helper"
    /bin/chmod 755 "$helper_path"
    /usr/bin/codesign "${helper_sign_args[@]}" "$helper_path"
    /usr/bin/codesign --verify --strict --verbose=2 "$helper_path"
    /usr/bin/lipo "$helper_path" -verify_arch arm64 x86_64
    if [[ -n "$application_identity" ]]; then
        helper_signature="$(/usr/bin/codesign --display --verbose=4 "$helper_path" 2>&1)"
        printf '%s\n' "$helper_signature" \
            | /usr/bin/grep -Fq "Authority=$application_identity" \
            || die "installer helper has the wrong signing authority: $helper"
        printf '%s\n' "$helper_signature" \
            | /usr/bin/grep -Fq "TeamIdentifier=$RIMES_TEAM_ID" \
            || die "installer helper has the wrong Team ID: $helper"
        printf '%s\n' "$helper_signature" \
            | /usr/bin/grep -Eq 'flags=.*runtime' \
            || die "installer helper lacks hardened runtime: $helper"
    fi
done

# 组件包：把内部兼容路径 ETInput.app 装到 /Library/Input Methods，带 pre/postinstall 注册脚本。
mkdir -p "$TMP/root"
/usr/bin/ditto "$APP" "$TMP/root/ETInput.app"
/bin/chmod 755 "$SCRIPT_STAGE/preinstall" "$SCRIPT_STAGE/postinstall"

if [[ "$signed_package" == true ]]; then
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$TMP/root/ETInput.app"
fi
if [[ "$require_notarization" == true ]]; then
    /usr/bin/xcrun stapler validate -v "$TMP/root/ETInput.app"
fi

pkgbuild \
    --root "$TMP/root" \
    --install-location "/Library/Input Methods" \
    --identifier "$IDENT" \
    --version "$VERSION" \
    --component-plist scripts/pkg/component.plist \
    --scripts "$SCRIPT_STAGE" \
    "$TMP/component.pkg"

# 产品包：套上欢迎/说明/完成三页向导。
distribution="$TMP/distribution.xml"
[[ "$(/usr/bin/grep -Fc '<pkg-ref id="com.isaac.inputmethod.RimeBuffer" version="0"' \
    scripts/pkg/distribution.xml)" == "1" ]] \
    || die "distribution template must contain one version placeholder"
/usr/bin/sed "s/version=\"0\"/version=\"$VERSION\"/" \
    scripts/pkg/distribution.xml >"$distribution"
/usr/bin/xmllint --noout "$distribution"
[[ "$(/usr/bin/xmllint --xpath \
    "count(/installer-gui-script/pkg-ref[@id='$IDENT' and @version='$VERSION' and text()='component.pkg'])" \
    "$distribution")" == "1" ]] \
    || die "could not stamp package version into Distribution"
productbuild_args=(
    --distribution "$distribution"
    --resources scripts/pkg/resources
    --package-path "$TMP"
)
if [[ "$signed_package" == true ]]; then
    productbuild_args+=(
        --sign "$installer_identity"
        --keychain "$RIMES_SIGNING_KEYCHAIN"
        --timestamp
    )
fi
productbuild "${productbuild_args[@]}" "$OUT"
package_bytes="$(/usr/bin/stat -f%z "$OUT")"
[[ "$package_bytes" -gt 0 && "$package_bytes" -le "$MAX_PACKAGE_BYTES" ]] \
    || die "product archive must be a non-empty file no larger than 512 MiB"

# Reopen the exact product archive before it can leave this script. productbuild
# resolves the component reference and stamps its real version into the final
# Distribution; that signed metadata is also what the in-app updater checks to
# reject renamed historical packages.
verify_product="$TMP/verify-product"
/usr/sbin/pkgutil --expand "$OUT" "$verify_product"
[[ -f "$verify_product/Distribution" ]] \
    || die "product archive has no Distribution metadata"
[[ "$(/usr/bin/xmllint --xpath \
    "count(/installer-gui-script/pkg-ref[@id='$IDENT' and @version='$VERSION' and text()='#component.pkg'])" \
    "$verify_product/Distribution")" == "1" ]] \
    || die "product Distribution id/version does not match the app"
verify_component="$verify_product/component.pkg"
[[ -d "$verify_component" && ! -L "$verify_component" ]] \
    || die "product archive has no unique component.pkg"
[[ -f "$verify_component/PackageInfo" ]] \
    || die "component archive has no PackageInfo metadata"
[[ "$(/usr/bin/xmllint --xpath \
    "count(/pkg-info[@identifier='$IDENT' and @version='$VERSION'])" \
    "$verify_component/PackageInfo")" == "1" ]] \
    || die "component PackageInfo id/version does not match the app"
[[ "$(/usr/bin/xmllint --xpath \
    "count(/pkg-info/bundle)" \
    "$verify_component/PackageInfo")" == "1" ]] \
    || die "component PackageInfo must describe exactly one direct payload bundle"
[[ "$(/usr/bin/xmllint --xpath \
    "count(/pkg-info/bundle[@id='$IDENT' and @path='./ETInput.app' and @CFBundleShortVersionString='$VERSION'])" \
    "$verify_component/PackageInfo")" == "1" ]] \
    || die "component payload bundle id/path/version does not match the updater contract"
for required_script in \
    preinstall postinstall rimes-install-common.sh \
    rimes-user-activation-agent.sh rimes-timeout rimes-update-handoff; do
    [[ -e "$verify_component/Scripts/$required_script" ]] \
        || die "component is missing installer script/helper: $required_script"
done

if [[ "$signed_package" == true ]]; then
    signature_output="$(/usr/sbin/pkgutil --check-signature "$OUT" 2>&1)" \
        || die "signed pkg failed pkgutil verification"
    printf '%s\n' "$signature_output"
    printf '%s\n' "$signature_output" | /usr/bin/grep -Fq "$installer_identity" \
        || die "pkg signature does not use the requested Installer identity"
    printf '%s\n' "$signature_output" | /usr/bin/grep -Fq "($RIMES_TEAM_ID)" \
        || die "pkg signature does not use the requested Team ID"
fi

echo "==> 已生成 $OUT ($(du -h "$OUT" | cut -f1))"
