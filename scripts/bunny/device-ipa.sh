#!/bin/bash
# [Bunny] 真机不签名 ipa：给用户自备签名工具重签安装的测试包（不覆盖现用 App）。
# Bundle ID 前缀 com.susu.MemoryPalace.next → 主 App com.susu.MemoryPalace.next.ios（现用包是 com.susu.MemoryPalace.ios）。
# 用法：scripts/bunny/device-ipa.sh [Release|Debug]；产物 build/bunny/BunnyPalaceNext-unsigned.ipa
set -euo pipefail
config=${1:-Release}
cd "$(dirname "$0")/../.."
die() { echo "❌ $1" >&2; exit 1; }
step() { echo "::group::$1"; }
endstep() { echo "::endgroup::"; }

xcode_major=$(xcodebuild -version | sed -n 's/^Xcode \([0-9]*\).*/\1/p')
[ "${xcode_major:-0}" -ge 26 ] || die "要 Xcode 26+"

if [ ! -e Config/Signing.local.xcconfig ]; then
  [ "${CI:-}" = "true" ] || die "本机请自己准备 Config/Signing.local.xcconfig"
  printf 'DEVELOPMENT_TEAM =\nMP_BUNDLE_ID_BASE = com.susu.MemoryPalace.next\n' > Config/Signing.local.xcconfig
fi

if ! xcrun metal -v >/dev/null 2>&1; then
  step "下载 Metal 工具链"; xcodebuild -downloadComponent MetalToolchain; endstep
fi
step "bootstrap-sandbox"; bash scripts/bootstrap-sandbox.sh; endstep
step "xcodegen generate"; xcodegen generate; endstep

mkdir -p build/bunny
log=build/bunny/device-$config.log
step "xcodebuild MemoryPalaceIOS $config generic/platform=iOS → $log"
set +e
xcodebuild -project MemoryPalace.xcodeproj -scheme MemoryPalaceIOS -configuration "$config" \
  -destination 'generic/platform=iOS' -derivedDataPath build/bunny/dd \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  build > "$log" 2>&1
rc=$?
set -e
endstep
if ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$log"; then
  echo "—— 报错（前 40 条）——"; grep -E '(^|: )error: ' "$log" | sort -u | head -40 || true
  echo "—— 日志末尾 ——"; tail -60 "$log"
  die "真机 $config 没编过（rc=$rc）"
fi

app=$(find "build/bunny/dd/Build/Products/$config-iphoneos" -maxdepth 1 -name '*.app' | head -1)
[ -n "$app" ] || die "没找到 .app"
step "打包 ipa"
rm -rf build/bunny/Payload && mkdir -p build/bunny/Payload
cp -R "$app" build/bunny/Payload/
(cd build/bunny && rm -f BunnyPalaceNext-unsigned.ipa && zip -qry BunnyPalaceNext-unsigned.ipa Payload)
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist" || true
ls "$app/PlugIns" 2>/dev/null || true
du -sh build/bunny/BunnyPalaceNext-unsigned.ipa
endstep
echo "✅ build/bunny/BunnyPalaceNext-unsigned.ipa"
