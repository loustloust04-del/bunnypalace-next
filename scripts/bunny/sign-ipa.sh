#!/bin/bash
# [Bunny] 用正式身份（原 Bundle ID com.susu.MemoryPalace.ios + 粟粟团队开发证书）给 device-ipa.sh 产出的 .app 签名。
# ⚠️ 这个包装到手机上会「顶替」旧兔（同一 Bundle ID）——换车当天之前只做验证，不要安装。
# 需要环境变量：NEXT_P12_BASE64 NEXT_P12_PASSWORD NEXT_TEAM_ID NEXT_PROFILE_MAIN_B64 NEXT_PROFILE_WIDGET_B64 NEXT_PROFILE_PUSHNSE_B64
set -euo pipefail
cd "$(dirname "$0")/../.."
die() { echo "❌ $1" >&2; exit 1; }
for v in NEXT_P12_BASE64 NEXT_P12_PASSWORD NEXT_TEAM_ID NEXT_PROFILE_MAIN_B64 NEXT_PROFILE_WIDGET_B64 NEXT_PROFILE_PUSHNSE_B64; do
  [ -n "${!v:-}" ] || die "缺 $v"
done
W=build/bunny/sign; rm -rf "$W"; mkdir -p "$W"
APP_SRC=$(find build/bunny/Payload -maxdepth 1 -name '*.app' | head -1); [ -n "$APP_SRC" ] || die "没有 .app（先跑 device-ipa.sh）"
mkdir -p "$W/Payload"; cp -R "$APP_SRC" "$W/Payload/"; APP="$W/Payload/$(basename "$APP_SRC")"

echo "$NEXT_PROFILE_MAIN_B64"    | base64 --decode > "$W/main.mobileprovision"
echo "$NEXT_PROFILE_WIDGET_B64"  | base64 --decode > "$W/widget.mobileprovision"
echo "$NEXT_PROFILE_PUSHNSE_B64" | base64 --decode > "$W/pushnse.mobileprovision"

KC="$W/bunny-sign.keychain-db"; KCPW=$(uuidgen)
cleanup() { security delete-keychain "$KC" >/dev/null 2>&1 || true; rm -f "$W/cert.p12"; }
trap cleanup EXIT
echo "$NEXT_P12_BASE64" | base64 --decode > "$W/cert.p12"
security create-keychain -p "$KCPW" "$KC"
security set-keychain-settings -lut 3600 "$KC"
security unlock-keychain -p "$KCPW" "$KC"
security import "$W/cert.p12" -k "$KC" -P "$NEXT_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KC" >/dev/null
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
IDENT=$(security find-identity -v -p codesigning "$KC" | awk '/Apple Development/ {print $2; exit}')
[ -n "$IDENT" ] || die "钥匙串里没有可用的开发证书"
echo "签名身份：$(security find-identity -v -p codesigning "$KC" | grep "$IDENT" | sed 's/.*"\(.*\)"/\1/')"

# 生成 entitlements：上游源文件 + application-identifier / team / get-task-allow；并核对是描述文件的子集
make_ent() {   # $1=源 entitlements $2=描述文件 $3=Bundle ID $4=输出
  security cms -D -i "$2" > "$4.profile.plist"
  python3 - "$1" "$4.profile.plist" "$3" "$NEXT_TEAM_ID" "$4" <<'PY'
import plistlib, sys, fnmatch
src, prof, bid, team, out = sys.argv[1:]
e = plistlib.load(open(src, "rb")); p = plistlib.load(open(prof, "rb")); pe = p["Entitlements"]
appid = f"{team}.{bid}"
assert fnmatch.fnmatch(appid, pe["application-identifier"]), f"描述文件 {pe['application-identifier']} 不覆盖 {appid}"
e["application-identifier"] = appid
e["com.apple.developer.team-identifier"] = team
e["get-task-allow"] = bool(pe.get("get-task-allow", False))
for k, v in e.items():
    assert k in pe, f"描述文件没有权限 {k}"
    pv = pe[k]
    if isinstance(v, list):
        for item in v:
            ok = item in pv if isinstance(pv, list) else fnmatch.fnmatch(item, str(pv))
            assert ok or any(fnmatch.fnmatch(item, x) for x in (pv if isinstance(pv, list) else [pv])), f"{k} 里的 {item} 不在描述文件允许范围"
plistlib.dump(e, open(out, "wb"))
print(f"  {bid}: {sorted(e.keys())}")
PY
}
bid_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Info.plist"; }

# 先签内层：框架 / 动态库（无 entitlements）
find "$APP" -type d -name '*.framework' -o -type f -name '*.dylib' | while read -r f; do
  codesign --force --sign "$IDENT" --keychain "$KC" --timestamp=none "$f"
done
# 扩展
for appex in "$APP"/PlugIns/*.appex; do
  [ -d "$appex" ] || continue
  bid=$(bid_of "$appex")
  case "$bid" in
    *.Widget)  prof="$W/widget.mobileprovision";  src=MemoryPalaceWidget/MemoryPalaceWidget.entitlements ;;
    *.PushNSE) prof="$W/pushnse.mobileprovision"; src=MemoryPalacePushNSE/MemoryPalacePushNSE.entitlements ;;
    *) die "未知扩展 $bid（没有对应描述文件）" ;;
  esac
  cp "$prof" "$appex/embedded.mobileprovision"
  make_ent "$src" "$prof" "$bid" "$W/$(basename "$appex").entitlements"
  find "$appex" -type d -name '*.framework' | while read -r f; do codesign --force --sign "$IDENT" --keychain "$KC" --timestamp=none "$f"; done
  codesign --force --sign "$IDENT" --keychain "$KC" --timestamp=none --entitlements "$W/$(basename "$appex").entitlements" "$appex"
done
# 主 App
bid=$(bid_of "$APP")
[ "$bid" = "com.susu.MemoryPalace.ios" ] || die "主 App Bundle ID 是 $bid，不是 com.susu.MemoryPalace.ios"
cp "$W/main.mobileprovision" "$APP/embedded.mobileprovision"
make_ent MemoryPalaceIOS.entitlements "$W/main.mobileprovision" "$bid" "$W/main.entitlements"
codesign --force --sign "$IDENT" --keychain "$KC" --timestamp=none --entitlements "$W/main.entitlements" "$APP"

echo "—— 校验 ——"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -3
codesign -d --entitlements :- "$APP" 2>/dev/null | plutil -p - | head -30
(cd "$W" && rm -f ../BunnyPalaceNext-SIGNED-DO-NOT-INSTALL.ipa && zip -qry ../BunnyPalaceNext-SIGNED-DO-NOT-INSTALL.ipa Payload)
du -sh build/bunny/BunnyPalaceNext-SIGNED-DO-NOT-INSTALL.ipa
echo "✅ 已签名（换车当天之前不要安装：会顶替旧兔）"
