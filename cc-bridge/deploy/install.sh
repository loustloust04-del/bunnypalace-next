#!/usr/bin/env bash
# cc-bridge VPS 部署脚本（check-only，按 codex review 收紧）
#
# 用法：在 VPS 上 git clone 或 scp 整个 cc-bridge/ 目录，cd 进去跑
#   sudo bash deploy/install.sh
#   sudo bash deploy/install.sh --pair-info   # 装好之后单独再打一次配对信息
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
TMUX_DIR="$DATA_DIR/tmux"   # TMUX_TMPDIR：tmux socket 不落 PrivateTmp 的私有 /tmp，SSH 进来也看得到同一个 tmux
DEFAULT_SERVICE_PATH="/usr/local/bin:/usr/bin:/bin:$DATA_DIR/.bun/bin:$DATA_DIR/.local/bin"
BUN_BIN=""   # Step 3b 以服务用户身份验过的 bun 绝对路径，bun install 用它

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

# 服务的 PATH：env 已存在就用里面那串（用户可能改过），否则用默认值。依赖必须在这串里找得到——
# root 的 PATH（/root/.bun/bin、nvm 等）服务用户看不见，用 root 的 PATH 查会误判「装齐了」。
service_path() {
  local p=""
  if [[ -f "$ENV_FILE" ]]; then
    p=$(grep -E '^PATH=' "$ENV_FILE" | tail -1 | cut -d= -f2- || true)
    p=${p#\"}; p=${p%\"}
  fi
  echo "${p:-$DEFAULT_SERVICE_PATH}"
}

svc_which() { (PATH="$(service_path)"; hash -r; command -v "$1") }

# 以服务用户身份跑（脚本本来就是 root；runuser 是 util-linux 自带，精简系统没装 sudo 也能用）
as_service() {
  if command -v runuser >/dev/null 2>&1; then
    (cd / && runuser -u "$SERVICE_USER" -- env PATH="$(service_path)" "$@")
  else
    (cd / && sudo -u "$SERVICE_USER" env PATH="$(service_path)" "$@")
  fi
}

install_hint() {
  case "$1" in
    bun)      echo "   - bun       → sudo env BUN_INSTALL=/usr/local/bun bash -c 'curl -fsSL https://bun.sh/install | bash' && sudo ln -sf /usr/local/bun/bin/bun /usr/local/bin/bun"
              echo "                 （装到系统目录：默认装法落在你自己的 ~/.bun，服务用户 $SERVICE_USER 进不去。装 bun 要先有 unzip）" ;;
    node|npm) echo "   - $1        → sudo apt install -y nodejs npm   # 别用 nvm：nvm 装在你自己的 home，服务用户看不见" ;;
    tmux)     echo "   - tmux      → sudo apt install -y tmux" ;;
    qrencode) echo "   - qrencode  → sudo apt install -y qrencode" ;;
    claude)   echo "   - claude    → sudo npm i -g @anthropic-ai/claude-code   # 落在 /usr/local/bin" ;;
  esac
}

