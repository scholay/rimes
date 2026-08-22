#!/bin/bash
# Builds RIMES as a SELF-CONTAINED IMK input method. ETInput.app remains the
# frozen internal compatibility path used by existing installs and updates:
# librime + the Rime shared data are packaged inside, so no separate Squirrel
# install is needed. Installs into the per-user Input Methods folder and
# registers + enables + selects it so it shows in System Settings / the input menu.
#
# IMPORTANT invariants (learned the hard way — see RELEASE.md):
#   * The .app directory remains ETInput.app. The RIMES product name lives in
#     CFBundleName/CFBundleDisplayName + InfoPlist.strings. Renaming the path
#     would strand old updaters and duplicate the same TIS identity.
#   * There must be EXACTLY ONE bundle with this id on disk. A stray copy (e.g.
#     left in the repo working tree) registers the same input-source id at a
#     second path and poisons TIS/LaunchServices → blank/greyed picker row. So
#     we assemble in a throwaway staging dir and delete it after installing.
#
# (The SPM target / source dir stay named "RimeBuffer" — internal codename / repo;
# the shipped product is RIMES.)
set -euo pipefail
cd "$(dirname "$0")"
source scripts/lib/rime-user-state.sh

CONFIG="${1:-release}"
APP="ETInput.app"                   # Frozen compatibility path; display name is RIMES.
EXE="ETInput"
STAGE=".build/stage"                # assemble here, not in the repo root
APP_PATH="$STAGE/$APP"
DEST="$HOME/Library/Input Methods/$APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# A system-wide release copy and this per-user dev copy would advertise the
# same bundle/input-source IDs. Stop before creating that poisoned duplicate;
# remove the pkg-installed copy explicitly before returning to dev installs.
for system_copy in "/Library/Input Methods/ETInput.app" \
                   "/Library/Input Methods/RimeBuffer.app" \
                   "/Library/Input Methods/Enter输入法.app" \
                   "/Library/Input Methods/恩特输入法.app"; do
    [ -e "$system_copy" ] || continue
    system_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$system_copy/Contents/Info.plist" 2>/dev/null || true)"
    case "$system_id" in
        com.isaac.inputmethod.RimeBuffer|com.isaac.inputmethod.ETInput)
            echo "!! found system-wide duplicate: $system_copy"
            echo "   remove it first: sudo rm -rf '$system_copy'"
            exit 1
            ;;
    esac
done

# Fetch the bundled librime runtime (cached in Vendor/, not committed to git).
./scripts/fetch-rime.sh

# Its OWN Rime user dir (never fights Squirrel over the userdb LevelDB lock).
# IMPORT: if you have a live ~/Library/Rime (Squirrel), carry your real config
# in — your schemes, learned userdb, custom_phrase, lua, dicts — so RIMES uses
# your actual setup. We then force RIMES's five ordinary product schemas
# (雾凇全拼、自然码双拼、小鹤双拼、五笔86、英文) + 9 candidates; the optional
# 并击 schema is added only when its extension is enabled. Everything else you
# have is preserved. With no ~/Library/Rime, the app deploys from the bundled
# schemas instead. RB_KEEP_USERDB=1 skips reseeding.
RB_USER="$HOME/Library/RimeBuffer"
if [ -L "$RB_USER" ]; then
    echo "!! refusing to update symlinked RimeBuffer user directory: $RB_USER"
    exit 1
fi
if [ "${RB_KEEP_USERDB:-0}" != "1" ]; then
    if [ -d "$HOME/Library/Rime" ]; then
        echo "==> importing your ~/Library/Rime into $RB_USER (schemes, userdb, custom_phrase, lua…)"
        import_rime_user_dir_preserving_product_state "$HOME/Library/Rime" "$RB_USER"
    else
        echo "==> no ~/Library/Rime; deploying from the bundled schemas"
        reset_rime_user_dir_preserving_product_state "$RB_USER"
    fi
    # Enforce RIMES's five ordinary product schemas + 9 candidates. The optional
    # chord schema is reconciled by the extension state at startup. Your learned
    # userdb and unrelated tweaks are kept.
    cp rime-data/default.custom.yaml "$RB_USER/default.custom.yaml"
