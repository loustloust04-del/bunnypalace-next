#!/bin/bash
# gen-icon-assets.sh —— 下载 Remix Icon / simple-icons SVG 生成 Assets.xcassets imageset
#
# 产物提交进仓，脚本可重跑（幂等：重跑覆盖同名 imageset）。
# 每个 imageset 写 template-rendering-intent: template + preserves-vector-representation: true，
# 由 AppIconView 统一 tint 跟 Theme token（品牌图标不引原色，见 docs/plan-icons.md）。
#
# 归一化两步（Xcode SVG 导入器要求）：
#   1. 源 SVG 只有 viewBox 没有 width/height  → 补 width="24" height="24"
#   2. Remix 的 fill="currentColor" 在 asset catalog 里无上下文 → 换成 #000000（template 只取 alpha）

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSETS="$REPO_ROOT/MemoryPalace/Assets.xcassets"
REMIX_BASE="https://raw.githubusercontent.com/Remix-Design/RemixIcon/master/icons"
SIMPLE_BASE="https://raw.githubusercontent.com/simple-icons/simple-icons/develop/icons"

# asset 名|来源|路径
#   remix  → 路径是 "<Category>/<file>.svg"（Category 含空格/& 会被 URL 编码）
#   simple → 路径是 "<name>.svg"
MANIFEST=(
  # —— 品牌（provider logo，Remix Logos 用 -fill 实心版）——
  "ri-openai|remix|Logos/openai-fill.svg"
  "ri-anthropic|remix|Logos/anthropic-fill.svg"
  "ri-claude|remix|Logos/claude-fill.svg"
  "ri-gemini|remix|Logos/gemini-fill.svg"
  "ri-deepseek|remix|Logos/deepseek-fill.svg"
  "ri-grok-ai|remix|Logos/grok-ai-fill.svg"
  "ri-qwen-ai|remix|Logos/qwen-ai-fill.svg"
  "ri-zhipu-ai|remix|Logos/zhipu-ai-fill.svg"
  # —— 品牌（Remix 无，simple-icons 补）——
  "ri-openrouter|simple|openrouter.svg"
  "ri-moonshotai|simple|moonshotai.svg"
  "ri-ollama|simple|ollama.svg"
  # —— 通用（C 级替换用，Remix -line 线性版跟设置树细笔画调性）——
  "ri-robot-2|remix|User & Faces/robot-2-line.svg"
  "ri-emoji-sticker|remix|Communication/emoji-sticker-line.svg"
  "ri-sword|remix|Game & Sports/sword-line.svg"
  "ri-stack|remix|Business/stack-line.svg"
  "ri-compass-3|remix|Map/compass-3-line.svg"
  # —— 聊天页（09-28 粟粟：去 Remix 挑好点的）——
  "ri-history|remix|System/history-line.svg"
  "ri-git-branch|remix|Development/git-branch-line.svg"
)

# 路径分段 URL 编码（保留 /）
urlencode_path() {
  python3 -c 'import sys,urllib.parse; print("/".join(urllib.parse.quote(s) for s in sys.argv[1].split("/")))' "$1"
}

normalize_svg() {
  python3 - "$1" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
m = re.search(r'<svg\b[^>]*>', s)
if not m:
    sys.exit(f"no <svg> root in {p}")
tag = m.group(0)
if 'viewBox="0 0 24 24"' not in tag:
    sys.exit(f"unexpected viewBox in {p}: {tag[:120]}")
if ' width=' not in tag:
    tag = tag.replace('<svg', '<svg width="24" height="24"', 1)
tag = tag.replace('currentColor', '#000000')
open(p, "w", encoding="utf-8").write(s[:m.start()] + tag + s[m.end():])
PY
}

fail=0
for entry in "${MANIFEST[@]}"; do
  IFS='|' read -r name source path <<<"$entry"
  case "$source" in
    remix)  url="$REMIX_BASE/$(urlencode_path "$path")" ;;
    simple) url="$SIMPLE_BASE/$path" ;;
    *) echo "unknown source: $source" >&2; exit 1 ;;
  esac

  dir="$ASSETS/$name.imageset"
  mkdir -p "$dir"
  svg="$dir/$name.svg"

  code=$(curl -sfL -o "$svg" -w "%{http_code}" "$url" || echo "000")
  if [[ "$code" != "200" ]] || [[ ! -s "$svg" ]]; then
    echo "FAIL  $name  HTTP $code  $url" >&2
    rm -f "$svg"
    fail=1
    continue
  fi

  normalize_svg "$svg"

  cat >"$dir/Contents.json" <<JSON
{
  "images": [
    {
      "filename": "$name.svg",
      "idiom": "universal"
    }
  ],
  "info": {
    "author": "xcode",
    "version": 1
  },
  "properties": {
    "preserves-vector-representation": true,
    "template-rendering-intent": "template"
  }
}
JSON

  echo "ok    $name  <- $url"
done

exit $fail
