#!/bin/bash
# iOS post-build 资源闸：共享 sources 已排除 TutuSkin；只在 PERSONAL_APPS 开启时
# 拷贝整棵目录，保留场景层级。每次运行同步删除旧资源，关闸也清理同一构建目录的残留。
set -euo pipefail

: "${SRCROOT:?Xcode SRCROOT is required}"
: "${TARGET_BUILD_DIR:?Xcode TARGET_BUILD_DIR is required}"
: "${UNLOCALIZED_RESOURCES_FOLDER_PATH:?Xcode resource folder is required}"

source_dir="$SRCROOT/MemoryPalace/Resources/TutuSkin"
resource_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
destination="$resource_dir/TutuSkin"

if [[ ! "${PERSONAL_APPS_FLAG:-}" =~ (^|[[:space:]])PERSONAL_APPS($|[[:space:]]) ]]; then
    rm -rf -- "$destination"
    exit 0
fi

if [[ ! -d "$source_dir" ]]; then
    echo "error: TutuSkin resources missing; run scripts/tutu-skin/sync.sh <commit> first" >&2
    exit 1
fi
mkdir -p "$destination"
/usr/bin/rsync -a --delete "$source_dir/" "$destination/"
