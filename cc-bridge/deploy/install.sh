#!/usr/bin/env bash
# cc-bridge VPS 部署脚本（check-only，按 codex review 收紧）
#
# 用法：在 VPS 上 git clone 或 scp 整个 cc-bridge/ 目录，cd 进去跑
#   sudo bash deploy/install.sh
#
# 不自动 sudo apt install——缺啥提示给命令让你自己装。
# 检查通过后才安装 systemd unit + 启动。
#
# 假设：
# - Ubuntu 22.04+ / Debian 12+（更老 distro 不保证 bun runtime 跑得动）
# - 你的 VPS 已装 Tailscale 并加入了 tailnet（iOS 端跟 VPS 同 tailnet 才能连）
# - 你订阅了 Claude Pro / Max（hub 桥接的是 Claude CLI，不是 API key）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"   # cc-bridge/ 源码目录

INSTALL_DIR="/opt/cc-bridge"
DATA_DIR="/var/lib/cc-bridge"
CONF_DIR="/etc/cc-bridge"
SERVICE_USER="ccbridge"
SERVICE_NAME="cc-bridge"
TOKEN_FILE="$CONF_DIR/token"
ENV_FILE="$CONF_DIR/env"

c_red()    { printf "\033[31m%s\033[0m\n" "$*"; }
c_green()  { printf "\033[32m%s\033[0m\n" "$*"; }
c_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
c_dim()    { printf "\033[2m%s\033[0m\n" "$*"; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    c_red "❌ 这个脚本要 root 跑（要写 /opt/cc-bridge、/etc/cc-bridge、systemd unit）"
    echo "   重新跑：sudo bash $0"
    exit 1
  fi
}

# === Step 1: 系统检查 ===
check_system() {
  echo "=== Step 1: 系统检查 ==="

  # OS
  if [[ ! -f /etc/os-release ]]; then
    c_red "❌ 没 /etc/os-release，无法识别 distro"; exit 1
  fi
  . /etc/os-release
  echo "  OS: $PRETTY_NAME"
  case "$ID" in
    ubuntu|debian) ;;
    *)
      c_yellow "  ⚠️ 当前只在 Ubuntu 22.04+ / Debian 12+ 测过。其他 distro 可能跑得起来但出问题不保证"
      ;;
  esac

  # arch
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64)  TARGET_ARCH="x64" ;;
    aarch64|arm64) TARGET_ARCH="arm64" ;;
    *)
      c_red "❌ 不支持的架构 $ARCH（只支持 x86_64 和 arm64）"; exit 1
      ;;
  esac
  echo "  Arch: $ARCH → bun-linux-$TARGET_ARCH"

  # systemd
  if ! command -v systemctl >/dev/null 2>&1; then
    c_red "❌ 没 systemd，本脚本只支持 systemd 系。"; exit 1
  fi

  c_green "  ✓ 系统检查通过"
}

# === Step 2: 依赖检查（check-only，缺啥提示）===
check_deps() {
  echo ""
  echo "=== Step 2: 依赖检查 ==="

  local missing=()

  if ! command -v bun >/dev/null 2>&1; then
    missing+=("bun")
  else
    echo "  ✓ bun: $(bun --version)"
  fi

  if ! command -v node >/dev/null 2>&1; then
    missing+=("node")
  else
    echo "  ✓ node: $(node --version)"
  fi

  if ! command -v npm >/dev/null 2>&1; then
    missing+=("npm")
  else
    echo "  ✓ npm: $(npm --version)"
  fi

  if ! command -v tmux >/dev/null 2>&1; then
    missing+=("tmux")
  else
    echo "  ✓ tmux: $(tmux -V)"
  fi

  if ! command -v qrencode >/dev/null 2>&1; then
    missing+=("qrencode")
  else
    echo "  ✓ qrencode: 装着"
  fi

  if ! command -v claude >/dev/null 2>&1; then
    missing+=("claude")
  else
    echo "  ✓ claude: $(claude --version 2>/dev/null | head -1)"
  fi

  if ! command -v tailscale >/dev/null 2>&1; then
    c_yellow "  ⚠️ 没装 Tailscale。强烈建议装 + tailscale up 后再继续（默认 hub 不绑 0.0.0.0，公网连不上）"
    echo "     装 Tailscale：curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up"
  else
    echo "  ✓ tailscale: 装着"
    if ! tailscale ip -4 >/dev/null 2>&1; then
      c_yellow "  ⚠️ Tailscale 装了但还没 tailscale up，先跑：sudo tailscale up"
    fi
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    c_red "❌ 缺这些工具："
    for d in "${missing[@]}"; do
      case "$d" in
        bun)      echo "   - bun       → curl -fsSL https://bun.sh/install | bash" ;;
        node|npm) echo "   - $d        → sudo apt install -y nodejs npm   # 或 nvm" ;;
        tmux)     echo "   - tmux      → sudo apt install -y tmux" ;;
        qrencode) echo "   - qrencode  → sudo apt install -y qrencode" ;;
        claude)   echo "   - claude    → sudo npm i -g @anthropic-ai/claude-code" ;;
      esac
    done
    echo ""
    echo "装完重新跑这个脚本。"
    exit 1
  fi

  c_green "  ✓ 依赖全装齐"
}

