# StreamDock 原生重写 — 交接设计文档

> 供总设计师(做架构决策)与执行 agent(写代码)共用的一页式上下文包。
> 所有事实均已本机实测或溯源到可查实现,**不要重新调查,直接在此之上设计**。
> 最后更新:2026-10-15(PI 落地 + settings 持久化重构 B「内存即真相」,47 测全绿,dist 与最新提交一致)
> **M2.5 已全部验收通过(2026-10-15)**;M3 进行中:Property Inspector(✅ 代码落地见 §6.9,持久化健壮化见 §6.10,真机验收基本完成)> HTML 家族插件 > 自研 ZCode 状态灯

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
- MiraBox Stream Dock **293V3**(系统枚举名 `StreamDock[293S]`/`HOTSPOTEKUSB HID DEMO` 有误导性,实机为 15 键):
  5×3 = **15 键全主键(100×100),没有软键列**
- USB **VID 0x6603 : PID 0x1005**(另批次 0x1006)。⚠️ 社区模块的 HSV-293S(6 列带 3 软键)条目自带
  `TODO: verify these` 存疑标记,对应的是另一批次硬件——**不要**把 6 列布局套用在本机(2026-10-13 已踩坑并修正)
- 2026-10-13 实拍解码确认:固件键位 id 自**底行**起算(0x01=左下角,0x0f=右上角);
  设备以 180° 旋转显示图像,渲染层需预旋转(数字竖向对称曾致误判为水平镜像)
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

  - 画键:`BAT` 头后跟 JPEG 原始数据按 1024B 分块(**无 CRT 前缀**),每块补零到 1024,最后 `STP`。
    JPEG 规格:全键 100×100,RGB,**单张 ≤10240 字节**(超了就降质量重压或缩图)
- **按键上报**:输入报告 data[9]=键 id,data[10]=0 抬起 / 非0 按下
- **键位映射(逻辑行自顶行;固件 id 自底行起算,2026-10-13 实拍修正)**:
  r0:`0b 0c 0d 0e 0f` r1:`06 07 08 09 0a` r2:`01 02 03 04 05`
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
├── UI 层:15 键网格编辑器、页面管理、设置
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
验收:退出官方 app → 启动自研 app → 15 键显示自定义图标 → 按键触发对应动作 → 重启后配置保留 → 空闲 CPU <2%。

**M2 — 插件宿主 v1(✅ 已落地并验收,2026-10-13,提交链 f3e9e0d→549ee31→收尾提交)**
WebSocket 宿主 + node 拉起 + 事件闭环(keyDown/keyUp→插件,setImage→键面)+ per-context settings 持久化。
验收:官方 OBS 插件免修改装入,能在面板上显示状态图并响应按键。✅ 全部达成(实测记录见 §6)。

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
7. 键位是顺序映射(行序已按实拍修正)(见 1.2),UI 网格坐标↔键 id 必须经映射表转换
8. 图标包制作规格是 128×128,但线上键面分辨率由型号决定(293S:100×100/80×80),由**管理器下采样**,别把 128 图直接发设备
9. **CLE 0xff 全清会被固件静默忽略**(IOKit 写成功≠生效):视觉清屏用黑图管线,勿依赖 CLE
10. **熄屏勿暂停心跳**:无主待机态输入上报可能死透,「按键唤醒」依赖它必然偶发失效;心跳常驻 + 键面黑图才是正解(§6.5)

---

## 5. 待办实验(M1 动工前完成,合计约半天)

| 实验 | 方法 | 决定什么 |
|---|---|---|
| 按键上报物理验证 | 跑 `./probe` 按面板键,看 `⌨️` 输出 | M1 验收前提 |
| 背景图/动画/LED 能力 | 探针加三条命令试发,肉眼验证 | 视觉层上限(锦上添花) |
| 休眠-唤醒行为记录 | 等设备自动休眠,记录唤醒条件 | 状态机细节 |

---

## 6. M2 落地记录(2026-10-13,全部本机实测)

