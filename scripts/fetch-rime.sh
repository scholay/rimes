#!/bin/bash
# =============================================================================
# 拉取 librime 运行时到 Vendor/rime/，用于把 RimeBuffer 打成自包含 app
# （装一个就能用，无需单独安装 Squirrel）。
#
# 来源：Squirrel 官方 .pkg + 官方 rime-octagram-data 固定版本。librime 是
# 静态链接的（依赖只有系统 libSystem/libc++），所以取 librime.1.dylib、
# 3 个插件、SharedSupport（默认词库/方案）与已校验的简体语言模型。
# 不取 Sparkle（那是 Squirrel 自己的更新器，RimeBuffer 用自己的自动更新）。
#
# Vendor/ 是 gitignore 的——不把二进制提交进仓库，构建时按审计过的
# 版本、长度、SHA-256 与 Developer ID 身份拉取。
#
#   ./scripts/fetch-rime.sh            # 已存在则跳过
#   ./scripts/fetch-rime.sh --force    # 强制重新拉取
#   RB_OCTAGRAM_MODEL_PATH=/path/to/zh-hans-t-essay-bgw.gram \
#       ./scripts/fetch-rime.sh        # 离线复用同一份已审计模型
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

SQUIRREL_VERSION="1.1.2"
SQUIRREL_PACKAGE_BYTES="25498033"
SQUIRREL_PACKAGE_SHA256="614746013212937623d5bbab9901e9c43d1ec937aa32307d6b6092a05e308287"
SQUIRREL_TEAM_ID="28HU5A7B46"
SQUIRREL_INSTALLER_IDENTITY="Developer ID Installer: Yuncao Liu (${SQUIRREL_TEAM_ID})"
SQUIRREL_BUNDLE_ID="im.rime.inputmethod.Squirrel"
OCTAGRAM_RELEASE_TAG="20260712"
OCTAGRAM_RELEASE_ASSET="zh-hans-t-essay-bgw-compact.gram"
OCTAGRAM_REVISION="f8ce3b534733e489a8470a7c2adf5a154e8ea069"
OCTAGRAM_MODEL="zh-hans-t-essay-bgw.gram"
OCTAGRAM_MODEL_BYTES="40925228"
OCTAGRAM_MODEL_SHA256="d3cb2438c1fdcd6a855dd6ca8f5c1060a29273c6b64c2c2c69af67cd71b6aa7e"
DEST="Vendor/rime"
FORCE="${1:-}"
CACHE_DIR="Vendor/.cache"
CACHE_PKG="$CACHE_DIR/Squirrel-${SQUIRREL_VERSION}.pkg"

die() {
    echo "fetch-rime: $*" >&2
    exit 1
}

warn() {
    echo "fetch-rime: $*" >&2
}

octagram_model_is_valid() {
    local candidate="$1"
    [[ -f "$candidate" && ! -L "$candidate" ]] \
        && [[ "$(/usr/bin/stat -f%z "$candidate")" == "$OCTAGRAM_MODEL_BYTES" ]] \
        && [[ "$(/usr/bin/shasum -a 256 "$candidate" | /usr/bin/awk '{print $1}')" \
            == "$OCTAGRAM_MODEL_SHA256" ]]
}

download_octagram_model() {
    local label="$1"
    local url="$2"
    local output="$3"
    local partial="$TMP/.${OCTAGRAM_MODEL}.${label}.partial"
    local effective_url

    /bin/rm -f "$partial"
    echo "==> 下载 Octagram 模型（${label}）"
    if ! effective_url="$(
        curl --fail --location --show-error --silent \
            --retry 2 --retry-delay 1 --retry-all-errors \
            --retry-max-time 600 \
            --connect-timeout 10 --max-time 600 \
            --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --output "$partial" \
            --write-out '%{url_effective}' \
            "$url"
    )"; then
        /bin/rm -f "$partial"
        warn "$label Octagram source failed"
        return 1
    fi
    case "$effective_url" in
        https://github.com/*|https://release-assets.githubusercontent.com/*|https://raw.githubusercontent.com/*) ;;
        *)
            /bin/rm -f "$partial"
            warn "$label Octagram download left the reviewed GitHub HTTPS hosts: $effective_url"
            return 1
            ;;
    esac
    if ! octagram_model_is_valid "$partial"; then
        /bin/rm -f "$partial"
        warn "$label Octagram source returned unexpected bytes"
        return 1
    fi
    /bin/mv -f "$partial" "$output"
}

[[ -z "$FORCE" || "$FORCE" == "--force" ]] \
    || die "the only supported option is --force"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PKG_URL="https://github.com/rime/squirrel/releases/download/${SQUIRREL_VERSION}/Squirrel-${SQUIRREL_VERSION}.pkg"
