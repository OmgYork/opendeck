import Darwin
import Foundation

/// 单实例守卫:对锁文件取 flock(2) 排他锁(LOCK_NB 非阻塞)。
/// 背景:swift run 调试实例与 dist 生产实例并存时互不感知,两份「内存即真相」
/// 各自整文件覆盖盘上 config/pluginSettings,后写者把先写者的变更无痕抹掉
/// (HANDOFF §6.10 数据完整性架构的前提「唯一写入者」被双实例打破)。
/// 不用 fcntl(F_SETLK):POSIX 记录锁按进程判定,同进程二次加锁会静默替换而非冲突,
/// 测试无法覆盖;flock 按打开文件描述符判定,同/跨进程二次获取都正确报冲突。
/// 进程存活期间锁自动持有,崩溃/被杀由内核释放,无陈锁问题。
nonisolated final class InstanceLock: @unchecked Sendable {
    enum AcquireResult {
        /// 锁已持有(持有返回的实例即可,deinit 释放)
        case acquired(InstanceLock)
        /// 已有实例持锁
        case locked
        /// 锁文件不可用(目录不可写等):放行启动但不设防——防御失效好过误伤正常启动
        case unavailable
    }

    private let fileDescriptor: Int32
    private var released = false
    let path: String

    private init(path: String, fileDescriptor: Int32) {
        self.path = path
        self.fileDescriptor = fileDescriptor
    }

    /// 显式释放(测试与早退路径用;正常持有到进程退出,deinit 兜底)
    func release() {
        guard fileDescriptor >= 0, !released else { return }
        released = true
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    static func acquire(path: String) -> AcquireResult {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { return .unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return .locked // EWOULDBLOCK = 另一实例(或本进程另一份描述符)持锁
        }
        return .acquired(InstanceLock(path: path, fileDescriptor: fd))
    }

    deinit {
        release()
    }
}