### 6.1 架构落地
- 新 SPM 库 **`PluginHost`**(零依赖):`SDProtocol`(v2 协议编解码/纯函数)、`SDManifest`(宽容解析+图片扩展名探测)、`PluginServer`(WebSocket 服务端)、`PluginProcess`(node 拉起与收割)、`PluginRegistry`(拷贝制安装/官方导入/废纸篓卸载)、`PluginSettingsStore`、`PluginImageDecoder`
- 应用侧 **`PluginHostModel`**(@MainActor 协调器):context 实例表、按需拉起(崩溃有界重启 ×3)、消息路由(按消息自带 context)、settings 内存缓存(OBS 每秒 setGlobalSettings,无变化不落盘)、IconRenderer 合成上屏(180° 预旋转 + JPEG≤10KB 复用 Kit 管线)
- **插件根(拷贝制)**:`~/Library/Application Support/OpenDeck/plugins/`;settings 在 `pluginSettings/<pluginUUID>.json`;管理器入口:编辑器 ⋯ 菜单
- `KeyAction` 增 `case plugin(pluginID:actionUUID:contextID:)`,contextID 分配时生成并持久化(同键保存复用)
- 冒烟工具:Harness `--plugin-test`、`Scripts/opendeck.fake.sdPlugin`(零依赖手写 RFC6455 客户端)、`Scripts/fake-obs.py`(8765 假 OBS,协议见 6.3)

### 6.2 协议事实(实测铁证)
- 官方拉起命令行(pgrep 实抓):`node20 <插件>/plugin/index.js -port P -pluginUUID U -registerEvent registerPlugin -info <纯JSON argv单元素,无URL编码>`;info 内 `application.language=zh_CN`、`devices[].type=0`、colors 五键;官方把**设备序列号**当 pluginUUID 传(插件只回显,宿主可用 manifest UUID)
- **注册包必须先于路由守卫处理**:`{uuid,event:"registerPlugin"}` 是建立连接归属表的消息,放进通用守卫会鸡生蛋死锁(已踩)
- 插件收到首条宿主消息即发 `getGlobalSettings`,**宿主必答 `didReceiveGlobalSettings`**(OBS 插件硬需求)
- OBS 插件 18 个动作全 `"Controllers": []`(**空数组=不限制**,误滤会全军覆没);重度多状态 + 全系 `DisableAutomaticStates: true`;`setImage` 空串 = 恢复 manifest 默认图;不依赖 PI 不崩
- 事件推送格式(helper→插件):`{jsonrpc:"2.0",method:"event",params:{event_type,data}}`;OBS 插件订阅**空列表**但靠 `_emit(event_type)` 分发,监听 `streaming.started/stopped` 等字面量
- 多状态自动轮换仅在 `!DisableAutomaticStates` 时由宿主代劳(keyUp 后)

### 6.3 OBS 生态事实
- OBS 插件对 OBS 的桥接:自带 helper `StreamDockOBSPlugin.plugin` 部署到 `obs-studio/plugins/`,开 **ws://localhost:8765** JSON-RPC 2.0(**不是**官方 obs-websocket 4455),方法名带命名空间(`streaming.start/stop/active`、`events.subscribe`…,完整清单可从 bundle `this.call("…")` 抠出);地址硬编码,不读配置
- **helper 是 x86_64-only 且要求更新版 OBS 符号**(`_obs_sceneitem_get_info2`),在 Apple Silicon 原生 OBS 上 dlopen 失败 → **真 OBS 在线联调在本机不可用(MiraBox 生态缺陷,非宿主问题)**;验收用 `Scripts/fake-obs.py` 伪造 8765 完成
- OBS 插件对 `streaming.active` 的应答按**裸布尔值**消费;「直播」动作两态图(亮图标/暗图标渐变)肉眼差异极小,验收时勿误判为"没反应"

