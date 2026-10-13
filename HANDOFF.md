# StreamDock 原生重写 — 交接设计文档

> 供总设计师(做架构决策)与执行 agent(写代码)共用的一页式上下文包。
> 所有事实均已本机实测或溯源到可查实现,**不要重新调查,直接在此之上设计**。
> 最后更新:2026-10-13

---

## 0. 目标与非目标

**目标**:用原生 Swift(macOS)重写 MiraBox Stream Dock 管理器,替代官方 StreamDock.app。
**非目标(明确不做)**:插件商店、账号体系、生态运营、Windows/Linux 版本。

**动机基线(官方软件实测,2026-10-13)**:
23 个进程 / 常驻 1.9 GB(其中 17 个 Chromium/QCefView 子进程)/ 主进程空闲 ~20% CPU / 磁盘 2.1 GB。
病根 = Qt 壳 + 内嵌浏览器引擎画 UI。插件系统本身不重(每个 node 插件进程仅 12–25 MB)。

**预期收益**:单进程 SwiftUI 应用,内存 60–250 MB(含插件),空闲 CPU ≈0%,磁盘 <20 MB。

---

## 1. 已验证事实

### 1.1 设备(用户手里这台)
- MiraBox Stream Dock **293S**:5×3 主键(LCD 100×100)+ 右侧 3 软键(80×80)
- 系统枚举名 `HOTSPOTEKUSB HID DEMO`,USB **VID 0x6603 : PID 0x1005**
- ⚠️ 同型号不同批次 PID 不同(社区已知 0x6602:0x1014、0x5548:0x6670、0x1500:0x3003)。
  **枚举逻辑按布局/VID 段识别,不要硬编码单一 PID**
- **旧平台**:命令必须串行同步发送,禁止并发写(官方文档明示)
- 官方 app 路径 `/Applications/StreamDock.app`;**测试自研驱动前必须先退出它**(HID 会互抢,现象:图标闪烁)

### 1.2 通信协议(HID,写入路径已实测打通)
- 输出报告:reportID 0,载荷 = `"CRT\0\0"`(43 52 54 00 00)+ 命令,补零到 **1024 字节**(本机验证 1024/无报告头可用;512 是部分型号的回退项)
- 命令均为 ASCII 助记符:

| 能力 | 命令字节 | 说明 |
|---|---|---|
| 心跳 | `43 4f 4e 4e 45 43 54`("CONNECT") | **≤8s 一次,否则设备自动重启** |
| 唤醒 | `44 49 53`("DIS") | |
| 刷新 | `53 54 50`("STP") | 传输完成后调用 |
| 亮度 | `4c 49 47 00 00 b`("LIG") | b=(v/100)^0.75×100,0–100 |
| 清键/全清 | `43 4c 45 00 00 00 id`("CLE") | id=0xff 全板 |
| 画键头 | `42 41 54` + size(u32 BE) + keyId("BAT") | 后跟 JPEG 数据 |
| 断开 | `43 4c 45 00 00 44 43` | CLE.."DC" |

- **画键**:`BAT` 头 → JPEG 原始字节按 1024B 分块(**无 CRT 前缀**,每块补零到 1024)→ `STP`。
  JPEG 规格:主键 100×100、软键 80×80,RGB,**单张 ≤10240 字节**(超了就降质量重压或缩图)
- **按键上报**:输入报告 data[9]=键 id,data[10]=0 抬起 / 非0 按下
- **键位映射(蛇形走线,勿按行序想当然)**:
  r0:`0d 0a 07 04 01` r1:`0e 0b 08 05 02` r2:`0f 0c 09 06 03` 软键:`10 11 12`
- 传输层还支持(未实测):整屏背景图、背景动画帧(x/y/w/h/layer)、LED 彩灯(RGB)、sleep()

### 1.3 已有资产
- **`mirabox/StreamDockProbe.swift`**(零依赖 Swift+IOKit,约 230 行)+ 编译产物 `probe`。
  已验证:打开设备、握手、亮度、清屏、4 键画图全部成功;按键上报代码就绪,**待物理按压验证**
- 协议参考实现(活跃维护,293S 有专属型号文件):
  `github.com/bitfocus/companion-surface-mirabox-stream-dock`(TypeScript,MIT)
