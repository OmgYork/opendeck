// @preconcurrency:CFRunLoopPerformBlock 的 block 参数未标 Sendable,捕获 CFRunLoop
// 等跨线程值时会产生噪音诊断;捕获内容经锁/信号量保护(见 stop 注释)
@preconcurrency import Foundation
@preconcurrency import IOKit
@preconcurrency import IOKit.hid

/// HID 传输层:设备发现/热插拔/串行写/输入回调/心跳。
///
/// 线程模型:
/// - IOHIDManager 与设备回调在专属 runloop 线程
/// - 所有写入进串行队列(旧平台要求命令串行,队列天然保序)
/// - 共享属性用 `lock` 保护
///
/// 回调闭包在任意线程触发,实现方自行跳线程(如 Task { @MainActor in … })。
/// 对 DeviceController 只暴露 `DeviceTransport` 那层(见 DeviceTransport.swift)。
final class HIDTransport: @unchecked Sendable, DeviceTransport {
    private final class CallbackBox {
        weak var transport: HIDTransport?
        init(transport: HIDTransport) { self.transport = transport }
    }

    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "opendeck.hid.write")
    private let bootSemaphore = DispatchSemaphore(value: 0)

    private var manager: IOHIDManager?
    private var runLoop: CFRunLoop?
    private var device: IOHIDDevice?
    private var callbackBox: CallbackBox?
    /// 输入报告缓冲:注册期间指针必须保持有效,手动分配管理
    private var inputBuffer: UnsafeMutablePointer<UInt8>?
    private var inputBufferLength = 0
    private var heartbeatTimer: DispatchSourceTimer?
    private var started = false

    var onReport: (@Sendable ([UInt8]) -> Void)?
    var onDeviceAttached: (@Sendable () -> Void)?
    var onDeviceDetached: (@Sendable () -> Void)?
    var onLog: (@Sendable (String) -> Void)?
    /// 每次成功写入的报文追踪(诊断用;在写线程触发)。
    /// 运行中会被设置(harness 诊断),读写都走锁——无锁直赋会与写线程构成数据竞争
    private var onWrite: (@Sendable ([UInt8]) -> Void)?

    /// 设置写入追踪回调(任意时刻调用安全)
    func setWriteTrace(_ trace: (@Sendable ([UInt8]) -> Void)?) {
        lock.lock()
        onWrite = trace
        lock.unlock()
    }

    // MARK: - 生命周期

    func start() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        let box = CallbackBox(transport: self)
        callbackBox = box
        let context = Unmanaged.passUnretained(box).toOpaque()

        // 匹配所有 HID 设备,回调内按已知 VID/PID 过滤(293S 系列 PID 随批次变化)
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, Self.matchingCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, Self.removalCallback, context)
        lock.unlock()

        Thread.detachNewThread { [weak self] in
            guard let self else { return }
            guard let rl = CFRunLoopGetCurrent() else { return }
            let mgr = self.lock.withLock { () -> IOHIDManager? in
                self.runLoop = rl
                return self.manager
            }
            guard let mgr else { return }
            IOHIDManagerScheduleWithRunLoop(mgr, rl, CFRunLoopMode.defaultMode.rawValue)
            self.bootSemaphore.signal()
            CFRunLoopRun()
        }
        _ = bootSemaphore.wait(timeout: .now() + 2)
    }

    func stop() {
        lock.lock()
        guard started else {
            lock.unlock()
            return
        }
        started = false
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        let dev = device
        let mgr = manager
        let rl = runLoop
        lock.unlock()

        guard let rl else { return } // start 从未完成调度:无 runloop 可串行化,状态已清

        // 关停全部搬到 runloop 线程串行执行:与 attach/detach/report 回调同一线程排队,
        // 一次性消除三组竞态——① stop 与 handlePossibleAttach 并发会留下未关句柄/复活心跳;
        // ② 此前在调用线程 deallocate 输入缓冲,runloop 里迟到的 reportCallback 仍持该指针
        //    (use-after-free);③ 注销与在途回调交错。
        let finished = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(rl, "kCFRunLoopDefaultMode" as CFString) { [weak self] in
            defer { finished.signal() }
            guard let self else { return }
            // 与在途写保序:close 排到串行写队列尾(设备固件无响应时 IOHIDDeviceClose
            // 可能永久阻塞,不能在 runloop 线程同步等)
            if let dev {
                self.writeQueue.async {
                    IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
                    IOHIDDeviceUnscheduleFromRunLoop(dev, rl, CFRunLoopMode.defaultMode.rawValue as CFString)
                }
            }
            if let mgr {
                IOHIDManagerRegisterDeviceMatchingCallback(mgr, nil, nil)
                IOHIDManagerRegisterDeviceRemovalCallback(mgr, nil, nil)
                IOHIDManagerUnscheduleFromRunLoop(mgr, rl, CFRunLoopMode.defaultMode.rawValue as CFString)
            }
            // 此刻就在 runloop 线程,绝无并发 reportCallback:释放输入缓冲安全
            self.lock.lock()
            self.inputBuffer?.deallocate()
            self.inputBuffer = nil
            self.inputBufferLength = 0
            self.device = nil
            self.manager = nil
            self.callbackBox = nil
            self.runLoop = nil
            self.lock.unlock()
            // 在 perform 末尾停 runloop:保证清理先于退出,CFRunLoopStop 不会把本块丢掉
            CFRunLoopStop(rl)
        }
        CFRunLoopWakeUp(rl)
        // 有界等待:runloop 已死的极端情形不拖死调用方;超时则保守放弃缓冲释放
        // (泄漏一块 512B 缓冲换不崩,此路径只在进程退出时走,可接受)
        if finished.wait(timeout: .now() + 2) == .timedOut {
            onLog?("传输层停止超时(runloop 未响应),已放弃缓冲释放")
        }
    }

    // MARK: - 写入(串行队列,保序)

    func sendCommand(_ cmd: [UInt8]) {
        let packet = StreamDock293S.commandPacket(cmd)
        writeQueue.async { [weak self] in
            self?.performWrite(packet)
        }
    }

    func sendRaw(_ bytes: [UInt8]) {
        writeQueue.async { [weak self] in
            self?.performWrite(bytes)
        }
    }

    private func performWrite(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        // device 与 onWrite 同锁读取:onWrite 可在运行中被设置,无锁读是数据竞争
        let (dev, trace) = lock.withLock { (device, onWrite) }
        guard let dev else { return }
        let kr = bytes.withUnsafeBufferPointer { buf -> IOReturn in
            guard let base = buf.baseAddress else { return kIOReturnError }
            return IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x00, base, buf.count)
        }
        if kr != kIOReturnSuccess {
            onLog?(String(format: "写入失败 0x%08x(%d 字节)", kr, bytes.count))
        } else {
            trace?(bytes)
        }
    }

    // MARK: - 设备接入/移除(均在 runloop 线程)

    private func handlePossibleAttach(_ dev: IOHIDDevice) {
        let vid = (IOHIDDeviceGetProperty(dev, kIOHIDVendorIDKey as CFString) as? Int) ?? -1
        let pid = (IOHIDDeviceGetProperty(dev, kIOHIDProductIDKey as CFString) as? Int) ?? -1
        guard StreamDock293S.isKnownUSBId(vendorId: vid, productId: pid) else { return }

        lock.lock()
        guard started, device == nil else {
            lock.unlock()
            return
        }
        let kr = IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        guard kr == kIOReturnSuccess else {
            lock.unlock()
            onLog?(String(format: "打开设备失败 0x%08x(可能被占用)", kr))
            return
        }
        let maxInput = (IOHIDDeviceGetProperty(dev, "MaxInputReportSize" as CFString) as? Int) ?? 512
        let bufferLength = max(1, maxInput) + 1
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferLength)
        buffer.initialize(repeating: 0, count: bufferLength)

        IOHIDDeviceScheduleWithRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        if let box = callbackBox {
            IOHIDDeviceRegisterInputReportCallback(
                dev, buffer, bufferLength, Self.reportCallback, Unmanaged.passUnretained(box).toOpaque()
            )
        }
        device = dev
        inputBuffer = buffer
        inputBufferLength = bufferLength
        lock.unlock()

        startHeartbeat()
        onDeviceAttached?()
    }

    private func handleDetach(_ dev: IOHIDDevice) {
        lock.lock()
        let isCurrent: Bool
        if let current = device {
            isCurrent = CFEqual(current, dev)
        } else {
            isCurrent = false
        }
        guard isCurrent else {
            lock.unlock()
            return
        }
        IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDDeviceUnscheduleFromRunLoop(dev, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        inputBuffer?.deallocate()
        inputBuffer = nil
        inputBufferLength = 0
        device = nil
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
        lock.unlock()

        onDeviceDetached?()
    }

    // MARK: - 心跳

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: writeQueue)
        timer.schedule(
            deadline: .now() + StreamDock293S.heartbeatInterval,
            repeating: StreamDock293S.heartbeatInterval
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.lock.withLock({ self.device }) != nil else {
                self.onLog?("心跳 tick:设备句柄为空,跳过")
                return
            }
            self.performWrite(StreamDock293S.commandPacket(StreamDock293S.heartbeatCommand))
            self.onLog?("心跳 tick:CONNECT 已入队")
        }
        timer.resume()
        lock.lock()
        heartbeatTimer?.cancel()
        heartbeatTimer = timer
        lock.unlock()
    }

    // MARK: - C 回调(IOHIDDeviceCallback / IOHIDReportCallback 均为 C 函数指针,经 context 传 box)

    private static let matchingCallback: IOHIDDeviceCallback = { context, _, _, dev in
        guard let context else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
        box.transport?.handlePossibleAttach(dev)
    }

    private static let removalCallback: IOHIDDeviceCallback = { context, _, _, dev in
        guard let context else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
        box.transport?.handleDetach(dev)
    }

    private static let reportCallback: IOHIDReportCallback = { context, _, _, _, _, report, reportLength in
        guard let context, reportLength > 0 else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue()
        let bytes = [UInt8](UnsafeBufferPointer(start: report, count: reportLength))
        box.transport?.onReport?(bytes)
    }
}