### 6.4 基建教训(执行 agent 必读)
- **NWListener 在无 Info.plist 裸进程中一律 EINVAL**(macOS 15+ 本地网络隐私;所有参数组合含纯 TCP 实测全灭,沙箱外同样)。PluginServer 最终为 **BSD socket 手写 RFC6455**(CryptoKit SHA1 握手、掩码帧解析、分片累积),仅回环+临时端口,零权限面
- **阻塞式监听 fd 上二次 accept 会卡死串行队列**(症状:TCP 连上但握手无响应)——监听 fd 必须 O_NONBLOCK + 水平触发源一次一个
- **构建失败会被静默吞掉**:`swift build` 后必须显式确认成功再验证,否则"修复后重启"跑的还是旧二进制(本轮因此多查一小时)
- `swift run` 直跑时 stdout 是块缓冲,日志要 `setvbuf(stdout, nil, _IOLBF, 0)`(OpenDeckApp.init 已加);协议收发有 DEBUG 级 📥/📤 镜像
- swift-testing 的 `#require` 在 async 上下文要用 `try #require`,锁用 `OSAllocatedUnfairLock`

### 6.5 熄屏机制(重设计 2026-10-14,日志实证;初版探针方案已废弃)
- **新机制 = 心跳常驻 + 键面黑图 + 背光归零**:`screenOff()` 全 15 键下发纯黑 JPEG(不触碰键面缓存)+ LIG 0;`wakeFromScreenOff()` 恢复亮度 + `redrawAll()`。设备保持认领、输入随时可达,熄屏/唤醒均即时,固件永不自重启
- **旧机制「清屏 + 暂停心跳→固件自重启待机」废弃**,2026-10-14 日志实证三缺陷:①CLE 0xff 全清被固件**静默忽略**(IOKit 写成功、面板不动)——旧方案的视觉熄屏全靠自重启黑屏;②无主待机态输入上报**可能死透**(同场景第一轮存活、第二轮 4.5 分钟零事件),「按键唤醒」依赖待机输入必然偶发失效;③自重启无 USB 重枚举信号,app 全盲 → 固件出厂开机画面(蓝块彩角)永久滞留。三症状合流为「唤醒→按键→又熄屏」死循环
- API:`DeviceController.screenOff()/wakeFromScreenOff()/isScreenOff/keysBlacked/setKeysBlacked(_:)`;`drawKey` 在 isScreenOff/keysBlacked 时只更新缓存不写设备(防插件 setImage/编辑操作盖掉黑屏);熄屏中拔插视同唤醒;`HIDTransport` 心跳暂停/恢复 API 已删除
- 「立即熄屏」菜单项与自动熄屏看门狗共用上述实现;黑图管线有单测(IconRendererTests.blackJPEG)

### 6.6 M2.5 多页面 + 设备控制 + 场景联动(2026-10-14 落地,全部实测)
- **多页面**:`Page.id`(normalize 补齐,旧配置无感)+ 页面 CRUD + 芯片栏(每页一枚平铺芯片:点按切换、当前页高亮、右键重命名/删除/场景联动/复制、`+` 追加,位于网格下方居中)
- **触控板两级手势**(最终机制):垂直扫=场景内翻页,水平扫=切场景;机制为 **NSEvent 本地监听 + 事件相位步进**——触控板精确手势以「手指接触周期」(phase began→changed→ended)为单位,周期内至多步进 1,手指离开后的惯性滚动(momentumPhase)全部吞掉(不论速度多快恰好步进 1);传统滚轮退回 0.35s 冷却。编辑器外层 ScrollView 已移除(内容固定),网格内滚动一律吞掉。历程:NSEvent(可用但快扫连翻)→ CGEventTap 系统拦截(全系统滚动被主线程 tap 拖慢,且与 SwiftUI.Scene 撞名,已回退)→ 相位步进定案。历史教训:新模型字段有默认值时,旧配置靠「解码失败」触发迁移不可靠,须按键名探测
- **设备控制动作 7 个**(KeyAction 新 case,AppModel.handleDeviceAction 本地消化,不经 ActionRunner):previousPage/nextPage(循环)、gotoPage(Page.id 稳定引用)、pageIndicator(键面动态 N/M)、brightnessUp/Down(±10,退出跟随并落盘)、screenOff;熄屏待机时任意按下沿唤醒且不触发动作,亮度跟随轮询待机期暂停
- **场景联动**(官方「场景」设置移植):`Page.boundAppBundleIDs`(最多绑 3 应用)+ `AppConfig.defaultPageID`;前台应用激活 → 绑定页优先,无绑定回默认页;**生效条件与官方一致 = 编辑器窗口关闭**(`editorWindowVisible` 标志)+ 非熄屏;应用清单扫 /Applications 与 /System/Applications;已用 osascript 激活 Safari/Finder 断言 config 索引完成自动化自验
- **自动熄屏**:`AppConfig.autoScreenOffMinutes`(0/缺省=关),AppModel 空闲看门狗 15s 周期检查(最近按键时间含唤醒按压);入口 = 编辑器 ⋯ 菜单
- 页面切换经 applyPage→syncKey 链自动同步插件实例显隐,零额外代码

