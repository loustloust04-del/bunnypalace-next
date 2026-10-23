#!/usr/bin/env bash
# 卸载 cc-bridge VPS 部署。保留 $DATA_DIR/cc-rp（你的 CLAUDE.md 人设和 CC 历史）。

set -euo pipefail

SERVICE_NAME="cc-bridge"
INSTALL_DIR="/opt/cc-bridge"
DATA_DIR="/var/lib/cc-bridge"
CONF_DIR="/etc/cc-bridge"
SERVICE_USER="ccbridge"

if [[ $EUID -ne 0 ]]; then
  echo "❌ 要 root 跑：sudo bash $0"
  exit 1
fi

echo "停 + 禁用 systemd service..."
systemctl stop "$SERVICE_NAME.service" 2>/dev/null || true
systemctl disable "$SERVICE_NAME.service" 2>/dev/null || true
rm -f "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload

echo "删 $INSTALL_DIR + $CONF_DIR..."
rm -rf "$INSTALL_DIR" "$CONF_DIR"

echo ""
echo "保留了 $DATA_DIR（含你的 CC 工作目录 + CLAUDE.md 人设）"
echo "想彻底删干净：sudo rm -rf $DATA_DIR && sudo userdel $SERVICE_USER"
echo ""
echo "✓ cc-bridge 已卸载"
