#!/bin/zsh
# 像素对拍：在回归机上跑 MemoryPalaceIOSTests/TranscriptParityTests。
# 用法：zsh Packages/TranscriptKit/scripts/parity.sh <日志目录> [只跑的测试名，如 TranscriptParityTests/testNewPageMatchesOldPage]
# 不重编：前面加 SKIP_BUILD=1
# 条件照 Warden 11-11：租 regress；开机前只能有 9451 Booted；负载高先等；跑完 shutdown 再 release；不碰 9451。
set -u
OUT="$1"
ONLY="${2:-TranscriptParityTests}"
WT="$(cd "$(dirname "$0")/../../.." && pwd)"
REG="F3BAB89B-5F61-438F-90E8-3F93E70BF83C"
DAILY="9451D1D2-7F24-46CB-B7FB-2AA3AD6304A9"
DEST="platform=iOS Simulator,id=$REG"
cd "$WT" || exit 1

if [ "${SKIP_BUILD:-0}" != "1" ]; then
xcodegen generate >/dev/null 2>&1
xcodebuild build-for-testing -scheme MemoryPalaceIOSTests -destination "$DEST" > "$OUT/parity-bft.log" 2>&1
rc=$?
echo "bft exit=$rc"
grep -E "error:|TEST BUILD" "$OUT/parity-bft.log" | sort -u | head -20
[ $rc -eq 0 ] || exit $rc
fi

device-lease acquire regress --why "重构 R1 像素对拍 TranscriptParityTests（合成夹具，隔离宿主）" || exit 1
trap 'xcrun simctl shutdown "$REG" >/dev/null 2>&1; device-lease release regress 2>&1 | tail -1' EXIT

for i in $(seq 1 60); do
  others=$(xcrun simctl list devices | grep "(Booted)" | grep -v "$DAILY" | grep -v "$REG" | wc -l | tr -d ' ')
  load=$(sysctl -n vm.loadavg | awk '{print int($3)}')
  if [ "$others" = "0" ] && [ "$load" -le 40 ]; then break; fi
  echo "等：别的模拟器 $others 台开着，5 分钟负载 $load"
  sleep 30
done

xcrun simctl boot "$REG" >/dev/null 2>&1
xcrun simctl bootstatus "$REG" -b > "$OUT/parity-boot.log" 2>&1
echo "sim booted rc=$?"

MEDIA="$HOME/MemoryPalace-docs-media/docs/evidence/transcript-parity"
mkdir -p "$MEDIA"
rc=1
for attempt in 1 2 3; do
  xcrun simctl spawn "$REG" log stream --level default --predicate 'process == "记忆花园"' > "$OUT/parity-simlog-$attempt.txt" 2>&1 &
  LOGPID=$!
  xcodebuild test-without-building -scheme MemoryPalaceIOSTests -destination "$DEST" \
    -only-testing:"MemoryPalaceIOSTests/$ONLY" > "$OUT/parity-test.log" 2>&1 &
  XPID=$!
  connected=0
  i=0
  while [ $i -lt 60 ]; do
    sleep 5
    kill -0 $XPID 2>/dev/null || break
    # 编译闸因为机器超载在排队：还没开始跑，不计时
    if tail -1 "$OUT/parity-test.log" 2>/dev/null | grep -q "机器超载"; then continue; fi
    i=$((i+1))
    if grep -q "test-host\] home=" "$OUT/parity-simlog-$attempt.txt" 2>/dev/null && grep -q "Test Suite\|Test Case" "$OUT/parity-test.log" 2>/dev/null; then connected=1; break; fi
  done
  if [ $connected -eq 0 ] && kill -0 $XPID 2>/dev/null; then
    echo "第 $attempt 次：开跑 5 分钟没连上，采样后重试"
    APP=$(pgrep -f "CoreSimulator/Devices/$REG/.*记忆花园.app/记忆花园" | head -1)
    [ -n "$APP" ] && sample "$APP" 2 -file "$OUT/parity-sample-$attempt.txt" >/dev/null 2>&1
    kill $XPID >/dev/null 2>&1; wait $XPID 2>/dev/null
    kill $LOGPID >/dev/null 2>&1
    xcrun simctl terminate "$REG" com.susu.MemoryPalace.ios >/dev/null 2>&1
    continue
  fi
  wait $XPID; rc=$?
  kill $LOGPID >/dev/null 2>&1
  break
done
echo "test exit=$rc"
grep -E "\[像素对拍\]|error:|Executed [0-9]+ test|\*\* TEST|XCTAssert" "$OUT/parity-test.log" | cut -c1-400 | sort -u | head -60
echo "不一致的图（如有）：$MEDIA"
ls "$MEDIA" 2>/dev/null | head -20
exit $rc
