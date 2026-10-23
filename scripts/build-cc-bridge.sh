#!/usr/bin/env bash
# Phase 2: cc-bridge 二进制 build script
#
# 输入：cc-bridge/hub.ts + cc-bridge/mcp-server.ts（及它们 import 的本地模块）
# 输出：build/cc-bridge/
#   - hub-arm64 (签名 + Hardened Runtime + JIT entitlements)
#   - hub-x64    （同上，baseline target 兼容所有 Intel Mac）
#   - mcp-server-arm64
#   - mcp-server-x64
#   - ATTRIBUTION.md（third-party LICENSE）
#
# 调用方：Xcode pre-build script（Phase 2.5 集成进 project.yml）
#        或本地手动 `bash scripts/build-cc-bridge.sh`
#
# 依赖：bun (1.3.11 锁定，见 .bun-version)；没有 cc-bridge/node_modules 时按 bun.lock 装
# 签名身份按顺序选：
#   1. CC_BRIDGE_SIGN_IDENTITY（显式；"-" = ad-hoc）
#   2. 有 DEVELOPMENT_TEAM（Xcode 预构建自带）且钥匙串里有 "Developer ID Application: … (<TEAM>)" → 用它
#   3. 否则 ad-hoc。Release 构建落到这一步直接失败（防发版时悄悄签成 ad-hoc），要 ad-hoc 就显式设 1
# Team 校验只在非 ad-hoc 时做：期望值 = CC_BRIDGE_TEAM_ID，没设就取身份字符串末尾括号里的 Team。
# 安全时间戳只在 Release 打（公证要，得联网连 Apple 时间戳服务器，失败重试 3 次）；Debug / 测试 / 手动跑 --timestamp=none。
# 注意：spike 验证 bun compile 自动加 adhoc 签名，本机可裸跑；
#       这里强制重签 Developer ID 为 archive/distribute 准备。

set -euo pipefail

# 路径解析（脚本不依赖被 cwd 调用，从脚本所在目录推 repo root）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$REPO_ROOT/cc-bridge"
OUT_DIR="$REPO_ROOT/build/cc-bridge"
ENT="$SRC_DIR/hub.entitlements"
BINS=(hub-arm64 hub-x64 mcp-server-arm64 mcp-server-x64)

find_developer_id() {  # $1 = Team ID；钥匙串里第一个匹配的 Developer ID Application 身份，没有输出空
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' -v t="($1)" 'index($2, "Developer ID Application: ") == 1 && substr($2, length($2) - length(t) + 1) == t { print $2; exit }' \
    || true
}

if [[ -n "${CC_BRIDGE_SIGN_IDENTITY:-}" ]]; then
  SIGN_ID="$CC_BRIDGE_SIGN_IDENTITY"
else
  SIGN_ID=""
  [[ -n "${DEVELOPMENT_TEAM:-}" ]] && SIGN_ID=$(find_developer_id "$DEVELOPMENT_TEAM")
  if [[ -z "$SIGN_ID" ]]; then
    if [[ "${CONFIGURATION:-}" == Release && -n "${DEVELOPMENT_TEAM:-}" ]]; then
      echo "❌ [build-cc-bridge] Release 构建，但钥匙串里没有 Developer ID Application (… ($DEVELOPMENT_TEAM))"
      echo "   要用 ad-hoc 签就设 CC_BRIDGE_SIGN_IDENTITY=-"
      exit 1
    fi
    SIGN_ID="-"
    echo "[build-cc-bridge] 没找到 Developer ID 身份，用 ad-hoc 签（只能本机跑；发版设 CC_BRIDGE_SIGN_IDENTITY）"
  fi
fi
# 10-03 backend-2：Debug 编译碰上「The timestamp service is not available.」整个编译挂掉
TS_FLAG=--timestamp=none
[[ "${CONFIGURATION:-}" == Release ]] && TS_FLAG=--timestamp
TEAM_EXPECT=""
if [[ "$SIGN_ID" != "-" ]]; then
  TEAM_EXPECT="${CC_BRIDGE_TEAM_ID:-}"
  if [[ -z "$TEAM_EXPECT" && "$SIGN_ID" =~ \(([A-Z0-9]{10})\)$ ]]; then TEAM_EXPECT="${BASH_REMATCH[1]}"; fi
fi

# 体积 cache：输入没变就 skip。输入 = cc-bridge 下所有源码 / 配置 / 锁（带路径，改名也算）
# + bun 版本 + 本脚本 + entitlements + 签名身份、期望 Team、时间戳与否（Debug 的无时间戳产物不能被 Release 复用）。宁可多编不漏编。
# 排除：node_modules、e2e、测试、secrets/（hub 运行时状态）、.mcp.json 和隐藏目录
SOURCES_HASH=$(
  cd "$REPO_ROOT"
  {
    find cc-bridge \( -name node_modules -o -name e2e -o -name secrets -o -name '.?*' -type d \) -prune -o -type f \
      \( -name '*.ts' -o -name '*.js' -o -name '*.mjs' -o -name '*.json' -o -name '*.toml' -o -name bun.lock \) \
      ! -name '*.test.ts' ! -name .mcp.json -print
    printf '%s\n' .bun-version scripts/build-cc-bridge.sh cc-bridge/hub.entitlements
  } | LC_ALL=C sort -u | tr '\n' '\0' | xargs -0 shasum -a 256 \
    | { cat; printf 'sign=%s team=%s ts=%s\n' "$SIGN_ID" "$TEAM_EXPECT" "$TS_FLAG"; } | shasum -a 256 | cut -d' ' -f1
)
CACHE_FILE="$OUT_DIR/.sources-hash"
if [[ -f "$CACHE_FILE" && "$(cat "$CACHE_FILE" 2>/dev/null)" == "$SOURCES_HASH" ]]; then
  all_there=1
  for f in "${BINS[@]}"; do [[ -f "$OUT_DIR/$f" ]] || all_there=0; done
  if [[ $all_there == 1 ]]; then
    echo "[build-cc-bridge] sources unchanged (hash $SOURCES_HASH), skip"
    exit 0
  fi
