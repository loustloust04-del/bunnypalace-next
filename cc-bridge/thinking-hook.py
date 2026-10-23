#!/usr/bin/env python3
"""CC Stop hook：把当轮 thinking（摘要）回传 hub → 记忆宫殿。

前提：cc workdir 的 .claude/settings.json 已开 showThinkingSummaries（否则 thinking 恒空）。
约束：绝不阻塞/打扰 CC——任何异常 swallow、永远 exit 0；状态打一行到 /tmp/cc-thinking-hook.log。
"""
import json
import os
import re
import sys
import time
import urllib.request

HUB_PORT = os.environ.get("MP_CC_HUB_PORT", "7890")
LOG_PATH = "/tmp/cc-thinking-hook.log"
TAIL_BYTES = 10 * 1024 * 1024   # 大 transcript 只读末尾 10MB
MAX_THINKING = 64_000

CHANNEL_RE = re.compile(r'<channel source="memorypalace[^"]*"[^>]*?\schat_id="([^"]+)"')
MESSAGE_ID_RE = re.compile(r'<channel source="memorypalace"[^>]*?\smessage_id="([^"]+)"')
REPLY_TOOL = "mcp__cc-bridge__reply"
MAX_REPLY_TEXT = 20_000
MAX_TERMINAL_INPUT = 500
# 终端里直接打的字才算「终端轮」：系统注入（<command-name> / <task-notification> 等）、中断、compact 续写、斜杠命令都不算
NOT_TERMINAL_PREFIXES = ("<", "/", "[Request interrupted", "This session is being continued")
SPOOL_DIR = os.environ.get("MP_CC_THINKING_SPOOL") or os.path.expanduser("~/.cc-bridge/thinking-spool")


def log(status: str) -> None:
    try:
        with open(LOG_PATH, "a") as f:
            f.write(f"{status}\n")
    except Exception:
        pass


