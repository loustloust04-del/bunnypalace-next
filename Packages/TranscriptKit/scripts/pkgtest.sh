#!/bin/zsh
# 本地包的 iOS 测试，在回归机上跑。用法：zsh Packages/TranscriptKit/scripts/pkgtest.sh <日志目录> <包目录名> <scheme> <only-testing>
# 例：… TranscriptKit TranscriptKit-Package TranscriptUIKitTests
#     … SwiftStreamingMarkdown SwiftStreamingMarkdown SwiftStreamingMarkdownTests/MarkdownBlockRowsTests
# 条件同 parity.sh（Warden 11-11）。
set -u
OUT="$1"
PKG="$(cd "$(dirname "$0")/../../.." && pwd)/Packages/$2"
SCHEME="$3"
ONLY="$4"
TAG="$2"
REG="F3BAB89B-5F61-438F-90E8-3F93E70BF83C"
DAILY="9451D1D2-7F24-46CB-B7FB-2AA3AD6304A9"
DEST="platform=iOS Simulator,id=$REG"
cd "$PKG" || exit 1

xcodebuild build-for-testing -scheme "$SCHEME" -destination "$DEST" > "$OUT/pkg-bft-$TAG.log" 2>&1
rc=$?
echo "pkg bft exit=$rc"
grep -E "error:|TEST BUILD" "$OUT/pkg-bft-$TAG.log" | sort -u | head -20
[ $rc -eq 0 ] || exit $rc

device-lease acquire regress --why "重构 R2 包内 iOS 测试 $ONLY（无宿主 app）" || exit 1
trap 'xcrun simctl shutdown "$REG" >/dev/null 2>&1; device-lease release regress 2>&1 | tail -1' EXIT
for i in $(seq 1 60); do
  others=$(xcrun simctl list devices | grep "(Booted)" | grep -v "$DAILY" | grep -v "$REG" | wc -l | tr -d ' ')
  load=$(sysctl -n vm.loadavg | awk '{print int($3)}')
  if [ "$others" = "0" ] && [ "$load" -le 40 ]; then break; fi
  echo "等：别的模拟器 $others 台开着，5 分钟负载 $load"
  sleep 30
done

xcodebuild test-without-building -scheme "$SCHEME" -destination "$DEST" \
  -only-testing:"$ONLY" > "$OUT/pkg-test-$TAG.log" 2>&1
rc=$?
echo "pkg test exit=$rc"
grep -E "error:|Executed [0-9]+ test|\*\* TEST|XCTAssert|failed" "$OUT/pkg-test-$TAG.log" | cut -c1-400 | sort -u | head -40
exit $rc
