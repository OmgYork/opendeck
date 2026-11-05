# OpenDeck 使用手册（供其他 AI agent）

**读者**：需要在用户的 Mac 上使用 OpenDeck / Stream Dock 293V3 的其他 AI coding agent。
**目标**：让你在不破坏用户现有配置的前提下，读取键面状态、绑定按键、编写插件或接入状态灯。

配套文档：

| 文档 | 作用 |
|---|---|
| 本文 `AGENT-GUIDE.md` | 操作手册：路径、规矩、接入方式、部署、排障 |
| `HANDOFF.md` | 开发史与设计决策（根因、协议实测、各里程碑）；改代码前必读 §1/§4 |
| `Scripts/状态灯接入指南.md` | 只做「agent 状态灯」的模板化步骤，照抄即可 |
| `Design/MonitorInputIcon/README.md` | 显示器输入源动效键的设计与状态机 |

> 事实基线：2026-11-06（十一轮后，167 测全绿）。仓库已迁至 `/Users/yorkli/Projects/mirabox`。配置与槽位以运行中的 `config.json` 为准，本文的槽位表只是快照。
> 新增事实：**单实例锁**（第二实例弹窗退出；LaunchAgent 拉起的实例带环境标记静默退出）；`pending-import/` 目录会被下次启动自动应用（导入暂存，勿手碰）；自动备份在 `backups/`；键面 112 与保留槽 13/14 规则不变。
> **排障第一步用体检脚本**：`python3 /Users/yorkli/Projects/mirabox/Scripts/opendeck-doctor.py`（只读，输出运行中构建指纹/配置健康/插件完整性/备份新鲜度/近期错误，9 项 ✓/✗ 清单）。
> **崩溃自愈**：面板「启动方式」= 关/登录启动/**登录+崩溃自愈**（LaunchAgent `~/Library/LaunchAgents/com.opendeck.app.plist`，KeepAlive.SuccessfulExit=false——崩溃自动重启、正常退出不重启；与登录项互斥，二者至多一个生效）。崩溃后 oslog 取证仅 error/fault 可持久（`log show` 不含 info 历史，§6.13）。

---

## 0. 30 秒事实

- OpenDeck 是自研 macOS 应用，**取代官方 StreamDock.app**，管理一块 **Stream Dock 293V3**：5 列 × 3 行 = **15 键**，键面 **112×112**，设备以 **180° 旋转**显示。
- 应用是 SwiftUI 单进程，主窗口是 15 键编辑器，菜单栏常驻一个控制面板。
- 插件格式兼容 **Elgato Stream Deck SDK v2**（`.sdPlugin`），支持两类：
  - **Node 插件**：`CodePath` 为 `.js`，宿主拉起 `node` 子进程；
  - **HTML 插件**：`CodePath` 为 `.html`，宿主用无头 `WKWebView` 承载。
- **设备是独占资源**：OpenDeck 与官方 StreamDock.app 不能同时运行（HID 会互抢，表现为图标闪烁）。
- **配置由运行中的 app 持有**：`ConfigStore` 每次变更都会原子落盘；app 运行时手改盘上文件，下一次配置变更会把整份内存快照写回去、覆盖你的修改。
- 插件目录只在 **app 启动**（或经插件管理器安装/卸载）时扫描；手工拷贝插件后需重启 app。

---

## 1. 路径速查

| 内容 | 路径 |
|---|---|
| 源码仓库 | `/Users/yorkli/Projects/mirabox` |
| 构建产物 | `mirabox/dist/OpenDeck.app` |
| 配置文件 | `~/Library/Application Support/OpenDeck/config.json` |
| 已安装插件 | `~/Library/Application Support/OpenDeck/plugins/<uuid>.sdPlugin/` |
| 插件实例参数 | `~/Library/Application Support/OpenDeck/pluginSettings/<pluginID>.json` |
| 官方 app 插件（只读来源） | `~/Library/Application Support/HotSpot/StreamDock/plugins/` |
| 状态灯模板源码 | `mirabox/Scripts/com.zcode.status.sdPlugin/` |
| 显示器输入状态 | `~/.cache/lg_input`（内容 `mac` / `pc`） |
| 日志子系统 | `opendeck`（category `device`，info 级） |

Bundle ID：`com.opendeck.app`。源码入口：`Sources/OpenDeck/OpenDeckApp.swift`。

---

## 2. 硬规矩（违反会破坏用户配置或设备）

1. **不要在 OpenDeck 运行时写配置/参数文件。**
   app 不监听磁盘变化，且每次变更都会用内存快照整份覆盖盘上文件。需要脚本化改配置时：先退出 app → 备份 → 改 → 再启动。
   ```bash
   osascript -e 'quit app "OpenDeck"'
   cp "$HOME/Library/Application Support/OpenDeck/config.json" \
      "$HOME/Library/Application Support/OpenDeck/config.json.bak-$(date +%Y%m%d-%H%M)"
   # 编辑……
   open "/Users/yorkli/Projects/mirabox/dist/OpenDeck.app"
   ```
2. **不要同时运行官方 StreamDock.app。** OpenDeck 已能检测并提示退出它；你也不要在后台拉起官方 app。
3. **不要修改保留槽。** 索引 13/14（位置 14/15）是固定导航键；编辑器禁止编辑，配置里的旧值也不会渲染。索引 5/6/7（位置 6/7/8）自 2026-11-01 起不再是保留槽——统计键（GPU/CPU/温度）动作化为 `KeyAction.stat`，可放任意键位、可清除。
4. **不要手改正在被插件读写的运行时文件。** 例如状态灯的 `state.json` 可以写（这正是契约），但不要删除、替换插件目录内的运行中文件；先退出 app。
5. **键面图必须是 112×112。** 小于键面的图会被固件锚定到右下角，表现为「左/上空隙大」。单张 JPEG ≤ 10240 字节由宿主自动降质，插件侧不必自己压。
6. **不要提交（git commit/push）**，除非用户明确要求。文档与代码改完留在工作区即可。

---

## 3. 接入方式怎么选

| 你的需求 | 方式 | 改动面 | 从哪里开始 |
|---|---|---|---|
| 让你的 agent 有一个实时状态灯 | **复制状态灯模板** | 只写 hook 脚本 + manifest 身份 | `Scripts/状态灯接入指南.md`，§4 |
| 在键面画任意内容（图表、时钟、动画） | **写 HTML 插件** | 新目录 `plugins/<uuid>.sdPlugin/` | 本文 §5 |
| 复用现成 Elgato Node 插件 | **装 Node 插件** | 拷贝/导入，无需改代码 | 本文 §5.7 |
| 只想要一个按键动作（开 app、跑快捷指令、发热键） | **在编辑器里绑定** | 改配置（通过 UI） | 本文 §6 |
| 需要宿主级新动作 / 新动效 | **改 OpenDeck 源码** | Swift 代码 + 测试 + 重打包 | 本文 §8，另读 `HANDOFF.md` |

优先顺序：能用模板就不要写新插件；能写 HTML 就不要改宿主。

---

## 4. 方式 A：agent 状态灯（最常用）

完整步骤见 `Scripts/状态灯接入指南.md`，这里只给不可省略的要点：

1. 整目录拷贝模板（**必须带上 `whale.js` 和 `hook.py`**）：
   ```bash
   cp -R "/Users/yorkli/Projects/mirabox/Scripts/com.zcode.status.sdPlugin" \
         "$HOME/Library/Application Support/OpenDeck/plugins/com.<你的标识>.status.sdPlugin"
   ```
2. 改 `manifest.json`：目录名、`Name`、`Actions[0].UUID` 三处换成你自己的身份；可选加 `ActivateAppBundleID`（按键抬起时把你的 app 置前）。
3. **不要改 `index.html` 和 `whale.js`。** 渲染、读盘、宿主推拍契约都是现成的。
4. 改 `hook.py` 里的 `EVENT_TO_STATE` 和 `ASKING_TOOL`。
5. 在你的 agent 配置里挂 hooks，命令用**绝对路径**指向你插件根里的 `hook.py`。
6. 重启 OpenDeck，请用户在编辑器里把新动作绑到空闲键位。
7. 自测写盘：
   ```bash
   echo '{"hook_event_name":"SessionStart"}' | python3 \
     "$HOME/Library/Application Support/OpenDeck/plugins/com.<你的标识>.status.sdPlugin/hook.py"
   cat "$HOME/Library/Application Support/OpenDeck/plugins/com.<你的标识>.status.sdPlugin/state.json"
   ```
   期望 `{"state":"ready","updatedAt":...}`。

状态语义、事件映射、红线见接入指南 §1/§2/§5。**一个 agent 一份插件拷贝**，靠独立目录隔离 `state.json`；不要共用 ZCode 的插件目录。

---

## 5. 方式 B：写一个 `.sdPlugin`

### 5.1 最小 HTML 插件目录

```
com.example.demo.sdPlugin/
├── manifest.json
└── index.html
```

`manifest.json` 最小可用形态：

```json
{
  "Name": "Demo",
  "Version": "1.0.0",
  "SDKVersion": 1,
  "CodePath": "index.html",
  "OS": [{ "Platform": "mac", "MinimumVersion": "10.11" }],
  "Actions": [
    {
      "UUID": "com.example.demo.action",
      "Name": "Demo 动作",
      "Controllers": ["Keypad"],
      "States": [{}]
    }
  ]
}
```

字段语义（解析器：`Sources/PluginHost/SDManifest.swift`）：

| 字段 | 说明 |
|---|---|
| `CodePath` / `CodePathMac` | 入口，`.html` = HTML 家族，`.js` = Node 家族；`CodePathMac` 优先 |
| `Nodejs.Version` | manifest 声明的大版本（如 `"20"`，仅记录；宿主按候选顺序找可用 node，不强制版本） |
| `Actions[].UUID` | 动作身份，绑定实例时写入配置 |
| `Actions[].States` | 状态数量；`[{}]` 单态，多个则宿主可自动轮换 |
| `Actions[].DisableAutomaticStates` | `true` = 插件自己管状态，宿主不在 keyUp 后轮换 |
| `Actions[].Controllers` | 缺省或空数组 = 不限制；显式不含 `"Keypad"` 的动作不会出现在 15 键选择器 |
| `Actions[].PropertyInspectorPath` | 动作级 PI 页面；顶层 `PropertyInspector` 是旧式兜底 |
| `Actions[].ActivateAppBundleID` | OpenDeck 扩展：按键抬起时激活该 bundle id（无权限要求） |

插件 UUID = 目录名去掉 `.sdPlugin`（官方 manifest 顶层没有 UUID 字段，目录名是权威来源）。

### 5.2 启动与注册（HTML）

宿主在页面 `documentEnd` 注入引导，调用：

```js
connectElgatoStreamDeckSocket(port, pluginUUID, "registerPlugin", infoJSON)
```

你的页面需要定义这个全局函数。最小实现：

```js
var ws;
window.connectElgatoStreamDeckSocket = function (port, uuid, registerEvent, info) {
  ws = new WebSocket('ws://127.0.0.1:' + port);
  ws.onopen = function () {
    ws.send(JSON.stringify({ event: registerEvent, uuid: uuid })); // 必须第一条
  };
  ws.onmessage = function (evt) {
    var msg = JSON.parse(evt.data);
    if (msg.event === 'willAppear') {
      // msg.context 是本键实例身份；记住它，之后 setImage 要用
    } else if (msg.event === 'willDisappear') {
      // 键离开当前页
    }
  };
};
```

**一个 WebView 服务该插件所有键实例。** 必须按 `context` 维护注册表；`setImage` 要逐 context 发。

### 5.3 生命周期事件（宿主 → 插件）

| 事件 | 时机 | 关键字段 |
|---|---|---|
| `deviceDidConnect` | 设备连接/重连 | `deviceInfo` |
| `deviceDidDisconnect` | 设备断开 | `device` |
| `willAppear` | 键出现在当前页（含切换页面、启动） | `context`、`action`、`payload.settings/state/coordinates` |
| `willDisappear` | 键离开当前页 | `context` |
| `keyDown` / `keyUp` | 物理按压两沿，**两沿都转发** | 同上 |
| `didReceiveSettings` | 参数变化（PI 或插件写入） | `payload.settings` |
| `didReceiveGlobalSettings` | 宿主应答 `getGlobalSettings` | `payload.settings` |
| `propertyInspectorDidAppear/Disappear` | PI 打开/关闭 | `context` |
| `systemDidWakeUp` | Mac 从睡眠唤醒 | — |

实例事件的 `payload` 固定含 `settings`、`coordinates: {row, column}`、`isInMultiAction:false`，多状态动作还带 `state`。

### 5.4 插件 → 宿主（常用）

| 发送 | 形态 | 说明 |
|---|---|---|
| 注册 | `{event:"registerPlugin", uuid:"<pluginUUID>"}` | 连接后第一条，先于一切 |
| 上屏 | `{event:"setImage", context, payload:{image, target:0}}` | `image` 为 data URL；空串 = 恢复 manifest 默认图 |
| 标题 | `{event:"setTitle", context, payload:{title, target:0}}` | 多行会折成单行 |
| 状态 | `{event:"setState", context, payload:{state:N}}` | 0 基 |
| 参数 | `{event:"setSettings", context, payload:{...}}` | **整对象替换**，不是逐字段合并 |
| 全局参数 | `{event:"setGlobalSettings", context:"<pluginUUID>", payload:{...}}` | 注意 context 填插件 UUID，不是实例 context |
| 日志 | `{event:"logMessage", payload:{message:"..."}}` | 进 `opendeck` 日志，排障首选 |
| 提示 | `showOk` / `showAlert` / `openUrl` | 可选 |

图像契约：

- 画布用 **112×112**；PNG/JPEG data URL 均可，SVG data URL 也支持（百分号编码或 base64）。
- 透明像素由宿主合成到该键配置的底色（当前默认深色）后转 JPEG 下发。
- 宿主自动把 JPEG 压到 ≤10240 字节，并保持画布尺寸；不要自己缩到 80/60。
- 高帧率动画靠连续 `setImage`。宿主推拍最短 **200ms（5fps）**，设备不支持 GIF。

### 5.5 宿主扩展桥（HTML 专用）

`WKWebView` 对 `file://` 有硬限制，宿主注入了三个通用能力（实现：`Sources/OpenDeck/PluginWebviewRuntime.swift`）：

1. **`window.opendeckReadFile(相对路径)` → `Promise<string base64>`**
   只能读插件根目录内的文件；绝对路径/越界会被拒；5 秒超时。
   状态灯用它读 `state.json`。**不要用 `fetch()` 读本地文件。**
2. **透明 `fetch` polyfill**
   `file:` 相对路径的 `fetch` 会自动转成上面的桥并返回字节体 `Response`；其他协议原样透传。这是为了兼容官方 HTML 插件。
3. **`window.__opendeckPulse`（可选）**
   页面定义该函数即接入宿主推拍：宿主按固定间隔调用它，**返回值 = 期望的下一拍毫秒数**（钳制 200–5000）。
   隐藏页面的自链 `setTimeout` 会被 WebKit 冻毙（约 2 分钟），**动画/轮询一律用推拍，不要自持定时器**。
   参考实现：`Scripts/com.zcode.status.sdPlugin/index.html` 的 `tick()` 与 `__opendeckPulse`。

另外，页面的未捕获异常、`unhandledrejection`、`console.error/warn` 会自动上报到宿主日志（有频率限制），不需要自己接。

已知限制：`localStorage` 不跨重启（nonPersistent dataStore）；`window.open`/弹窗不支持；`<input type="file">` 不支持；插件间互不共享存储。

### 5.6 Property Inspector（可选）

在 action 上声明 `PropertyInspectorPath`，编辑器会打开一个 `WKWebView` 承载该页面。契约：

- 宿主注入 5 参调用：`connectElgatoStreamDeckSocket(port, contextID, "registerPropertyInspector", appJSON, infoJSON)`；第 2 参是**动作实例 contextID**，不是插件 UUID。
- PI 注册包 `{event:"registerPropertyInspector", uuid:"<contextID>"}`。
- 注册后宿主会主动推 `didReceiveSettings`；**页面要等这条才渲染主界面**，否则会永久空白。
- PI 的 `get/setGlobalSettings` 的 context 也填 contextID；`sendToPlugin` / `sendToPropertyInspector` 双向原帧透传。
- PI 可以直接发 `setImage` / `setTitle` / `setState` 操纵键面。

没有 PI 也能正常工作；状态灯模板就没有 PI。

### 5.7 Node 插件

宿主兼容官方 Elgato 拉起的命令行：

```
node <plugin>/plugin/index.js -port <P> -pluginUUID <U> -registerEvent registerPlugin -info <JSON>
```

其余协议与 HTML 相同（同一个 WebSocket 服务端、同一套事件）。Node 位置由 `NodeLocator` 查找（官方 StreamDock.app 自带或系统 node）。插件会随当前页实例按需拉起；崩溃最多重试 3 次。

---

## 6. 方式 C：只加按键动作（不改代码）

在 OpenDeck 主窗口点击任意非保留键 → 编辑面板可设置：标题、底色、图标、动效、动作。

原生动作（`KeyAction`）：

| 类型 | 说明 |
|---|---|
| 打开 App | `.app` 的 POSIX 路径 |
| 打开 URL | http/https 等 |
| 运行快捷指令 | Shortcuts 名称 |
| Shell | `zsh -c` |
| AppleScript | osascript |
| 全局热键 | keyCode + command/option/control/shift |
| 媒体键 | playPause / next / previous / volumeUp / volumeDown / mute |
| 页面/场景 | 上一页、下一页、上一场景、下一场景、页面指示、熄屏 |
| 插件 | 绑定某个 `.sdPlugin` 的 action |

如果是替用户临时加一个键，**请通过 UI 完成**；确实需要脚本化时遵守 §2 的退出后再改配置。

---

## 7. 键位、保留槽与当前占用

索引 `index = row*5 + column`，从 0 开始；**位置 = index + 1**（用户口语通常说「第 N 键」）。

```
物理布局（位置 1–15）
+-----+-----+-----+-----+-----+
|  1  |  2  |  3  |  4  |  5  |   ← 顶行
+-----+-----+-----+-----+-----+
|  6  |  7  |  8  |  9  | 10  |   ← 中行
+-----+-----+-----+-----+-----+
| 11  | 12  | 13  | 14  | 15  |   ← 底行
+-----+-----+-----+-----+-----+
```

保留槽（任何页面都强制渲染，不可编辑）：

| 索引 | 位置 | 内容 |
|---|---|---|
| 13 | 14 | `↔` 下一场景 |
| 14 | 15 | `↕` 下一页 |

统计键（GPU/CPU/温度）自 2026-11-01 起是普通动作（`KeyAction.stat`）：从调色盘「系统」分类拖到任意键位即实时刷新，清除即消失，不再固定占用 6/7/8。

2026-10-22 默认场景首页占用（**以 `config.json` 为准**）：

| 索引 | 位置 | 内容 |
|---|---|---|
| 0 | 1 | 显示器输入源动效 + `runShortcut("Toggle Monitor")` |
| 1 | 2 | ZCode 状态灯 `com.zcode.status.light` |
| 2 | 3 | Hermes 状态灯 `com.hermes.status.light` |
| 9 | 10 | 下一页 |
| 10 | 11 | 播放/暂停媒体键 |
| 12 | 13 | 壁纸图标 |
| 13/14 | 14/15 | 保留导航键 |

首页其余空闲键（索引）：3、4、5、6、7、8、11（5/6/7 自 2026-11-01 统计键动作化后为普通用户槽）。**加东西前先读配置确认，不要凭这张表猜。**

设备与绘制细节：

- 绘制键 id 与输入键 id 是**两套编号空间**（绘制自底行起算，输入自顶行起算），见 `Sources/StreamDockKit/StreamDock293S.swift`。
- 宿主渲染帧会预旋转 180°，UI 镜像再转回来；插件只画**正立**的 112×112 图。
- 心跳 7s；设备断电/长时间无心跳会自重启。不要绕过 `DeviceController` 直接写 HID。

---

## 8. 构建、部署、验证

在 `mirabox/` 目录下：

```bash
swift build                 # 增量构建，必须确认 "Build complete"
swift test                  # 全部测试（只增不减），全绿才算通过
./make-app.sh               # release + 图标 + 组装 dist/OpenDeck.app + ad-hoc 签名
```

重启（**先退再开**，否则可能跑到旧二进制/旧插件列表）：

```bash
osascript -e 'quit app "OpenDeck"'
open "/Users/yorkli/Projects/mirabox/dist/OpenDeck.app"
```

插件部署：

```bash
# app 退出后执行
cp -R "你的插件.sdPlugin" "$HOME/Library/Application Support/OpenDeck/plugins/"
```

验证清单：

1. `swift build` 与 `swift test` 均通过，零新警告。
2. 重启后菜单栏状态为「已连接」。
3. 绑定键后键面有图（不是固件默认蓝块）。
4. 日志无 `setImage 解码失败` / `未找到 node` / `插件未安装`：
   ```bash
   log stream --level info --predicate 'subsystem == "opendeck"'
   ```
   （**必须带 `--level info`**；`log show` 默认不含 info 历史。）
5. 插件页存活观测：状态灯每 60s 一条 `alive state=... ctx=N`；没有这条说明页面没跑起来。

硬件冒烟工具（会独占 HID，**先退出 OpenDeck**）：

```bash
swift run StreamDockHarness --listen 30          # 画满键位 + 打印按键事件
swift run StreamDockHarness --plugin-test <插件目录>  # WS + 插件进程 + 设备上屏闭环
```

---

## 9. 排障速查

| 症状 | 最可能原因 | 处理 |
|---|---|---|
| 键面显示固件默认蓝块/彩角 | 心跳断过或设备刚重启；app 未完成校准 | 重启 OpenDeck，看日志是否有「校准」 |
| 图标左/上空隙大 | 图不是 112×112（被固件右下锚定） | 插件画布改 112，别自己缩图 |
| 键面一直是 manifest 默认图 | 插件没发 `setImage`，或注册前就发了 | 确认 `willAppear` 后按 context 发图 |
| HTML 插件静默不工作 | `file://` fetch/XHR 被拒、自持定时器被冻毙 | 用 `opendeckReadFile`，轮询改 `__opendeckPulse` |
| 插件列表里没有新插件 | 插件目录只在启动时扫描 | 退出并重启 OpenDeck |
| 「插件未安装，动作暂不生效」 | 键绑定的插件已卸载/改名 | 重绑或恢复插件；空置属预期 |
| 按键无反应 | 绑定在保留槽、动作未保存、或插件实例不在当前页 | 换到非保留槽；确认当前页；看 keyDown 日志 |
| 图标闪烁/互相打架 | 官方 StreamDock.app 也在运行 | 退出官方 app |
| 改完配置又变回去 | app 运行时改了盘上文件，退出时被内存覆盖 | 按 §2 退出后再改 |
| PI 页面空白 | 宿主未收到 `didReceiveSettings` 前的渲染时序 | 确认 PI 等首条下行再显示主界面 |
| 动画播两分钟停住 | 页面自链 `setTimeout` 被 WebKit 节流 | 改用宿主推拍 `__opendeckPulse` |

日志定位顺序：`log stream` → 搜 `📜` / `插件` / `setImage` / `显示器` → 必要时临时加 `hooks.log` 再重编译。

---

## 10. 交付规范（你改完以后）

1. **更新文档**：新功能/新坑写进 `HANDOFF.md` 的 `§6.x`（追加，不覆盖历史）；状态灯相关同步 `Scripts/状态灯接入指南.md`。
2. **跑验证**：`swift build` + `swift test`；涉及 UI/硬件时说明哪些是目视验收、哪些是日志佐证。
3. **说明改动面**：列出改了哪些文件、为什么；区分「已提交」「仅工作区」。
4. **不要顺手改职责外的东西**：看到其他问题先汇报，等用户指令。
5. **不要擅自提交/推送**，也不要改版本号。
6. **多 agent 归属**：主控 agent 用 `python3 Scripts/docs_baseline.py snapshot` 保存基线，之后 `diff` 里多出来的新增行/新增文件就是基线后写入的内容。你写文档时请注明 `agent: <名字>` 与日期，方便归属；不要删除或改写别人刚写的段落，追加为主。

---

## 11. 明确不要做的事

- 不要绕过 OpenDeck 直接向设备写 HID（会和宿主抢设备、破坏心跳与状态机）。
- 不要删除或覆盖 `com.zcode.status.sdPlugin`（ZCode 自己的灯）。
- 不要改保留槽、不要改别的页面的绑定。
- 不要用守护进程常驻轮询 agent 内部状态来替代 hooks；有事才写盘。
- 不要把 `state.json`、settings 等运行时文件提交进 git。
- 不要把 100×100 写回代码——112×112 是官方抓包定案（`HANDOFF.md §6.20`）。
