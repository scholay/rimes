#!/bin/bash
# =============================================================================
# 开发快速迭代：把新编译的二进制换进「已安装」的 ~/Library 输入法里，只重启
# 输入法进程。同步更新 CFBundleVersion，但不 lsregister、不杀
# TextInputMenuAgent/imklaunchagent——macOS 保持输入源已注册、输入菜单不重建。
#
# 完整安装（首次、或身份/资源/词库变化时）仍用 build_install.sh。
# 前提：已经用 build_install.sh 装过一次（~/Library/Input Methods/RIMES.app 存在）。
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

DEST="$HOME/Library/Input Methods/RIMES.app"
if [ ! -d "$DEST" ]; then
    echo "!! 未找到 $DEST — 先用 ./build_install.sh 完整装一次"
    exit 1
fi

CONFIG="${1:-debug}"   # debug（默认，编译快）或 release

echo "==> swift build ($CONFIG)"
if [ "$CONFIG" = "release" ]; then
    swift build -c release 2>&1 | tail -1
    BIN="$(swift build -c release --show-bin-path)/RimeBuffer"
else
    swift build 2>&1 | tail -1
    BIN="$(swift build --show-bin-path)/RimeBuffer"
fi

EXPECTED_UUID="$(dwarfdump --uuid "$BIN" | awk 'NR == 1 { print $2 }')"
NEW_BIN="$DEST/Contents/MacOS/RIMES.new"

echo "==> 原子替换二进制（不动 40MB 词库/框架）"
cp "$BIN" "$NEW_BIN"
chmod 755 "$NEW_BIN"
mv -f "$NEW_BIN" "$DEST/Contents/MacOS/RIMES"

BUILD_NUMBER="$(date +%s)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
    "$DEST/Contents/Info.plist"

echo "==> 重签 ad-hoc（二进制变了，签名必须刷新，否则 macOS 拒绝加载）"
codesign --force --deep --sign - "$DEST" 2>&1 | tail -1
xattr -cr "$DEST" 2>/dev/null || true

echo "==> 只重启输入法进程（不重新注册、不重建菜单）"
/usr/bin/killall RIMES 2>/dev/null || true
sleep 0.3
/usr/bin/open "$DEST"

INSTALLED_UUID="$(dwarfdump --uuid "$DEST/Contents/MacOS/RIMES" | awk 'NR == 1 { print $2 }')"
if [ -z "$EXPECTED_UUID" ] || [ "$INSTALLED_UUID" != "$EXPECTED_UUID" ]; then
    echo "!! 安装后 UUID 验证失败: expected=$EXPECTED_UUID installed=$INSTALLED_UUID"
    exit 1
fi

echo "==> 完成。build=$BUILD_NUMBER UUID=$INSTALLED_UUID"
echo "    切回 RIMES 打字即用，无需等菜单重建。"
