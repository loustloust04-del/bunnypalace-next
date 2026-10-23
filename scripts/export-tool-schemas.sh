#!/bin/bash
# 从 ToolRegistry 导出中性工具 schema（{name,description,parameters}）给 hub（TS）端。
# 复用 XCTest（testExportNeutralSchemaJSON 落 /tmp/tools-schema.json），不为导出单立 CLI target。
# hub 端用法（Phase 1）：运行时加载 cc-bridge/tools-schema.json——TS 侧只需要 name+schema 喂 LLM，
# 不需要类型化 codegen（B-D3 调研结论，见 plan-pi-style-toolbase.md 附录）。
# 分两步（10-01）：`xcodebuild test` 跑测试的全程都占着全机编译锁；build-for-testing 排锁编完，
# test-without-building 用本工作区 DerivedData 里的 xctestrun 跑，不占锁（scripts/xcodebuild-lock.sh 3b）。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
xcodebuild build-for-testing -scheme MemoryPalaceTests -destination 'platform=macOS' -quiet
DD=""
for d in "$HOME"/Library/Developer/Xcode/DerivedData/MemoryPalace-*; do
  if [ "$(plutil -extract WorkspacePath raw "$d/info.plist" 2>/dev/null)" = "$ROOT/MemoryPalace.xcodeproj" ]; then DD=$d; fi
done
XCTESTRUN=$(ls -t "$DD"/Build/Products/MemoryPalaceTests_*macosx*.xctestrun 2>/dev/null | head -1 || true)
[ -n "$DD" ] && [ -n "$XCTESTRUN" ] || { echo "找不到本工作区的 MemoryPalaceTests xctestrun（DerivedData：${DD:-无}）" >&2; exit 1; }
xcodebuild test-without-building -xctestrun "$XCTESTRUN" -destination 'platform=macOS' \
  -only-testing:MemoryPalaceTests/ToolRegistryTests/testExportNeutralSchemaJSON -quiet
cp /tmp/tools-schema.json cc-bridge/tools-schema.json
echo "exported → cc-bridge/tools-schema.json"