# === Step 3: 创建专用用户 ===
create_user() {
  echo ""
  echo "=== Step 3: 创建专用用户 $SERVICE_USER ==="
  if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    echo "  用户已存在，跳过"
  else
    useradd --system --shell /bin/bash --home-dir "$DATA_DIR" --create-home "$SERVICE_USER"
    c_green "  ✓ 创建用户 $SERVICE_USER（home=$DATA_DIR）"
  fi
}

# === Step 4: 准备目录 + 拷源码 ===
prepare_dirs() {
  echo ""
  echo "=== Step 4: 准备目录 ==="
  mkdir -p "$INSTALL_DIR" "$DATA_DIR" "$CONF_DIR" "$DATA_DIR/cc-rp" "$DATA_DIR/secrets"
  echo "  $INSTALL_DIR"
  echo "  $DATA_DIR/cc-rp（CC 工作目录，在这里写 CLAUDE.md 人设）"
  echo "  $DATA_DIR/secrets（hub 内部 session-map / reply-log）"
  echo "  $CONF_DIR（token + env）"
  echo ""
  # 整个 cc-bridge/ 拷过去，只排除依赖 / 本机状态 / 测试。hub.ts 会 import 一串本地模块、
  # 运行时还读 tools-schema.json / hook 脚本 / vendor/，按文件清单拷每次改 hub 都会漏。
  echo "  拷源码 $SRC_DIR → $INSTALL_DIR（排除 node_modules / secrets / e2e / *.test.ts）"
  tar -C "$SRC_DIR" \
    --exclude=./node_modules --exclude=./secrets --exclude=./e2e --exclude='*.test.ts' \
    -cf - . | tar -C "$INSTALL_DIR" -xf -

  # bun install npm deps
  cd "$INSTALL_DIR"
  echo "  跑 bun install..."
  bun install --production 2>&1 | tail -3

  chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" "$DATA_DIR"
  c_green "  ✓ 目录就绪"
}

# === Step 5: 生成 token（如果不存在）===
generate_token() {
  echo ""
  echo "=== Step 5: 生成 hub token ==="
  if [[ -f "$TOKEN_FILE" ]]; then
    echo "  token 已存在 $TOKEN_FILE，跳过"
  else
    # 16 字节 hex
    head -c 16 /dev/urandom | xxd -p -c 32 > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    chown "$SERVICE_USER:$SERVICE_USER" "$TOKEN_FILE"
    c_green "  ✓ 生成 16 字节 hex token → $TOKEN_FILE（chmod 600，只有 $SERVICE_USER 能读）"
  fi
}

# === Step 6: 写 EnvironmentFile + run-hub.sh ===
write_env() {
  echo ""
  echo "=== Step 6: systemd EnvironmentFile + 启动脚本 ==="

  # 默认 host: 127.0.0.1（codex review 强调不要默认 0.0.0.0）
  # 用户要让 iOS 远程连，要么改 host 到 Tailscale IP，要么 ssh tunnel
  # 自动探测 Tailscale IP（如果装了）
  local default_host="127.0.0.1"
  if command -v tailscale >/dev/null 2>&1 && tailscale ip -4 >/dev/null 2>&1; then
    default_host=$(tailscale ip -4 | head -1)
    c_green "  ✓ 探测到 Tailscale IP: $default_host（hub 会绑这个 + 127.0.0.1）"
  else
    c_yellow "  ⚠️ 没 Tailscale，hub 只绑 127.0.0.1（iOS 远程连不上）"
    echo "     部署完后装 Tailscale + sudo tailscale up，然后改 $ENV_FILE 的 MP_CC_HUB_HOST 为 \$(tailscale ip -4)"
  fi

  cat > "$ENV_FILE" <<EOF
MP_CC_HUB_PORT=7890
MP_CC_HUB_HOST=$default_host
MP_CC_HUB_TOKEN_FILE=$TOKEN_FILE
MP_CC_WORKDIR=$DATA_DIR/cc-rp
MP_CC_SECRETS_DIR=$DATA_DIR/secrets
MP_CC_TMUX_SESSION=mp-cc
PATH=/usr/local/bin:/usr/bin:/bin:$DATA_DIR/.bun/bin:$DATA_DIR/.local/bin
EOF
  chmod 640 "$ENV_FILE"
  chown root:"$SERVICE_USER" "$ENV_FILE"
  echo "  写好 $ENV_FILE"

  # run-hub.sh：systemd ExecStart 入口，简单 wrapper
  cat > "$INSTALL_DIR/run-hub.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
exec bun run hub.ts
EOF
  chmod 755 "$INSTALL_DIR/run-hub.sh"
  chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/run-hub.sh"
  echo "  写好 $INSTALL_DIR/run-hub.sh"
}

