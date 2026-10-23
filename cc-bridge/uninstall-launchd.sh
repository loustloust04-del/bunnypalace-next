#!/usr/bin/env bash
# 卸掉 cc-bridge 自愈守护（hub + watchdog）。卸完 hub 会停——之后想跑得手动 start_hub_lan.sh 或重装。
set -e
LA="$HOME/Library/LaunchAgents"
DOM="gui/$(id -u)"
# 只卸一个实例：MP_LAUNCHD_PREFIX 指定，或者只装了一个时就是它
EXISTING=("$LA"/*.cc-bridge-hub.plist)
[ -e "${EXISTING[0]}" ] || EXISTING=()
if [ -n "$MP_LAUNCHD_PREFIX" ]; then PREFIX="$MP_LAUNCHD_PREFIX"
elif [ ${#EXISTING[@]} -eq 1 ]; then PREFIX="$(basename "${EXISTING[0]}" .cc-bridge-hub.plist)"
elif [ ${#EXISTING[@]} -eq 0 ]; then echo "[uninstall] 没装过，什么都没做"; exit 0
else echo "[uninstall] ✗ 装了不止一个：${EXISTING[*]}，用 MP_LAUNCHD_PREFIX=<前缀> 指定卸哪个"; exit 1; fi
for L in "$PREFIX.cc-bridge-hub" "$PREFIX.cc-bridge-watchdog"; do
  launchctl bootout "$DOM/$L" 2>/dev/null || true
  rm -f "$LA/$L.plist"
  echo "[uninstall] 卸了 $L"
done
echo "✅ 卸完。hub 已停。"
