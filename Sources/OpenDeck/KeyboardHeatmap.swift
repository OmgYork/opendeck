import AppKit
import Foundation
import OSLog
import SQLite3
import os

// MARK: - 读数：只读 KeyAnalyze 自己的库
//
// 语义：这里不统计、不缓存、不推断——只把 App 已经算好的「今日合计」读出来。
// 约束：SQLITE_OPEN_READONLY + busy_timeout，绝不写入、不建表、不 VACUUM；
// WAL 模式下并发读安全，所以官方 App 在跑也能读。

struct HeatmapReading: Equatable {
    var today: Int64
    var lastBucketStart: Date?
    var readAt: Date
}

enum HeatmapStoreError: Error, Equatable {
    case openFailed(Int32)
    case queryFailed(String)
}

enum HeatmapStore {
    static let bundleID = "com.gouqinglin.keyanalyze"

    static var databaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("KeyAnalyze", isDirectory: true)
            .appendingPathComponent("KeyAnalyze.sqlite")
    }

    /// 今日合计 = 本地日界之后所有 15 分钟桶之和。Core Data 的时间戳是「自 2001-01-01 的秒数」。
    static func readToday(now: Date = Date()) -> Result<HeatmapReading, HeatmapStoreError> {
        var handle: OpaquePointer?
        let flag = sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard flag == SQLITE_OK, let db = handle else {
            let code = handle.map { sqlite3_errcode($0) } ?? flag
            sqlite3_close(handle)
            return .failure(.openFailed(code))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 400)

        let since = Calendar.current.startOfDay(for: now).timeIntervalSinceReferenceDate
        let sql = "SELECT COALESCE(SUM(ZCOUNT), 0), MAX(ZBUCKETSTART) FROM ZTIMEBUCKETENTITY WHERE ZBUCKETSTART >= ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return .failure(.queryFailed(String(cString: sqlite3_errmsg(db))))
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, since)

        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return .failure(.queryFailed(String(cString: sqlite3_errmsg(db))))
        }
        let total = sqlite3_column_int64(stmt, 0)
        var last: Date?
        if sqlite3_column_type(stmt, 1) != SQLITE_NULL {
            last = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 1))
        }
        return .success(HeatmapReading(today: total, lastBucketStart: last, readAt: now))
    }
}

// MARK: - 状态：优先读桥接推送，其次读它的统一日志

enum HeatmapPhase: String, Equatable {
    case normal      // App 在记录
    case attention   // 监听被中断且未自愈
    case retrying    // 刚按下重试，等待结果
    case off         // App 没在跑
    case unreadable  // 库读不到
}

struct HeatmapBridgeState {
    var raw: String
    var today: Int64?
    var updatedAt: Date?
}

enum HeatmapProbe {
    /// 与 KeyAnalyze fork 里的 Bridge 常量一致
    static let stateNotification = Notification.Name("com.gouqinglin.keyanalyze.bridge.state")
    static let commandNotification = Notification.Name("com.gouqinglin.keyanalyze.bridge.cmd")
    static let logSubsystem = "com.keyanalyze.app"

    static var bridgeStateURL: URL {
        HeatmapStore.databaseURL.deletingLastPathComponent()
            .appendingPathComponent("bridge-state.json")
    }

    static func appRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: HeatmapStore.bundleID).isEmpty
    }

    static func bridgeState() -> HeatmapBridgeState? {
        guard let data = try? Data(contentsOf: bridgeStateURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["state"] as? String else { return nil }
        let today = (obj["today"] as? NSNumber)?.int64Value
        let ts = (obj["updatedAt"] as? NSNumber)?.doubleValue
        return HeatmapBridgeState(
            raw: raw,
            today: today,
            updatedAt: ts.map { Date(timeIntervalSince1970: $0) }
        )
    }

    /// 没有桥接时的兜底：读它自己的 lifecycle 日志。
    /// `Event tap recovery failed` = 进了 .attention；`... recovered` = 自愈了。
    ///
    /// 代价控制：OSLogStore 查询会阻塞调用线程，所以结果缓存 60 秒、窗口只取 6 小时；
    /// 装了桥接的版本根本不会走到这里。
    private static var lifecycleCache: (at: Date, failed: Date?, recovered: Date?)?

    static func latestLifecycleEvent(since: Date) -> (failed: Date?, recovered: Date?) {
        if let cache = lifecycleCache, Date().timeIntervalSince(cache.at) < 60 {
            return (cache.failed, cache.recovered)
        }
        let window = max(since, Date().addingTimeInterval(-6 * 3600))
        guard let store = try? OSLogStore(scope: .system) else { return (nil, nil) }
        let position = store.position(date: window)
        let predicate = NSPredicate(format: "subsystem == %@", logSubsystem)
        guard let entries = try? store.getEntries(at: position, matching: predicate) else {
            return (nil, nil)
        }
        var failed: Date?
        var recovered: Date?
        for entry in entries {
            let message = entry.composedMessage
            if message.contains("Event tap recovery failed") { failed = entry.date }
            if message.contains("Event tap was interrupted and recovered") { recovered = entry.date }
        }
        lifecycleCache = (Date(), failed, recovered)
        return (failed, recovered)
    }

    /// 把外部读数收敛成一个相位。bridge 在先，日志在后——两者都不猜。
    static func phase(reading: Result<HeatmapReading, HeatmapStoreError>) -> HeatmapPhase {
        guard appRunning() else { return .off }
        guard case let .success(current) = reading else { return .unreadable }

        if let bridge = bridgeState(), bridge.updatedAt.map({ Date().timeIntervalSince($0) < 300 }) ?? false {
            switch bridge.raw {
            case "attention": return .attention
            case "running", "starting", "suspended", "pausing", "idle": return .normal
            default: break
            }
        }

        // 没有桥接：只看它自己的日志，且要求「失败之后库没有再增长」才算仍未恢复。
        let (failed, recovered) = latestLifecycleEvent(since: Date().addingTimeInterval(-86_400))
        guard let failedAt = failed else { return .normal }
        if let recoveredAt = recovered, recoveredAt > failedAt { return .normal }
        if let lastBucket = current.lastBucketStart, lastBucket > failedAt { return .normal }
        return .attention
    }

    static func send(command: String) {
        DistributedNotificationCenter.default().postNotificationName(
            commandNotification, object: nil,
            userInfo: ["action": command], deliverImmediately: true)
    }

    @discardableResult
    static func openApp() -> Bool {
        let url = URL(fileURLWithPath: "/Applications/KeyAnalyze.app")
        return NSWorkspace.shared.open(url)
    }
}

// MARK: - 文本：112px 里只允许一种数字格式

enum HeatmapFormat {
    static func count(_ value: Int64) -> String {
        let n = max(0, value)
        if n < 10_000 { return String(n) }
        if n < 1_000_000 {
            let k = Double(n) / 1_000
            return trim(String(format: "%.1f", k)) + "k"
        }
        let m = Double(n) / 1_000_000
        return trim(String(format: "%.1f", m)) + "m"
    }

    private static func trim(_ s: String) -> String {
        s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}
