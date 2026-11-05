import AppKit
import Darwin
import IOKit
import StreamDockKit

/// 亮度域:设备背光、内建屏亮度读取、「跟随 MacBook」轮询、0% 涂黑与点亮回涂黑、
/// 以及自动熄屏空闲看门狗。
///
/// 为什么这四件事同域:它们是同一组状态的两个出口。`followSystemBrightness` 与
/// `autoScreenOffMinutes` 在设计上互斥(任一方开启即归零另一方),而「0% 涂黑后按键
/// 点亮 → 15s 无操作重涂黑」要读跟随链算出的 `lastMirroredBrightness`。拆成两个
/// 协调器就得把这批私有状态跨对象暴露,反而把耦合写进 API。
///
/// 纯搬移:方法体、日志文案、定时粒度、守卫顺序与拆分前逐字一致。
@MainActor
final class BrightnessCoordinator {
    /// 诊断日志钩子(与各 animator 一致:在持有者的 init 里挂接,便于早于 start() 的调用也能记日志)
    var onLog: ((String) -> Void)?

    private let device: DeviceController
    private let config: ConfigStore

    /// 最近一次设备按键时间(自动熄屏的空闲时钟;唤醒按键也会重置)
    private var lastDeviceActivityAt = Date()
    private var screenOffWatchdogTask: Task<Void, Never>?

    private var followTask: Task<Void, Never>?
    /// 上次镜像到设备的百分比:轮询读值便宜,但 USB 写没必要重复
    private var lastMirroredBrightness = -1
    /// 最近一次非 0 的镜像亮度:「0% 涂黑后按键点亮」的暂态亮度(与内屏暂时解耦)
    private var lastNonZeroMirroredBrightness = 80
    /// 内建屏亮度读取失败的去重标志(失败态每 1.5s 才轮一次,不去重会刷屏)
    private var lastBrightnessReadFailed = false
    /// 「0% 涂黑后按键点亮」的 15s 无操作重涂黑任务:期间每次设备按键都会重新计时
    private var peekReDarkenTask: Task<Void, Never>?

    init(device: DeviceController, config: ConfigStore) {
        self.device = device
        self.config = config
    }

    // MARK: - 对外状态

    var followSystemBrightness: Bool {
        config.followSystemBrightness
    }

    /// 最近一次非 0 的镜像亮度(键面涂黑时按键点亮的目标亮度)
    var lastNonZeroMirroredPercent: Int {
        lastNonZeroMirroredBrightness
    }

    /// 设备按键活动:重置自动熄屏的空闲时钟(唤醒按键也算)
    func noteDeviceActivity() {
        lastDeviceActivityAt = Date()
    }

    // MARK: - 启动

    /// 启动亮度相关后台循环。顺序不可调换:
    /// ① 已开跟随则立即起轮询(设备连上后 1.5s 内完成首次镜像)
    /// ② 旧配置两者同开时归一化关闭自动熄屏
    /// ③ 再起空闲看门狗
    func start() {
        if config.followSystemBrightness {
            startFollowingBrightness()
        }
        // 亮度跟随与自动熄屏互斥(2026-10-15):旧配置两者同开时,启动即归一化关闭自动熄屏
        if config.followSystemBrightness, config.autoScreenOffMinutes > 0 {
            config.autoScreenOffMinutes = 0
            onLog?("亮度跟随开启中,自动熄屏已关闭(两者互斥)")
        }
        startScreenOffWatchdog()
    }

    // MARK: - 亮度

    /// 拖动滑杆调用:更新内存与设备(实时反馈),不落盘;跟随模式下手动调节自动退出跟随
    func setBrightness(_ percent: Int, userInitiated: Bool = true) {
        if userInitiated, config.followSystemBrightness {
            setFollowSystemBrightness(false)
        }
        let clamped = max(0, min(100, percent))
        config.brightness = clamped
        device.setBrightness(clamped)
        // 「滑杆 0% 时键面涂黑」(可选):手动拉到 0 视同键面熄灭;拖离 0 立即恢复
        guard userInitiated else { return }
        if clamped == 0, config.sliderZeroBlacksKeys, !device.isScreenOff {
            device.setKeysBlacked(true)
        } else if clamped > 0, device.keysBlacked, !device.isScreenOff {
            device.setKeysBlacked(false)
        }
    }