used_cache=false
if [[ "$FORCE" != "--force" && -f "$CACHE_PKG" && ! -L "$CACHE_PKG" ]] \
    && [[ "$(/usr/bin/stat -f%z "$CACHE_PKG")" == "$SQUIRREL_PACKAGE_BYTES" ]] \
    && [[ "$(/usr/bin/shasum -a 256 "$CACHE_PKG" | /usr/bin/awk '{print $1}')" \
        == "$SQUIRREL_PACKAGE_SHA256" ]]; then
    echo "==> 使用已校验字节的本地 Squirrel pkg 缓存"
    /usr/bin/ditto "$CACHE_PKG" "$TMP/squirrel.pkg"
    used_cache=true
else
    echo "==> 下载 $PKG_URL"
    effective_url="$(
        curl --fail --location --show-error --silent \
            --proto '=https' --tlsv1.2 \
            --output "$TMP/squirrel.pkg" \
            --write-out '%{url_effective}' \
            "$PKG_URL"
    )"
    case "$effective_url" in
        https://github.com/*|https://*.githubusercontent.com/*) ;;
        *) die "download left the reviewed GitHub HTTPS hosts: $effective_url" ;;
    esac
fi

actual_bytes="$(/usr/bin/stat -f%z "$TMP/squirrel.pkg")"
[[ "$actual_bytes" == "$SQUIRREL_PACKAGE_BYTES" ]] \
    || die "unexpected Squirrel pkg size: $actual_bytes"
actual_sha256="$(/usr/bin/shasum -a 256 "$TMP/squirrel.pkg" | /usr/bin/awk '{print $1}')"
[[ "$actual_sha256" == "$SQUIRREL_PACKAGE_SHA256" ]] \
    || die "Squirrel pkg SHA-256 mismatch"

signature_output="$(/usr/sbin/pkgutil --check-signature "$TMP/squirrel.pkg" 2>&1)" \
    || die "Squirrel pkg signature is invalid"
printf '%s\n' "$signature_output"
printf '%s\n' "$signature_output" \
    | /usr/bin/grep -F "$SQUIRREL_INSTALLER_IDENTITY" > /dev/null \
    || die "Squirrel pkg signer is not the reviewed Developer ID identity"
/usr/sbin/spctl --assess --type install --verbose=4 "$TMP/squirrel.pkg" \
    || die "Gatekeeper rejected the Squirrel pkg"
/usr/bin/xcrun stapler validate -v "$TMP/squirrel.pkg" \
    || die "Squirrel pkg has no valid stapled notarization ticket"

if [[ "$used_cache" != true ]]; then
    /bin/mkdir -p "$CACHE_DIR"
    cache_tmp="$(/usr/bin/mktemp "$CACHE_DIR/.Squirrel.pkg.XXXXXX")"
    /usr/bin/ditto "$TMP/squirrel.pkg" "$cache_tmp"
    /bin/chmod 600 "$cache_tmp"
    /bin/mv -f "$cache_tmp" "$CACHE_PKG"
fi

echo "==> 展开 pkg"
pkgutil --expand-full "$TMP/squirrel.pkg" "$TMP/expand" >/dev/null
SRC="$TMP/expand/Payload/Squirrel.app/Contents"
[[ -d "$SRC" && ! -L "$SRC" ]] || die "Squirrel app payload is missing"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC/Info.plist")" \
    == "$SQUIRREL_BUNDLE_ID" ]] || die "unexpected Squirrel bundle identity"
/usr/bin/codesign --verify --deep --strict --verbose=2 "${SRC%/Contents}" \
    || die "expanded Squirrel app signature is invalid"

runtime_files=(
    "$SRC/Frameworks/librime.1.dylib"
    "$SRC/Frameworks/rime-plugins/librime-lua.dylib"
    "$SRC/Frameworks/rime-plugins/librime-octagram.dylib"
    "$SRC/Frameworks/rime-plugins/librime-predict.dylib"
)
expected_runtime_sha256=(
    abb06aa5b3f53de375bc401512b49a7a31b7ed5ee62b2ef7a438512abee5958f
    a0862901b4d36d35aba7012f05c132dd087890cca564609c5d1ea3ba9de7c12b
    70f587ca908e1b857f4180dc50584b8843ec0852dbc2013248badc5fb0571525
    78ba33a2e1d6fd6b7ee456ebfe8d57e3b16f7185d80fd1181600d6cc5fb7ad3f
)
for index in "${!runtime_files[@]}"; do
    runtime="${runtime_files[$index]}"
    [[ -f "$runtime" && ! -L "$runtime" ]] \
        || die "missing or unsafe reviewed runtime: $runtime"
    [[ "$(/usr/bin/shasum -a 256 "$runtime" | /usr/bin/awk '{print $1}')" \
        == "${expected_runtime_sha256[$index]}" ]] \
        || die "reviewed runtime hash mismatch: $runtime"
    # One architecture per call: Xcode 27's lipo reads a second arch after
    # -verify_arch as another input file and fails with "requires exactly one
    # input file". The single-arch form works on every toolchain.
    /usr/bin/lipo "$runtime" -verify_arch arm64 \
        && /usr/bin/lipo "$runtime" -verify_arch x86_64 \
        || die "runtime is not universal: $runtime"
    /usr/bin/codesign --verify --strict --verbose=2 "$runtime" \
        || die "runtime signature is invalid: $runtime"
    runtime_signature="$(/usr/bin/codesign --display --verbose=4 "$runtime" 2>&1)"
    printf '%s\n' "$runtime_signature" \
        | /usr/bin/grep -F "TeamIdentifier=$SQUIRREL_TEAM_ID" > /dev/null \
        || die "runtime Team ID mismatch: $runtime"
