import Foundation
import StreamDockKit

/// 按键事件 → 动作分发域:一颗键被按下/抬起之后,到底该发生什么。
///
/// 判定顺序就是产品的行为契约,拆分时逐条保留(顺序改变会直接改变手感):
/// ① 熄屏态任意按下沿只唤醒、不产生动作
/// ② 键面涂黑中按下沿先点亮到最近有效亮度、15s 后回涂黑,动作照常
/// ③ 插件动作两沿都转发(协议要求)
/// ④ 热键两沿都转发(keyDown/keyUp,支持按住)
/// ⑤ 其余动作只在按下沿:热力图 / 合盖休眠锁 / 设备控制(翻页·亮度·熄屏)/ 动效键 / ActionRunner
///
/// 纯搬移:方法体、日志文案、早退位置与拆分前一致。
@MainActor
final class KeyPressRouter {
    /// 诊断日志钩子(与其它子系统一致:在持有者 init 里挂接)
    var onLog: ((String) -> Void)?
    /// 物理按下集合的回写。存储留在 AppModel:KeycapView 在 body 里读它,搬走会丢观察
    var onPressedChange: ((_ index: Int, _ down: Bool) -> Void)?
    /// 合盖休眠锁:要跑 sudo、回读并弹窗,留在 AppModel,由它决定异步路径
    var onSleepGuard: ((_ index: Int) -> Void)?
    /// 导航键方向过渡(§6.34):场景/页切换后播滑移动画(index/类/方向)
    var onNavTransition: ((_ index: Int, _ kind: NavTileRenderer.Kind, _ offset: Int) -> Void)?

    private let device: DeviceController
    private let config: ConfigStore
    private let pluginHost: PluginHostModel
    private let heatmap: KeyboardHeatmapAnimator
    private let monitorInput: MonitorInputAnimator
    private let pressPulse: PressPulseAnimator
    private let brightness: BrightnessCoordinator
    private let sceneRouter: SceneRouter

    init(
        device: DeviceController,
        config: ConfigStore,
        pluginHost: PluginHostModel,
        heatmap: KeyboardHeatmapAnimator,
        monitorInput: MonitorInputAnimator,
        pressPulse: PressPulseAnimator,
        brightness: BrightnessCoordinator,
        sceneRouter: SceneRouter
    ) {
        self.device = device
        self.config = config
        self.pluginHost = pluginHost
        self.heatmap = heatmap
        self.monitorInput = monitorInput
        self.pressPulse = pressPulse
        self.brightness = brightness
        self.sceneRouter = sceneRouter
    }

    // MARK: - 入口

    func handle(_ event: KeyEvent) {
        let index = event.row * StreamDock293S.columns + event.column
        onLog?("按键 r\(event.row)c\(event.column) \(event.phase == .down ? "按下" : "抬起") 熄屏态=\(device.isScreenOff)")
        onPressedChange?(index, event.phase == .down)
        brightness.noteDeviceActivity()
        // 熄屏待机:任意按下沿唤醒,该次按压不产生动作
        if device.isScreenOff {
            if event.phase == .down { device.wakeFromScreenOff() }
            return
        }
        // 键面纯黑(亮度跟随 0% 态):按下沿暂时与内屏解耦——点亮键面至最近有效亮度,
        // 动作照常触发;内屏亮度下次变化时镜像自动重新关联(涂黑或跟随新值)
        if event.phase == .down, device.keysBlacked {
            device.setKeysBlacked(false)
            brightness.setBrightness(brightness.lastNonZeroMirroredPercent, userInitiated: false)
            brightness.armPeekReDarken()
        }
        // 固定导航键(位置 14/15)的动作是解析后强制的,配置原文在这两格恒空,
        // 直接读配置会让按键事件无动作(2026-10-18 用户反馈按压无反应)
        let key = ReservedSlots.keyConfig(at: index, config: config)
        let action = key.action
        // 插件动作:按下/抬起两沿都转发(协议要求),不走原生动作执行器
        if case .plugin = action {
            pluginHost.handleKey(index: index, phase: event.phase)
            return
        }
        // 热键 = 键盘按键:按下沿 keyDown、抬起沿 keyUp(按住槽位 = 按住该键;单按修饰键如右⌘也走这里)
        if case .hotkey(let keyCode, let modifiers) = action {
            Task { await ActionRunner.runHotkey(keyCode: keyCode, modifiers: modifiers, down: event.phase == .down) }
            return
        }
        // 其余动作只在按下沿触发,抬起沿不重复执行
        guard event.phase == .down, let action else { return }
        // 热力图键:读数与状态都在 animator 里,按下只转发给它自己的入口
        if case .keyboardHeatmap = action {
            heatmap.handlePress()
            return
        }
        // 合盖休眠锁:要跑 sudo 并回读,独立异步路径(不阻塞按键回调,也不进 ActionRunner)
        if case .sleepGuard = action {
            onSleepGuard?(index)
            return
        }
        // 设备控制动作(页面/亮度/熄屏)本地消化,不经 ActionRunner
        if handleDeviceAction(action, index: index) { return }
        // 动效键面:先起动画,再照常执行动作(乐观展示,状态文件随后对账);
        // 确定性输入命令(inputMac/inputPC)把命令目标传给动画器,别把「已在其位」演成失败回退
        if key.animation == .monitorInput {
            monitorInput.handlePress(command: action)
        }
        // 按压脉冲:纯视觉反馈,动作照常;在脉冲中连按不重起(会话自然跑完)
        if key.animation == .pressPulse {
            pressPulse.handlePress(index: index)
        }
        Task { await ActionRunner.run(action) }
    }

    // MARK: - 私有

    /// 页面/亮度/熄屏类动作:纯本地状态操作。返回 true 表示已消化
    private func handleDeviceAction(_ action: KeyAction, index: Int) -> Bool {
        func nav(_ kind: NavTileRenderer.Kind, _ offset: Int) {
            onNavTransition?(index, kind, offset)
        }
        switch action {
        case .previousPage: sceneRouter.switchPage(offset: -1); nav(.page, -1)
        case .nextPage: sceneRouter.switchPage(offset: 1); nav(.page, 1)
        case .previousScene: sceneRouter.switchScene(offset: -1); nav(.scene, -1)
        case .nextScene: sceneRouter.switchScene(offset: 1); nav(.scene, 1)
        case .gotoPage(let pageID):
            // 兼容旧配置的动作:跨场景按 Page.id 定位
            sceneRouter.gotoLegacyPage(pageID)
        case .screenOff: device.screenOff()
        case .pageIndicator: break // 纯显示键,按下无操作
        case .stat: break // 系统状态键:纯显示,整帧由 StatTileAnimator 驱动,按压无操作
        default: return false
        }
        return true
    }
}
