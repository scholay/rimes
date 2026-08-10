#!/bin/bash
# =============================================================================
# RIMES 发布脚本
#
# 在唯一的正式发布仓库 scholay/rimes 创建 vX.Y.Z tag。tag 推送后由
# .github/workflows/release.yml 构建并创建 GitHub Release。
#
# 用法：
#   ./scripts/release.sh                 # 基于远端 tag / Info.plist 的较新版本 patch +1
#   ./scripts/release.sh patch           # 同上
#   ./scripts/release.sh minor           # 次版本 +1
#   ./scripts/release.sh major           # 主版本 +1
#   ./scripts/release.sh 0.4.2           # 显式指定版本号
#   ./scripts/release.sh --dry-run 0.4.2 # 只做校验并展示计划
#   ./scripts/release.sh --yes 0.4.2     # 跳过交互确认（用于受控自动化）
#   ./scripts/release.sh preview 0.2.0   # 发布 Windows / Linux 数据预览包
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
die()     { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

usage() {
    sed -n '2,17p' "$0" | sed -E 's/^# ?//'
}

is_version() {
    [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

version_gt() {
    local a_major a_minor a_patch b_major b_minor b_patch
    IFS='.' read -r a_major a_minor a_patch <<< "$1"
    IFS='.' read -r b_major b_minor b_patch <<< "$2"
    (( a_major > b_major )) && return 0
    (( a_major < b_major )) && return 1
    (( a_minor > b_minor )) && return 0
    (( a_minor < b_minor )) && return 1
    (( a_patch > b_patch ))
}

bump() {
    local major minor patch
    IFS='.' read -r major minor patch <<< "$1"
    case "$2" in
        major) echo "$((major + 1)).0.0" ;;
        minor) echo "$major.$((minor + 1)).0" ;;
        patch) echo "$major.$minor.$((patch + 1))" ;;
        *) die "未知的版本升级类型: $2" ;;
    esac
}

github_repo_from_url() {
    local url="$1" repo
    case "$url" in
        git@github.com:*) repo="${url#git@github.com:}" ;;
        ssh://git@github.com/*) repo="${url#ssh://git@github.com/}" ;;
        https://github.com/*) repo="${url#https://github.com/}" ;;
        http://github.com/*) repo="${url#http://github.com/}" ;;
        *) return 1 ;;
    esac
    repo="${repo%/}"
    repo="${repo%.git}"
    printf '%s' "$repo" | tr '[:upper:]' '[:lower:]'
}

remote_tag_exists() {
    local output
    if ! output="$(git ls-remote --tags "$REMOTE" "refs/tags/$1" 2>/dev/null)"; then
        die "无法查询 $REMOTE 的远端标签；未执行任何发布操作。"
    fi
    [[ -n "$output" ]]
}

DRY_RUN=false
ASSUME_YES=false
POSITIONAL=()

