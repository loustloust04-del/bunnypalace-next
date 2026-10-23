#!/bin/bash
set -e
cd "$(dirname "$0")"

# loopback 模式 hub 仍要求 token env，但 loopback 连接跳过校验，所以用 placeholder
export MP_CC_HUB_TOKEN="${MP_CC_HUB_TOKEN:-loopback-only}"
export MP_CC_HUB_HOST="${MP_CC_HUB_HOST:-127.0.0.1}"

exec bun run hub.ts