fi

mkdir -p "$OUT_DIR"

# bun 版本守护：锁定 1.3.11（避开 1.3.12 macOS arm64 code sig 截断 bug #29120）
EXPECTED_BUN_VERSION=$(cat "$REPO_ROOT/.bun-version" 2>/dev/null || echo "")
CURRENT_BUN_VERSION=$(bun --version 2>/dev/null || echo "")
if [[ -n "$EXPECTED_BUN_VERSION" && "$CURRENT_BUN_VERSION" != "$EXPECTED_BUN_VERSION" ]]; then
  echo "[build-cc-bridge] ⚠️ bun version mismatch: expected $EXPECTED_BUN_VERSION, got $CURRENT_BUN_VERSION"
  echo "[build-cc-bridge] 若是 1.3.12 必须降级（arm64 code sig 截断 bug）。继续 build..."
fi

if [[ ! -d "$SRC_DIR/node_modules" ]]; then
  echo "[build-cc-bridge] 没有 cc-bridge/node_modules，按 bun.lock 安装"
  (cd "$SRC_DIR" && bun install --frozen-lockfile)
fi

echo "[build-cc-bridge] bun $CURRENT_BUN_VERSION → ${OUT_DIR}（签名：${SIGN_ID}）"

# 单文件编译 helper
compile_one() {
  local src="$1"        # cc-bridge/xxx.ts
  local target="$2"     # bun-darwin-arm64 或 bun-darwin-x64-baseline
  local outfile="$3"    # build/cc-bridge/xxx-arm64
  echo "  → $outfile ($target)"
  bun build "$src" \
    --compile \
    --target="$target" \
    --minify \
    --outfile="$outfile" >/dev/null
  sign_one "$outfile"
}

# 强制重签 + Hardened Runtime + JIT entitlements。失败不吞：打时间戳时重试（服务器偶尔连不上），最后原样打出 codesign 的报错退出
sign_one() {
  local f="$1" tries=1 max=1 err
  [[ "$TS_FLAG" == --timestamp ]] && max=3
  while ! err=$(codesign --force --options runtime "$TS_FLAG" --entitlements "$ENT" --sign "$SIGN_ID" "$f" 2>&1); do
    err=$(printf '%s\n' "$err" | grep -v "replacing existing signature" || true)
    if (( tries >= max )); then
      echo "❌ $(basename "$f") codesign 失败（试了 $tries 次）："
      echo "$err"
      exit 1
    fi
    echo "  ⚠️ codesign 失败（第 $tries 次），重试：$err"
    sleep "${CC_BRIDGE_SIGN_RETRY_SLEEP:-5}"
    tries=$((tries + 1))
  done
}

# 四个二进制：hub + mcp-server，各 arm64 + x64-baseline
compile_one "$SRC_DIR/hub.ts"        "bun-darwin-arm64"          "$OUT_DIR/hub-arm64"
compile_one "$SRC_DIR/hub.ts"        "bun-darwin-x64-baseline"   "$OUT_DIR/hub-x64"
compile_one "$SRC_DIR/mcp-server.ts" "bun-darwin-arm64"          "$OUT_DIR/mcp-server-arm64"
compile_one "$SRC_DIR/mcp-server.ts" "bun-darwin-x64-baseline"   "$OUT_DIR/mcp-server-x64"

# 验证：每个 binary 格式 + 签名团队（set -euo pipefail + grep 的 race，改成先存变量再 grep）
echo "[build-cc-bridge] verify"
for f in "${BINS[@]}"; do
  if ! file "$OUT_DIR/$f" | grep -q "Mach-O"; then
    echo "❌ $f 不是 Mach-O"; exit 1
  fi
  if ! codesign --verify "$OUT_DIR/$f" 2>/dev/null; then
    echo "❌ $f 签名无效"; exit 1
  fi
  if [[ -n "$TEAM_EXPECT" ]]; then
    sig_info=$(codesign -dvv "$OUT_DIR/$f" 2>&1 || true)
    if ! echo "$sig_info" | grep -q "TeamIdentifier=$TEAM_EXPECT"; then
      echo "❌ $f 不是 $TEAM_EXPECT 签的"
      echo "$sig_info" | head -3
      exit 1
    fi
  fi
  echo "  ✓ $f"
done

# 写 cache
echo "$SOURCES_HASH" > "$CACHE_FILE"

echo "[build-cc-bridge] ✅ done"
du -sh "$OUT_DIR"/*