### 6.7 导航矩阵 UI + 键帽定尺 + 亮度跟随(2026-10-14,M2.5 验收期迭代)
- **导航三样式**(`NavigationStyle`,⋯菜单切换,即时落盘):经典(芯片栏+页点胶囊)/ A 矩阵·下置(芯片=列头,页点纵列)/ B 矩阵·右缘(转置:场景=行,页点横排,底座旁挂深色轨)。矩阵任一格点按 = 跨场景直达(复用 switchPage 语义);单场景自然退化
- **键帽定尺 100pt(与设备键面 1:1,用户确认)**:LazyVGrid 弹性列在全屏/大窗把键帽摊大饼;修法 = `GridItem(.fixed(100))` + chassis `.fixedSize(horizontal: true)`(LazyVGrid 容器默认撑满提案,固定轨道只会被居中——底座会比键列宽一大截)+ 画布顶部居中留白
- **亮度跟随修复(此前从未真正工作)**:本机(macOS 26/AS)**不存在** IODisplayConnect/AppleBacklight 服务,`CoreDisplay_Display_GetUserBrightness` 恒返 1.0 假值;有效读法 = **DisplayServicesGetBrightness**(私有框架,kr=0,仅内屏;外接屏 kr=1000 本就不镜像)。1.5s 轮询 + ≥1% 变化检测;**内屏 0% → 键面涂黑 + 背光归零**(LIG 0 只是背光最暗,非黑屏);0% 涂黑态按任意键 → 点亮至最近有效亮度(暂态解耦,动作照常),15s 无操作重涂黑,内屏变化即重新关联;「滑杆 0% 涂黑」为 ⋯菜单选项(默认关)
- **诊断基建**:`appendLog` 镜像 oslog(subsystem `opendeck`,查询须 `--level info`)+ 心跳 tick + 按键事件日志——硬件行为问题先开日志复现再断言,勿凭代码推演定案
- **亮度跟随 × 自动熄屏互斥(2026-10-15 验收反馈)**:两者同开会叠出「内屏 0% 涂黑后看门狗再叠熄屏,晨起调亮被熄屏守卫挡住、永不恢复」的卡死(日志实证)。语义:开启跟随自动归零自动熄屏;开启自动熄屏自动关跟随;启动时归一化遗留同开配置。手动「立即熄屏」不受影响,仍为仅按键唤醒(显式指令显式唤醒)。夜间变暗需求由跟随的 0% 涂黑承担
- **场景联动补强(验收实测)**:关窗即评估(三连采样 +0.3s/+1s/+2s 覆盖「关窗瞬间 frontmost 仍是自己」的结算竞态,评估幂等);联动决策与前台探针日志(前台探针走 oslog debug 防刷屏)。**竖扫方向教训:AppKit 的 scrollingDeltaY 与 deltaX 符号约定相反**(自然滚动下左扫 deltaX 为正、上扫 deltaY 为负),勿按直觉假设,以真机实证为准

