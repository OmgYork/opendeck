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
    case previousPage                   // 上一页(场景内循环)
    case nextPage                       // 下一页(场景内循环)
    case previousScene                  // 上一场景(横向)
    case nextScene                      // 下一场景(横向)
    case gotoPage(pageID: UUID)         // 前往指定页(按 Page.id 稳定引用)
    case pageIndicator                  // 页面指示键:动态显示 "N/M"
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
    /// 前台应用自动切换(场景联动):绑定到本页的应用 bundle id,最多 3 个,空串=未设
    var boundAppBundleIDs: [String]? = nil
    /// 所属场景(同名的页归为一个场景;垂直手势在场景内翻页,水平手势切场景)
    var sceneName: String? = nil
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
    /// 场景联动的默认页:前台应用无绑定时显示此页(可选,旧配置缺省)
    var defaultPageID: UUID? = nil
    /// 自动熄屏:设备空闲(无按键)达到该分钟数后自动熄屏;0/缺省 = 关
    var autoScreenOffMinutes: Int? = nil
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

    /// 新增页面(自动命名「页面 N」,加入当前场景),返回其 id
    @discardableResult
    func addPage() -> UUID {
        let id = UUID()
        config.pages.append(Page(
            id: id,
            name: "页面 \(config.pages.count + 1)",
            keys: Array(repeating: KeyConfig(), count: Self.keyCount),
            sceneName: currentSceneName
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
        if config.defaultPageID == id {
            config.defaultPageID = nil
        }
        save()
    }

    /// 复制页面(沿用键位/绑定,新 id,名称加「副本」),插到原页之后
    @discardableResult
    func duplicatePage(id: UUID) -> UUID? {
        guard let index = indexOfPage(id: id) else { return nil }
        var copy = config.pages[index]
        copy.id = UUID()
        copy.name = config.pages[index].name + " 副本"
        config.pages.insert(copy, at: index + 1)
        save()
        return copy.id
    }

    // MARK: 场景联动(前台应用自动切换)

    func page(id: UUID) -> Page? {
        config.pages.first { $0.id == id }
    }

    /// 绑定了指定前台应用的页( nil = 无绑定)
    func pageBoundToApp(_ bundleID: String) -> Page? {
        config.pages.first { $0.boundAppBundleIDs?.contains(bundleID) == true }
    }

    /// 读取某页第 slot 个应用绑定(0-based,最多 3;nil = 未设)
    func pageAppBinding(id: UUID, slot: Int) -> String? {
        guard let page = page(id: id), let bindings = page.boundAppBundleIDs,
              slot < bindings.count, !bindings[slot].isEmpty
        else { return nil }
        return bindings[slot]
    }

    /// 设置某页第 slot 个应用绑定;尾部空槽自动收紧,全空则置 nil
    func setPageAppBinding(id: UUID, slot: Int, bundleID: String?) {
        guard let index = indexOfPage(id: id) else { return }
        var bindings = config.pages[index].boundAppBundleIDs ?? []
        while bindings.count < 3 { bindings.append("") }
        bindings[slot] = bundleID ?? ""
        while bindings.last == "" { bindings.removeLast() }
        config.pages[index].boundAppBundleIDs = bindings.isEmpty ? nil : bindings
        save()
    }

    /// 默认页(前台应用无绑定时显示);nil = 不启用
    func setDefaultPage(id: UUID?) {
        config.defaultPageID = id
        save()
    }

    // MARK: 场景分组(两级手势导航)

    private func sceneName(of page: Page) -> String {
        page.sceneName ?? "默认场景"
    }

    /// 场景名列表(按首次出现顺序,去重)
    var sceneNames: [String] {
        var seen = Set<String>()
        var names: [String] = []
        for page in config.pages {
            let name = sceneName(of: page)
            if !seen.contains(name) {
                seen.insert(name)
                names.append(name)
            }
        }
        return names
    }

    var currentSceneName: String? {
        guard config.pages.indices.contains(config.currentPageIndex) else { return nil }
        return sceneName(of: config.pages[config.currentPageIndex])
    }

    /// 场景内第 position 页(0-based)的 id(圆点指示器点击直达用)
    func pageIDInScene(position: Int) -> UUID? {
        guard let scene = currentSceneName else { return nil }
        let indices = config.pages.indices.filter { sceneName(of: config.pages[$0]) == scene }
        guard indices.indices.contains(position) else { return nil }
        return config.pages[indices[position]].id
    }

    /// 当前页在场景内的序号(0-based)与场景内页数(页面指示键用)
    var currentPagePositionInScene: (position: Int, count: Int)? {
        guard config.pages.indices.contains(config.currentPageIndex) else { return nil }
        let scene = sceneName(of: config.pages[config.currentPageIndex])
        let indices = config.pages.indices.filter { sceneName(of: config.pages[$0]) == scene }
        guard let position = indices.firstIndex(of: config.currentPageIndex) else { return nil }
        return (position, indices.count)
    }

    /// 页面切换目标索引:withinScene=true 在当前场景内循环翻页;false 在场景列表间循环(切到目标场景第一页)
    func targetPageIndex(offset: Int, withinScene: Bool) -> Int? {
        guard config.pages.indices.contains(config.currentPageIndex) else { return nil }
        let pages = config.pages
        let currentIndex = config.currentPageIndex
        let cycle = { (value: Int, modulus: Int) -> Int in ((value % modulus) + modulus) % modulus }
        if withinScene {
            let scene = sceneName(of: pages[currentIndex])
            let indices = pages.indices.filter { sceneName(of: pages[$0]) == scene }
            guard indices.count > 1, let position = indices.firstIndex(of: currentIndex) else { return nil }
            return indices[cycle(position + offset, indices.count)]
        }
        let scenes = sceneNames
        guard scenes.count > 1, let scenePosition = scenes.firstIndex(of: sceneName(of: pages[currentIndex])) else { return nil }
        let targetScene = scenes[cycle(scenePosition + offset, scenes.count)]
        return pages.firstIndex { sceneName(of: $0) == targetScene }
    }

    /// 设置页面所属场景(空名归入「默认场景」)
    func setSceneName(id: UUID, to name: String) {
        guard let index = indexOfPage(id: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        config.pages[index].sceneName = trimmed.isEmpty ? "默认场景" : trimmed
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

    /// 自动熄屏分钟数(0 = 关);菜单直选,立即落盘
    var autoScreenOffMinutes: Int {
        get { config.autoScreenOffMinutes ?? 0 }
        set {
            config.autoScreenOffMinutes = max(0, newValue)
            save()
        }
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
