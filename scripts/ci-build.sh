#!/bin/bash
# 干净 clone 编译：mac 本体 / iOS 模拟器各一遍，不签名（#075，plan：docs/plan-open-source.html §7）。
# GitHub Actions（.github/workflows/build.yml）调它；本机在导出的公开快照里也能跑：CI=true scripts/ci-build.sh ios
# 用法：scripts/ci-build.sh mac|ios
# 前提（workflow 里装）：xcodegen；mac 要 bun（版本见 .bun-version）；ios 要 meson ninja llvm lld libarchive + 联网（Alpine rootfs）
# 环境变量：MP_SIM_UDID 指定模拟器（默认挑 iOS 版本最高的一台可用 iPhone）
# 日志写 build/ci-logs/<平台>.log；只认 xcodebuild 的 BUILD SUCCEEDED，不认退出码
set -euo pipefail
platform=${1:-}
case "$platform" in mac|ios) ;; *) echo "用法：scripts/ci-build.sh mac|ios" >&2; exit 2 ;; esac
cd "$(dirname "$0")/.."

die() { echo "❌ $1" >&2; exit 1; }
step() { echo "::group::$1"; }   # Actions 折叠日志；本机就是一行普通输出
endstep() { echo "::endgroup::"; }

xcode_major=$(xcodebuild -version | sed -n 's/^Xcode \([0-9]*\).*/\1/p')
[ "${xcode_major:-0}" -ge 26 ] || die "要 Xcode 26+（iOS 部署目标 26），现在是 $(xcodebuild -version | head -1)"

# 签名：仓里只有 example。CI 里原样复制（Team 空、com.example）；本机不替你复制——
# 私有仓 worktree 里放一份 example 会盖住软链主仓那份，之后编出来就是 com.example（#071）
if [ ! -e Config/Signing.local.xcconfig ]; then
  [ "${CI:-}" = "true" ] || die "没有 Config/Signing.local.xcconfig：干净 clone 里先 cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig（或 CI=true 让本脚本复制）"
  cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
fi

# Xcode 26 起 Metal 工具链单独下载；有 .metal 源文件（mac / iOS 都有）没它编不过
if ! xcrun metal -v >/dev/null 2>&1; then
  step "下载 Metal 工具链"
  xcodebuild -downloadComponent MetalToolchain
  endstep
fi

if [ "$platform" = ios ]; then
  # 子模块 + Alpine rootfs zip + ish 静态库，和 BUILDING 里陌生人走的同一条路
  step "bootstrap-sandbox"
  bash scripts/bootstrap-sandbox.sh
  endstep
fi

step "xcodegen generate"
xcodegen generate
endstep

if [ "$platform" = mac ]; then
  scheme=MemoryPalace
  dest="platform=macOS,arch=arm64"
else
  scheme=MemoryPalaceIOS
  udid=${MP_SIM_UDID:-$(xcrun simctl list devices available -j | python3 -c '
import json, sys
best = None
for rt, devs in json.load(sys.stdin)["devices"].items():
    if ".SimRuntime.iOS-" not in rt: continue
    ver = tuple(int(x) for x in rt.rsplit("iOS-", 1)[1].split("-"))
    for d in devs:
        if d["name"].startswith("iPhone") and ver >= (26,) and (best is None or ver > best[0]):
            best = (ver, d["udid"], d["name"])
if best: print(best[1]); print("模拟器：%s（iOS %s）" % (best[2], ".".join(map(str, best[0]))), file=sys.stderr)
')}
  [ -n "$udid" ] || die "没有可用的 iOS 26+ iPhone 模拟器（xcrun simctl list devices available）"
  dest="platform=iOS Simulator,id=$udid"
fi

mkdir -p build/ci-logs
log=build/ci-logs/$platform.log
step "xcodebuild ${scheme}（${dest}）→ $log"
set +e
xcodebuild -project MemoryPalace.xcodeproj -scheme "$scheme" -configuration Debug \
  -destination "$dest" \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  build > "$log" 2>&1
rc=$?
set -e
endstep

if grep -q '\*\* BUILD SUCCEEDED \*\*' "$log"; then
  echo "✅ ${platform}：BUILD SUCCEEDED（xcodebuild rc=${rc}）"
  exit 0
fi
echo "—— 报错（前 40 条）——"
grep -E '(^|: )error: ' "$log" | sort -u | head -40 || true
echo "—— 日志末尾 ——"
tail -40 "$log"
die "$platform 没编过（rc=${rc}），完整日志 $log"