### 6.8 已知限制(→ M3 后续)
- SVG 数据 URL 不支持(回退默认图);多行标题折叠单行;HTML 家族(13 个 WebView 插件)不宿主;插件更新需手动重装
- M3 优先级建议:PI(WKWebView,✅ 已落地见 §6.9)> 多页面(✅ M2.5)> HTML 家族 > 自研插件实战(如 ZCode 状态灯:hook 写状态文件/打本地端口 → 插件推色)

### 6.9 M3-1 Property Inspector(2026-10-15 落地)
- **协议契约(实测钉死,来源 = OBS 插件 `propertyInspector/utils/action.js`,勿凭文档想象)**:
  宿主向 PI 页面注入调用 `connectElgatoStreamDeckSocket(port, contextID, "registerPropertyInspector", app, info)`——第 2 参是 **action 实例 contextID**(PI 的 setSettings/getSettings/sendToPlugin 的 context 都填它),`info` 含 `{action, context, payload.settings}`,`app` 为 registrationInfo 全量 JSON(PI 取 `.application.language` XHR 插件根的 `<lang>.json`);PI 注册包 `{event, uuid}` **无 action 字段**,宿主按 contextID 反查归属(instances 表,草稿态用 pendingPI 预登记兜底);**时序硬约束:PI 等首条下行消息才发 getGlobalSettings、等 didReceiveSettings 才显示主界面 → 注册后宿主必须主动推 didReceiveSettings,否则页面永久空白**;PI 侧 get/setGlobalSettings 的 context 字段填 contextID(≠插件侧的 pluginUUID);PI 可直接发 setTitle/setState/setImage 操纵键面;sendToPlugin/sendToPropertyInspector 双向原帧透传
- **实现布局**:`SDProtocol` 增 3 解析 + 2 编码;`SDManifest` 补顶层 `PropertyInspector` 兜底字段 + `piPagePath`(action 级优先);`PluginHostModel` 增 `piByConnection` 归属表 + **PI 专属 switch(应答按请求连接寻址,与插件路径的 runtime 寻址不同)** + `prepareForPI/registerPendingPI/piSettings/piPageURL/piRegistrationInfoJSON/piActionInfoJSON/removeContextRecord` 公共 API + init 根目录注入接缝(单测隔离);UI 侧 `PropertyInspectorView.swift`(WKWebView,文件域限定插件根,documentEnd 用户脚本轮询注入引导,10s 上限)挂 `KeyEditView`「动作参数」Section(`.id(action/context)` 换动作即重建);连接随 webview 释放断开 → 宿主发 propertyInspectorDidDisappear
- **草稿实例身份**:KeyEditView 原以计算属性现算 contextID(每次求值新 UUID),PI 需稳定 id → `@State draftContextID`(原动作复用持久化 context,换动作 onChange 一次生成);取消编辑时清理草稿 context 的孤儿 settings 记录(`removeContextRecord`)
- **settings 流语义**:PI setSettings → 落盘 + 插件实时收 didReceiveSettings + 在开 PI 回显;插件 setSettings → 落盘 + 在开 PI 同步(UI 不脱节)
- **已知边界(记录不处理)**:PI 页面 `<input type="file">` 无面板可弹(WKUIDelegate 可选方法与 MainActor 默认隔离相抵,已知在装插件未用文件输入);同 context 多 PI 并存的相互同步靠回显兜底
- **验证**:PIFlowTests 集成测试(假插件+假 PI 双真 socket 连接)8 断言全过;43 单测零警告;fake 插件(Scripts/opendeck.fake.sdPlugin)带 PI 回显页(输入 titleText → setSettings → 插件收 didReceiveSettings 刷键面标题,设备上肉眼可验全链路);OBS 插件 18 动作全带 PI 页为真实验收靶

