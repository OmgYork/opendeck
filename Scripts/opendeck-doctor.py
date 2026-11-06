#!/usr/bin/env python3
"""OpenDeck 一键体检(agent 可运维性,§6.37;只读,零依赖)。

用法: python3 Scripts/opendeck-doctor.py
输出 ✓/✗/⚠ 清单 + 结论。供 AI agent 与人排障:一眼看清运行中构建、配置健康、
插件完整性、备份新鲜度、近期错误计数。不改动任何文件。
"""

import json
import os
import plistlib
import shutil
import subprocess
import sys
from datetime import datetime, timezone

SUPPORT = os.path.expanduser("~/Library/Application Support/OpenDeck")
CONFIG = os.path.join(SUPPORT, "config.json")
PLUGINS = os.path.join(SUPPORT, "plugins")
SETTINGS = os.path.join(SUPPORT, "pluginSettings")
BACKUPS = os.path.join(SUPPORT, "backups")
PENDING = os.path.join(SUPPORT, "pending-import")
AGENT_PLIST = os.path.expanduser("~/Library/LaunchAgents/com.opendeck.app.plist")

JSON_MODE = "--json" in sys.argv
results = []


def check(name, ok, detail=""):
    warn = detail.startswith("WARN")
    results.append({"name": name, "ok": ok, "warn": warn, "detail": detail.replace("WARN ", "", 1) if warn else detail})
    if JSON_MODE:
        return
    mark = "✓" if ok else ("⚠" if warn else "✗")
    print(f"{mark} {name}" + (f" — {detail}" if detail else ""))


