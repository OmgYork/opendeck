# OpenDeck

自研 macOS 版 Stream Dock 管理器（替代官方 StreamDock.app），目标设备 MiraBox Stream Dock **293V3**：15 键（5×3），键面 **112×112**，JPEG，设备 180° 旋转显示。

## 先读哪份

| 你是 | 读 |
|---|---|
| 第一次接触本项目的 agent | [`AGENT-GUIDE.md`](AGENT-GUIDE.md)（操作手册：路径、规矩、插件契约、部署、排障） |
| 要改 OpenDeck 源码 | [`HANDOFF.md`](HANDOFF.md)（开发史、协议实测、设计决策、各里程碑根因） |
| 只想给 agent 接一个状态灯 | [`Scripts/状态灯接入指南.md`](Scripts/状态灯接入指南.md)（模板化步骤） |
| 要看显示器输入源动效 | [`Design/MonitorInputIcon/README.md`](Design/MonitorInputIcon/README.md) |

## 快速开始

```bash
cd "/Users/yorkli/Downloads/shortcut general/mirabox"

swift build          # 增量构建
swift test           # 全部测试（只增不减）
./make-app.sh        # 组装 dist/OpenDeck.app 并 ad-hoc 签名

osascript -e 'quit app "OpenDeck"'
open dist/OpenDeck.app
```

日志：

```bash
log stream --level info --predicate 'subsystem == "opendeck"'
```

## 转发给其他 agent 的模板

```text
请在 /Users/yorkli/Downloads/shortcut general/mirabox 下工作。
先读 AGENT-GUIDE.md，并遵守 §2 的硬规矩（不要运行时改配置、不要动保留槽、不要提交）。
只做状态灯：读 Scripts/状态灯接入指南.md。
改完跑 swift build && swift test，并把新事实追加到 HANDOFF.md §6.x。
```

## 多 agent 文档改动检测

多个 agent 共用这套文档时，用基线快照判断「哪些内容不是我写的」：

```bash
python3 Scripts/docs_baseline.py snapshot --label before-other-agent
python3 Scripts/docs_baseline.py status     # 只看哪些文件变了
python3 Scripts/docs_baseline.py diff       # 列出新增行/新增文件（关键输出）
python3 Scripts/docs_baseline.py diff --full # 附完整 unified diff
```

基线存放在 `.handoff-baseline/<时间戳>/`（已 gitignore），每次 `snapshot` 会新建一份，不会覆盖旧基线。`diff` 中「新增行 / 新增文件」如果不是本 agent 写的，就是另一个 agent 写的。

## 关键路径

- 配置：`~/Library/Application Support/OpenDeck/config.json`
- 插件：`~/Library/Application Support/OpenDeck/plugins/`
- 插件参数：`~/Library/Application Support/OpenDeck/pluginSettings/`
- 状态灯模板源码：`Scripts/com.zcode.status.sdPlugin/`

## 当前状态（2026-11-01）

- 15 键、112×112 JPEG、180° 预旋转；心跳 7s。
- 官方 HTML/Node 插件宿主、Property Inspector、多页面/场景。
- 保留槽：仅索引 13/14（切场景/翻页）；统计键（GPU/CPU/温度）已动作化（`KeyAction.stat`），从功能调色盘「系统」分类拖到任意键位即实时刷新，可清除。
- 功能调色盘：编辑器右列常驻，含自定义（指定槽位实时镜像）/显示器/翻页·场景/媒体控制/系统/模板（待配置）六类。
- 首页：槽 1 显示器输入动效 + Toggle Monitor，槽 2 ZCode 状态灯，槽 3 Hermes 状态灯。
- `swift test` 全绿；剩余挂账：官方 HTML 插件逐个视觉适配。
