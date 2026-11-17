#!/bin/bash
# 文件夹模式的 hub（docs/plan-folder-floor.md P0）：同一份 hub.ts 换配置起第二个实例，工作目录是你给的文件夹。
#
#   ./start_folder_hub.sh <文件夹绝对路径> [端口，默认 7891]
#
# 手动起、Ctrl-C 停（开机自启以后再说）。和主 hub（7890）互不相干：自己的端口、口令、状态目录、tmux 服务器、
# thinking 暂存、自主任务目录都在 ~/.cc-bridge-folder/<文件夹的短哈希>/ 下，不碰文件夹本身，也不碰主 hub 的 secrets/。
# 推送用的 .p8 跟着源码目录走（cc-bridge/secrets/）：从主仓的 cc-bridge 起才有推送，从工位起没有。
# 账号：在状态目录的 secrets/hub-config.json 里手写 accounts（格式见 folder-mode.ts parseAccounts），不写就只有默认账号。
set -euo pipefail

FOLDER=${1:?用法：$0 <文件夹绝对路径> [端口]}
PORT=${2:-7891}
case "$FOLDER" in /*) ;; *) echo "文件夹要写绝对路径：$FOLDER" >&2; exit 2 ;; esac
[ -d "$FOLDER" ] || { echo "不是一个文件夹：$FOLDER" >&2; exit 2; }
[ "$PORT" != 7890 ] || { echo "7890 是主 hub 的端口，换一个" >&2; exit 2; }
FOLDER=${FOLDER%/}

DIR="$(cd "$(dirname "$0")" && pwd)"
SLUG=$(printf '%s' "$FOLDER" | shasum | cut -c1-10)
STATE="${MP_FOLDER_HUB_STATE:-$HOME/.cc-bridge-folder/$SLUG}"
# tmux 的 socket 是 <状态目录>/tmux/tmux-<uid>/default，系统限制路径 104 字节以内，太长 tmux 连不上
if [ $(( ${#STATE} + 30 )) -gt 104 ]; then echo "状态目录路径太长（tmux socket 会超过 104 字节）：$STATE" >&2; exit 2; fi
mkdir -p "$STATE/secrets" "$STATE/agent" "$STATE/spool" "$STATE/tmux"
chmod 700 "$STATE" "$STATE/secrets" "$STATE/tmux"
printf '%s\n' "$FOLDER" > "$STATE/folder"   # 给人看的：这个状态目录是哪个文件夹的

TOKEN_FILE="$STATE/secrets/hub-token"
if [ ! -s "$TOKEN_FILE" ]; then
  (umask 077; head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$TOKEN_FILE")
fi

# 自己的 tmux 服务器：hub 里同步 / 异步的 tmux 调用、CC 里的 mcp-server 都跟着这个目录走；
# 清掉继承来的 TMUX，免得在别的 tmux 窗口里起它时连回外面那个
unset TMUX TMUX_PANE
export TMUX_TMPDIR="$STATE/tmux"

# 主 hub 那套只属于它的变量一律不带进来
unset MP_CC_WORKDIR MP_CODEX_WORKDIR MP_CC_HUB_TOKEN MP_CC_TMUX_SOCKET MP_CC_MCP_SERVER_BIN CC_MEMORY_SYNC_DIR MP_CC_WARROOM

export MP_HUB_MODE=folder MP_HUB_FOLDER="$FOLDER"
export MP_CC_HUB_PORT="$PORT" MP_CC_HUB_HOST="${MP_CC_HUB_HOST:-auto}" MP_CC_HUB_TOKEN_FILE="$TOKEN_FILE"
export MP_CC_SECRETS_DIR="$STATE/secrets" MP_CC_AGENT_DIR="$STATE/agent" MP_CC_THINKING_SPOOL="$STATE/spool"
export MP_CC_DEFAULT_TRANSPORT=tmux MP_CC_RELAY_CONNECTOR=off

echo "[folder-hub] 文件夹 $FOLDER"
echo "[folder-hub] 端口 $PORT · 状态目录 $STATE"
echo "[folder-hub] 看它的 tmux：TMUX_TMPDIR='$STATE/tmux' tmux ls"
cd "$DIR"
exec bun run hub.ts