### 6.10 settings 持久化重构 B:内存即真相(2026-10-15,排障驱动的架构定案)
- **事故**:16:20 经 PI 写入的参数在 17:41:11 被抹(用户同期按物理键)。插桩定位:写盘记录形态 = 「缺 3A4D 记录的整文档 + setState 新建默认格」——即某次写持有了旧缓存副本;且 cancelEdit 的孤儿清理 `removeContextRecord` 被插桩二次实锤会误删**活**记录(18:27:11.867,触发状态不可完整重构)
- **根因 = 「文件即真相 + 内存缓存副本」双真相架构**:缓存副本参与定夺磁盘内容,旧副本覆盖新数据的失败类无法靠守卫根除
- **行业对照(实测+查证)**:Elgato(Stream Deck)参数内嵌 profile JSON 每动作实例、单一宿主进程独占写入、内存即真相;MiraBox 官方(本机 `~/Library/Application Support/HotSpot/StreamDock/profiles/<序列号>.sdProfile/manifest.json`)参数按 `行,列` 内嵌 + **A/B 双副本轮换备份**;Companion 同族(内存真相 + SQLite)。无一例外「唯一写入者 + 内存即真相」
- **新架构(B,用户拍板)**:`PluginHostModel.settingsDocs` = 唯一权威副本(每插件一份文档,懒加载一次、进程内永不重载、卸载时摘除);一切变更经 `mutateSettingsDoc`(原地改 + diff 守卫吸收 OBS 式高频写 + 立即原子落盘,零丢失窗口)+ caller 插桩日志;`PluginSettingsStore` 降级为哑持久化汇(`load`/`persist`/`removeDocument`,不持内存、不做合并);shutdown 增落盘兜底(防御性);**cancelEdit 孤儿清理永久移除**(孤儿记录无害,误删活记录不可接受)
- **验证**:47 测全绿零警告(新增 PluginSettingsStoreTests 4 测 + PIFlowTests 17:41 回归闸门:PI setSettings → setState → settings 必须原样存活;注意 **setSettings 是整对象替换语义**,非逐字段合并——与 OBS action.js 一致);真机复验:重启恢复回显 ✓、PI 改参写穿落盘 ✓、翻页实例生灭 ✓
- **已知边界(记录)**:①Sheet 开着会阻止 osascript 优雅退出(-128,标准模态行为);②插件实例随当前页生灭,插件页非当前时 PI 注册被「未知 context」拒(设计语义,勿误判服务端坏);③未来做 profile 导入/导出时,参数应随动作实例内嵌(Elgato 形态),届时数据模型已就位

