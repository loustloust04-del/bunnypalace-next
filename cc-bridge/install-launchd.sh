#!/usr/bin/env bash
# cc-bridge 自愈一键安装：把 hub + watchdog 交给 launchd 守护，迁掉手动 nohup。
# 前提：bun 已开 Full Disk Access（否则 launchd 跑 bun 读 ~/Desktop 下 hub.ts 会 EPERM）。
# 幂等：重复跑会先 bootout 再 bootstrap。token 从 hub-token.txt 注入 hub plist（不进仓库）。
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
LA="$HOME/Library/LaunchAgents"
DOM="gui/$(id -u)"
# label 前缀：已装过就沿用（免得新旧两个 hub 抢 7890）；没装过用 MP_LAUNCHD_PREFIX 或 local.memorypalace
EXISTING=("$LA"/*.cc-bridge-hub.plist)
[ -e "${EXISTING[0]}" ] || EXISTING=()
if [ ${#EXISTING[@]} -gt 1 ]; then
  echo "[install] ✗ 装了不止一个 hub：${EXISTING[*]}，先用 uninstall-launchd.sh 卸到只剩一个"; exit 1
elif [ ${#EXISTING[@]} -eq 1 ]; then
  PREFIX="$(basename "${EXISTING[0]}" .cc-bridge-hub.plist)"
  if [ -n "$MP_LAUNCHD_PREFIX" ] && [ "$MP_LAUNCHD_PREFIX" != "$PREFIX" ]; then
    echo "[install] ✗ 已装的是 $PREFIX，要换成 $MP_LAUNCHD_PREFIX 先跑 uninstall-launchd.sh"; exit 1
  fi
else
  PREFIX="${MP_LAUNCHD_PREFIX:-local.memorypalace}"
fi
HUB=$PREFIX.cc-bridge-hub
WD=$PREFIX.cc-bridge-watchdog
BUN="$(command -v bun || echo "$HOME/.bun/bin/bun")"

if [ ! -f "$HERE/hub-token.txt" ]; then
  echo "[install] ✗ 找不到 hub-token.txt，先跑一次 start_hub_lan.sh 生成 token"; exit 1
fi
TOKEN="$(tr -d '[:space:]' < "$HERE/hub-token.txt")"

echo "[install] 停掉手动 nohup 的 hub（避免抢 7890）…"
pkill -f "bun run hub.ts" 2>/dev/null || true
sleep 1

echo "[install] 装 plist → $LA（label $HUB，跑 $HERE/hub.ts，bun $BUN）"
mkdir -p "$LA"
# 值先做 XML 转义再做 sed 替换串转义；渲染到临时文件、plutil 校验过再换上
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/[|\\&]/\\&/g'; }
render() {
  local tmp="$2.tmp.$$"
  sed -e "s|__PREFIX__|$(esc "$PREFIX")|g" -e "s|__BUN_DIR__|$(esc "$(dirname "$BUN")")|g" -e "s|__BUN__|$(esc "$BUN")|g" \
      -e "s|__HUB_DIR__|$(esc "$HERE")|g" -e "s|__HOME__|$(esc "$HOME")|g" -e "s|__HUB_TOKEN__|$(esc "$TOKEN")|g" "$1" > "$tmp"
  plutil -lint -s "$tmp" || { rm -f "$tmp"; echo "[install] ✗ 渲染出的 $2 不是合法 plist"; exit 1; }
  mv "$tmp" "$2"
}
render "$HERE/launchd/cc-bridge-hub.plist.template" "$LA/$HUB.plist"
render "$HERE/launchd/cc-bridge-watchdog.plist.template" "$LA/$WD.plist"

for L in "$HUB" "$WD"; do
  launchctl bootout "$DOM/$L" 2>/dev/null || true   # 若已加载，先卸
  launchctl bootstrap "$DOM" "$LA/$L.plist"
  echo "[install] bootstrapped $L"
done

sleep 6
echo "[install] hub 状态："
launchctl print "$DOM/$HUB" 2>/dev/null | grep -E "state =|pid =" | head -3 || true
echo -n "[install] /health: "; curl -s --max-time 5 http://127.0.0.1:7890/health || echo "(未响应——看 /tmp/cc-hub.log)"
echo
echo "✅ 装好了。"
echo "⚠️ 别忘了开【开机自动登录】：系统设置 → 用户与群组 → 自动登录 → 选本账户。"
echo "   否则断电重启又没人在场时 launchd 用户域不会跑，全哑。出远门前务必确认。"
