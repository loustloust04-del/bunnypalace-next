#!/bin/bash
# 跑「绑中心对象」那批 Mac 测试（docs/plan-重构.md R6 第 3 步的网兜）：core-net.sh <日志>
# 默认用已经编好的测试包（test-without-building）；前面加 BUILD=1 先重新生成工程并编测试包（改过代码就要加，不然跑的是旧包）
set -u
R="$(cd "$(dirname "$0")/../../.." && pwd)"
log=$1
cd "$R" || exit 1
classes="ConversationLoadGenerationTests HistoryWindowMaterializeTests ConversationDisplayModeTests BranchOffMainCountTests ChatReactionReworkTests EditAndResendAttachmentTests InspectorRealPathTests OpenAIReasoningStreamTests ThinkingSegmentTests ToolTuckingTests InputBarDraftPersistenceTests ChatCardTests BudgetGateTests AskUserToolTests MessageDisplayTests MessageDisplayTextTests SegmentDisplayTextTests BranchSelectionTests"
only=()
for c in $classes; do
  if ls MemoryPalaceTests | grep -q "^$c.swift$"; then only+=("-only-testing:MemoryPalaceTests/$c"); else echo "没有这个测试文件：$c"; fi
done
if [ "${BUILD:-0}" = 1 ]; then
  xcodegen generate > "$log.build" 2>&1 && xcodebuild build-for-testing -scheme MemoryPalaceTests -destination 'platform=macOS' >> "$log.build" 2>&1
  rc=$?
  echo "编测试包 rc=$rc"
  [ $rc = 0 ] || { grep -aE "error:" "$log.build" | sort -u | head -20 | cut -c1-300; exit $rc; }
fi
start=$(date +%s)
xcodebuild test-without-building -scheme MemoryPalaceTests -destination 'platform=macOS' "${only[@]}" > "$log" 2>&1
rc=$?
echo "rc=$rc 用时 $(( $(date +%s) - start )) 秒"
grep -aE "Test Suite '[A-Za-z]+Tests' (passed|failed)" "$log" | sed -E "s/ at .*//" | sort -u
grep -aE "Executed [0-9]+ tests" "$log" | tail -1
grep -aE "error: -\[" "$log" | cut -c1-260 | head -15