    /// 拖动结束调用:一次性落盘,避免滑杆每帧写配置文件
    func commitBrightness() {
        config.save()
    }

    // MARK: - 亮度跟随系统

    /// 开关「亮度跟随 MacBook」:开启后每 1.5s 镜像内建屏亮度(环境光自动调节即随之生效)。
    /// 与自动熄屏互斥:开启跟随即关闭自动熄屏(夜间变暗由跟随的 0% 涂黑承担)
    func setFollowSystemBrightness(_ on: Bool) {
        config.followSystemBrightness = on
        if on, config.autoScreenOffMinutes > 0 {
            config.autoScreenOffMinutes = 0
            onLog?("亮度跟随已开启,自动熄屏已关闭(两者互斥)")
        }
        on ? startFollowingBrightness() : stopFollowingBrightness()
    }

    /// ⋯菜单「自动熄屏」:与亮度跟随互斥——开启自动熄屏将关闭亮度跟随
    func setAutoScreenOffMinutes(_ minutes: Int) {
        config.autoScreenOffMinutes = minutes
        if minutes > 0, config.followSystemBrightness {
            onLog?("自动熄屏已开启,亮度跟随已关闭(两者互斥)")
            setFollowSystemBrightness(false)
        }
    }

    /// 「滑杆 0% 时键面涂黑」开关;关闭时若正处涂黑态立即按当前真实状态恢复
    func setSliderZeroBlacksKeys(_ on: Bool) {
        config.sliderZeroBlacksKeys = on
        if config.followSystemBrightness {
            lastMirroredBrightness = -1 // 强制下个轮询重同步(内屏 0 时维持涂黑,非 0 恢复)
            mirrorSystemBrightnessOnce()
        } else if device.keysBlacked, !device.isScreenOff {
            device.setKeysBlacked(false)
            setBrightness(config.brightness, userInitiated: false)
        }
    }

    // MARK: - 自动熄屏(空闲看门狗)

