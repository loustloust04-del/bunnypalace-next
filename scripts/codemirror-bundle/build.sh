#!/bin/bash
# 重建 MemoryPalace/Resources/Web/codemirror.bundle.js
# 用法：bash scripts/codemirror-bundle/build.sh
set -euo pipefail

cd "$(dirname "$0")"
REPO_ROOT="$(cd ../.. && pwd)"
OUT="$REPO_ROOT/MemoryPalace/Resources/Web/codemirror.bundle.js"
VERSIONS="$REPO_ROOT/MemoryPalace/Resources/Web/codemirror.bundle.VERSIONS.txt"

if [ -f package-lock.json ]; then
  npm ci --silent
else
  npm install --silent
fi

# IIFE 经典脚本挂 window.MPCodeMirror：WKWebView 的 file:// 下 ES module import 会被
# CORS（Origin null）拒掉，经典 <script src> 不受限——这是 app 内 CodeMirror 能加载的前提
npx esbuild entry.js --bundle --format=iife --global-name=MPCodeMirror --outfile="$OUT"

# 验证：JS 语法 + 关键导出齐全
node --check "$OUT"
node -e "
(0, eval)(require('fs').readFileSync(process.argv[1], 'utf8'));
const m = globalThis.MPCodeMirror;
if (!m) { console.error('MPCodeMirror 全局未生成'); process.exit(1); }
const want = ['EditorState','EditorView','HighlightStyle','SearchQuery','StateField','basicSetup','bracketMatching','defaultHighlightStyle','foldGutter','foldKeymap','indentOnInput','keymap','markdown','markdownLanguage','minimalSetup','searchExtensions','setSearchQuery','replaceNext','replaceAll','syntaxHighlighting','tags','Decoration','ViewPlugin','RangeSetBuilder','WidgetType'];
const missing = want.filter(k => !(k in m));
if (missing.length) { console.error('缺导出:', missing.join(', ')); process.exit(1); }
console.log('导出齐全 ✅ (' + want.length + ' 个)');
" "$OUT"

# 记录本次 bundle 的依赖版本和大小
{
  echo "# codemirror.bundle.js 构建信息（由 scripts/codemirror-bundle/build.sh 生成，勿手改）"
  echo "构建时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "bundle 大小: $(wc -c < "$OUT" | tr -d ' ') bytes"
  echo ""
  npm ls --depth=0 2>/dev/null | tail -n +2
} > "$VERSIONS"

echo "完成: $OUT"
cat "$VERSIONS"
