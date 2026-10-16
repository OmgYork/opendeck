#!/usr/bin/env python3
"""ZCode 状态灯 hook:读 stdin JSON(hook_event_name)→ 映射状态 → 原子写 state.json。

设计约束(见 HANDOFF §6.12):hook 同步阻塞 ZCode 主流程,故本脚本
亚 100ms 退出、exit 0、无 stdout/stderr;任何异常静默吞掉——状态灯绝不反噬主流程。
"""

import json
import os
import sys
import time

# 与 hook.py 同目录 = 插件根(webview 的 fetch 读取域内)
STATE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "state.json")

EVENT_TO_STATE = {
    "SessionStart": "ready",
    "UserPromptSubmit": "working",
    "PostToolUse": "working",
    "PermissionRequest": "permission",
    "PostToolUseFailure": "error",
    "Stop": "done",
}

# PreToolUse 不进通用映射:只在助手发起结构化提问(AskUserQuestion)时切 asking,
# 其余工具调用不写(working 由 PostToolUse 负责);纯文本问句无事件可挂(已知边界)
ASKING_TOOL = "AskUserQuestion"


def resolve_state(payload: dict) -> str | None:
    event = payload.get("hook_event_name", "")
    if event == "PreToolUse" and payload.get("tool_name") == ASKING_TOOL:
        return "asking"
    return EVENT_TO_STATE.get(event)


def main() -> None:
    try:
        payload = json.load(sys.stdin)
        state = resolve_state(payload)
        if state is None:
            return
        document = {"state": state, "updatedAt": int(time.time() * 1000)}
        tmp = STATE_PATH + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(document, f)
        os.replace(tmp, STATE_PATH)  # 原子替换,读侧永不看到半截 JSON
    except Exception:
        pass


if __name__ == "__main__":
    main()
