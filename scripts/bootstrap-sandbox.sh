#!/bin/bash
set -euo pipefail

# ============================================================================
# bootstrap-sandbox.sh —— 离线沙箱的一条命令开工准备
# ============================================================================
# 新克隆 / 新 worktree 里跑一次就够；之后 xcodebuild 会靠 preBuildScript 自己
# 增量维护 .a，不用再手跑。做三件事，每件都幂等：
#
#   1. 拉 deps/ish 子模块（**不 --recursive**：它自己的 libapps/libarchive/linux
#      三个子模块一个都不需要，见 scripts/build-ish.sh 头部注释）
#   2. 缺 deps/resources/alpine-rootfs.zip 就跑 prepare-rootfs.sh（要联网下 Alpine）
#   3. 两个平台各构建一份 ish 静态库
#
# 用法：bash scripts/bootstrap-sandbox.sh [--force-rootfs]
# ============================================================================

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORCE_ROOTFS=0
[ "${1:-}" = "--force-rootfs" ] && FORCE_ROOTFS=1

info() { echo "ℹ️  $1"; }
ok() { echo "✅ $1"; }
die() { echo "❌ $1" >&2; exit 1; }

cd "$REPO_ROOT"

# ---- 1. 子模块 ----
if [ -f "deps/ish/meson.build" ]; then
    info "deps/ish 已就位"
else
    info "拉 deps/ish 子模块（不递归）…"
    git submodule update --init deps/ish
    [ -f "deps/ish/meson.build" ] || die "子模块拉完还是没有 deps/ish/meson.build"
fi
ok "ish 源码：$(git -C deps/ish rev-parse --short HEAD)"

# ---- 2. rootfs ----
ZIP="deps/resources/alpine-rootfs.zip"
if [ "$FORCE_ROOTFS" -eq 1 ] || [ ! -s "$ZIP" ]; then
    info "构建 rootfs（要联网下 Alpine minirootfs）…"
    bash scripts/prepare-rootfs.sh
else
    info "rootfs 已存在（$(stat -f%z "$ZIP") 字节），跳过；要重建加 --force-rootfs"
fi
[ -s "$ZIP" ] || die "rootfs 没生成：$ZIP"

# ---- 3. 两个平台的静态库 ----
for platform in iphonesimulator iphoneos; do
    info "构建 ish 静态库（${platform}）…"
    bash scripts/build-ish.sh "$platform" > /dev/null
    ok "$platform → deps/libs/$platform"
done

echo ""
echo "============================================================"
echo "  沙箱准备完成，可以 xcodegen generate && xcodebuild 了"
echo "    rootfs  $(stat -f%z "$ZIP") 字节"
echo "    libs    $(du -sh deps/libs | cut -f1)"
echo "============================================================"
