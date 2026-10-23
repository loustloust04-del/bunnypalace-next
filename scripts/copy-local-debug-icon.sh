#!/bin/bash
# 「开发」子应用（pmBoard）的本地默认图标拷进 app 包（app 侧读取见 AppIconView.swift 的 LocalDefaultIcon）。
# 源图有版权，只放仓库外 ~/.mp-local-assets/，绝不进 git。
# 只在 Debug 且本机有源图时拷；否则删掉包里可能残留的旧拷贝后 exit 0——别的机器 / CI / Release 照常编过、包里没图。
# 只写 $TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH 下这一个文件，不碰源码目录 / bridging 头；内容没变就不写（mtime 不动）。
set -u

[ -n "${TARGET_BUILD_DIR:-}" ] && [ -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ] || exit 0
src="$HOME/.mp-local-assets/pmboard-icon.png"
dst_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
dst="$dst_dir/pmboard-local-icon.png"

if [ "${CONFIGURATION:-}" != "Debug" ] || [ ! -f "$src" ]; then
  rm -f "$dst"
  exit 0
fi
cmp -s "$src" "$dst" && exit 0
mkdir -p "$dst_dir" && cp "$src" "$dst" || { echo "warning: 本地开发图标没拷进包，「开发」回落 SF 图标"; rm -f "$dst"; }
exit 0
