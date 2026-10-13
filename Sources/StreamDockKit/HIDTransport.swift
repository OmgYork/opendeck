import Foundation
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
final class HIDTransport: @unchecked Sendable {
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
    /// 每次成功写入的报文追踪(诊断用;在写线程触发)
    var onWrite: (@Sendable ([UInt8]) -> Void)?

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

        if let dev = device {
            // 与已入队的写命令保序:关闭动作排到串行队列尾执行。
            // 有界等待:设备固件无响应时 IOHIDDeviceClose 可能永久阻塞,不能拖死调用方
            // (此 SDK 中注销回调的参数非 Optional,无法传 nil;IOHIDDeviceClose 即注销一切)
            let closed = DispatchSemaphore(value: 0)
            writeQueue.async { [weak self] in
                guard let self else { return }
                IOHIDDeviceClose(dev, IOOptionBits(kIOHIDOptionsTypeNone))
                if let rl = self.lock.withLock({ self.runLoop }) {
                    IOHIDDeviceUnscheduleFromRunLoop(dev, rl, CFRunLoopMode.defaultMode.rawValue)
                }
                closed.signal()
            }
            _ = closed.wait(timeout: .now() + 1)
        }
        if let manager, let runLoop {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
            CFRunLoopStop(runLoop)
        }
        inputBuffer?.deallocate()
        inputBuffer = nil
        inputBufferLength = 0
        device = nil
        manager = nil
        runLoop = nil
        callbackBox = nil
        lock.unlock()
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
        let dev = lock.withLock { device }
        guard let dev else { return }
        let kr = bytes.withUnsafeBufferPointer { buf -> IOReturn in
            guard let base = buf.baseAddress else { return kIOReturnError }
            return IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0x00, base, buf.count)
        }
        if kr != kIOReturnSuccess {
            onLog?(String(format: "写入失败 0x%08x(%d 字节)", kr, bytes.count))
        } else {
            onWrite?(bytes)
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
            guard self.lock.withLock({ self.device }) != nil else { return }
            self.performWrite(StreamDock293S.commandPacket(StreamDock293S.heartbeatCommand))
        }
        timer.resume()
        lock.lock()
        heartbeatTimer?.cancel()
        heartbeatTimer = timer
        lock.unlock()
    }

    /// 暂停心跳(熄屏):设备 ≤8s 收不到 CONNECT 会自重启进入黑屏待机;输入上报是否存活由探针实测
    func suspendHeartbeat() {
        writeQueue.async { [weak self] in
            self?.heartbeatTimer?.cancel()
            self?.lock.withLock { self?.heartbeatTimer = nil }
        }
    }

    /// 恢复心跳(唤醒);重复调用无副作用
    func resumeHeartbeat() {
        writeQueue.async { [weak self] in
            guard let self, self.heartbeatTimer == nil else { return }
            self.startHeartbeat()
        }
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