### 6.11 M3-2 HTML 家族插件宿主(2026-10-15,隐藏 WKWebView 运行时)
- **协议契约(官方 12 个 HTML 插件源码解剖定案,存放于官方 app `~/Library/Application Support/HotSpot/StreamDock/plugins/`)**:宿主调 `connectElgatoStreamDeckSocket('<port>','<pluginUUID>','registerPlugin','<infoJSON>')`——**插件模式 4 参**(PI 5 参,同函数不同形;参数全部单引号字符串);注册包 `{event,uuid:<pluginUUID>}`;**一个 WebView 服务该插件全部 context**(官方插件全按多 context 编写,tactics/weather/memo 均有 context 注册表);资源域 = 插件根全目录(根级 `<lang>.json`、Worker、字体、音视频);无 Node 依赖浏览器可直接跑;入站事件带 `action`+`device` 字段(我们的 instanceEvent 本就携带,零改动);压缩版插件自建 `window.argv=[port,uuid,event,info,actionInfo|null]`,宿主无需实现
- **架构**:`PluginWebviewRuntime`(@MainActor,NSObject+WKNavigationDelegate)= Runtime 强持有的**无宿主 WKWebView**(不入视图层级即可加载/执行 JS/跑 WS;nonPersistent dataStore 插件间隔离);documentEnd 用户脚本轮询注入 4 参引导(10s 上限);`webViewWebContentProcessDidTerminate` → onGone → 既有 respawn ×3 路径(主动 close 不触发,镜像 PluginProcess 语义);`Runtime.webview` 与 `process` 互斥,`isAlive = process != nil || webview != nil`;spawn 顶部按 family 分支,下游注册/路由/willAppear 重放/断开**零改动**(webview 就是普通 WS 客户端)
- **过滤放宽**:SDManifest 加 `isHostable`(node|html);PluginManagerSheet 徽章收窄 `.unsupported`(「不支持」)、卸载门槛 isHostable;PluginRegistry 官方导入放宽 isHostable(12 个官方 HTML 插件可导入);EditorView 动作选择器 isHostable(最后翻,spawn 分支就位后)
- **v1 边界(记录)**:MiraBox 扩展事件(setBackground/stopBackground/setAcImgTop/exitFullScreen/triggerKey/getUserInfo/registrationScreenSaverEvent)忽略+日志;window.open 弹窗不支(memo 便签);localStorage 不跨重启(nonPersistent);App Nap 节流观察项;个别插件自带 bug(tactics 的 `window.argv[5]` 恒 undefined,memo willAppear 清 localStorage)不属宿主责任
- **验证**:48 测全绿零警告(新增 webview 集成测试:沙盒真 HTML → 真 WKWebView 加载 → 引导注入 → 注册 → willAppear → setImage → draw 钩子全链 0.5s);**真机收官**:拷贝安装官方 time 插件 → 分配键位 → webview 注册 ✓ → willAppear/setSettings 流 ✓ → settings 落盘 ✓,设备键面出时钟待用户目视
- **已知边界**:同页双模式插件(CodePath==PropertyInspectorPath)的 PI 复用同一 HTML,第 5 参区分——PI 路径本就支持,未额外处理;HTML 插件页加载失败(didFailProvisionalNavigation)按 onGone 进 respawn×3 后放弃

### 6.12 M3-3 自研 ZCode 状态灯插件(2026-10-16,HTML 家族实战首跑)
- **形态**:自研 HTML 家族插件 `com.zcode.status.sdPlugin`(源码 `Scripts/com.zcode.status.sdPlugin/`,拷贝安装),键面实时反映 ZCode 工作状态
- **状态机**(4 色+空闲):working 蓝▶(UserPromptSubmit/PostToolUse)、permission 黄?(PermissionRequest)、error 红!(PostToolUseFailure)、done 绿✓(Stop/SessionStart)、idle 灰●(插件端判:state.json 缺失或 updatedAt 超 30 分钟)
- **管线**:ZCode hook(6 事件)→ `hook.py` 读 stdin `hook_event_name` → 原子写插件根 `state.json`(tmp+rename;亚 100ms、exit 0、无输出,绝不反噬 ZCode 主流程)→ 插件 webview 每 1s `fetch('state.json?t=<ms>')` 轮询(cache-busting)→ 状态变化才 canvas 重绘 + setImage(防 HID 刷屏);willAppear 新键上屏、deviceDidConnect 全量重画
- **hooks 配置**(用户级 `~/.zcode/cli/config.json` 顶层 hooks,备份 `config.json.pre-zcode-light.bak`):6 事件 × `python3 <插件根>/hook.py`,timeoutMs 2000,enabled true。**hooks 在会话启动时加载——写入后需新 ZCode 会话才生效**(运行中的会话不受影响);hook.py 常驻插件根 = webview fetch 读取域内(file:// 读取域即插件根)
- **验证**:webview 注册 ✓;hook 单测 working→permission 写入 ✓;插件 1s 轮询刷键 ✓(键面黄色 ?);写盘日志 `写盘[setSettings·PI]` 同款插桩可观测。ZCode 事件全环形验证待日常使用中自然覆盖(新会话即生效)
- **v1 边界**:hooks 用户级全局,多会话并发后写覆盖;无「等待用户输入」专用事件(Stop≈,注意 Stop 可能触发 ≤3 次自动续跑造成短暂回蓝);安装脚本与 hooks 配置属用户目录变更不入库(源码已入库)