def post_lifecycle_stop(session_id) -> None:
    """M4b ⑤：无条件告诉 hub「这轮结束了」。

    thinking 有没有开、锚不锚得上、transcript 在不在，都跟灵动岛该不该落 done 无关——
    所以这一发必须在下面任何一个 return 之前。失败静默：绝不影响原有 thinking 逻辑。
    """
    try:
        body = json.dumps({"event": "stop", "session_id": session_id}).encode("utf-8")
        req = urllib.request.Request(
            f"http://127.0.0.1:{HUB_PORT}/la/lifecycle",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        resp = urllib.request.urlopen(req, timeout=3).read().decode("utf-8", "replace")
        log(f"la_lifecycle {resp[:80]}")
    except Exception as e:
        log(f"la_lifecycle_fail {type(e).__name__}")


def text_of(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            b.get("text", "") for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def squash(s: str) -> str:
    return "".join(s.split())


def turn_finished(last_row, texts, last_assistant_message) -> bool:
    """本轮最后那段话落盘了没有（10-11：Stop hook 比 CC 写最后一段早，读到的只有中间旁白，最后一段被吞）。

    - CC 给了 last_assistant_message（2.1.x 起 Stop hook 输入里有）：转录里的正文要以它结尾才算齐
    - 转录最后一行 assistant 还停在工具调用（stop_reason=tool_use / 最后一块是 tool_use）或只有 thinking：
      后面还有话没写，没齐
    """
    if last_row is None:
        return False
    content = [b for b in (last_row.get("content") or []) if isinstance(b, dict)]
    if last_row.get("stop_reason") == "tool_use" or (content and content[-1].get("type") == "tool_use"):
        return False
    if content and all(b.get("type") in ("thinking", "redacted_thinking") for b in content):
        return False
    lam = squash(last_assistant_message or "")
    if lam and not squash("".join(texts)).endswith(lam):
        return False
    return True


def is_terminal_input(text: str, compact: bool) -> bool:
    s = text.strip()
    if not s or compact or "<channel" in text:
        return False
    return not s.startswith(NOT_TERMINAL_PREFIXES)


def main() -> None:
    data = json.load(sys.stdin)
    post_lifecycle_stop(data.get("session_id"))
    path = data.get("transcript_path") or ""
    if not os.path.isfile(path):
        log("no_transcript")
        return
    # CC 写转录比 Stop hook 慢一点点（09-19 实测正文行 0.2s 后才落盘，hook 读到空、正文没投）：
    # 本轮还没读到小克的话就每 0.5s 重读，最多 5s。hub 另有 20s 轮末兜底。
    tries = int(os.environ.get("MP_CC_HOOK_REREAD_TRIES") or 10)
    for attempt in range(tries + 1):
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            if size > 2 * TAIL_BYTES:
                f.seek(-TAIL_BYTES, 2)
                raw = f.read()
                raw = raw.split(b"\n", 1)[1] if b"\n" in raw else b""
            else:
                raw = f.read()
        lines = raw.decode("utf-8", "replace").splitlines()

        # 最后一条来自记忆宫殿的用户输入（channel tag）→ chat_id + 本轮起点
        chat_id = None
        message_id = None
        last_user_idx = -1
        last_human_idx = -1   # 最后一条真人输入（任何 channel / 保暖 ping 都算，tool_result 不算）
        last_human_text = ""
        last_human_compact = False
        for i, line in enumerate(lines):
            if '"role":"user"' not in line and '"role": "user"' not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("isSidechain") or o.get("isMeta"):
                continue
            msg = o.get("message") or {}
            if msg.get("role") != "user":
                continue
            content = msg.get("content")
            if isinstance(content, list) and not any(isinstance(b, dict) and b.get("type") == "text" for b in content):
                continue   # tool_result 行
            last_human_idx = i
            last_human_text = text_of(content)
            last_human_compact = bool(o.get("isCompactSummary"))
            m = CHANNEL_RE.search(text_of(content))
            if m:
                chat_id = m.group(1)
                last_user_idx = i
                mm = MESSAGE_ID_RE.search(text_of(content))
                message_id = mm.group(1) if mm else None
        # 终端轮（10-06）：她在终端里直接打字 → 正文挂到会话绑定的对话（转录里最后一条 MP channel 的 chat_id）
        terminal_input = None
        if last_human_idx != last_user_idx and is_terminal_input(last_human_text, last_human_compact):
            terminal_input = last_human_text.strip()[:MAX_TERMINAL_INPUT]
        if not chat_id:
            log("terminal_no_chat" if terminal_input else "no_channel")
            return
        # 最后真人输入既不是 MP channel 也不是终端轮（保暖 ping 等）→ 不投：thinking 会错锚到上一条 MP 回复
        if terminal_input is None and last_user_idx != last_human_idx:
            log(f"not_mp_turn chat={chat_id[:8]}")
            return
        turn_start = last_human_idx

        # 本轮全部 assistant thinking block，按序拼接
        parts = []
        for line in lines[turn_start + 1:]:
            if '"thinking"' not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("isSidechain"):
                continue
            msg = o.get("message") or {}
            if msg.get("role") != "assistant":
                continue
            for b in (msg.get("content") or []):
                if isinstance(b, dict) and b.get("type") == "thinking":
                    t = (b.get("thinking") or "").strip()
                    if t:
                        parts.append(t)
        # 本轮正文（REPLY_VIA_TEXT）：本轮 = 最后一条真人输入（MP channel 或终端轮）之后。
        # 用了 reply 工具的轮不投（混合期防双发）。
        texts = []
        rows = []   # 每段正文 + 转录 uuid：hub 按段去重（读早了少段 → 下次只补缺的段，不整轮重发）
        used_reply = False
        turn_uuid = None
        last_row = None
        for line in lines[turn_start + 1:]:
            if '"role":"assistant"' not in line and '"role": "assistant"' not in line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("isSidechain"):
                continue
            msg = o.get("message") or {}
            if msg.get("role") != "assistant":
                continue
            last_row = msg
            for b in (msg.get("content") or []):
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use" and b.get("name") == REPLY_TOOL:
                    used_reply = True
                if b.get("type") == "text" and (b.get("text") or "").strip():
                    texts.append(b["text"].strip())
                    turn_uuid = o.get("uuid") or turn_uuid
                    if o.get("uuid"):
                        rows.append({"uuid": o["uuid"], "text": b["text"].strip()})
        reply_text = "" if used_reply else "\n\n".join(texts).strip()[:MAX_REPLY_TEXT]
        # 终端轮只认正文（没正文就没有能锚的节点），所以光有 thinking 不算读到、接着等。
        # 有正文也要等本轮写完（turn_finished）：只读到中间旁白就投，最后一段就丢了
        if used_reply or attempt == tries:
            break
        if (reply_text or (parts and terminal_input is None)) and turn_finished(last_row, texts, data.get("last_assistant_message")):
            break
        time.sleep(0.5)

    # 终端轮没正文（只有 thinking / 用了 reply 工具）→ 不投：没有能锚的节点
    if terminal_input is not None and not reply_text:
        log(f"terminal_no_text chat={chat_id[:8]}")
        return
    if not parts and not reply_text:
        log(f"no_thinking chat={chat_id[:8]}")
        return

    thinking = "\n\n".join(parts)[:MAX_THINKING]
    payload = {
        "session_id": data.get("session_id"),
        "chat_id": chat_id,
        "thinking": thinking,
    }
    if reply_text:
        payload["reply_text"] = reply_text
        payload["turn_uuid"] = turn_uuid
        if rows:
            # 只带完整放得下的段：截过的段 hub 会当成投过，后半截就永远补不上了（10-11 审）。
            # 放不下的段不带，hub 轮末兜底自己读转录补。
            # 例外：第一段自己就超限 → 截断后照带（hub 会记成投过；不带的话这段永远发不出去）
            used = 0
            kept = []
            for r in rows:
                add = len(r["text"]) + (2 if kept else 0)
                if kept and used + add > MAX_REPLY_TEXT:
                    break
                kept.append({"uuid": r["uuid"], "text": r["text"][:MAX_REPLY_TEXT]})
                used += add
                if used > MAX_REPLY_TEXT:
                    break
            payload["rows"] = kept
        if terminal_input is not None:
            payload["terminal_input"] = terminal_input
        else:
            payload["message_id"] = message_id
    body = json.dumps(payload).encode("utf-8")
    # 先落盘再投（09-19：hub 卡了 3 秒，hook 超时放弃，正文就丢了）。投成功才删；失败留给 hub 定时补投（幂等）。
    spool = None
    try:
        os.makedirs(SPOOL_DIR, exist_ok=True)
        spool = os.path.join(SPOOL_DIR, f"{int(time.time() * 1000)}-{(turn_uuid or 'x')[:12]}.json")
        with open(spool, "wb") as f:
            f.write(body)
    except Exception as e:
        log(f"spool_fail {type(e).__name__}")
        spool = None
    last_err = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(
                f"http://127.0.0.1:{HUB_PORT}/thinking",
                data=body,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            resp = urllib.request.urlopen(req, timeout=10).read().decode("utf-8", "replace")
            if spool:
                try:
                    os.remove(spool)
                except Exception:
                    pass
            log(f"posted chat={chat_id[:8]} len={len(thinking)} text={len(reply_text)} try={attempt + 1} resp={resp[:80]}")
            return
        except Exception as e:
            last_err = e
            time.sleep(2)
    log(f"post_fail chat={chat_id[:8]} text={len(reply_text)} {type(last_err).__name__} → spooled={bool(spool)}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(f"error {type(e).__name__}: {e}")
    sys.exit(0)
