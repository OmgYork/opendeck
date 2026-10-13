import Foundation
import Observation
import os

// MARK: - 配置数据模型(UI 层依赖此契约,字段名与类型勿改)

/// 单键动作(带关联值的枚举,Codable 自动合成)
enum KeyAction: Codable, Hashable {
    case openApp(path: String)          // .app 的 POSIX 路径
    case openURL(String)
    case runShortcut(name: String)      // macOS 快捷指令(Shortcuts)
    case shellScript(String)            // zsh -c
    case appleScript(String)
    case hotkey(keyCode: Int, modifiers: [String])  // modifiers 元素: "command"/"option"/"control"/"shift"
    case mediaKey(String)               // "playPause"/"next"/"previous"/"volumeUp"/"volumeDown"/"mute"
    // 设备控制动作(M2.5):AppModel 本地消化,不经 ActionRunner
    case previousPage                   // 上一页(循环)
    case nextPage                       // 下一页(循环)
    case gotoPage(pageID: UUID)         // 前往指定页(按 Page.id 稳定引用)
    case pageIndicator                  // 页面指示键:动态显示 "N/M"
    case brightnessUp                   // 亮度 +10
    case brightnessDown                 // 亮度 -10
    case screenOff                      // 熄屏(任意按键唤醒)
    /// 插件动作:pluginID = .sdPlugin 目录名去后缀(= manifest UUID),contextID = 实例身份
    /// (分配时生成的 UUID,持久化于此,跨重启稳定;settings 存 pluginSettings/<pluginID>.json)
    case plugin(pluginID: String, actionUUID: String, contextID: String)
}

struct KeyConfig: Codable, Hashable {
    var title: String = ""
    var backgroundColorHex: String = "#3B4252"
    var iconPath: String? = nil
    var action: KeyAction? = nil
}

struct Page: Codable, Hashable {
    /// 稳定引用 id(「前往页面」动作的锚点,删页/重排不漂移);旧配置缺省,normalize 补齐
    var id: UUID? = nil
    var name: String = "默认页面"
    var keys: [KeyConfig] = Array(repeating: KeyConfig(), count: 15)  // index = row*5+column
}

/// 亮度胶囊布局参数(pt):调参模式实时可调
struct LayoutParams: Codable, Equatable {
    var lead: CGFloat = 10   // 胶囊左边距
    var gap: CGFloat = 6     // 太阳 ↔ 滑杆间距
    var slot: CGFloat = 124  // 滑杆/自适应共用槽宽
    var trail: CGFloat = 12  // 胶囊右边距(14 = 轨道与胶囊右端同心)

    static let defaultValue = LayoutParams()
    /// 轨道右端与胶囊右端同心所需的右边距:轨道视觉终点 = 槽位终点 + (NEG-内缩)/2,
    /// 同心要求 = 胶囊右缘 -(胶囊半径16 - 轨道半径3)
    static var concentricTrail: CGFloat { 14 }
}

struct AppConfig: Codable {
    var pages: [Page] = [Page()]
    var currentPageIndex: Int = 0
    var brightness: Int = 80
    /// 亮度跟随 MacBook(环境光自动调节);可选保证旧配置文件缺键可解码
    var followSystemBrightness: Bool? = false
    var layout: LayoutParams? = nil
}

// MARK: - 配置存储

/// 配置持久化:JSON 读写 + 面向 UI 的便捷入口。
/// 全部状态收敛在主线程;save() 走原子写,任何时刻磁盘上都是完整文件,
/// 崩溃/断电也不会留下半截 JSON。
@MainActor
@Observable
final class ConfigStore {
    private(set) var config: AppConfig

    private static let logger = Logger(subsystem: "opendeck", category: "config")
    /// 293V3 键板固定 15 键(5×3),index = row*5+column
    private static let keyCount = 15
    /// 默认键面底色(Nord 风格调色板),按键序轮转
    private static let defaultPalette = [
        "#BF616A", "#D08770", "#EBCB8B", "#A3BE8C", "#88C0D0",
        "#5E81AC", "#B48EAD", "#8FBCBB", "#4C566A",
    ]
    /// ~/Library/Application Support/OpenDeck/config.json
    /// 目录链的创建交给 ensureDirectory(非抛出的 urls(for:in:) 只做定位)
    private static let configFileURL: URL = {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("OpenDeck/config.json")
    }()

    init() {
        if var loaded = Self.loadConfiguration() {
            Self.normalize(&loaded)
            config = loaded
        } else {
            config = Self.defaultConfig()
            // 首次启动(或配置损坏)立即落盘,保证后续启动读到的是真实文件
            // normalize 补页面 id 等派生字段,与读盘路径行为一致
            Self.normalize(&config)
            save()
        }
    }

    // MARK: 便捷读写

    /// 亮度胶囊布局参数(缺省 = 内置默认);拖动调参后 save() 持久化
    var layout: LayoutParams {
        get { config.layout ?? .defaultValue }
        set {
            config.layout = newValue
            save()
        }
    }

