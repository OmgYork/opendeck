# AGENTS.md — OpenDeck 仓库 agent 入口

> 本文件是 AI coding agent 进入本仓库的第一读点(工具链自动发现 AGENTS.md)。
> 人类读者请从 [README.md](README.md) 开始。

## 30 秒事实

- OpenDeck:自研 macOS Stream Dock 管理器,驱动 MiraBox 293V3(15 键,112×112 JPEG,180° 旋转)。
- **已开源**:`github.com/OmgYork/opendeck`(Public, Apache 2.0)。可以 push;不要改版本号。
- 提交规范:中文一行标题 + 要点正文;`swift test` 全绿(只增不减,当前 167 测)才可提交。

## 工作循环

1. 读 `AGENT-GUIDE.md`(操作手册:硬规矩/插件契约/部署/排障)——改代码前必读其 §2。
2. 改代码前读 `HANDOFF.md` §1/§4(协议事实与陷阱);你的改动完成后**追加** §6.x(不覆盖历史)。
3. 验证三件套:`swift build`(零警告)→ `swift test`(3× 连跑防波动)→ `./make-app.sh` 重建 dist。
4. 排障第一步:`python3 Scripts/opendeck-doctor.py`(9 项只读体检)。
5. 部署:先 `osascript -e 'quit app "OpenDeck"'` 再 `open dist/OpenDeck.app`(先退再开)。

## 硬规矩(违反会破坏用户配置或设备)

- app 运行时不要手改 `~/Library/Application Support/OpenDeck/` 下任何文件(内存即真相,退出时整份覆盖)。
- 不要动保留槽(索引 13/14)与 `com.zcode.status.sdPlugin`。
- 不要绕过 DeviceController 直接写 HID;键面 112×112 是官方抓包定案。
- 运行中的 dist 实例与调试实例互斥(单实例锁):验证 UI 前先退一个。

## 文档地图

| 文件 | 作用 |
|---|---|
| `AGENT-GUIDE.md` | 操作手册(硬规矩/插件契约/部署/排障) |
| `HANDOFF.md` | 开发史与设计决策(§1/§4 陷阱必读;§6.x 追加式日志,§6.26 起为 2026-11 加固系列) |
| `docs/subsystem-integration.md` | 子系统接入约定(线程规则/animator 形态/事故对照) |
| `Scripts/opendeck-doctor.py` | 一键体检(只读) |
| `Scripts/状态灯接入指南.md` | 给 agent 接状态灯的模板化步骤 |