fi

# Product-owned schemas must advance even when the learned userdb is kept.
# Rime gives a root user-data schema precedence over the app's SharedSupport
# copy, and older installs imported exactly such a my_combo.schema.yaml from
# Squirrel.  Keep user customisations in my_combo.custom.yaml (Rime's standard
# overlay); refresh only the versioned base schema here.
mkdir -p "$RB_USER"
install -m 0644 rime-data/my_combo.schema.yaml "$RB_USER/my_combo.schema.yaml"

# GRDB 7.11 requires a newer toolchain than the Command Line Tools Swift on
# some supported Macs. Allow CI/developers to pin one, otherwise prefer the
# keg-only Homebrew Swift when present and fall back to the active Xcode Swift.
if [[ -n "${RB_SWIFT_BIN:-}" ]]; then
    RIMES_SWIFT_BIN="$RB_SWIFT_BIN"
elif [[ -x /opt/homebrew/opt/swift/bin/swift ]]; then
    RIMES_SWIFT_BIN=/opt/homebrew/opt/swift/bin/swift
elif [[ -x /usr/local/opt/swift/bin/swift ]]; then
    RIMES_SWIFT_BIN=/usr/local/opt/swift/bin/swift
else
    RIMES_SWIFT_BIN="$(command -v swift || true)"
fi
if [[ -z "$RIMES_SWIFT_BIN" || ! -x "$RIMES_SWIFT_BIN" ]]; then
    echo "!! no usable Swift toolchain found"
    exit 1
fi

# Homebrew/upstream Swift may compile against the selected CLT SDK while
# recording the deployment target as both minOS and SDK in LC_BUILD_VERSION.
# AppKit uses that SDK field for linked-on-or-after rendering behavior, so make
# both platform versions explicit from their authoritative sources.
RIMES_PACKAGE_DESCRIPTION="$("$RIMES_SWIFT_BIN" package dump-package)"
RIMES_PACKAGE_PLATFORM="$(
    printf '%s' "$RIMES_PACKAGE_DESCRIPTION" |
        /usr/bin/plutil -extract platforms.0.platformName raw -o - -
)"
RIMES_DEPLOYMENT_TARGET="$(
    printf '%s' "$RIMES_PACKAGE_DESCRIPTION" |
        /usr/bin/plutil -extract platforms.0.version raw -o - -
)"
RIMES_MACOS_SDK_PATH="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
RIMES_MACOS_SDK_VERSION="$(/usr/bin/xcrun --sdk macosx --show-sdk-version)"

if [[ "$RIMES_PACKAGE_PLATFORM" != "macos" ||
      ! "$RIMES_DEPLOYMENT_TARGET" =~ ^[0-9]+([.][0-9]+){1,2}$ ||
      ! "$RIMES_MACOS_SDK_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
    echo "!! could not resolve macOS deployment/SDK versions safely"
    exit 1
fi

echo "==> swift build ($CONFIG, macOS $RIMES_DEPLOYMENT_TARGET / SDK $RIMES_MACOS_SDK_VERSION)"
"$RIMES_SWIFT_BIN" build -c "$CONFIG" \
    --sdk "$RIMES_MACOS_SDK_PATH" \
    -Xlinker -platform_version \
    -Xlinker macos \
    -Xlinker "$RIMES_DEPLOYMENT_TARGET" \
    -Xlinker "$RIMES_MACOS_SDK_VERSION"

BIN=".build/$CONFIG/RimeBuffer"
RIMES_BUILD_VERSION_INFO="$(/usr/bin/vtool -show-build "$BIN")"
RIMES_BUILT_MIN_OS="$(
    printf '%s\n' "$RIMES_BUILD_VERSION_INFO" |
        awk '$1 == "minos" { print $2; exit }'
)"
RIMES_BUILT_SDK="$(
    printf '%s\n' "$RIMES_BUILD_VERSION_INFO" |
        awk '$1 == "sdk" { print $2; exit }'
)"
if [[ "$RIMES_BUILT_MIN_OS" != "$RIMES_DEPLOYMENT_TARGET" ||
      "$RIMES_BUILT_SDK" != "$RIMES_MACOS_SDK_VERSION" ]]; then
    echo "!! invalid LC_BUILD_VERSION: minOS=$RIMES_BUILT_MIN_OS SDK=$RIMES_BUILT_SDK"
    exit 1