while (( $# > 0 )); do
    case "$1" in
        -n|--dry-run) DRY_RUN=true ;;
        -y|--yes) ASSUME_YES=true ;;
        -h|--help) usage; exit 0 ;;
        --)
            shift
            while (( $# > 0 )); do
                POSITIONAL[${#POSITIONAL[@]}]="$1"
                shift
            done
            break
            ;;
        -*) die "未知选项: $1（使用 --help 查看用法）" ;;
        *) POSITIONAL[${#POSITIONAL[@]}]="$1" ;;
    esac
    shift
done

MODE="release"
if (( ${#POSITIONAL[@]} > 0 )) && [[ "${POSITIONAL[0]}" == "preview" ]]; then
    MODE="preview"
    (( ${#POSITIONAL[@]} == 2 )) || die "预览版用法: $0 preview X.Y.Z"
    VERSION_ARG="${POSITIONAL[1]}"
    is_version "$VERSION_ARG" || die "预览版本号格式应为 x.y.z（不允许前导零）: $VERSION_ARG"
else
    (( ${#POSITIONAL[@]} <= 1 )) || die "只能指定一个版本或升级类型。"
    VERSION_ARG="${POSITIONAL[0]:-patch}"
fi

REMOTE="origin"
EXPECTED_REPO="scholay/rimes"

cd "$(dirname "$0")/.."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "当前目录不是 Git 仓库。"

git remote get-url "$REMOTE" >/dev/null 2>&1 || die "缺少发布远端 ${REMOTE}。"
fetch_url="$(git remote get-url "$REMOTE")"
push_url="$(git remote get-url --push "$REMOTE")"
fetch_repo="$(github_repo_from_url "$fetch_url")" || die "$REMOTE fetch URL 不是 GitHub 地址: $fetch_url"
push_repo="$(github_repo_from_url "$push_url")" || die "$REMOTE push URL 不是 GitHub 地址: $push_url"
[[ "$fetch_repo" == "$EXPECTED_REPO" ]] || die "$REMOTE fetch URL 必须指向 ${EXPECTED_REPO}，实际为 ${fetch_repo}。"
[[ "$push_repo" == "$EXPECTED_REPO" ]] || die "$REMOTE push URL 必须指向 ${EXPECTED_REPO}，实际为 ${push_repo}。"
info "发布远端: $REMOTE ($push_url)"

branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[[ "$branch" == "main" ]] || die "只能从 main 分支发布，当前分支: ${branch:-detached HEAD}。"

dirty="$(git status --porcelain --untracked-files=all)"
if [[ -n "$dirty" ]]; then
    echo "$dirty" >&2
    die "工作区不干净。请先单独提交、暂存或恢复这些改动；发布脚本不会自动 add/commit。"
fi

plist_version=""
latest_remote=""
if [[ "$MODE" == "release" ]]; then
    [[ -f Info.plist ]] || die "找不到 Info.plist。"
    [[ -x /usr/libexec/PlistBuddy ]] || die "找不到 /usr/libexec/PlistBuddy；请在 macOS 上运行正式版发布脚本。"
    plist_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist 2>/dev/null || true)"
    is_version "$plist_version" || die "Info.plist 版本号不是严格的 x.y.z 格式: ${plist_version:-<空>}"
    tag_pattern='refs/tags/v*'
    tag_prefix='v'
else
    tag_pattern='refs/tags/platform-preview-v*'
    tag_prefix='platform-preview-v'
fi

if ! remote_refs="$(git ls-remote --tags --refs "$REMOTE" "$tag_pattern" 2>/dev/null)"; then
    die "无法读取 $EXPECTED_REPO 的远端标签；未执行任何发布操作。"
fi

while IFS=$'\t' read -r _ ref; do
    [[ -n "${ref:-}" ]] || continue
    candidate="${ref#refs/tags/$tag_prefix}"
    is_version "$candidate" || continue
    if [[ -z "$latest_remote" ]] || version_gt "$candidate" "$latest_remote"; then
        latest_remote="$candidate"
    fi
done <<< "$remote_refs"

if [[ "$MODE" == "release" ]]; then
    baseline="$plist_version"
    if [[ -n "$latest_remote" ]] && version_gt "$latest_remote" "$baseline"; then
        baseline="$latest_remote"
    fi

    info "Info.plist 版本: $plist_version"
    if [[ -n "$latest_remote" ]]; then
        info "远端最新正式 tag: v$latest_remote"
    else
        info "远端尚无严格匹配 vX.Y.Z 的正式 tag"
    fi
    info "版本递增基线: $baseline"

    case "$VERSION_ARG" in
        patch|minor|major) new="$(bump "$baseline" "$VERSION_ARG")" ;;
        *)
            is_version "$VERSION_ARG" || die "版本号格式应为 x.y.z（不允许前导零）: $VERSION_ARG"
            new="$VERSION_ARG"
            ;;
    esac
else
    new="$VERSION_ARG"
    if [[ -n "$latest_remote" ]]; then
        info "远端最新跨平台预览 tag: platform-preview-v$latest_remote"
    else
        info "远端尚无严格匹配 platform-preview-vX.Y.Z 的 tag"
    fi
fi
tag="$tag_prefix$new"

if [[ -n "$latest_remote" ]] && ! version_gt "$new" "$latest_remote"; then
    die "$tag 不高于同类远端最新 tag ${tag_prefix}${latest_remote}；禁止覆盖或回退已发布版本。"
fi
if [[ "$MODE" == "release" ]] && version_gt "$plist_version" "$new"; then
    die "$tag 低于 Info.plist 的当前版本 v${plist_version}；禁止版本回退。"
fi
remote_tag_exists "$tag" && die "远端 tag $tag 已存在；发布脚本绝不会删除或覆盖远端标签。"
git show-ref --verify --quiet "refs/tags/$tag" && die "本地 tag $tag 已存在；请先确认其来源，发布脚本不会重建标签。"

if ! remote_main_line="$(git ls-remote --heads "$REMOTE" refs/heads/main 2>/dev/null)"; then
    die "无法查询 $EXPECTED_REPO 的 main 分支。"
fi
[[ -n "$remote_main_line" ]] || die "$EXPECTED_REPO 不存在 main 分支。"
remote_main="${remote_main_line%%[[:space:]]*}"
git cat-file -e "$remote_main^{commit}" 2>/dev/null || die "本地缺少远端 main 的最新提交。请先运行 git fetch origin main。"
git merge-base --is-ancestor "$remote_main" HEAD || die "本地 main 不包含远端 main；请先同步并解决分叉。"

echo ""
info "发布计划:"
echo "  仓库:    https://github.com/$EXPECTED_REPO"
echo "  分支:    main ($(git rev-parse --short HEAD))"
if [[ "$MODE" == "release" ]]; then
    echo "  类型:    macOS 正式版"
    echo "  版本:    $plist_version -> $new"
else
    echo "  类型:    Windows / Linux 数据预览版"
    echo "  版本:    ${latest_remote:-<首次发布>} -> $new"
fi
echo "  标签:    $tag"
if [[ "$MODE" == "release" && "$plist_version" != "$new" ]]; then
    echo "  本地提交: 仅更新 Info.plist"
else
    echo "  本地提交: 无"
fi
echo "  推送:    main 与 $tag 原子推送"

if [[ "$DRY_RUN" == true ]]; then
    echo ""
    success "dry-run 校验通过；没有修改文件、创建 tag 或推送远端。"
    exit 0
fi

if [[ "$ASSUME_YES" != true ]]; then
    [[ -t 0 ]] || die "非交互环境必须显式传入 --yes。"
    echo ""
    read -r -p "确认发布 $tag 到 ${EXPECTED_REPO}？(y/n) " -n 1 reply
    echo
    [[ "$reply" =~ ^[Yy]$ ]] || { warn "已取消"; exit 0; }
fi

# 确认后再次检查，缩小并发发布或编辑造成的竞态窗口。
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || die "确认后工作区发生变化，已中止。"
remote_tag_exists "$tag" && die "确认后发现远端 tag $tag 已存在，已中止且不会覆盖。"

if [[ "$MODE" == "release" && "$plist_version" != "$new" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $new" Info.plist
    updated_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
    [[ "$updated_version" == "$new" ]] || die "Info.plist 版本更新校验失败。"
    git add -- Info.plist
    staged_files="$(git diff --cached --name-only)"
    [[ "$staged_files" == "Info.plist" ]] || die "暂存区包含 Info.plist 以外的文件，已中止。"
    git commit -m "chore: bump version to $new" -- Info.plist
fi

[[ -z "$(git status --porcelain --untracked-files=all)" ]] || die "创建 tag 前工作区不再干净，已中止。"
remote_tag_exists "$tag" && die "创建 tag 前发现远端 tag $tag 已存在，已中止且不会覆盖。"

release_commit="$(git rev-parse HEAD)"
git tag "$tag" "$release_commit"

info "原子推送 main 与 $tag 到 $EXPECTED_REPO..."
if ! git push --atomic "$REMOTE" "HEAD:refs/heads/main" "refs/tags/$tag:refs/tags/$tag"; then
    die "推送失败。远端未被部分更新；本地 tag $tag 保留以便人工检查。"
fi

echo ""
success "已推送 ${tag}，GitHub Actions 正在构建。"
echo "  构建进度: https://github.com/$EXPECTED_REPO/actions"
echo "  Release:  https://github.com/$EXPECTED_REPO/releases/tag/$tag"