    private func startScreenOffWatchdog() {
        guard screenOffWatchdogTask == nil else { return }
        screenOffWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                self.autoScreenOffCheck()
            }
        }
    }

    private func autoScreenOffCheck() {
        let minutes = config.autoScreenOffMinutes
        guard minutes > 0, device.state == .running, !device.isScreenOff else { return }
        guard Date().timeIntervalSince(lastDeviceActivityAt) >= TimeInterval(minutes * 60) else { return }
        device.screenOff()
        onLog?("设备空闲超过 \(minutes) 分钟,已自动熄屏")
    }

    // MARK: - 跟随轮询

    private func startFollowingBrightness() {
        followTask?.cancel()
        lastMirroredBrightness = -1 // 重新进入跟随:强制首次下发
        lastBrightnessReadFailed = false
        onLog?("亮度跟随:开始(1.5s 轮询)")
        followTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.mirrorSystemBrightnessOnce()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        mirrorSystemBrightnessOnce()
    }

    private func stopFollowingBrightness() {
        followTask?.cancel()
        followTask = nil
        onLog?("亮度跟随:停止")
    }

    /// 读取代数:后台读取完成时已有更新一轮在采,旧结果丢弃(乱序覆盖会闪旧值)
    private var brightnessReadGeneration = 0

    private func mirrorSystemBrightnessOnce() {
        guard config.followSystemBrightness, device.state == .running, !device.isScreenOff else { return }
        // NSScreen 枚举留主线程(AppKit);IOKit/DisplayServices 读移后台——
        // legacy 兜底路径的 IOServiceGetMatchingServices 是周期采样 IO,不该钉在主线程
        let displayID = Self.builtInDisplayID()
        let generation = brightnessReadGeneration + 1
        brightnessReadGeneration = generation
        Task.detached(priority: .utility) { [weak self] in
            let percent = Self.readBrightnessPercent(displayID: displayID)
            await MainActor.run { [weak self] in
                guard let self, self.brightnessReadGeneration == generation else { return }
                self.applyMirroredBrightness(percent)
            }
        }
    }

    private func applyMirroredBrightness(_ percent: Int?) {
        guard let percent else {
            if !lastBrightnessReadFailed {
                lastBrightnessReadFailed = true
                onLog?("亮度跟随:内建屏亮度读取失败(持续静默重试)")
            }
            return
        }
        lastBrightnessReadFailed = false
        guard abs(percent - lastMirroredBrightness) >= 1 else { return }
        lastMirroredBrightness = percent
        onLog?("亮度跟随:MacBook \(percent)% → 设备")
        if percent > 0 { lastNonZeroMirroredBrightness = percent }
        if percent == 0 {
            // 内屏全黑 → 键面涂黑(设备背光 0 只是「最暗」档,非黑屏;黑像素 + 最暗背光才是真黑)
            setBrightness(0, userInitiated: false)
            device.setKeysBlacked(true)
        } else {
            device.setKeysBlacked(false)
            setBrightness(percent, userInitiated: false)
        }
    }

    // MARK: - 点亮后回涂黑

    /// 按键点亮涂黑键面后武装重涂黑定时
    func armPeekReDarken() {
        peekReDarkenTask?.cancel()
        peekReDarkenTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled else { return }
            self.reDarkenIfIdleInDark()
        }
    }

    /// 点亮 15s 后复查:暗源仍为 0(内屏 0 / 滑杆 0 涂黑态)→ 重新涂黑;内屏已变亮则跟随接管,勿动
    private func reDarkenIfIdleInDark() {
        guard !device.isScreenOff, !device.keysBlacked else { return }
        guard lastMirroredBrightness <= 0 else { return } // 跟随中且内屏非 0:键面应保持可见
        let sliderDark = config.sliderZeroBlacksKeys && config.brightness == 0
        guard lastMirroredBrightness == 0 || sliderDark else { return }
        setBrightness(0, userInitiated: false)
        device.setKeysBlacked(true)
        onLog?("亮度跟随:15s 无操作,重新涂黑")
    }

    // MARK: - 内建屏亮度读取

    /// 内建屏亮度(0–100)。读取链:DisplayServices(私有,macOS 26 实测唯一有效,
    /// 外接屏返回不支持——本就只镜像内屏)→ IOKit IODisplayConnect 旧路径(其他机型兜底)。
    /// (CoreDisplay_GetUserBrightness 在 macOS 26 恒返 1.0 假值,已弃用——假值比失败更有害)
    /// 非隔离:在并发池执行(displayServices 失败时的 legacy IOKit 路径是重 IO)
    private nonisolated static func readBrightnessPercent(displayID: UInt32?) -> Int? {
        if let percent = displayServicesBrightnessPercent(displayID: displayID) { return percent }
        return legacyDisplayBrightnessPercent()
    }

    private nonisolated static let displayServicesGetBrightness: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32)? = {
        guard let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let sym = dlsym(ds, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32).self)
    }()

    private nonisolated static func displayServicesBrightnessPercent(displayID: UInt32?) -> Int? {
        guard let get = displayServicesGetBrightness, let displayID else { return nil }
        var level: Float = -1
        guard get(displayID, &level) == 0, level.isFinite, level >= 0, level <= 1.001 else { return nil }
        return max(0, min(100, Int((level * 100).rounded())))
    }

    private static func builtInDisplayID() -> UInt32? {
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { continue }
            if CGDisplayIsBuiltin(id) != 0 { return id }
        }
        return nil
    }

    private nonisolated static func legacyDisplayBrightnessPercent() -> Int? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }
            var level: Float = -1
            if IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &level) == KERN_SUCCESS, level >= 0 {
                return max(0, min(100, Int((level * 100).rounded())))
            }
        }
        return nil
    }
}