fi

echo "==> assembling $APP (in $STAGE)"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" \
         "$APP_PATH/Contents/Frameworks" "$APP_PATH/Contents/SharedSupport"
cp "$BIN" "$APP_PATH/Contents/MacOS/$EXE"
cp Info.plist "$APP_PATH/Contents/Info.plist"

# Bump CFBundleVersion on the installed copy each build so LaunchServices/TIS
# re-read the bundle's metadata instead of serving a stale cache. (Source
# Info.plist is untouched, so git stays clean.)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%s)" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true
# A complete .app has a PkgInfo (both Squirrel and Sogou ship one).
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"

# Bundle the self-contained runtime: librime + plugins + Rime shared data.
cp -R Vendor/rime/Frameworks/* "$APP_PATH/Contents/Frameworks/"
cp -R Vendor/rime/SharedSupport/* "$APP_PATH/Contents/SharedSupport/"

# Ship no unrelated stock input schemes. The two non-product schemas copied
# below (melt_eng/radical_pinyin) are required hidden dependencies and are not
# present in schema_list/F4.
find "$APP_PATH/Contents/SharedSupport" -maxdepth 1 -type f -name '*.schema.yaml' -delete

# Overlay OUR Rime schemas (并击、自然码双拼、雾凇拼音、英文，以及它们的隐藏依赖)
# onto the stock SharedSupport so a fresh install deploys the real schemas — not
# just default luna_pinyin. This works WITHOUT a separate Squirrel/~/Library/Rime. The secret
# rime_ai.local.json is intentionally NOT bundled (only rime_ai.example.json).
cp -R rime-data/* "$APP_PATH/Contents/SharedSupport/"

# App icon, if it's been generated.
if [ -f "Logo/AppIcon.icns" ]; then
    cp "Logo/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi

# Localized input-source display name (RIMES) + the input-mode menu icon.
# Without the .lproj the source shows its raw id; without the icon it renders as
# a blank row and won't enable.
cp -R Resources/*.lproj "$APP_PATH/Contents/Resources/" 2>/dev/null || true
cp Resources/etinput.pdf "$APP_PATH/Contents/Resources/" 2>/dev/null || true
cp Resources/etinput-menu.pdf "$APP_PATH/Contents/Resources/" 2>/dev/null || true
cp Resources/menubar-template.png "$APP_PATH/Contents/Resources/" 2>/dev/null || true
cp THIRD_PARTY_NOTICES.md "$APP_PATH/Contents/Resources/"

# Ad-hoc sign. --deep now that we have nested dylibs (librime + plugins).
echo "==> ad-hoc signing (deep)"
codesign --force --deep --sign - "$APP_PATH"

echo "==> handing active clients to a safe fallback input source"
if ! /bin/launchctl asuser "$(id -u)" "$APP_PATH/Contents/MacOS/$EXE" --prepare-update; then
    echo "!! could not leave the active RIMES source safely; refusing a hot replacement"
    exit 1
fi
sleep 0.5

echo "==> purging stray/duplicate registrations (same id at other paths poisons the picker)"
pkill -x "$EXE" 2>/dev/null || true
pkill -x RimeBuffer 2>/dev/null || true
sleep 0.5
# Any leftover copies in the repo tree or a previous CJK-named install.
for stray in "Enter输入法.app" "恩特输入法.app" "ETInput.app" "RimeBuffer.app" \
             "$HOME/Library/Input Methods/Enter输入法.app" \
             "$HOME/Library/Input Methods/恩特输入法.app" \
             "$HOME/Library/Input Methods/RimeBuffer.app" \
             "$HOME/Documents/05-dev/apps/rime-buffer/RimeBuffer.app"; do
    if [ -e "$stray" ]; then
        "$LSREGISTER" -u "$stray" 2>/dev/null || true
        rm -rf "$stray"
        echo "    removed stray: $stray"
    fi
done

echo "==> staging the new install beside $DEST"
mkdir -p "$HOME/Library/Input Methods"
DEST_NEW="$DEST.new"
DEST_BACKUP="$DEST.bak"
rm -rf "$DEST_NEW" "$DEST_BACKUP"
if ! cp -R "$APP_PATH" "$DEST_NEW"; then
    echo "!! failed to stage the new bundle; keeping the current install"
    exit 1
fi
rm -rf "$STAGE/$APP"                 # don't leave a staging copy lying around

restore_previous_install() {
    echo "!! restoring the previous RIMES installation"
    pkill -x "$EXE" 2>/dev/null || true
    "$LSREGISTER" -u "$DEST" 2>/dev/null || true
    rm -rf "$DEST"
    if [ -e "$DEST_BACKUP" ]; then
        mv "$DEST_BACKUP" "$DEST"
        "$LSREGISTER" -f "$DEST" 2>/dev/null || true
        /bin/launchctl asuser "$(id -u)" "$DEST/Contents/MacOS/$EXE" --install >> "$HOME/rimebuffer-install.log" 2>&1 || true
        open "$DEST" 2>/dev/null || true
    fi
    rm -rf "$DEST_NEW"
}

echo "==> atomically swapping the installed bundle"
"$LSREGISTER" -u "$DEST" 2>/dev/null || true
if [ -e "$DEST" ] && ! mv "$DEST" "$DEST_BACKUP"; then
    echo "!! could not move the current bundle aside"
    rm -rf "$DEST_NEW"
    exit 1
fi
if ! mv "$DEST_NEW" "$DEST"; then
    echo "!! could not activate the staged bundle"
    restore_previous_install
    exit 1
fi

echo "==> registering the single installed copy with Launch Services"
"$LSREGISTER" -f "$DEST" || true

echo "==> self-install: register + enable + select inside the login session"
INSTALL_LOG="$HOME/rimebuffer-install.log"
ACTIVATION_READY=1
if ! /bin/launchctl asuser "$(id -u)" "$DEST/Contents/MacOS/$EXE" --install 2>&1 | tee "$INSTALL_LOG"; then
    # The bundle is already valid and atomically installed. Recent macOS
    # releases can require a login-session refresh before TIS exposes a newly
    # registered source; do not roll back good payload bytes for that condition.
    ACTIVATION_READY=0
    echo "!! input-source activation is pending a logout/login session refresh"
fi
open "$DEST" || true                 # start the IMK server (candidate/settings UI ready)
rm -rf "$DEST_BACKUP"

if [ "$ACTIVATION_READY" -eq 1 ]; then
    activation_summary="Installed, registered, and enabled RIMES."
else
    activation_summary="Installed RIMES; registration/enablement is pending session refresh."
fi

cat <<EOF

==> done. $activation_summary

If RIMES doesn't appear in the input menu (⌃Space) immediately, run:
  log out and back in once, then add RIMES in System Settings if needed.
After switching to it, press F4 to choose an input scheme.

Watch behaviour:  tail -f ~/rimebuffer.log
Self-contained: librime + Rime data are bundled, no Squirrel needed.
EOF