# === Step 2: 依赖检查（check-only，缺啥提示）===
# 两段：这里按服务的 PATH 找位置；Step 3b 建完用户后以服务用户身份真跑一遍（verify_deps_as_service）。
check_deps() {
  echo ""
  echo "=== Step 2: 依赖检查（按服务的 PATH：$(service_path)）==="

  local missing=()
  local d where

  for d in bun node npm tmux claude; do
    if where=$(svc_which "$d"); then
      echo "  ✓ $d: $where"
    else
      missing+=("$d")
      if command -v "$d" >/dev/null 2>&1; then
        c_yellow "  ⚠️ $d 装在 $(command -v "$d")，但不在服务的 PATH 里（服务用户 $SERVICE_USER 用不了）"
      fi
    fi
  done

  # qrencode / tailscale 是 root 自己在这个脚本里用的，按 root 的 PATH 查
  if ! command -v qrencode >/dev/null 2>&1; then
    missing+=("qrencode")
  else
    echo "  ✓ qrencode: 装着"
  fi

  if ! command -v tailscale >/dev/null 2>&1; then
    c_yellow "  ⚠️ 没装 Tailscale。强烈建议装 + tailscale up 后再继续（默认 hub 不绑 0.0.0.0，公网连不上）"
    echo "     装 Tailscale：curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up"
    echo "     国内借梯子连法（不用 Tailscale）见 deploy/VPS.md「国内连法」"
  else
    echo "  ✓ tailscale: 装着"
    if ! tailscale ip -4 >/dev/null 2>&1; then
      c_yellow "  ⚠️ Tailscale 装了但还没 tailscale up，先跑：sudo tailscale up"
    fi
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    c_red "❌ 缺这些工具（或服务用户找不到）："
    for d in "${missing[@]}"; do install_hint "$d"; done
    echo ""
    echo "装完重新跑这个脚本。"
    exit 1
  fi

  c_green "  ✓ 依赖都找得到"
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

# === Step 3b: 以服务用户身份真跑一遍依赖 ===
# 找得到 ≠ 跑得动：/usr/local/bin/bun 软链到 /root/.bun、nvm 的 node 之类，服务用户执行时才露馅。
verify_deps_as_service() {
  echo ""
  echo "=== Step 3b: 以 $SERVICE_USER 身份试跑依赖 ==="
  local failed=() d out rc
  for d in "bun --version" "node --version" "tmux -V" "claude --version"; do
    rc=0
    # shellcheck disable=SC2086  # 故意按空格拆成命令 + 参数
    out=$(as_service $d 2>&1) || rc=$?
    if [[ $rc -eq 0 ]]; then
      echo "  ✓ $d → $(echo "$out" | head -1)"
    else
      failed+=("${d%% *}")
      c_red "  ❌ $d 以 $SERVICE_USER 身份跑不起来（exit $rc）："
      echo "$out" | head -3 | sed 's/^/       /'
    fi
  done
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo ""
    c_red "❌ 服务用户跑不了：${failed[*]}"
    echo "   多半是装在 root 私有目录（/root/...）或 nvm 下、再软链进 /usr/local/bin——服务用户进不去那个目录。"
    echo "   按系统目录装法重装："
    for d in "${failed[@]}"; do install_hint "$d"; done
    echo ""
    echo "装完重新跑这个脚本。"
    exit 1
  fi
  BUN_BIN=$(svc_which bun)
  c_green "  ✓ $SERVICE_USER 能跑全部依赖（bun = $BUN_BIN）"
}

# === Step 4: 准备目录 + 拷源码 ===
prepare_dirs() {
  echo ""
  echo "=== Step 4: 准备目录 ==="
  mkdir -p "$INSTALL_DIR" "$DATA_DIR" "$CONF_DIR" "$DATA_DIR/cc-rp" "$DATA_DIR/secrets" "$TMUX_DIR"
  echo "  $INSTALL_DIR"
  echo "  $DATA_DIR/cc-rp（CC 工作目录，在这里写 CLAUDE.md 人设）"
  echo "  $DATA_DIR/secrets（hub 内部 session-map / reply-log）"
  echo "  $TMUX_DIR（tmux socket，TMUX_TMPDIR）"
  echo "  $CONF_DIR（token + env）"
  echo ""
  # 整个 cc-bridge/ 拷过去，只排除依赖 / 本机状态 / 测试。hub.ts 会 import 一串本地模块、
  # 运行时还读 tools-schema.json / hook 脚本 / vendor/，按文件清单拷每次改 hub 都会漏。
  echo "  拷源码 $SRC_DIR → $INSTALL_DIR（排除 node_modules / secrets / e2e / *.test.ts）"
  tar -C "$SRC_DIR" \
    --exclude=./node_modules --exclude=./secrets --exclude=./e2e --exclude='*.test.ts' \
    -cf - . | tar -C "$INSTALL_DIR" -xf -

  # bun install npm deps（用 Step 3b 以服务用户验过的那个 bun）
  cd "$INSTALL_DIR"
  echo "  跑 $BUN_BIN install..."
  "$BUN_BIN" install --production 2>&1 | tail -3

  write_bind_config
  chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" "$DATA_DIR"
  chmod 700 "$TMUX_DIR"
  c_green "  ✓ 目录就绪"
}

# hub 的绑定开关（hub-config.ts BindPrefs）：VPS 上 LAN 段是 docker0（172.17.x）、商家内网（10.x），不该绑；
# Tailscale 照绑。只在文件不存在时写，用户 / app 改过的不动。
write_bind_config() {
  local f="$DATA_DIR/secrets/bind-config.json"
  if [[ -f "$f" ]]; then
    echo "  $f 已存在，不动"
  else
    echo '{"lan":false,"tailscale":true}' > "$f"
    echo "  写好 $f（不绑 LAN 段，Tailscale 照绑）"
  fi
}

# === Step 5: 生成 token（如果不存在 / 无效）===
token_valid() {
  local t
  [[ -f "$1" ]] || return 1
  t=$(cat "$1")
  [[ "$t" =~ ^[0-9a-fA-F]{32}$ ]]
}

generate_token() {
  echo ""
  echo "=== Step 5: 生成 hub token ==="
  if token_valid "$TOKEN_FILE"; then
    echo "  token 已存在 $TOKEN_FILE，跳过"
    return
  fi
  if [[ -e "$TOKEN_FILE" ]]; then
    c_yellow "  ⚠️ $TOKEN_FILE 是空的或不是 32 位 hex（多半是以前装失败留下的），重新生成"
  fi
  # 16 字节 hex。od 是 coreutils 自带（不依赖 xxd）。同目录临时文件（mktemp 建出来就是 600）→ 校验 → mv 原子替换
  local tmp
  tmp=$(mktemp "$CONF_DIR/.token.XXXXXX")
  if ! head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$tmp" || ! token_valid "$tmp"; then
    rm -f "$tmp"
    c_red "  ❌ token 生成失败（head / od / tr 不可用？）"; exit 1
  fi
  chmod 600 "$tmp"
  chown "$SERVICE_USER:$SERVICE_USER" "$tmp"
  mv -f "$tmp" "$TOKEN_FILE"
  c_green "  ✓ 生成 16 字节 hex token → $TOKEN_FILE（chmod 600，只有 $SERVICE_USER 能读）"
}

# === Step 6: 写 EnvironmentFile + run-hub.sh ===
write_env() {
  echo ""
  echo "=== Step 6: systemd EnvironmentFile + 启动脚本 ==="

  # 默认 host: auto（codex review 强调不要默认 0.0.0.0）——hub 自己探测，只绑 127.0.0.1 + Tailscale 这些具体地址
  # （LAN 段由 bind-config.json 关掉，见 write_bind_config）。后装 Tailscale 的话 hub 30s 内自愈补绑，不用改 env。
  # 写具体 IP 的话 hub 就只绑那一个、不再自动探测。
  local defaults=(
    "MP_CC_HUB_PORT=7890"
    "MP_CC_HUB_HOST=auto"
    "MP_CC_HUB_TOKEN_FILE=$TOKEN_FILE"
    "MP_CC_WORKDIR=$DATA_DIR/cc-rp"
    "MP_CC_SECRETS_DIR=$DATA_DIR/secrets"
    "MP_CC_TMUX_SESSION=mp-cc"
    "TMUX_TMPDIR=$TMUX_DIR"
    "PATH=$DEFAULT_SERVICE_PATH"
  )
  local kv
  if [[ ! -f "$ENV_FILE" ]]; then
    {
      for kv in "${defaults[@]}"; do echo "$kv"; done
      echo "# 国内借梯子连法：hub 额外多听的网卡地址（具体 IP，逗号分隔；见 deploy/VPS.md「国内连法」）"
      echo "# MP_CC_HUB_EXTRA_HOSTS=<VPS网卡地址>"
      echo "# 代理（见 deploy/VPS.md「代理」）"
      echo "# HTTPS_PROXY=http://<代理地址>:<端口>"
      echo "# HTTP_PROXY=http://<代理地址>:<端口>"
      echo "# NO_PROXY=127.0.0.1,localhost,100.64.0.0/10"
    } > "$ENV_FILE"
    echo "  写好 $ENV_FILE"
  else
    # 重跑安装：只补缺的键，不覆盖已有的（代理、改过的端口 / PATH 都保留）
    local added=() cur_host
    for kv in "${defaults[@]}"; do
      if ! grep -qE "^${kv%%=*}=" "$ENV_FILE"; then
        echo "$kv" >> "$ENV_FILE"
        added+=("${kv%%=*}")
      fi
    done
    if [[ ${#added[@]} -gt 0 ]]; then
      echo "  $ENV_FILE 已存在，补上缺的：${added[*]}（已有的不动）"
    else
      echo "  $ENV_FILE 已存在，键都在，不动"
    fi
    cur_host=$(grep -E '^MP_CC_HUB_HOST=' "$ENV_FILE" | tail -1 | cut -d= -f2-)
    if [[ "$cur_host" != "auto" ]]; then
      c_yellow "  ⚠️ MP_CC_HUB_HOST=$cur_host：写具体值 hub 只绑这一个、不自动探测。建议改成 auto（改完 sudo systemctl restart $SERVICE_NAME）"
    fi
  fi
  chmod 640 "$ENV_FILE"
  chown root:"$SERVICE_USER" "$ENV_FILE"

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
    if curl -s --noproxy '*' "http://127.0.0.1:$port/health" | grep -q '"ok":true'; then
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

  # 地址不自己拼（MP_CC_HUB_HOST=auto 拼出来是 ws://auto），问 hub 本机的 /pair：
  # 它按**实际在听的** listener 给 u（LAN 或 Tailscale）/ u2，跟 Mac app 二维码同一个格式。
  local token port pair u u2 extra qr mc
  token=$(cat "$TOKEN_FILE")
  port=$(grep -E '^MP_CC_HUB_PORT=' "$ENV_FILE" | tail -1 | cut -d= -f2-)
  # 口令走 curl -K -（从 stdin 读配置），不出现在进程参数里
  pair=$(printf 'url = "http://127.0.0.1:%s/pair?token=%s"\n' "$port" "$token" | curl -s --noproxy '*' --max-time 5 -K - || true)
  if [[ "$pair" != *'"mpcc"'* ]]; then
    c_red "  ❌ 问 hub 的 /pair 没拿到配对信息（hub 没起来 / 口令文件和 hub 用的不一致？）"
    echo "     看 log：sudo journalctl -u $SERVICE_NAME -n 50"
    return 1
  fi
  u=$(echo "$pair" | grep -o '"u":"[^"]*"' | cut -d'"' -f4 || true)
  u2=$(echo "$pair" | grep -o '"u2":"[^"]*"' | cut -d'"' -f4 || true)
  # 新 hub 的 /pair 同时带 v1 + v2 字段（plan-hub-keypair-auth §0.6）：mc = 手填配对码，老 hub 没有
  mc=$(echo "$pair" | grep -o '"mc":"[^"]*"' | cut -d'"' -f4 || true)
  extra=$(grep -E '^MP_CC_HUB_EXTRA_HOSTS=' "$ENV_FILE" | tail -1 | cut -d= -f2- | cut -d, -f1 | tr -d ' ' || true)

  echo ""
  if [[ -n "$u" ]]; then
    echo "Hub URL:   $u"
    if [[ -n "$u2" ]]; then echo "备用 URL:  $u2"; fi
  else
    c_yellow "hub 现在只听本机（没有 Tailscale 地址）。按 deploy/VPS.md 两种连法之一配好："
    echo "  - Tailscale：VPS 上 sudo tailscale up，hub 30s 内自动补绑，再跑 sudo bash $0 --pair-info"
    echo "  - 国内借梯子：$ENV_FILE 设 MP_CC_HUB_EXTRA_HOSTS，重启 hub"
    echo "  然后在花园里手填地址 + 下面这个口令。"
  fi
  if [[ -n "$extra" ]]; then
    echo "梯子连法:  ws://$extra:$port/cc（MP_CC_HUB_EXTRA_HOSTS；手机梯子要把这个 IP 分流到 VPS 节点）"
  fi
  if [[ -n "$mc" ]]; then
    echo "手填配对码：$mc（10 分钟内有效，用一次就作废；过期了用下面「管理命令」里的 devices.ts pair 重新出）"
  fi
  echo "Token:     $token（口令也能配，手机三条任一：扫码 / 地址 + 配对码 / 地址 + 口令）"
  echo ""
  c_yellow "⚠️ 这个 token 等于 hub 的密码——不要复制到 Discord/微信公开聊天 或者贴公网剪贴板"
  echo ""

  # ASCII QR（iOS 端扫码）：有远程地址时就是 /pair 原样（v1 + v2 合一，老 app 也认）；
  # 只有梯子地址时拿它当 u，其余字段（含 v2 的 hid / hk / 配对码）照抄 /pair
  qr=""
  if [[ -n "$u" ]]; then
    qr="$pair"
  elif [[ -n "$extra" ]]; then
    qr="${pair/\"u\":null/\"u\":\"ws://$extra:$port/cc\"}"
  fi
  if [[ -n "$qr" ]]; then
    echo "扫码（iOS 记忆花园 → 设置 → Claude Code → 扫码配对）："
    echo ""
    # 二维码内容（含口令 / 配对码）走 stdin，不进 qrencode 的进程参数（printf 是 shell 内建）
    printf '%s' "$qr" | qrencode -t ANSI256 -o - 2>/dev/null || c_yellow "qrencode 出错；上面 URL + 配对码 / token 手填"
  fi

  echo ""
  echo "════════════════════════════════════════════════════════════"
  echo ""
  echo "管理命令："
  echo "  sudo systemctl status $SERVICE_NAME       看状态"
  echo "  sudo systemctl restart $SERVICE_NAME      重启"
  echo "  sudo systemctl stop $SERVICE_NAME         停"
  echo "  sudo journalctl -u $SERVICE_NAME -f       看实时日志"
  local devices_cmd="sudo -u $SERVICE_USER env MP_CC_HUB_TOKEN_FILE=$TOKEN_FILE ${BUN_BIN:-bun} $INSTALL_DIR/devices.ts"
  echo "  $devices_cmd pair --port $port                 重新出配对码（二维码 + 手填码 + 口令）"
  echo "  $devices_cmd list --port $port                 这台 hub 认的设备"
  echo "  $devices_cmd revoke <id 前缀> --port $port      移除一台（id 看 list）"
  echo "  $devices_cmd rename <id 前缀> <名字> --port $port 改名"
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
main() {
  need_root
  if [[ "${1:-}" == "--pair-info" ]]; then   # 装好之后单独再打一次配对信息（比如后装了 Tailscale）
    print_pair_info
    return
  fi
  check_system
  check_deps
  create_user
  verify_deps_as_service
  prepare_dirs
  generate_token
  write_env
  install_unit
  start_service
  print_pair_info
}

# 被 source 时只定义函数（测试单独调 print_pair_info 等），直接跑才执行
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