def main():
    # 1. app 进程与运行中构建指纹
    app_proc = None
    try:
        out = subprocess.run(
            ["pgrep", "-x", "OpenDeck"], capture_output=True, text=True, timeout=5
        )
        pid = out.stdout.strip().splitlines()[0] if out.returncode == 0 else None
        if pid:
            cmd = subprocess.run(
                ["ps", "-o", "command=", "-p", pid], capture_output=True, text=True, timeout=5
            ).stdout.strip()
            app_proc = cmd
    except Exception:
        pass
    if app_proc:
        fingerprint = "?"
        running_commit = None
        m = app_proc.replace("Contents/MacOS/OpenDeck", "").rstrip("/ ") or ""
        info_plist = os.path.join(m, "Contents", "Info.plist") if m else ""
        if info_plist and os.path.exists(info_plist):
            try:
                with open(info_plist, "rb") as f:
                    info = plistlib.load(f)
                fingerprint = (
                    f"{info.get('OpenDeckBuildCommit', '?')}·{info.get('OpenDeckBuildState', '?')} "
                    f"{info.get('OpenDeckBuildTime', '?')}"
                )
                running_commit = info.get("OpenDeckBuildCommit")
            except Exception as e:
                fingerprint = f"Info.plist 读取失败({e})"
        # 与 git HEAD 对账(仓库内运行时):「旧二进制」从肉眼判定升级为机器判定
        stale_note = ""
        try:
            head = subprocess.run(
                ["git", "rev-parse", "--short", "HEAD"],
                capture_output=True, text=True, timeout=5, cwd=os.path.dirname(os.path.abspath(__file__)),
            ).stdout.strip()
            if head and running_commit and head != running_commit:
                stale_note = f" ⚠落后 HEAD({head}),记得 make-app 重建+重启"
        except Exception:
            pass
        check("OpenDeck 运行中", True, f"pid={pid} 构建 {fingerprint}{stale_note}")
    else:
        check("OpenDeck 运行中", False, "进程未找到 — 设备处于无人管理状态")
        print("  (未运行时后续设备相关检查仅覆盖文件面)")

    # 2. config.json 可解码 + 概要
    config = None
    try:
        with open(CONFIG, encoding="utf-8") as f:
            config = json.load(f)
        scenes = config.get("scenes", [])
        pages = sum(len(s.get("pages", [])) for s in scenes)
        check(
            "config.json 可解码",
            True,
            f"schema v{config.get('schemaVersion')} · {len(scenes)} 场景 {pages} 页",
        )
    except FileNotFoundError:
        check("config.json 存在", False, f"缺失: {CONFIG}(app 未启动过或路径迁移)")
    except Exception as e:
        check("config.json 可解码", False, f"损坏: {e}(应有 config.corrupt-* 归档)")

    # 3. config 引用的插件 vs 已安装目录
    referenced = set()

    def payload_strings(plugin_payload, acc):
        """KeyAction.plugin 的编码形状随关联值而异(dict["_"-键]/list/str)——
        收集全部字符串:其中必含 pluginID(= 插件目录名),误报由「集合交集」匹配吸收"""
        if isinstance(plugin_payload, str):
            acc.add(plugin_payload)
        elif isinstance(plugin_payload, list):
            for item in plugin_payload:
                payload_strings(item, acc)
        elif isinstance(plugin_payload, dict):
            for v in plugin_payload.values():
                payload_strings(v, acc)

    referenced_payloads = []

    def collect_actions(obj):
        if isinstance(obj, dict):
            action = obj.get("action")
            if isinstance(action, dict) and "plugin" in action:
                strings = set()
                payload_strings(action["plugin"], strings)
                if strings:
                    referenced_payloads.append(strings)
            for v in obj.values():
                collect_actions(v)
        elif isinstance(obj, list):
            for v in obj:
                collect_actions(v)

    installed = set()
    if os.path.isdir(PLUGINS):
        installed = {d for d in os.listdir(PLUGINS) if d.endswith(".sdPlugin")}
    if config:
        collect_actions(config)
        # 一个引用 = 一组候选字符串(含 pluginID/actionUUID/contextID);
        # 只有当某组字符串与任何已装插件目录名都无交集时才算缺失
        stems = {d[: -len(".sdPlugin")] for d in installed}
        missing = [
            next(iter(payload - stems)) if (payload - stems) else "?"
            for payload in referenced_payloads
            if not (payload & stems)
        ]
        check(
            "插件完整性",
            not missing,
            f"配置引用 {len(referenced_payloads)} 处 · 已装 {len(installed)} 个"
            + (f" · 缺失: {sorted(set(missing))}" if missing else ""),
        )

    # 4. pluginSettings 孤儿(参数文档无对应已装插件)
    orphans = []
    if os.path.isdir(SETTINGS) and installed:
        for f in os.listdir(SETTINGS):
            if f.endswith(".json"):
                uuid = f[: -len(".json")]
                if f"{uuid}.sdPlugin" not in installed:
                    orphans.append(f)
    check(
        "pluginSettings 孤儿",
        not orphans,
        f"{len(orphans)} 份无对应插件(无害,可手工清理): {orphans[:5]}" if orphans else "",
    )

    # 5. 自动备份新鲜度
    newest_age_h = None
    if os.path.isdir(BACKUPS):
        autos = sorted(
            (f for f in os.listdir(BACKUPS) if f.startswith("auto-") and f.endswith(".zip")),
            reverse=True,
        )
        if autos:
            mtime = os.path.getmtime(os.path.join(BACKUPS, autos[0]))
            newest_age_h = (datetime.now(timezone.utc).timestamp() - mtime) / 3600
    if newest_age_h is None:
        check("自动备份", False, "backups/ 无 auto-*.zip(开启启动方式后每次配置变更自动产出)")
    elif newest_age_h > 168:
        check("自动备份", False, f"最新备份已 {newest_age_h:.0f}h 未更新(超过一周,检查 app 是否常驻)")
    else:
        check("自动备份", True, f"最新 {newest_age_h:.1f}h 前")

    # 6. pending-import 残留
    pending = os.path.isdir(PENDING) and os.listdir(PENDING)
    check(
        "导入暂存",
        not pending,
        f"pending-import/ 有残留(上次导入取消/失败),下次启动会自动应用: {os.listdir(PENDING) if pending else ''}"
        if pending
        else "",
    )

    # 7. 崩溃自愈 agent
    if os.path.exists(AGENT_PLIST):
        check("崩溃自愈 LaunchAgent", True, AGENT_PLIST)
    else:
        check("崩溃自愈 LaunchAgent", False, "WARN 未启用(面板「启动方式」可开;崩溃后设备无人管理 ~9s 进待机)")

    # 8. 近 5 分钟错误计数(oslog;info 级以下不可取,历史区需 --info)
    try:
        out = subprocess.run(
            ["log", "show", "--last", "5m", "--style", "compact", "--predicate",
             'subsystem == "opendeck" AND process == "OpenDeck" AND (eventMessage CONTAINS "失败" OR eventMessage CONTAINS "错误" OR messageType == 16 OR messageType == 17)'],
            capture_output=True, text=True, timeout=30,
        )
        lines = [l for l in out.stdout.splitlines() if l.strip() and not l.startswith(("Filtering", "Timestamp"))]
        check("近 5 分钟错误/失败日志", not lines, f"{len(lines)} 条" + (f"(首条: {lines[0][:120]})" if lines else ""))
    except Exception as e:
        check("近 5 分钟错误/失败日志", True, f"WARN 无法查询: {e}")

    # 9. 磁盘余量(家目录所在卷)
    try:
        usage = shutil.disk_usage(os.path.expanduser("~"))
        free_gb = usage.free / 2**30
        check("磁盘余量", free_gb > 5, f"{free_gb:.0f} GB free" + ("" if free_gb > 5 else "(<5GB,原子写盘可能失败)"))
    except Exception as e:
        check("磁盘余量", True, f"WARN 无法查询: {e}")

    # 结论
    hard = sum(1 for r in results if not r["ok"])
    if JSON_MODE:
        print(json.dumps({"ok": hard == 0, "failed": hard, "checks": results},
                         ensure_ascii=False, indent=2))
    else:
        print(f"\n结论: {len(results) - hard}/{len(results)} 项通过" + (f",{hard} 项待处理" if hard else ",全部健康"))


if __name__ == "__main__":
    main()
