#!/usr/bin/env python3
"""CC PreToolUse/PostToolUse hook（matcher=AskUserQuestion）：题面/答案回传 hub → 记忆宫殿弹选择卡。

- PreToolUse：tool_input.questions 结构化题面 → hub 记 pending + 推 ask_user_question 帧
- PostToolUse：tool_response.answers → hub 清 pending + 推 ask_user_resolved 帧
  （实测 Esc 拒答时 PostToolUse 不 fire——declined 由 hub 靠该 session 下一条 reply 到达兜底清账）
约束：绝不阻塞/打扰 CC——任何异常 swallow、永远 exit 0；状态打一行到 /tmp/cc-askuser-hook.log。
"""
import json
import os
import re
import sys
import urllib.request

HUB_PORT = os.environ.get("MP_CC_HUB_PORT", "7890")
LOG_PATH = "/tmp/cc-askuser-hook.log"
TAIL_BYTES = 10 * 1024 * 1024   # 大 transcript 只读末尾 10MB

CHANNEL_RE = re.compile(r'<channel source="memorypalace[^"]*"[^>]*?\schat_id="([^"]+)"')


def log(status: str) -> None:
    try:
        with open(LOG_PATH, "a") as f:
            f.write(f"{status}\n")
    except Exception:
        pass


def text_of(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            b.get("text", "") for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def chat_id_from_transcript(path: str) -> str | None:
    """最后一条来自记忆宫殿的用户输入（channel tag）→ chat_id。同 thinking-hook。"""
    if not os.path.isfile(path):
        return None
    size = os.path.getsize(path)
    with open(path, "rb") as f:
        if size > 2 * TAIL_BYTES:
            f.seek(-TAIL_BYTES, 2)
            raw = f.read()
            raw = raw.split(b"\n", 1)[1] if b"\n" in raw else b""
        else:
            raw = f.read()
    chat_id = None
    for line in raw.decode("utf-8", "replace").splitlines():
        if '<channel source=\\"memorypalace' not in line:
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
        m = CHANNEL_RE.search(text_of(msg.get("content")))
        if m:
            chat_id = m.group(1)
    return chat_id


def main() -> None:
    data = json.load(sys.stdin)
    if data.get("tool_name") != "AskUserQuestion":
        log("skip_tool")
        return
    event = data.get("hook_event_name")
    if event not in ("PreToolUse", "PostToolUse"):
        log(f"skip_event {event}")
        return
    chat_id = chat_id_from_transcript(data.get("transcript_path") or "")
    if not chat_id:
        log("no_channel")   # 非 MP 会话（人肉 CC）不打扰 hub
        return

    body: dict = {
        "event": "pre" if event == "PreToolUse" else "post",
        "session_id": data.get("session_id"),
        "tool_use_id": data.get("tool_use_id"),
        "chat_id": chat_id,
    }
    if event == "PreToolUse":
        questions = (data.get("tool_input") or {}).get("questions") or []
        if not questions:
            log(f"no_questions chat={chat_id[:8]}")
            return
        body["questions"] = questions
    else:
        body["answers"] = (data.get("tool_response") or {}).get("answers") or {}

    req = urllib.request.Request(
        f"http://127.0.0.1:{HUB_PORT}/agent/ask-user",
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    resp = urllib.request.urlopen(req, timeout=3).read().decode("utf-8", "replace")
    log(f"posted {body['event']} chat={chat_id[:8]} tool_use={str(body.get('tool_use_id'))[:12]} resp={resp[:80]}")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(f"error {type(e).__name__}: {e}")
    sys.exit(0)
