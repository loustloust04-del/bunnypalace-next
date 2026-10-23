# 自建中继（#068）

开着代理 VPN 也能秒连 hub：Mac 主动往外连你自己的中继，手机多一个 `wss://中继/cc` 候选参加连接竞速。中继只搬字节，WS 握手、口令、回放还是手机和 hub 直接做。设计见 `docs/plan-remote-relay.md`。

```
手机 ──TLS──▶ 中继（VPS，一个端口）◀──TLS（Mac 主动连出）── relay-connector ──Unix socket──▶ hub
```

> ⚠️ 一期一个中继只服务一台 Mac，**中继能看到明文**（包括 `/cc?token=` 里的口令）。只部署在你自己的机器上，别用别人的中继。

## 1. Mac 端：生成密钥

```bash
cd cc-bridge
# 有域名 + 正规证书：
bun relay/new-secret.ts relay.example.com 8443 --out secrets/relay.json
# 只有 IP、自签证书（先做第 2 步生成证书，再带 --cert 算 pin）：
bun relay/new-secret.ts 203.0.113.10 8443 --out secrets/relay.json --cert relay-cert.pem
```

它把密钥原文写进 `secrets/relay.json`（0600），终端只打出中继那边要填的 `MP_RELAY_SECRET_SHA256`。重启 hub 后 hub 会开 Unix socket 入口、拉起 `relay-connector`，`/pair` 二维码里多出 `u3`（和自签时的 `p3`）。**手机要重新扫一次码**才会多出中继候选。

## 2. 证书（二选一）

- **有域名**：用正规证书（Let's Encrypt：certbot / acme.sh 都行），app 走系统校验，不用 pin。续期时如果换了私钥也没关系。
- **只有 IP**：自签，app 靠 pin 认它：
  ```bash
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj /CN=mp-relay -addext "subjectAltName=IP:203.0.113.10" \
    -keyout relay-key.pem -out relay-cert.pem
  ```
  pin 是证书公钥（SPKI）的 sha256：**换了私钥就要重新跑 new-secret（或手动改 relay.json 的 pinSpkiSha256）、重启 hub、手机重新扫码**。只续期不换私钥 pin 不变。

## 3. 中继端（VPS）

`relay/relay.ts` 是单文件，只用 Bun / Node 内置模块，拷过去就能跑：

```bash
MP_RELAY_SECRET_SHA256=<第 1 步打印的那串> \
MP_RELAY_CERT=/etc/mp-relay/cert.pem MP_RELAY_KEY=/etc/mp-relay/key.pem \
MP_RELAY_PORT=8443 bun relay.ts
```

- 不给证书时只准绑 `127.0.0.1`（测试用），否则拒绝启动。
- **必须由中继自己终止 TLS**，或者前面只做 **TCP 透传**（nginx `stream`、HAProxy `mode tcp`）。不能放在 Caddy / nginx 这类 HTTP 反代后面：Mac 那条连接不是 HTTP。
- 防火墙只开这一个端口。
- 别开访问日志。中继自己的日志只有 `conn / method / path / status / ms`，不记 IP、口令、query、密钥。

systemd 示例（`/etc/systemd/system/mp-relay.service`）：

```ini
[Unit]
Description=MemoryPalace relay
After=network-online.target

[Service]
User=mp-relay
Environment=MP_RELAY_SECRET_SHA256=...
Environment=MP_RELAY_CERT=/etc/mp-relay/cert.pem
Environment=MP_RELAY_KEY=/etc/mp-relay/key.pem
Environment=MP_RELAY_PORT=8443
ExecStart=/usr/local/bin/bun /opt/mp-relay/relay.ts
Restart=always
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
```

## 4. 怎么确认通了

- 中继日志出现 3 行 `connector_ready`（Mac 保持 3 条空闲通道）。
- 手机或任何机器：`curl -i https://中继:8443/health` 回 **403 且带 `x-mp-hub: 1`** = 经中继摸到了真 hub；回 503 = Mac 没连上中继。
- hub 日志里中继来的连接记成 `from relay`；秒连账本 `connect-ledger.jsonl` 的 `from` 也是 `relay`。

## 5. 规则摘要（实现见 relay.ts 顶部注释）

- 手机只能 `GET /health` 和 WS `GET /cc`；带 body、裸 LF、折行、非法头名一律拒；一条连接只转一个请求。
- 中继自己的回应（400 / 429 / 503 / 504 / 502）永远不带 `x-mp-hub`，app 对中继候选只认带这个头的回应为活。
- hub 对中继入口进来的请求一律按远程处理：要口令、要 bundle，本机专用端点全部 404。
- 限额：每 IP 同时 8 条、每分钟 30 次；全局 64 条管道；connector 鉴权每 IP 每分钟 20 次。

## 换密钥 / 停用

- 换密钥：删掉 `secrets/relay.json` 重新跑第 1 步，中继换新的 `MP_RELAY_SECRET_SHA256`，重启两边。
- 停用：删掉 `secrets/relay.json`，重启 hub（不再开入口、不拉 connector、二维码不再带 u3）。手机重新扫码清掉旧中继。