    /// 当前页。索引越界时读取返回空白页兜底;写入立即持久化,
    /// 使「整页编辑」与 updateKey 一样不丢数据。
    var currentPage: Page {
        get {
            guard config.pages.indices.contains(config.currentPageIndex) else { return Page() }
            return config.pages[config.currentPageIndex]
        }
        set {
            guard config.pages.indices.contains(config.currentPageIndex) else { return }
            config.pages[config.currentPageIndex] = newValue
            save()
        }
    }

    /// 当前页索引(M1 单页恒为 0;暴露转发访问器,UI 的页面切换反应在 M2 生效)
    var currentPageIndex: Int {
        get { config.currentPageIndex }
        set {
            guard config.pages.indices.contains(newValue) else { return }
            config.currentPageIndex = newValue
            save()
        }
    }

    // MARK: 页面管理(M2.5 多页面)

    var pageCount: Int { config.pages.count }

    func indexOfPage(id: UUID) -> Int? {
        config.pages.firstIndex { $0.id == id }
    }

    /// 切换当前页(索引版,越界忽略)
    func setCurrentPageIndex(_ index: Int) {
        currentPageIndex = index
    }

    /// 新增页面(自动命名「页面 N」),返回其 id
    @discardableResult
    func addPage() -> UUID {
        let id = UUID()
        config.pages.append(Page(
            id: id,
            name: "页面 \(config.pages.count + 1)",
            keys: Array(repeating: KeyConfig(), count: Self.keyCount)
        ))
        save()
        return id
    }

    func renamePage(id: UUID, to newName: String) {
        guard let index = indexOfPage(id: id) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        config.pages[index].name = trimmed
        save()
    }

    /// 删除页面(至少保留 1 页);若删的是当前页,当前页回退到第 0 页
    func deletePage(id: UUID) {
        guard config.pages.count > 1, let index = indexOfPage(id: id) else { return }
        config.pages.remove(at: index)
        if !config.pages.indices.contains(config.currentPageIndex) {
            config.currentPageIndex = 0
        }
        save()
    }

    /// 亮度跟随 MacBook 的开关(nil 视为关)
    var followSystemBrightness: Bool {
        get { config.followSystemBrightness ?? false }
        set {
            config.followSystemBrightness = newValue
            save()
        }
    }

    /// 亮度的非落盘读写:拖动滑杆期间高频更新,仅内存;松手由调用方 save()
    var brightness: Int {
        get { config.brightness }
        set { config.brightness = max(0, min(100, newValue)) }
    }

    /// 越界时返回空白键配置(手改文件兜底),不让 UI 网格崩溃
    func keyConfig(at index: Int) -> KeyConfig {
        let keys = currentPage.keys
        guard keys.indices.contains(index) else { return KeyConfig() }
        return keys[index]
    }

    /// 更新单键并自动落盘
    func updateKey(_ key: KeyConfig, at index: Int) {
        guard config.pages.indices.contains(config.currentPageIndex),
              config.pages[config.currentPageIndex].keys.indices.contains(index)
        else {
            Self.logger.error("updateKey 索引越界:\(index)")
            return
        }
        config.pages[config.currentPageIndex].keys[index] = key
        save()
    }

    // MARK: 持久化

    /// 原子写盘:先写临时文件再换名
    func save() {
        do {
            let encoder = JSONEncoder()
            // 人工可读可改:调试期直接手编辑 config.json 是常见操作
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try Self.ensureDirectory()
            try data.write(to: Self.configFileURL, options: .atomic)
        } catch {
            Self.logger.error("配置保存失败:\(error, privacy: .public)")
        }
    }

    // MARK: 私有

    /// 读取失败(缺失/损坏/结构不合法)返回 nil,由调用方回退默认配置
    private static func loadConfiguration() -> AppConfig? {
        let url = configFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            logger.error("配置文件无法解析,将回退默认配置:\(error, privacy: .public)")
            return nil
        }
    }

    /// 数据完整性兜底:UI 按 18 键网格与固定页索引工作,
    /// 手改/旧版文件可能页为空、索引越界、键数不符,载入时统一拉回合法形状
    private static func normalize(_ config: inout AppConfig) {
        if config.pages.isEmpty { config.pages = [Page()] }
        if !config.pages.indices.contains(config.currentPageIndex) { config.currentPageIndex = 0 }
        for pageIndex in config.pages.indices {
            if config.pages[pageIndex].id == nil { config.pages[pageIndex].id = UUID() }
            let count = config.pages[pageIndex].keys.count
            if count < keyCount {
                config.pages[pageIndex].keys += Array(repeating: KeyConfig(), count: keyCount - count)
            } else if count > keyCount {
                config.pages[pageIndex].keys.removeLast(count - keyCount)
            }
        }
    }

    private static func defaultConfig() -> AppConfig {
        var keys = [KeyConfig]()
        keys.reserveCapacity(keyCount)
        for index in 0..<keyCount {
            // 5×3 全主键,按阅读顺序编 1–15
            keys.append(KeyConfig(
                title: "\(index + 1)",
                backgroundColorHex: defaultPalette[index % defaultPalette.count]
            ))
        }
        return AppConfig(pages: [Page(name: "默认页面", keys: keys)])
    }

    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: configFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