- 官方开发者文档:`creator.key123.vip`(C++/Python 直控 SDK);插件协议:`sdk.key123.vip`

### 1.4 插件兼容性(已核实)
- 官方插件就是 **Elgato Stream Deck SDK 格式**(`.sdPlugin`:manifest.json + plugin/*.js + propertyInspector/ HTML + i18n json),代码未混淆、可读可改
- 官方 app 宿主方式:拉起 `node20 plugin/index.js -port 18618 -pluginUUID <uuid> -registerEvent registerPlugin -info <json>`,经本地 WebSocket 收发事件
- **结论:自研管理器实现宿主侧协议 → 大部分插件免改直接跑**;Windows 残留的插件做配置级小修

---

## 2. 目标架构

```
StreamDockApp(SwiftUI,菜单栏可选 LSUIElement)
├── UI 层:18 键网格编辑器、页面管理、设置
├── 动作层(原生):打开 App/URL、运行 Shortcuts、Shell/AppleScript、
│   发送全局热键(CGEvent)、媒体键
├── 插件宿主层(M2):NWProtocolWebSocket 服务 + Process 拉起 node +
│   manifest 解析 + setImage/setSettings 事件 + WKWebView 承载 Property Inspector(按需)
└── StreamDockKit(驱动库,Swift Package,独立可测)
    ├── HID:IOKit 打开/枚举(IOHIDManager,热插拔回调)/串行写队列/输入报告回调
    ├── 协议:心跳定时器、wake、brightness、clearKey/clearPanel、setKeyImage(自动压质到≤10KB+分块)
    └── 状态机:连接 → 校准(亮度/清屏/全量重画) → 运行(心跳+按键事件) → 睡眠/唤醒重画 → 断开
```

建议工程布局(总设计师可调整):
```
mirabox/
├── StreamDockKit/        # Swift Package:驱动+协议+状态机(纯逻辑,可单元测试,mock HID)
├── StreamDockApp/        # Xcode 项目:UI+动作+插件宿主,依赖 Kit
├── StreamDockProbe.swift # 已有:协议探针(保留作回归工具)
└── HANDOFF.md            # 本文档
```

---

## 3. 里程碑与验收标准

**M1 — MVP(先做这个)**
驱动库 + 静态键位配置(JSON 持久化)+ 原生动作 5 种 + 简单编辑器。
验收:退出官方 app → 启动自研 app → 18 键显示自定义图标 → 按键触发对应动作 → 重启后配置保留 → 空闲 CPU <2%。

**M2 — 插件宿主 v1**
WebSocket 宿主 + node 拉起 + 事件闭环(keyDown/keyUp→插件,setImage→键面)+ per-context settings 持久化。
验收:官方 OBS 插件免修改装入,能在面板上显示状态图并响应按键。

**M3 — 兼容与体验打磨**
Property Inspector(WKWebView)、多状态图标、多页面、登录自启、屏幕休眠唤醒、逐插件适配。

---

## 4. 关键陷阱(执行 agent 必读)

1. JPEG ≤10240B/键,超限降质量重压;1024B 分块时**数据块不带 CRT 前缀**
2. 心跳 ≤8s;发漏设备会重启黑屏(现象像"坏了",其实是心跳断了)
3. **旧平台串行写**:驱动层放串行队列,UI 层随意调,排队由队列消化
4. 设备屏幕休眠后唤醒需 `DIS` + 全量重画;状态机必须处理
5. macOS 沙箱 app 需 USB entitlement;非沙箱 CLI/菜单栏 app 不需要
6. 与官方 app 互斥;自研 app 启动时可检测并提示
7. 键位是蛇形映射(见 1.2),UI 网格坐标↔键 id 必须经映射表转换
8. 图标包制作规格是 128×128,但线上键面分辨率由型号决定(293S:100×100/80×80),由**管理器下采样**,别把 128 图直接发设备

---

## 5. 待办实验(M1 动工前完成,合计约半天)

| 实验 | 方法 | 决定什么 |
|---|---|---|
| 按键上报物理验证 | 跑 `./probe` 按面板键,看 `⌨️` 输出 | M1 验收前提 |
| 背景图/动画/LED 能力 | 探针加三条命令试发,肉眼验证 | 视觉层上限(锦上添花) |
| 休眠-唤醒行为记录 | 等设备自动休眠,记录唤醒条件 | 状态机细节 |
