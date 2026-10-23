#!/bin/bash
# 拉取 mermaid 官方预编译包 → MemoryPalace/Resources/Web/mermaid.min.js（原样，不再打包）
# 用法：bash scripts/mermaid-bundle/fetch.sh [版本号，缺省 12.0.0]
# dist/mermaid.min.js 是 esbuild 出的经典 IIFE（末尾 globalThis["mermaid"]=…，无动态 import）：
# WKWebView 的 file:// 下 ES module / 动态 import 会被 CORS 拒，必须用经典 <script src>（research-mermaid §2）
set -euo pipefail

VERSION="${1:-12.0.0}"
cd "$(dirname "$0")"
REPO_ROOT="$(cd ../.. && pwd)"
OUT="$REPO_ROOT/MemoryPalace/Resources/Web/mermaid.min.js"
VERSIONS="$REPO_ROOT/MemoryPalace/Resources/Web/mermaid.VERSIONS.txt"
LICENSE_OUT="$REPO_ROOT/MemoryPalace/Resources/Licenses/mermaid.txt"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

(cd "$WORK" && npm pack "mermaid@$VERSION" --silent >/dev/null)
tar -xzf "$WORK/mermaid-$VERSION.tgz" -C "$WORK"

SRC="$WORK/package/dist/mermaid.min.js"
# 验证：JS 语法 + 不含动态 import（有就会撞 file:// CORS）
node --check "$SRC"
if grep -q 'import(' "$SRC"; then
  echo "mermaid.min.js 含动态 import(，file:// 下会被 CORS 拒，停止" >&2
  exit 1
fi

cp "$SRC" "$OUT"
cp "$WORK/package/LICENSE" "$LICENSE_OUT"

{
  echo "# mermaid.min.js 来源信息（由 scripts/mermaid-bundle/fetch.sh 生成，勿手改）"
  echo "来源: npm mermaid@$VERSION 的 dist/mermaid.min.js（原样拷贝，未改动）"
  echo "许可: MIT（全文见 Resources/Licenses/mermaid.txt）"
  echo "获取命令: bash scripts/mermaid-bundle/fetch.sh $VERSION"
  echo "获取时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "大小: $(wc -c < "$OUT" | tr -d ' ') bytes"
  echo "sha256: $(shasum -a 256 "$OUT" | cut -d' ' -f1)"
} > "$VERSIONS"

echo "完成: $OUT"
cat "$VERSIONS"
