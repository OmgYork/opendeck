# StreamDock 原生重写 — 交接设计文档

> 供总设计师(做架构决策)与执行 agent(写代码)共用的一页式上下文包。
> 所有事实均已本机实测或溯源到可查实现,**不要重新调查,直接在此之上设计**。
> **文档分工**:本文件 = 开发史与设计决策(根因/协议/里程碑);给其他 agent 的操作手册见 [AGENT-GUIDE.md](AGENT-GUIDE.md);状态灯接入见 [Scripts/状态灯接入指南.md](Scripts/状态灯接入指南.md);显示器动效设计见 [Design/MonitorInputIcon/README.md](Design/MonitorInputIcon/README.md)。
> 最后更新:2026-10-22(显示器输入源动效键落地;键面 112×112 事实回填至 §1/§4;58 测全绿)
> **M3 队列已全部消费**:Property Inspector(✅ §6.9/§6.10)> 多页面(✅ §6.6)> HTML 家族(✅ §6.11)> 自研 ZCode 状态灯(✅ §6.12/§6.13)> 多状态图标(✅ §6.15)> 登录自启与睡眠唤醒(✅ §6.16)> 状态灯置前(✅ §6.17)> Stats(✅ §6.18)> icon 偏移与 112 定案(✅ §6.19/§6.20)> 鲸鱼娘动画(✅ §6.21)> 显示器输入源动效(✅ §6.22)。**剩余挂账:官方 HTML 插件逐个视觉适配(time 等插件自身视图不渲染)。**

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
  5×3 = **15 键全主键(112×112,官方 app 抓包定案,见 §6.20),没有软键列**
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
    JPEG 规格:全键 **112×112**(本机 293V3;以官方 app 实际下发为准,见 §6.20),RGB,**单张 ≤10240 字节**(超了就降质量重压;降级后必须还原画布尺寸,见 §6.19)
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
8. 图标包制作规格是 128×128,但线上键面分辨率由型号决定(本机 293V3:**112×112**),由**管理器下采样**,别把 128 图直接发设备;小于键面的图会被固件右下锚定(§6.20)
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
- **键帽定尺 100pt(UI 设计尺寸,用户确认;设备画布 112,见 §6.20)**:LazyVGrid 弹性列在全屏/大窗把键帽摊大饼;修法 = `GridItem(.fixed(100))` + chassis `.fixedSize(horizontal: true)`(LazyVGrid 容器默认撑满提案,固定轨道只会被居中——底座会比键列宽一大截)+ 画布顶部居中留白
- **亮度跟随修复(此前从未真正工作)**:本机(macOS 26/AS)**不存在** IODisplayConnect/AppleBacklight 服务,`CoreDisplay_Display_GetUserBrightness` 恒返 1.0 假值;有效读法 = **DisplayServicesGetBrightness**(私有框架,kr=0,仅内屏;外接屏 kr=1000 本就不镜像)。1.5s 轮询 + ≥1% 变化检测;**内屏 0% → 键面涂黑 + 背光归零**(LIG 0 只是背光最暗,非黑屏);0% 涂黑态按任意键 → 点亮至最近有效亮度(暂态解耦,动作照常),15s 无操作重涂黑,内屏变化即重新关联;「滑杆 0% 涂黑」为 ⋯菜单选项(默认关)
- **诊断基建**:`appendLog` 镜像 oslog(subsystem `opendeck`,查询须 `--level info`)+ 心跳 tick + 按键事件日志——硬件行为问题先开日志复现再断言,勿凭代码推演定案
- **亮度跟随 × 自动熄屏互斥(2026-10-15 验收反馈)**:两者同开会叠出「内屏 0% 涂黑后看门狗再叠熄屏,晨起调亮被熄屏守卫挡住、永不恢复」的卡死(日志实证)。语义:开启跟随自动归零自动熄屏;开启自动熄屏自动关跟随;启动时归一化遗留同开配置。手动「立即熄屏」不受影响,仍为仅按键唤醒(显式指令显式唤醒)。夜间变暗需求由跟随的 0% 涂黑承担
- **场景联动补强(验收实测)**:关窗即评估(三连采样 +0.3s/+1s/+2s 覆盖「关窗瞬间 frontmost 仍是自己」的结算竞态,评估幂等);联动决策与前台探针日志(前台探针走 oslog debug 防刷屏)。**竖扫方向教训:AppKit 的 scrollingDeltaY 与 deltaX 符号约定相反**(自然滚动下左扫 deltaX 为正、上扫 deltaY 为负),勿按直觉假设,以真机实证为准

### 6.8 已知限制(→ M3 后续)
- ~~SVG 数据 URL 不支持(回退默认图)~~(✅ 2026-10-16 已支持,见 §6.14);多行标题折叠单行;HTML 家族(13 个 WebView 插件)~~不宿主~~(✅ 已宿主,见 §6.11);插件更新需手动重装
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

