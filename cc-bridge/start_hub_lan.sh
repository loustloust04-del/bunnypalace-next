#!/bin/bash
set -e
cd "$(dirname "$0")"

TOKEN_FILE="./hub-token.txt"
if [ ! -f "$TOKEN_FILE" ]; then
  openssl rand -hex 16 > "$TOKEN_FILE"
  echo "[lan] 生成新 token: $(cat $TOKEN_FILE)"
fi

TOKEN=$(cat "$TOKEN_FILE")
LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "127.0.0.1")

echo ""
echo "===== cc-bridge hub (LAN 模式) ====="
echo "本机 LAN IP: $LAN_IP"
echo "iOS MP 设置页填："
echo "  Hub URL:   ws://$LAN_IP:7890/cc"
echo "  Hub Token: $TOKEN"
echo "===================================="
echo ""

export MP_CC_HUB_HOST="0.0.0.0"
export MP_CC_HUB_TOKEN="$TOKEN"

exec bun run hub.ts