done

plugin_files=()
while IFS= read -r plugin_file; do
    plugin_files+=("$plugin_file")
done < <(/usr/bin/find "$SRC/Frameworks/rime-plugins" -type f -maxdepth 1 -print | /usr/bin/sort)
[[ "${#plugin_files[@]}" -eq 3 ]] \
    || die "unexpected files in the reviewed rime-plugins directory"

echo "==> 获取已审计的简体 Octagram 模型"
octagram_cache="$CACHE_DIR/$OCTAGRAM_MODEL"
octagram_tmp="$TMP/$OCTAGRAM_MODEL"
octagram_used_cache=false
if [[ "$FORCE" != "--force" && -n "${RB_OCTAGRAM_MODEL_PATH:-}" ]]; then
    octagram_local="$RB_OCTAGRAM_MODEL_PATH"
    octagram_model_is_valid "$octagram_local" \
        || die "RB_OCTAGRAM_MODEL_PATH is not the reviewed $OCTAGRAM_MODEL bytes"
    echo "==> 使用 RB_OCTAGRAM_MODEL_PATH 指定的已校验模型"
    /usr/bin/ditto "$octagram_local" "$octagram_tmp"
elif [[ "$FORCE" != "--force" ]] && octagram_model_is_valid "$octagram_cache"; then
    echo "==> 使用已校验字节的本地 Octagram 模型缓存"
    /usr/bin/ditto "$octagram_cache" "$octagram_tmp"
    octagram_used_cache=true
else
    octagram_release_url="https://github.com/lotem/rime-octagram-data/releases/download/${OCTAGRAM_RELEASE_TAG}/${OCTAGRAM_RELEASE_ASSET}"
    octagram_raw_url="https://raw.githubusercontent.com/lotem/rime-octagram-data/${OCTAGRAM_REVISION}/${OCTAGRAM_MODEL}"
    if ! download_octagram_model "release" "$octagram_release_url" "$octagram_tmp"; then
        echo "==> Release 资产不可用，回退到固定 revision 的 raw 源"
        download_octagram_model "raw" "$octagram_raw_url" "$octagram_tmp" \
            || die "all reviewed Octagram model sources failed"
    fi
fi
octagram_model_is_valid "$octagram_tmp" \
    || die "Octagram model failed final byte and SHA-256 verification"
if [[ "$octagram_used_cache" != true ]]; then
    /bin/mkdir -p "$CACHE_DIR"
    octagram_cache_tmp="$(/usr/bin/mktemp "$CACHE_DIR/.Octagram.XXXXXX")"
    /usr/bin/ditto "$octagram_tmp" "$octagram_cache_tmp"
    /bin/chmod 600 "$octagram_cache_tmp"
    /bin/mv -f "$octagram_cache_tmp" "$octagram_cache"
fi

# Resolve and verify the external model before replacing a previously usable
# Vendor runtime. This also permits an explicit model path inside the old DEST.
echo "==> 提取到 $DEST"
rm -rf "$DEST"
mkdir -p "$DEST/Frameworks"
cp "${runtime_files[0]}" "$DEST/Frameworks/"
mkdir -p "$DEST/Frameworks/rime-plugins"
cp "${runtime_files[@]:1}" "$DEST/Frameworks/rime-plugins/"
cp -R "$SRC/SharedSupport" "$DEST/SharedSupport"

/usr/bin/ditto "$octagram_tmp" "$DEST/SharedSupport/$OCTAGRAM_MODEL"
/bin/chmod 0644 "$DEST/SharedSupport/$OCTAGRAM_MODEL"

echo "==> 完成（Squirrel ${SQUIRREL_VERSION}）："
du -sh "$DEST/Frameworks" "$DEST/SharedSupport"
