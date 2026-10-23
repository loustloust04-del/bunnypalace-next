#!/bin/bash
# xcodegen preGenCommand：本机签名配置 Config/Signing.local.xcconfig 是 gitignore 的，worktree / 集成区里没有。
# 本地没有就软链主仓那份；主仓也没有就报错退出（xcodegen 随之中止）——
# 不许悄悄落到别的 bundle ID：装上去是个新的空 app，像数据没了，TestFlight 也传不上（#071）。
set -u
cd "$(dirname "$0")/.." && here=$(pwd -P) || exit 1
f=Config/Signing.local.xcconfig
[ -e "${f}" ] && exit 0
[ -L "${f}" ] && rm -f "${f}"   # 断链（主仓那份被删 / 挪了）
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=
main=${common%/.git}
if [ -n "$common" ] && [ "$main" != "$common" ] && [ "$main" != "$here" ] && [ -f "$main/${f}" ]; then
  ln -s "$main/${f}" "${f}" 2>/dev/null && echo "[signing] ${f} → 主仓 $main/${f}" && exit 0
  [ -e "${f}" ] && exit 0   # 同一工位两个 xcodegen 并发，别人刚建好
fi
{
  echo "❌ [signing] 没有 ${f}，xcodegen 停下。"
  echo "   第一次编：cp ${f}.example ${f}（原样能编模拟器；真机 / 发行填自己的 Team ID 和 bundle 前缀）。"
  [ -n "$common" ] && [ "$main" != "$here" ] && echo "   这是 worktree：放到主仓 $main/${f}，各 worktree 会自动软链。"
} >&2
exit 1
