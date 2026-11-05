import Foundation
import Testing
@testable import OpenDeck

/// 单实例守卫(§6.26):双实例并存会互相整文件覆盖配置(§6.10「唯一写入者」前提)。
/// fcntl 排程锁的持有/竞争/释放三态契约。
@Suite("InstanceLock 单实例守卫")
struct InstanceLockTests {
    @Test("首次获取成功,并发获取 locked,释放后可再获取")
    func acquireCompeteAndRelease() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-lock-\(UUID().uuidString)").path

        guard case .acquired(let first) = InstanceLock.acquire(path: path) else {
            Issue.record("首次获取应成功")
            return
        }
        // 第二把锁:被占
        guard case .locked = InstanceLock.acquire(path: path) else {
            Issue.record("并发获取应报 locked")
            return
        }
        // 释放后可重新获取
        first.release()
        guard case .acquired = InstanceLock.acquire(path: path) else {
            Issue.record("释放后应可再获取")
            return
        }
    }

    @Test("不可写目录返回 unavailable,不误伤启动")
    func unavailableWhenPathIsFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-lockfile-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file) // 锁路径落在一个文件下面:open 必败
        let result = InstanceLock.acquire(path: file.appendingPathComponent("sub/lock").path)
        guard case .unavailable = result else {
            Issue.record("不可写路径应报 unavailable,实际: \(result)")
            return
        }
    }
}