# === Step 7: systemd unit ===
install_unit() {
  echo ""
  echo "=== Step 7: 装 systemd unit ==="
  cp "$SCRIPT_DIR/cc-bridge.service" "/etc/systemd/system/$SERVICE_NAME.service"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME.service" 2>&1 | tail -3
  c_green "  ✓ systemd unit 装好，已开 enable（开机自启）"
}

# === Step 8: 启动 + 健康检查 ===
start_service() {
  echo ""
  echo "=== Step 8: 启动 cc-bridge ==="
  systemctl restart "$SERVICE_NAME.service"
  echo "  等 hub 起来（最多 10s）..."
  local i=0
  local port
  port=$(grep '^MP_CC_HUB_PORT=' "$ENV_FILE" | cut -d= -f2)
  while [[ $i -lt 10 ]]; do
    if curl -s "http://127.0.0.1:$port/health" | grep -q '"ok":true'; then
      c_green "  ✓ hub 跑起来了 + /health 返 ok"
      break
    fi
    sleep 1
    i=$((i+1))
  done
  if [[ $i -ge 10 ]]; then
    c_red "  ❌ hub 没在 10s 内起来"
    echo "     看 log：sudo journalctl -u $SERVICE_NAME -n 50"
    exit 1
  fi
}

# === Step 9: 输出 URL + token + QR ===
print_pair_info() {
  echo ""
  echo "════════════════════════════════════════════════════════════"
  c_green "✓ 部署完成！下面是配对信息——iPhone 端用"
  echo "════════════════════════════════════════════════════════════"

  local token host port url
  token=$(cat "$TOKEN_FILE")
  host=$(grep '^MP_CC_HUB_HOST=' "$ENV_FILE" | cut -d= -f2)
  port=$(grep '^MP_CC_HUB_PORT=' "$ENV_FILE" | cut -d= -f2)
  url="ws://$host:$port/cc"

  echo ""
  echo "Hub URL:   $url"
  echo "Token:     $token"
  echo ""
  c_yellow "⚠️ 这个 token 等于 hub 的密码——不要复制到 Discord/微信公开聊天 或者贴公网剪贴板"
  echo ""

  # ASCII QR（iOS 端扫码）
  echo "扫码（iOS 记忆花园 → 设置 → Claude Code → 扫码配对）："
  echo ""
  qrencode -t ANSI256 -o - "{\"mpcc\":1,\"u\":\"$url\",\"u2\":null,\"t\":\"$token\"}" 2>/dev/null || c_yellow "qrencode 出错；上面 URL+token 手填"

  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo ""
  echo "管理命令："
  echo "  sudo systemctl status $SERVICE_NAME       看状态"
  echo "  sudo systemctl restart $SERVICE_NAME      重启"
  echo "  sudo systemctl stop $SERVICE_NAME         停"
  echo "  sudo journalctl -u $SERVICE_NAME -f       看实时日志"
  echo ""
  echo "下一步：在 VPS 上启动 Claude Code（用 tmux 让 hub 能 attach 它）："
  echo "  sudo -u $SERVICE_USER -i"
  echo "  cd $DATA_DIR/cc-rp"
  echo "  # 首次写 CLAUDE.md 人设（可选）"
  echo "  vim CLAUDE.md"
  echo "  # 启动 CC（会跑 OAuth login 浏览器流，VPS 上拿 URL 用本机浏览器跑完）"
  echo "  claude"
  echo "  # OAuth 完了 Ctrl+D 退出，然后 hub 会自动 spawn 它"
}

# === main ===
need_root
check_system
check_deps
create_user
prepare_dirs
generate_token
write_env
install_unit
start_service
print_pair_info
