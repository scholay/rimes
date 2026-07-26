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
# your actual setup. We then force RIMES's product schema list (并击、自然码双拼、
# 雾凇拼音、英文) + 9 candidates; everything else you have is preserved. With no ~/Library/Rime, the
# app deploys from the bundled schemas instead. RB_KEEP_USERDB=1 skips reseeding.
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
    # Enforce RIMES's four product schemas + 9 candidates. Your learned
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

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/RimeBuffer"
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
        killall imklaunchagent 2>/dev/null || true
        killall TextInputMenuAgent 2>/dev/null || true
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

echo "==> refreshing InputMethodKit / input-menu caches"
killall imklaunchagent 2>/dev/null || true
killall TextInputMenuAgent 2>/dev/null || true
sleep 0.5

echo "==> self-install: register + enable + select inside the login session"
INSTALL_LOG="$HOME/rimebuffer-install.log"
if ! /bin/launchctl asuser "$(id -u)" "$DEST/Contents/MacOS/$EXE" --install 2>&1 | tee "$INSTALL_LOG"; then
    restore_previous_install
    exit 1
fi
killall TextInputMenuAgent 2>/dev/null || true
open "$DEST" || true                 # start the IMK server (candidate/settings UI ready)
rm -rf "$DEST_BACKUP"

cat <<EOF

==> done. Installed and self-enabled RIMES using its single compatibility bundle.

If RIMES doesn't appear in the input menu (⌃Space) immediately, run:
  killall TextInputMenuAgent SystemUIServer
(or log out / back in once). Then switch to it and press F4 to choose an input scheme.

Watch behaviour:  tail -f ~/rimebuffer.log
Self-contained: librime + Rime data are bundled, no Squirrel needed.
EOF
