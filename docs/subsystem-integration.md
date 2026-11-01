# OpenDeck 子系统接入约定

> 本文是全局架构审查（2026-10-31）的产物。此前每个子系统按「当时最顺手」的方式接入,
> 同一语义存在 2~4 种写法（后台执行、整帧驱动、回调挂接、Sheet 状态各有分叉）。
> 新子系统接入一律按本文执行;存量系统在触碰时向本文对齐。
> 违反约定的典型后果见文末「历史事故对照」。

## 0. 线程与 IO 规则（最重要）

模块开了 `.defaultIsolation(MainActor.self)`（Package.swift）,**未标注的代码默认在主线程**。
「忘记标 nonisolated」完全合法、编译器不报错,后果是主线程被 IO 阻塞——这是本工程
反复发生的债务模式（DDC 数百毫秒、SQLite busy_timeout、OSLog 扫描 6 小时都曾落在主线程）。

机械规则:

| 场景 | 做法 | 范本 |
|---|---|---|
| 一次动作型重 IO（子进程/I2C/安装解包） | `nonisolated enum` + `@concurrent func ... async`,调用方 `await` | `SleepGuard`、`ActionExecutor`、`MonitorDDC.apply` |
| 周期采样型 IO（读库/读盘/读注册表） | 主线程定时器触发 → `Task.detached(priority: .utility)` 做 IO → `MainActor.run` 回来应用,**带 generation 计数丢弃乱序结果** | `StatTileAnimator.refresh`、`KeyboardHeatmapAnimator.refresh`、`MonitorInputAnimator.pollState` |
| 子进程 | 必须有超时 + SIGTERM→宽限→SIGKILL 兜底（60s/5s）;stdout 接 /dev/null 防管道死锁 | `ActionExecutor.execute` |
| 轻量单次文件读（几百字节配置态文件） | 可留主线程,但周期性轮询的不算轻量,必须后台 | `MonitorDDC.currentInputIsMac` |

## 1. 整帧键面驱动（animator 家族）

绕过 IconRenderer 常规渲染、由专用节拍器整帧驱动键面的系统（热力图/显示器输入动效/
Stats 瓷贴）,遵守同一形态:

- **职责边界**:animator 只负责「采样 + 状态机 + 渲染帧」,经 `onFrame` 回调交出
  `CGImage`;写设备与 UI 镜像永远是 AppModel.setKeyImage（设备+镜像同源）。
- **生命周期两种模式**:
  - 随页挂卸（单键）:`attach(index:size:)` / `detach(ifIndex:)`,幂等且对称
    （停全部定时器、摘全部通知观察者）;`applyKey` 是全键对账点。
    范本:`KeyboardHeatmapAnimator`、`MonitorInputAnimator`。
  - 配置驱动动态槽位（多键）:`start()` 幂等起定时器,槽位清单由
    `setSlots(_:)` 按当前页配置对账（AppModel.syncStatSlots 在 applyKey 里触发,
    清单变化立即重渲）。范本:`StatTileAnimator`（2026-11-01 随 `KeyAction.stat`
    动作化从「常驻保留槽」改为此模式——统计键可放任意键位、可清除）。
- **节拍**:定时器一律 `Timer(timeInterval:repeats:)` + `RunLoop.main.add(.common)`
  （滚动时不断拍）,并设 `tolerance`（趋势类 0.2~1s）省电。
- **熄屏/断连**:不做各 animator 自守卫——统一依赖 `DeviceController.drawKey` 的
  「熄屏中只更新缓存不写设备」兜底;渲染可以照常发生。

## 2. 回调挂接

- **animator 回调（onFrame/onLog）统一在 AppModel.init 挂接**,不在 start() 挂。
  原因:编辑器 WindowGroup `.onAppear` 先于 `.task { start() }` 调 applyPageToDevice,
  start() 才挂会丢首次帧;且禁止两处重复挂接（曾出现 heatmap 接两遍的歧义）。
- **pluginHost 走 Hooks 结构体**（draw/backgroundColor/open/activateApp/log）,
  在 start() 一次性设置——宿主服务未启动前不会有回调,无 onAppear 竞态。
- 回调闭包一律 `[weak self]`;`@Observable` 逐槽更新（见 KeycapView 的单槽粒度注释）。

## 3. 外部事实对账（状态真相源哲学）

- 配置真相 = config.json（ConfigStore 单一写入口,原子写）;设备真相 = DeviceController
  键面缓存（断连重连按缓存全量重画）;**外部世界真相 = 回读对账**——
  不信乐观状态:SleepGuard 写后回读、monitorInput 的 PendingSwitch+deadline+回退动画、
  heatmap 的「失败之后库没再增长才算未恢复」。
- 新子系统与外部进程/硬件交互时,必须设计「对不上账怎么办」的路径（回退展示/重试/超时）,
  不允许单靠乐观假设。

## 4. 数据模型与动作分发

- 新动作类型 = `KeyAction` 加 case（Codable 自动合成）+ `ActionKind` + `actionForm` +
  `assembledAction` + `ActionStyle.symbol/label`;switch 穷尽会强制补齐。
  **优先考虑扩展现有 case 的语义而不是加并列新类型**（热键 → 键盘按键的教训:
  两个相似选项二选一是把局部最优推给用户）。
- 动作分发三段式是既定结构:双相动作（plugin/hotkey）在 AppModel 按键闭包两沿直调;
  设备控制（翻页/场景/熄屏）走 `handleDeviceAction`;其余走 `ActionRunner.run`。

## 5. Sheet 状态

- 编辑类 Sheet 一律草稿模式（@State 草稿,保存才写回配置,取消即丢弃）:范本 `KeyEditView`。
- 实时调参类（拖动滑杆即时看效果）允许直写 + 完成时 save:范本 `LayoutTuningSheet`。
- 新增 Sheet 若在编辑器内弹出,记得登记 `ModalSwipeSuppression`（隐藏耦合点,容易漏）。

## 历史事故对照

| 事故 | 违反的条款 |
|---|---|
| MonitorDDC 同步 I2C+usleep 阻塞主线程数百毫秒 | §0 动作型重 IO 未走 @concurrent |
| WS inbox 4GB 泄漏（7382825 修复） | §1 帧驱动系统缓冲无界（已修,规则:任何 inbox/outbox 必须有上限+压缩） |
| heatmap 钩子 init/start 接两遍 | §2 挂接唯一时机 |
| 键面 100×100 固件右下锚定假偏移 | §1 帧必须按 `StreamDock293S.keySize` 全尺寸 |
| 测试与源码漂移数月无人发现 | §6（P3:CI 兜底,另行实施） |