### 6.13 M3-3 收尾:状态灯真机闭环(file:// fetch 根因修复 + 宿主文件读取桥)(2026-10-16)
- **现象**:hooks 链路活(state.json 每事件实时刷新)、插件 webview 注册 ✓、willAppear 后首帧 setImage 已达服务端(帧日志 op=1 len=3265)——但键面永远停在 willAppear 推的那帧 idle 灰●(用户观感「白色」=灰块白●,非固件默认图;配置瓷贴是橙 #D08770,不在场)。早前「键面黄色 ? 验证 ✓」系连接时序误判:单帧推送无法区分「轮询活」与「一次性侥幸」
- **根因(插件页 logMessage 遥测实锤)**:**WKWebView 禁止 file:// 页面用 fetch()/XHR 读 file:// 资源**——`TypeError: Load failed` 即刻拒绝;`loadFileURL(allowingReadAccessTo:)` 的读取域只放行 img/script 子资源标签加载,不含 fetch API。§6.12 设计假设「hook.py 常驻插件根 = fetch 读取域内」不成立。轮询循环本身每 1s 正常跳动(setTimeout 未被节流),但 100% 失败 → stateData 恒 null → 永不重绘
- **修复(宿主通用文件读取桥)**:`PluginWebviewRuntime` 增 `window.opendeckReadFile(相对路径)` polyfill(atDocumentStart 注入,Promise+5s 超时兜底)+ `WKScriptMessageHandler "opendeckFile"`(经 WeakScriptMessageHandler 弱代理注册防 Runtime↔webview 保留环,注册须在 super.init() 后)+ 沙盒校验(拒绝绝对路径、standardized 后必须落在插件根内)→ 读盘 base64 → `evaluateJavaScript("__opendeckFileResolve(seq, ok, b64, err)")` 回填。**通用能力:任何 HTML 插件运行时读插件根文件皆可用**。另 `AppModel.start()` 增 `beginActivity(.userInitiated)` 断言:菜单栏 app 长期无窗口会被整进程 App Nap 挂起连累插件页定时器(进程常驻即业务,与 Elgato 同类做法)
- **插件侧**:`com.zcode.status` 弃 fetch 改 `opendeckReadFile('state.json')` → atob → 既有解析/变化检测/推送管线零改动;读失败 logMessage 限频日志(30s 一条,state.json 首事件前不存在属正常)
- **验证**:60 测全绿(含 webview 集成测试);dist 重编译部署;真机:遥测 chain-ok 每秒 state=working ageMs 递增 ✓,**用户目视键面 idle 灰● → 绿✓ 活切换**(M3-3 全链路首次闭环);绿✓→黄?→红!→绿✓ 序列实验已排队(遥测通道佐证)
- **同族受害者(新已知边界)**:官方 **time 插件**(Vite 打包)启动即 fetch i18n JSON + modulepreload polyfill 走 fetch,file:// 域全拒 → 注册后静默零输出,表盘从未上屏(§6.11「待目视」实为从未画出)。后续候选:官方 HTML 插件逐个甄别、必要时在桥上做透明 fetch/XHR polyfill(拦截 window.fetch 到 file 相对路径转桥),归入 M3「逐插件适配」
- **诊断方法论沉淀**:release 构建的 print/📤 插桩不落 oslog;serverLog.info 级 oslog 需 `log stream --level info`(`log show` 不含 info 历史区);宿主 logMessage 通道(`📜 插件日志:`)是免重编译的插件页观测面,排障首选
- **补遗(同日第二层根因,用户目视「工作态仍绿✓」触发)**:桥修好后键面仅活了 ~2 分钟——遥测实测页面自链 setTimeout 节拍 +0~89s 每 30s 窗 28-29 跳(1s 正常)、+90s 起衰减、**+108s 归零永不恢复**(隐藏页面 WebKit 定时器治理;节流加深/单环异常断链,链式结构一断即永久死亡;且链内任一回调抛异常也会静默断链)。**定案:轮询节拍所有权归宿主,页面自持定时器一律不可靠**。重构:`PluginWebviewRuntime` 增宿主推拍——documentEnd 用户脚本检测页面定义了 `__opendeckPulse` 即经 opendeckFile 通道回报,宿主起 Foundation 1s Timer(`evaluateJavaScript("window.__opendeckPulse&&__opendeckPulse()")`,不经 DOM 定时器队列、不受隐藏页节流,单拍异常下拍自愈;close() 注销);官方插件未定义回调零成本。插件页:tick 改纯函数由推拍驱动(去自链)、`sendImage` 加 readyState 守卫、新增 **60s 一条的 alive 存活日志**(本次排查缺它多绕一小时,长期观测面)。复验:推拍存活 8 分钟+、test 消息 UserPromptSubmit→working 1s 内检出推送、alive 序列 working→done→working 与回合边界完全吻合
- **状态机扩展:asking 黄?闪烁(2026-10-16,用户需求「向我提问时可见」)**:新状态 `asking`(亮黄↔暗黄 #5c4712 交替)。触发链:hooks 配置新增 **PreToolUse** 事件(条目形状照抄 UserPromptSubmit;备份 config.json.pre-asking.bak)→ `hook.py` 特判 `PreToolUse + tool_name=="AskUserQuestion"` → asking(其余工具调用不写,working 仍归 PostToolUse);用户作答即 PostToolUse → working 自动恢复。**闪烁的快节拍走自适应推拍契约**:页面 `__opendeckPulse()` 返回期望的下一拍间隔 ms(asking 350 / 其余 1000,宿主钳制 200…5000),`PluginWebviewRuntime` 单发 Timer 链按返回值重排——快节拍依然宿主驱动,不受页面定时器冻结影响;节拍自适应有一拍滞后,视觉无感。已知边界:纯文本问句无 hook 事件可挂,不触发 asking(记录不处理);hooks 会话启动时加载,新配置需新 ZCode 会话生效。验证:hook.py 单测(假 PreToolUse stdin → state=asking)✓、直写 state.json 用户目视黄?闪烁 ✓、回复后回蓝 ✓

### 6.14 M3 挂账清理:官方 HTML 插件排障(2026-10-16,time 插件死因定案 + SVG 解码 + 观测面升级)
- **缘起**:M3-3 挂账「官方 time 插件时钟从未上屏」。排障中发现 release 构建缺一切插件页观测手段,先升级观测面(全部永久保留):**透明 fetch polyfill**(file: 请求转 opendeckReadFile 桥 → 字节体 Response,其余协议透传原生;XMLHint:官方 bundle 静态扫描仅 1 处 fetch=modulepreload polyfill,但 polyfill 消灭整类 file:// fetch 失败)、**未捕获 error/unhandledrejection/console.error|warn 上报**(经 opendeckFile 通道 diag 分支 → 📜 日志;console 限前 20 条)、**5s 页面健康探针**(readyState/dom 体量/argv/fonts/worker 存活/#app innerHTML;Blob Worker 在 file:// 下可用,实测 worker-ok)、**注册重放计数日志**(`重放 willAppear×N[key…]`)。诊断方法论:evaluateJavaScript 旧 API 不解包 Promise(返回 Promise 对象 → "unsupported type"),异步结果须自落全局变量二次读取
- **time 死因定案(非宿主,不再追)**:Vue 应用挂载正常(argv 就位/Pinia store 收到 willAppear 完整报文/插件自行重写了 settings 默认值),**但视图层永远渲染 7 字节空注释 `<!---->`**,全程零异常、零 console 错误——消息链全通而视图不渲染,系 481KB 压缩 bundle 内部视图逻辑问题(其自带默认值 `"title":"UTCundefined"` 佐证带病);字体加载/Worker/UUID 匹配/报文形状(payload.settings 等)逐一实证排除。官方插件兼容性甄别归 M3「逐插件适配」
- **对照实验牵出真 bug**:装 centeredclock 于槽4 对照,其**活着且每秒推 SVG 表盘**,但 `setImage 解码失败(SVG 或坏数据)` 全拒——即 §6.8 已知限制命中。**PluginImageDecoder 补 SVG 支路**:percent-encoded(charset=utf8,`%3Csvg…` 实测形态)与 base64 双载体 → NSImage(CoreSVG)栅格化到按键面尺寸;无尺寸病态输入由 NSImage 容忍(透明图叠瓷贴无害,不另设契约);契约测试同步翻新(双载体尺寸断言)。**顺手销掉 §6.8 两条已知限制:SVG 数据 URL ✅ 已支持、HTML 家族 ✅ 已宿主**
- **处置(用户拍板「两个都清除」)**:time 与 centeredclock 插件目录及孤儿 settings 移废纸篓;槽3/4 摘除绑定、编号瓷贴保留;仅存 zcode.status。注意 shutdown 落盘兜底会把内存 settingsDocs 写回盘——**摘 settings 文件必须先退 app 再动盘**

### 6.15 M3-4 多状态图标(2026-10-16,协议闭环 + 测试加固 + 编辑器可视化;UI 镜像首版翻车回滚)
- **现状盘点**:多状态协议脚手架 M2 起即大体完备(SDManifest 解析 States/stateCount/DisableAutomaticStates;Instance 按 state 选图 stateImages[state]??allStateImage??manifestDefaultImage[state];keyUp 自动轮换含 OBS 豁免;setState 三入口统一落盘+重渲;state 跨重启持久化并随 willAppear 回放)——缺的是测试、可见性与真机验收
- **夹具语义厘清**:fake.toggle 加 `DisableAutomaticStates`(插件自管:插件不会在 keyDown 翻转+宿主 keyUp 再轮换=净变化为零的旧 quirks);新增 `opendeck.fake.autotoggle`(两态红绿,宿主 keyUp 自动轮换演示载体);index.js 按 `msg.action` 分流(toggle 自管图像/状态,autotoggle 全靠宿主)
- **宿主增量**:①实例创建即 `redrawInstanceIfPresent`——多状态动作上屏即显当前态 manifest 默认图(此前纯 manifest 插件首屏永远是瓷贴);②编辑器三访问器 `stateCount/currentState/cycleState`(cycleState 与 keyUp 轮换同出口)
- **测试**:MultiStateTests(真 socket,PIFlowTests 模式)5 用例——keyUp 轮换 0→1→回绕、DisableAutomaticStates 豁免(无状态写)、单态不轮换、按态选图(syncKey 上屏初始默认图+轮换产物差异)、持久化回放(重启后注册重放带上次态);66 测全绿
- **编辑器可视化**:KeyEditView 插件动作 stateCount>1 时显示「N 态 · 按键自动轮换 · 当前第 X 态」+「切换预览」按钮;注意 setState 原地改实例 @Observable 观测不可见,用本地 stateCycleCount 计数强制 body 重跑
- **真机验收**:autotoggle 绑槽4,按压红绿轮换 ✓,重启保持 ✓
- **UI 实时镜像(首版翻车,已回滚,挂账重做)**:需求真实存在(界面槽2 橙瓷贴 vs 硬件状态灯),但首版(每次推图 keyImages 全字典变更→网格全量重渲+iconPath 逐键磁盘 IO+180° rotationEffect 补偿)引发触控板滚动异常(回滚即愈,因果实锤)与渲染比例不符(硬件合成帧不满铺,镜像整面铺满)。**重做铁律**:①更新只落受影响单键(NSImage 缓存+懒更新,不碰网格渲染路径);②设备帧原样显示(仅 180° 转正,零额外变换);③交付前界面/硬件并排截图比对。另注意:摘插件后其余页的死绑定会让对应键空置(报「插件未安装,动作暂不生效」,属预期)

### 6.16 M3-5 系统项收尾(2026-10-16,登录自启验证 + Mac 睡眠唤醒恢复)
- **登录自启**:盘点发现早已实现(SMAppService.mainApp + 菜单栏面板「登录时启动」Toggle,AppModel.isLaunchAtLoginEnabled/setLaunchAtLogin;注释在案:裸二进制注册会失败,须 .app 形态)——本轮真机验证通过(开关无报错,M3 清单销账)
- **Mac 睡眠唤醒恢复(新补)**:缺口 = Mac 睡眠期间 app 挂起、心跳中断,设备 ~9s 自重启进待机;Mac 唤醒后若 USB **未重新枚举**,attach 校准路径不触发,设备停在待机直到重插。修复:`DeviceController.recalibrateAfterSystemWake()`(state==.running 守卫——设备真重枚举时让位给 attach 路径;复位 isScreenOff/keysBlacked → calibrate():握手先行→亮度→清屏→按缓存全量重画)+ AppModel 监听 `NSWorkspace.didWakeNotification` 调用
- **真机验证**:两轮真实睡眠循环均命中「系统唤醒:重新校准」,日志无 attach 重枚举(证实缺口真实存在,不补则只能重插);唤醒后亮度跟随恢复、按键事件正常、全日志零错误
- **M3 清单至此**:✅ PI ✅ 多页面 ✅ HTML 家族 ✅ 状态灯 ✅ 多状态图标 ✅ 登录自启 ✅ 屏幕休眠唤醒。**剩余挂账两项:UI 镜像重做(铁律见 §6.15)、逐插件适配(含官方 time 插件视图不渲染问题)**

### 6.17 状态灯按键置前宿主 app(2026-10-17,manifest 声明式通用机制)
- **需求**:按下 ZCode 状态灯键 → 电脑上 ZCode 窗口置前。方案定为**通用 manifest 扩展字段**而非宿主特判:action 声明 `ActivateAppBundleID` 即可获得「按键抬起激活该 app」,插件侧零改动;后续其他 agent 状态灯(接入指南 `Scripts/状态灯接入指南.md`)在各自 manifest 声明自家 bundle ID 即得同款行为
- **实现链**:SDManifest.Action 增 `activateAppBundleID: String?`(镜像键 `ActivateAppBundleID`,宽容解析缺省 nil,官方插件零影响)→ `PluginHostModel.Hooks.activateApp` 新钩子(默认 no-op,模型不 import AppKit,测试注入 spy)→ `handleKey` **抬起沿**触发(与 keyUp 自动轮换同沿,Elgato 惯例;keyDown 仍纯转发插件)→ AppModel 注线 `NSWorkspace.urlForApplication(withBundleIdentifier:)` + `openApplication(at:)`(等价 `open -a`:运行中=置前,未运行=启动;规避 `NSRunningApplication.activate` 的 macOS 14+ 弃用警告;目标未安装记 oslog 不弹窗,失败记 completion error)
- **权限**:走 LaunchServices 激活,**无需 Accessibility/辅助功能授权**(与模拟键鼠路径的本质区别)
- **manifest**:com.zcode.status 加 `"ActivateAppBundleID": "dev.zcode.app"`(bundle id 实测取自 /Applications/ZCode.app/Contents/Info.plist;仓库源码与部署目录已同步,重启 OpenDeck 生效)
- **测试**:69 全绿零警告(+3):SDManifest 解析(声明可解析/缺省 nil);真 socket 两用例(spy hook:抬起沿触发且参数正确、按下沿与未声明 action 不触发);KeyAction/ConfigStore 零改动,无配置兼容问题
- **边界**:ZCode 未运行时按键=启动并置前(预期行为);激活失败静默落日志;同一插件多键声明同 app 重复激活无副作用(LS 幂等)。待真机验收:按灯 ZCode 置前、未运行时启动置前、其他键零影响

### 6.18 Stats 集成:GPU/CPU/温度上屏(2026-10-18,槽位 6/7/8;含固定导航键+滚轮+镜像 v2 收尾)
- **需求**:Stats 软件同款指标上屏——GPU 利用率(槽6)、CPU 利用率(槽7)、传感器温度 hottest CPU(槽8)
- **数据源(全部本机实测打通,零外部依赖)**:①GPU = IOAccelerator 注册表 `PerformanceStatistics["Device Utilization %"]` 直读(多 GPU 取最大);②CPU = mach `host_statistics64` 差分;③温度 = **AppleSMC 现代接口**——经典 selector(5/8/9)在 macOS 26 全部 kIOReturnUnsupported,反汇编 Stats 的 Sensors.framework 定案:**仅 selector 2 存在(分发器),80 字节结构,data8@42=传统功能号(5=读键/8=按索引取键/9=键信息)、data32@44=参数、classic 字段整体后移 3 字节(keyInfo 对齐 12 字节,总长恰 80)**;温度键 = Tp* 全枚举(1762 键中 27 个),4 字节 IEEE754 浮点(实测 58~83°C 合理域),取最大
- **实现**:StatSampler.swift(SMCTemperatureReader + StatSampler + StatTileRenderer);StatTileRenderer 用 CoreText 直绘(NSAttributedString.draw 在裸 CGContext 上坐标错乱实测),100×100 深底+顶部标签+中央大值(§6.20 后已改 112),预旋转 180°;保留槽泛化 `reservedSlot(at:)`(导航 nav + 统计 stat 两类),Stats 槽由 2s 采样定时器整帧覆盖(setKeyImage → 设备 + UI 镜像同源),applyKey 先上占位帧
- **诊断陷阱(排障耗时实录)**:app 内 SMC 枚举 0 键 vs 脚本 1762 键——根因是移植时用了经典流程(funcID 9 keyInfo 拿 #KEY),而实测打通的现代流程是 funcID 5 读 #KEY + funcID 8 枚举;诊断日志(category stats,notice 级)定位
- **验收(截图自验)**:GPU 85%/CPU 35%/82° 实时刷新,状态灯蓝▶/Hermes 灰●/autotoggle 待命 同帧镜像;晨起用户验收硬件面
- **边界**:Stats 槽按压无动作;槽 5/6/7 原配置内容不渲染(保留槽语义);GPU 利用率依赖 IOAccelerator 键存在(缺则 N/A);温度键名按前缀 Tp* 过滤+合理域(15~110°C)过滤,机型相关的键位清单由枚举自适应,无需按机型硬编码
- **补遗(数值口径对齐,用户反馈「三个值与 Stats 不一致」)**:逐项对表 Stats 源码(exelban/stats,GPL)——①**温度**:Stats 的「Hottest CPU」= 其**分代精选键表**(Sensors/values.swift,group .CPU + average:true)上取最大,**不是全部 Tp***;本机 M2 表 = Tp1h/Tp1t/Tp1p/Tp1l + Tp01/Tp05/Tp09/Tp0D/Tp0X/Tp0b/Tp0f/Tp0j,我们此前全量 27 键取最大把表外键(本机 Tp0g 82.8°)算了进来 → 偏高;已按芯片代际(sysctl brand_string)硬编码 M1/M2/M3/M4 四代键表并与本机存在键取交集,无交集回退全量;独立验算 Stats 口径 65°C(Tp09)✓。②**CPU**:Stats totalUsage=(user+sys)/total,**nice 只入分母**;已对齐(此前 1-idle 含 nice)。③**GPU**:同源(IOAccelerator Device Utilization %,Stats reader.swift:139 逐字一致),本机仅 1 个 accelerator,残余差异纯属瞬时采样抖动(屏保下波动大)。侧记:槽 4 autotoggle 绑定在某次编辑器操作后消失(非渲染 bug);槽 5(位置 6)旧 mediaKey 绑定被 Stats 保留槽按设计覆盖,待用户决策去留

### 6.19 硬件 icon 偏移根因修复 + 官方 HTML 插件兼容矩阵(2026-10-18)
- **icon 左/上空隙大(用户实测定位)**:根因 = **JPEG 超限降级路径改变了画布尺寸**——高细节图标(动漫图)JPEG q0.1 仍超 10240B 时,`jpeg(from:)` 用 `redraw(scale:)` 缩到 80×80/60×60 并原样发送;固件把小于键面的图锚定在右下角 → 呈现「左/上空隙大、右下贴合」的偏移。瓷贴纯色不超限、100×100 全铺故正常。**修复**:降级后 `expand()` 双线性放大回原画布再编码(细节已丢失即省字节,画布尺寸恒定);新增回归测试「JPEG 超限降级:画布尺寸保持不变」(噪声图强制触发降级,70 测全绿)
- **官方 HTML 插件兼容矩阵(脚本化扫描:绑定→启动→采集→卸载,10 个 HTML 插件)**:全部**注册成功**;8 个 Vue+Pinia 挂载(calendar/dateTime/eatgoldcoins/h1time/pigmenteffects/screensaver/time/watertank,其中 7 个探针可见 store 已收到 willAppear——消息链通),memo/weather 为非 Vue 裸页面(weather 有 1 条 console 错误);**零解码失败、零渲染失败**。剩余「是否真正渲染上屏」属插件视图内部逻辑(time 的 `<!---->` 为已知插件侧问题),需逐插件目视,归 M3 逐插件适配后续;扫描产物(插件拷贝/孤儿 settings)已清理,现场恢复
- **媒体键调整(用户指令)**:「播放/暂停」从槽 6(Stats GPU 保留槽上被覆盖的旧绑定)挪到槽 11,已落 config

### 6.20 键面尺寸根因定案(官方 app 抓包:112×112)+ 对位调参面板(2026-10-22)
- **缘起**:§6.19 之后用户仍反馈「方形图标左/上空隙大」。先后试过「90% 内缩 + 平移」与「平移 + 边缘像素延展」,都只能把症状挪一挪;用户明确要求「看看官方软件怎么做的」
- **根因定案(动态抓包,一锤定音)**:官方 StreamDock.app 每个键下发的是 **112×112 JPEG**;本实现一直用 **100×100**。100 < 键面 → 固件把图按**右下角锚定**,于是左/上多出 12px 空隙。此前 §6.19 只堵住了「JPEG 超限降到 80×80」这一条路径,基座 100×100 本身仍是错的
- **抓包方法(可复用)**:把官方 app 复制到 /tmp → `codesign --force --deep --sign -`(ad-hoc,去掉 hardened runtime)→ 在副本 Info.plist 加 `LSEnvironment.DYLD_INSERT_LIBRARIES=/tmp/hidspy.dylib`(官方 app 会经 LaunchServices 重启自己,命令行 env 会被清掉,LSEnvironment 才可靠)→ 注入 fishhook 版探针拦截 `IOHIDDeviceSetReport`。**不要用 `__DATA,__interpose` + `dlsym(RTLD_NEXT)`**:实测 dlsym 返回的是探针自身,形成无限递归并触发官方 app 崩溃转储。fishhook(rebind_symbols)能拿到真实原函数
- **官方报文实证**:`43 52 54 00 00`("CRT\0\0")+ `42 41 54`("BAT")+ **4 字节大端 JPEG 长度** + 键 id,与我们的 `imageHeaderCommand` 逐字节一致;其后是 JPEG 数据块 + `STP` 刷新;前置 `DIS` 唤醒、`LIG` 亮度、`CLE` 清屏。抓到的首批键 id 0x0b/0x0c/0x0d/0x0e,JPEG SOF 全部 **112×112**,长度 8422/8871/6544/7728 字节(均 < 10240)
- **修复**:`StreamDock293S.keySize` → **112**;`StatTileRenderer` 改 112 且版式按 100→112 等比缩放;`DeviceController.blackImage` 用 keySize;`PluginImageDecoder` 默认 pixelSize 112;插件图经 `IconRenderer.render(size: 112, baseImage:)` 以 aspect-fill 放大到 112。JPEG 10240 字节上限不变(官方 112×112 实测 6.5–8.9KB)
- **官方 SDK 矩阵交叉验证(用户 skill `stream-dock-develop`)**:`references/device-matrix.md` 明确 **293V3 = 15 键 / 112×112 JPEG / 旋转 180°**,与抓包结论一致;PNG 原生格式只出现在 N4Pro / M3 / XL 等型号,**本机是 JPEG**。SDK 的 `to_native_key_format` 内部按「旋转→resize→flip→格式」处理(JPEG 合成到黑底);我们直驱 HID,所以自己预旋转 180° 是必要且正确的,与「SDK 用户不要预旋转」并不冲突。若未来支持多型号,应像 SDK 一样按设备运行时属性取 `keySize`/`key_image_format`,不要写死
- **对位补偿保留(用户最终拍板,2026-10-22)**:112 定案后本机正确值仍是 `0,0,100`(此时补偿是空操作);用户认为调参条好用,保留作为物理玻璃个体差异的微调口。界面为主窗口预览区下方的内联条(X/Y/缩放),⋯ 菜单 Toggle 呼出。注意 `zoom<100` 时图片瓷贴边缘会有拉伸条(边带填充的固有效果),纯色瓷贴无感
- **配置化**:`AppConfig.glassOffset: GlassOffset?`(可选,旧配置缺键可解码),字段 `x/y/zoom`;手写 `init(from:)` 保证上一版只有 `{x,y}` 的配置不整份解码失败。主窗口底座下方内联调参条(⋯ 菜单 Toggle 呼出),拖动即时落盘 + `redrawCachedKeys()` 重发缓存帧;缓存存原始帧、发送前统一套用参数
- **缩放 <100% 的白框伪影(2026-10-22 用户实测)**:缩放后内容矩形落在**小数像素**上,内容与边带两块相邻矩形各自抗锯齿,接缝处 alpha < 1,JPEG 把半透明垫成白色 → 显示区边缘出现一圈白线(不是硬件线条,也不是图片内容)。修法:`content`/`origin` 全部取整(`rounded`),边带绘制改 `.none` 最近邻(1px 源列/行整段复制,避免插值在 1px 源外采到透明);合成纯黑图 90% 缩放跑 JPEG 回归,修前接缝亮度 61、修后 0
- **删除的临时物**:`/tmp/opendeck-calib` 文件通道、`StatTileRenderer.calibration` 标定帧、AppModel 每 2s 标定帧块、临时 Sheet;官方 app 副本(1.6GB)与探针脚本已清理
- **物理结构(用户补充,2026-10-22,仅信息同步)**:键帽外壳是**圆角矩形**,内部真正的显示区是 **90° 直角矩形**,两者之间一圈黑边;设备下发帧本身无圆角(IconRenderer/StatTileRenderer/黑图都是全幅方形)。**UI 预览保持既有拟真圆角键帽样式,不做修改(用户明确要求「之前的 UI 挺好看」)**;此条作为后续视觉判读/渲染的事实基线,勿据此改 UI
- **验证**:`swift test` 58 测(15+30+13)全绿(`keySize` 断言改为 112);增量构建零警告;完整 release 仍只有既有的 `JSONValue.swift` deprecated ×6 与 PIFlowTests 多余 `try` ×1(未触碰)。已 `make-app.sh` 重打包并重启,配置 `glassOffset = {0,0,100}`,日志无失败项
- **教训**:键面分辨率不要照抄社区模块(100×100)或从照片反推;直接抓官方 app 的实际下发帧最可靠。`sendPicSizeCommand` 等库内符号容易误导,真正决定显示锚点的是 JPEG 的画布尺寸

### 6.21 状态灯换鲸鱼娘动画(2026-10-22,槽 2/ZCode + 槽 3/Hermes)
- **需求**:两个状态灯不再用色块+符号,改为原创 Q 版鲸鱼娘;不同状态不同动作,黄色闪烁(asking)= 招手。
- **硬约束**:293V3 键面是 112×112 **静态 JPEG**,设备不支持 GIF;动图只能靠插件连续 `setImage` 推帧。宿主推拍最短 200ms(5fps),页面返回 `nextInterval` 自适应节拍。
- **实现**:新 `Scripts/com.zcode.status.sdPlugin/whale.js`(canvas 2D,112×112 透明底,状态→动作 + 状态色光晕);两插件 `index.html` 改 112 画布、引入 `whale.js`、`tick` 每拍推进一帧并 `pushToAll`,状态切换重置帧。透明区域由宿主 `IconRenderer` 合成到键面底色(本机黑)后转 JPEG 下发。
- **动作映射**:`idle` 打盹+Zzz(灰/450ms)、`working` 敲键盘+气泡(蓝/200ms)、`permission` 举手+?(黄/300ms)、`asking` **招手**+黄色脉冲(黄/200ms)、`error` X 眼+汗+抖动(红/250ms)、`done`/`ready` 开心+星星(绿/250ms)。
- **验证**:WKWebView 离屏快照生成 7 状态×4 帧对照图(工具在 /tmp,不入库);真机 UI 镜像实测 working 动画、asking 招手(临时写 state.json 验证后恢复);app CPU 约 3–4%(2 键 5fps)。
- **边界**:槽 3 Hermes 插件属另一 agent,已备份 `index.html.bak-20261022-whale` 后同步改;对方若重新生成会覆盖,需协调。`whale.js` 以子资源方式加载(宿主 `allowingReadAccessTo` 插件根,实测可行);插件源在仓库 `Scripts/com.zcode.status.sdPlugin/`,部署时两个插件目录都要带 `whale.js`。

### 6.22 显示器输入源动效键面(2026-10-22,槽 1;宿主内建 KeyAnimation 首个实例)
- **需求**:槽 1 的 `Toggle Monitor` 快捷指令实际是切换 LG 27GP95U 的输入源(Mac DP ↔ PC HDMI1)。键面要回答「现在谁在屏」,按压时把「信号搬家」演出来,而不是画一个电源开关。
- **事实源**:`~/.cache/lg_input`(`mac` / `pc`,由 `/Users/yorkli/bin/lg-toggle.sh` 经 `m1ddc set input-alt` 写入)。键面、状态文件、按压后的乐观目标三方必须收敛。
- **数据模型**:`KeyConfig.animation: KeyAnimation?`(目前仅 `.monitorInput`),可选字段、旧配置缺键可解码;语义由渲染器决定,优先于 `iconPath`/`title`。编辑器外观区新增「动效:显示器输入切换」开关,草稿预览用 `AppModel.animationPreviewFrame(for:)` 取与设备同源的静息帧。
- **宿主挂载**:`AppModel` 持有单例 `MonitorInputAnimator`(全局只有一路输入状态);`applyKey` 时 `attach(index:size:)`,同页其它键/换页时 `detach(ifIndex:)`。动效键整帧由动画驱动,跳过常规「底色+底图+标题」渲染;帧回调统一走 `setKeyImage`(设备与 UI 镜像同源)。按下沿先起动画再照常执行动作(乐观展示)。
- **状态机**(`MonitorInputAnimator.swift`):按下立即播 12 帧 / 12fps 迁移(1.0s),不等脚本;动画结束后 1.5s 轮询状态文件对账——对上即销账,3s 仍未变则反向播一次回退动画(红色闪灯,不静默撒谎);外部切换(显示器摇杆/其它触发)由轮询检出并跟随。静息每 8s 一次「信号包」呼吸(6 帧 × 6fps),系统「减弱动态效果」开启时自动关闭。换页离开再回来重新读盘。
- **渲染**(`MonitorInputIcon.swift`):纯 CoreGraphics,112×112,无 AppKit 文字;Mac 冷蓝 `#4DA3FF` / PC 暖橙 `#FFA94D`,用源芯片 + 屏幕内容(Mac 顶部菜单栏 / PC 底部任务栏)+ LED 三重编码;输出预旋转 180°,UI 镜像再转回正立。实测 JPEG ≈3.9KB/帧,远低于 10240 上限。
- **预览工具链**:`Scripts/RenderMonitorIconFrames.swift` 用生产渲染器导出 112/336/448 三档逐帧 PNG;`Scripts/BuildMonitorIconPreview.py` 组装自包含 `Design/MonitorInputIcon/preview.html`(可播两个方向、静息呼吸、逐帧步进),预览帧 = 上机帧。设计说明见 `Design/MonitorInputIcon/README.md`。
- **验证**:`swift build` 通过;完整 `swift test` 58 测全绿(动效暂无单测,渲染确定性与硬件验收依赖预览导出);`make-app` 重打包重启后设备正常连接,槽 1 静息帧上屏、UI 镜像与设备同源;改写 `~/.cache/lg_input` 实测 UI 镜像逐帧更新并自动回到 Mac。
- **边界**:同一时刻只服务一颗键,若给第二颗键也开动效,动画挂到最后挂载的那颗;回退判定依赖状态文件,若手动改显示器输入却没更新 `lg_input`,图标会跟文件而非真实硬件(沿用 `lg-toggle.sh` 契约);这是宿主内建动效,不走插件协议,其他 agent 若要复用应先读本节与设计 README。


### 6.23 显示器功能托盘 + 宿主内建 DDC 动作(2026-10-22,独立浮动 deco;`KeyAction.monitor`)
- **需求**:把 LG OnScreen Control / UltraGear 里能调的显示器设置搬到硬件上,像槽 1 的 toggle monitor 那样一按即变;托盘条目拖到 15 个真实键位即绑定。
- **前提结论**:LG 应用只是 MCCS/DDC 的一个客户端,PC 侧走 USB→I2C 私有桥(`lpcusbsio.dll` + `LPCCommunicationLayer.dll`),但显示器对 Mac 的 USB-C(DP Alt)链路同样开放同一套 VCP 控制。因此**不逆应用、不依赖 PC**,宿主直连 DDC。调研与全码基线见 `~/projects/lg-osc/`(`FEATURES.md`、`lgddc/baseline.txt`)。
- **数据模型**:`KeyAction` 新增 `case monitor(MonitorCommand)`;`MonitorCommand`(18 个动作)是唯一事实源,集中声明 VCP 码、运算方式(`step`/`cycle`/`set`/`switchInput`)、分组、短标签、SF Symbol、校准备注与「会闪断」标记。校准新码只改 `MonitorActions.swift` 一张表,不动执行层与渲染层。
- **执行层**:`MonitorDDC.swift` 用私有 `IOAVServiceCreate/ReadI2C/WriteI2C`(与 m1ddc/MonitorControl 同法)发 DDC 帧,`ActionRunner.run` 的 `.monitor` 分支直调,失败走既有 `report(_:)` 弹窗,不静默。**两个必须记住的协议事实**:①**每个请求要连写两帧**,只写一帧时 IOKit 返回 0 但读回固定乱码(`6e 80 be 00 e6 d2 …`);②读帧校验不含寻址字节、写帧校验含寻址字节(上游 m1ddc 的不对称写法)。读回统一验帧 `head==0x6E / op==0x02 / vcp==请求码`,不符重试 3 次。0xF4(输入源)走 0x50 备用寻址;输入源自动切换与 `~/bin/lg-toggle.sh` 共用 `~/.cache/lg_input` 状态文件。
- **UI**:`MonitorPaletteView` 是从「矩阵·右缘」挂轨深色胶囊语言里剥出来的**独立浮动面板**(可拖动、可收起,默认显示,工具栏「显示器功能托盘」开关)。条目 `.draggable(MonitorCommand)`(`UTType com.opendeck.monitor-command`),键位 `ZStack` 外层 `.dropDestination`,落下即 `bindMonitor` 写配置 + `applyKey` 上屏;保留槽(6/7/8、14/15)拒绝放置,拖动悬停有白色描边反馈。编辑 sheet 的动作类型新增「显示器（DDC）」,落键后仍可双击改功能。
- **验证**:`swift build` 通过;`swift test` 63 测全绿(新增 5 测:目录完整性、分组覆盖、`KeyAction.monitor`/`KeyConfig` 编解码往返);DDC 执行路径用同一份源码编出的冒烟程序实测——亮度读 63 → +5 得 68 → −5 回 63、音量读 30、响应时间 0→1→2 循环并已复位 3;**拖拽投放未做机器验证**(合成 CGEvent 起不了 SwiftUI 拖拽会话),需人工拖一次确认。
- **边界**:0xF8(自适应同步)写入会触发 DP 重协商、掉屏约 18 秒,动作成功后不读回校验;0xF9(黑阶稳定器)本机写入回读恒为 100,标「待校准」不进正式键位;0xAC/0xAE(DP 版本)、0x04/0x05(恢复出厂)只读不写;图像模式/伽马/节能/色温的枚举值随型号变,须逐项校准后才可信(校准方法:`lgddc track` 全码轮询 + 用户在 OSD 里一次改一项)。

### 6.24 功能调色盘:显示器托盘泛化为全功能拖拽源(2026-11-01,常驻;`KeyTemplate` 模板占位)
- **需求**:原「显示器功能托盘」只服务 DDC 命令,其余动作类型(翻页/熄屏/媒体…)只能逐键在下拉菜单里手动配。升级为常驻「功能调色盘」:全动作类型按分类组织的统一拖拽源,显示器只是其中一格;工具栏开关移除(经三轮迭代后定为右列固定停靠,见下)。
- **分类**:五类——显示器(复合 + 画面/游戏/音频/输入,二级折叠沿用)/ 翻页·场景(5)/ 媒体控制(6)/ 系统(熄屏、合盖锁、热力图 3)/ 模板·待配置(打开应用、网址、快捷指令、Shell、AppleScript、热键 6)。插件动作(需已装插件+生成 contextID)与前往指定页(遗留类型)不进调色盘,仍走编辑器下拉。
- **数据模型**:`KeyConfig` 新增 `var template: KeyTemplate? = nil`(Optional 缺键解码为 nil,旧配置兼容)。`KeyTemplate`(openApp/openURL/runShortcut/shellScript/appleScript/hotkey)是**模板占位**:落下后 `action = nil`(按下无动作,强不变量「action 要么完整要么 nil」不破,运行时零改动),`KeyEditView` 点开按 `template.actionKind` 预选类型,保存即清除占位(draftConfig 显式 `template: nil`),取消则保留;`clearKey` 一并清除。
- **载荷契约(纯文本,超集兼容旧格式)**:`<MonitorCommand.rawValue>` / `"composite:<id>"` 照旧;新增 `"action:<name>"`(previousPage/nextPage/previousScene/nextScene/pageIndicator/screenOff/sleepGuard/keyboardHeatmap/`action:mediaKey:<value>`)与 `"template:<kind>"`。解析收敛为 **`FunctionPaletteCatalog.item(forPayload:)` 单一映射器**(旧实现 bindPayload/tileConfig/pickedHint 三处人肉同步分支已废),bindPayload 按磁贴语义覆盖 action/title/animation/template 四字段,底色与自定义图标沿用槽位现状。
- **UI**:`MonitorPaletteView` → `FunctionPaletteView`(`MonitorPalette.swift` → `FunctionPalette.swift`,旧文件移废纸篓);磁贴仍为真实键帽渲染 100pt 1:1,模板磁贴靠 `KeycapView` 的占位虚线区分。`defaultIconSymbol` 从「仅 .monitor」统一为 `ActionStyle.symbol(for:)` 全动作单表(键帽 UI 与设备帧经 `AppModel` 的 `symbolName` 同源生效),`.mediaKey` 六取值各配语义符号。**布局三轮迭代**:先按 §6.23 浮层语言常驻右上 overlay,同日按用户反馈改为**固定停靠右列**(body 重排为双列 HStack:左=底座+导航,右=调色盘卡片撑满内容区高度、内部滚动;去浮层/拖拽/收起,不再遮挡键位;`minWidth` 760→1000);再统一配色(浅色材质卡片+系统语义文字层级,磁贴底色改 KeyConfig 默认色以保住「磁贴=落键」颜色 1:1);最后分类导航磁贴化——顶部五个**分类页签磁贴**(点选切换、切换后滚回顶部),折叠文本头只剩显示器子分组在用。**交互定稿(v8)**:点选绑定(点磁贴→点键位)删除,拖拽是唯一放置手势;模板磁贴点击弹 `TemplateConfigSheet`(复用 HotkeyCaptureField/FilePicker,参数口径同 assembledAction)→ 存 `AppModel.templateDrafts`(会话内存不持久化,可重复落多个键)→ 拖拽落键即完整键,再点磁贴=改配置;就绪载荷前缀 `"draft:<kind>"`,bindPayload 从 draft store 取整份配置落键(底色仍沿用槽位现状),**一次性:落键即消费草稿、磁贴复原回占位态**。打开应用模板选中 app 后**自动带出显示名+真实图标**(`FileManager.displayName` + `NSWorkspace.icon`→256pt PNG 落盘缓存于 `app-icons/<bundleID>.png`,带 Finder 同款文件状态角标),就绪磁贴与落键共用该图标(iconPath 全幅底图机制)。**可见副作用**:既有非显示器键(如 14/15 上一页/下一页)键面从纯标题变为「语义图标+标题」,角标被默认图标接管后不再叠加(显示器键一贯如此)。
- **验证**:`swift build` 通过;`swift test` 全绿(新增 7 测:渲染源载荷全解析、互不碰撞、即用/模板二分、模板载荷↔KeyTemplate 对应、输入命令动效派生、旧配置无 template 字段兼容、模板往返);**拖拽投放仍未做机器验证**,需人工拖一次确认。

### 6.25 统计键动作化 + 调色盘「自定义」分类(2026-11-01,消除保留槽特例)
- **需求**:用户要求统计键能像普通磁贴一样「想看就拖出来,不想看就清除」;并要求调色盘新增「自定义」分类,把槽位 2/3/5/11/13 的现有键做成可复制的拖拽源。
- **为什么之前不行**:统计是 §6.18 时代的「固定仪表盘」特例——不走 KeyAction 体系,`StatTileAnimator` 启动时接死 `ReservedSlots.statSlots`(6/7/8),整帧覆盖。本次按 subsystem-integration §1 的 animator 形态消除特例。
- **动作化**:`KeyAction` 新增 `case stat(StatKind)`(StatKind 补 String/Codable/CaseIterable/Sendable);ActionKind/actionForm(监视项 Picker)/assembledAction/ActionStyle(gpu→cpu.fill、cpu→cpu、temp→thermometer.medium)/KeyPressRouter(按压无操作,同 pageIndicator)/ActionRunner(忽略表)按 §4 清单补齐。`ReservedSlots` 收缩到仅导航 13/14;AppModel 删 `statSlots`,新增 `syncStatSlots()`——扫当前页 `.stat` 动作喂 `statTiles.setSlots(_:)`(清单变化立即重渲),`applyKey` 顶部触发,编辑/换页/切场景三路径全覆盖;统计分支改判 `key.action`,先上占位帧,清除后常规渲染覆盖旧帧。**可见变化**:旧页 6/7/8 变普通空槽(统计不再强制出现),从调色盘「系统」分类拖 GPU/CPU/温度 到任意键位即实时键。
- **自定义分类**:调色盘页签首位新增「自定义」(`square.on.square`),内容 = `FunctionPaletteCatalog.customSlotIndices`(0-based [1,2,4,10,12])的**配置镜像磁贴**——`resolvedKeyConfig` 渲染 + 动效静息帧(`animationPreviewFrame`),**不接 keyImageSlots 实时帧**(用户原则:零件与源键运行态解耦,睡眠锁 ON/OFF、插件推送图不渗进调色盘;初版曾用实时镜像,当日按用户反馈改为解耦),左上角源槽位号角标;拖拽载荷 `"slot:<index>"` → `bindPayload` **整键复刻**(动作/标题/图标/动效/模板/底色全带,区别于目录磁贴的「保留目标底色」)。插件键复刻语义:contextID 随键复制 = 共享同一插件实例,状态跟随当前页持有者;同页两枚同款会互顶(实例表按 contextID 唯一)。
- **验证**:`swift build` 通过;`swift test` 全绿(新增统计动作编解码往返 + 槽位对账守卫 3 测;统计载荷经「渲染源载荷全解析」自动覆盖);拖拽与实时帧人工确认。
- **UX 成熟度巡检(同日)**:①「自定义」镜像取数从当前页**固定到首页**(第一场景第一页,`AppModel.homeKeyConfig`)——此前切到别的页/场景,镜像会变成那边空着的槽位,「复制我的常用键」语义断裂;②移除 ⋯ 菜单里无任何行为的「帮助」按钮;③状态灯插件键经 `AppIconCache` 思路配置静态键面图标(`key-icons/<plugin>.png`,config.iconPath 承载,设备/网格仍由插件帧接管,仅调色盘显示)。
- **十轮全维度迭代(同日,R1–R10)**:R1 数据完整性——config.json 解析失败先**归档留底**(`config.corrupt-<ts>-<原因>.json`)再回退默认,不再静默覆写用户配置;R2 性能——`KeycapView` 的 iconPath 底图从每次求值读盘改为 `KeycapImageCache` 路径缓存(按键全格重估不再触发 15 次磁盘 IO);R3 卫生——删死代码 `UTType.opendeckMonitorCommand`/`MonitorCommand: Transferable`、解 `PluginServer.acceptPending` 的 `if true{}` 遗留包裹;R4 测试——畸形/越界载荷 15 种全拒用例 + 自定义镜像索引合法性用例;R5 插件宿主写路径审计——SIGPIPE 抑制后 EPIPE 已走 `finish` 优雅关闭,判定完备;R6 日志——ConfigStore 生产 print 转 logger(`#if DEBUG` 协议追踪保留);R7 热键路径审计——HotkeyCaptureMonitor 生命周期纪律完整,校正两处「显示器托盘」遗留措辞;R8 亮度/熄屏审计——全库零 TODO/FIXME/强解包,涂黑守卫在 drawKey 统一生效;R9 文档——README/AGENT-GUIDE 测试计数改为「只增不减」防腐化;R10 终检——全量门禁连跑 2× 全绿(39+31+28=98 测),dist 重建重启。
- **双视角评审 P1 全修(同日,专业开发者 + 刁钻用户两代理交叉)**:①`applyKey` 的 stat 分支提前 return 前补 `heatmap.detach`/`monitorInput.detach`(键转统计键时旧动画器残留打架);②`duplicateScene` **重生成 Page.id**(克隆曾与原场景共享页 id,点页点会跳回原场景)+ delete/duplicate 平移 `currentSceneIndex` 保持视野场景不变;③KeyEditView 保存禁用条件(`kind != .none && assembledAction == nil`),双 sheet 空脚本一律不成动作——堵死「看起来配好的死键」;④`bindPayload` 从 EditorView **下沉 AppModel**(可测),`slot:` 载荷改解析首页(与镜像渲染同源),插件键复刻生成**新 contextID**(克隆 = 独立实例,不再互抢);⑤**可见错误通道**:`LogSheet`(运行日志…菜单,环容量 12→50)+ 状态胶囊显示熄屏/涂黑态——静默失败时代结束;⑥LayoutTuningSheet 改草稿模式(拖动只进内存,完成落盘,取消还原)、玻璃校准重渲/落盘防抖合并(80ms/700ms);⑦热键 AX 授权弹窗每会话一次;⑧PluginServer 读路径 EINTR/EAGAIN 不再误杀连接 + 写就绪源(outbox 滞留排空)+ shutdown 同步撤写源;⑨芯片右键菜单加「删除当前页(圆点)」、addPage 25 页封顶、保留槽不亮拖放圈、插件缺失键帽警示标+压暗、`reviveRuntimes()` 人工复活入口(重新应用到设备/打开插件管理触发)。
- **P2 批次(同日)**:①落键政策抽**纯函数 `AppModel.landingConfig`**(payload/current/homeKey/draft → KeyConfig)+ 5 个政策测试(保留槽拒绝/整键复刻/新 contextID/草稿清占位/畸形拒绝);②`LogRing` 容量 50;③StatSampler 缓存宿主 port(mach_host_self 每 2s 泄漏一个 send right);④SceneRouter.deleteScene 仅删当前场景才重渲;⑤PluginHostModel.handleMessage 三连 parse 合一;⑥MonitorDDC read/write 转 async,usleep 改 Task.sleep(协作线程池不被 10–60ms 硬件节拍钉住);⑦ActionKind 新增 `.gotoPageLegacy` 只读条目(旧动作不再静默伪装成「无动作」,保存即清除有文档);⑧config.json 增 `schemaVersion`(normalize 补 2,下次破坏性迁移不再靠键名嗅探);⑨SceneAppBindingSheet 应用列表改打开时扫描(后装应用可见);⑩**EditorView 拆分**:SwipeGesture/HotkeyCapture/EditorSupport 三文件独立(2048→1525 行),git 记录里不再有千行混合体。
- **hex 解析收敛收尾(同日)**:`KeyPalette` 的独立解析段删除,委托 `HexCGColor.components`(同模块;kit 内 HexColor 因 MonitorInputIcon 单文件编译约束不可合并,见 HexCGColor 头注释)。**漂移实证**:两份实现对 7 位输入行为不同(KeyPalette 产出错位色/HexCGColor 返回 nil)——`HexColorTests` 4 测锁死契约(分量正确性/7 位 nil 守卫/opaque 抹 alpha/KeyPalette 兜底灰)。全库解析唯一性核验:OpenDeck 侧仅 HexCGColor 一处,kit 内一份属文档化例外。全局审计(独立代理横切排查)另揪出两处一并修复:①`StatTileAnimator.setSlots` 对账守卫曾只比槽位号,同键换指标(GPU→CPU)永不重渲——对比改为 index+kind;②**`PluginServer` socket 未关 SIGPIPE**——对端断开后的 TCP 写入直接杀死整个进程,这正是当日 `swift test` ~40% 概率 "signal code 13" 波动的真凶(测试 FakeClient 断连),对正式 app 同样是潜在杀手(PI webview 断连),监听/已接受/FakeClient 三处补 `SO_NOSIGPIPE` 后连跑 3× 全量全绿。窗口 `minWidth`/`defaultSize` 1000→1120(矩阵·右缘轨双列放得下)。
