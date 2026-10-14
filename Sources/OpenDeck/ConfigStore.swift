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
    case gotoPage(pageID: UUID)         // 前往指定页(按 Page.id 稳定引用;选择器已移除,兼容旧配置)
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

/// 场景内的一页(15 键)。场景的第一页之外即「圆点」——内容超过一屏时的延伸页。
struct Page: Codable, Hashable {
    /// 稳定引用 id(「前往页面」动作兼容用);normalize 补齐
    var id: UUID? = nil
    var keys: [KeyConfig] = Array(repeating: KeyConfig(), count: 15)  // index = row*5+column
}

/// 场景:页面芯片栏的一枚芯片。内含若干页(≥1);第一页为主页,其余为「圆点」延伸页。
/// 场景联动(前台应用自动切换)的应用绑定挂在场景级。
struct DeckScene: Codable, Hashable {
    /// 稳定引用 id(场景联动/默认场景的锚点);normalize 补齐
    var id: UUID? = nil
    var name: String = "场景"
    /// 绑定到本场景的应用 bundle id,最多 3 个,空串=未设
    var boundAppBundleIDs: [String]? = nil
    var pages: [Page] = [Page()]
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

/// 编辑器导航区样式(classic = 现行「场景芯片栏 + 页点胶囊」)
enum NavigationStyle: String, Codable, CaseIterable {
    case classic        // 场景芯片栏(下方)+ 页点胶囊(右缘悬浮)
    case matrixBelow    // 矩阵·下置:芯片=列头,页点纵排成列(全景地图,任一格直达)
    case matrixRail     // 矩阵·右缘:底座旁挂轨(转置:场景=行,页点横排)
}

struct AppConfig: Codable {
    var scenes: [DeckScene] = [DeckScene()]
    var currentSceneIndex: Int = 0
    var currentPageIndex: Int = 0    // 场景内页索引
    var brightness: Int = 80
    /// 亮度跟随 MacBook(环境光自动调节);可选保证旧配置文件缺键可解码
    var followSystemBrightness: Bool? = false
    var layout: LayoutParams? = nil
    /// 场景联动的默认场景:前台应用无绑定时显示此场景(可选,旧配置缺省)
    var defaultSceneID: UUID? = nil
    /// 自动熄屏:设备空闲(无按键)达到该分钟数后自动熄屏;0/缺省 = 关
    var autoScreenOffMinutes: Int? = nil
    /// 编辑器导航样式(nil = 经典,旧配置缺键可解码)
    var navStyle: NavigationStyle? = nil
    /// 亮度滑杆拖到 0% 时键面涂黑(而不只是背光最暗);nil/缺省 = 关
    var sliderZeroBlacksKeys: Bool? = nil
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
            // normalize 补场景/页面 id 等派生字段,与读盘路径行为一致
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

    // MARK: 当前场景/页面访问

    var sceneCount: Int { config.scenes.count }

    /// 当前场景(索引越界时读取返回空白场景兜底)
    var currentScene: DeckScene {
        get {
            guard config.scenes.indices.contains(config.currentSceneIndex) else { return DeckScene() }
            return config.scenes[config.currentSceneIndex]
        }
        set {
            guard config.scenes.indices.contains(config.currentSceneIndex) else { return }
            config.scenes[config.currentSceneIndex] = newValue
            save()
        }
    }

    var currentSceneIndex: Int {
        get { config.currentSceneIndex }
        set {
            guard config.scenes.indices.contains(newValue) else { return }
            config.currentSceneIndex = newValue
            config.currentPageIndex = 0 // 切场景回到该场景第一页
            save()
        }
    }

    var currentSceneID: UUID? { currentScene.id }

    /// 当前场景内的页数(= 圆点数;1 页时圆点指示器隐藏)
    var pageCountInCurrentScene: Int { currentScene.pages.count }

    /// 当前场景内的页序号(0-based)
    var currentPageIndex: Int {
        get { config.currentPageIndex }
        set {
            guard currentScene.pages.indices.contains(newValue) else { return }
            config.currentPageIndex = newValue
            save()
        }
    }

    /// 越界时返回空白键配置(手改文件兜底),不让 UI 网格崩溃
    func keyConfig(at index: Int) -> KeyConfig {
        let scene = currentScene
        guard scene.pages.indices.contains(config.currentPageIndex) else { return KeyConfig() }
        let keys = scene.pages[config.currentPageIndex].keys
        guard keys.indices.contains(index) else { return KeyConfig() }
        return keys[index]
    }

    /// 更新单键并自动落盘
    func updateKey(_ key: KeyConfig, at index: Int) {
        guard config.scenes.indices.contains(config.currentSceneIndex),
              config.scenes[config.currentSceneIndex].pages.indices.contains(config.currentPageIndex),
              config.scenes[config.currentSceneIndex].pages[config.currentPageIndex].keys.indices.contains(index)
        else {
            Self.logger.error("updateKey 索引越界:\(index)")
            return
        }
        config.scenes[config.currentSceneIndex].pages[config.currentPageIndex].keys[index] = key
        save()
    }

    // MARK: 场景管理

    func indexOfScene(id: UUID) -> Int? {
        config.scenes.firstIndex { $0.id == id }
    }

    func scene(id: UUID) -> DeckScene? {
        config.scenes.first { $0.id == id }
    }

    /// 切换当前场景(索引版,越界忽略;页索引复位为该场景第一页)
    func setCurrentSceneIndex(_ index: Int) {
        currentSceneIndex = index
    }

    /// 新增场景(自动命名「场景 N」,1 页),返回其 id
    @discardableResult
    func addScene() -> UUID {
        let id = UUID()
        config.scenes.append(DeckScene(
            id: id,
            name: "场景 \(config.scenes.count + 1)",
            pages: [Page(keys: Array(repeating: KeyConfig(), count: Self.keyCount))]
        ))
        save()
        return id
    }

    func renameScene(id: UUID, to newName: String) {
        guard let index = indexOfScene(id: id) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        config.scenes[index].name = trimmed
        save()
    }

    /// 删除场景(至少保留 1 个);若删的是当前场景,回退到第 0 个
    func deleteScene(id: UUID) {
        guard config.scenes.count > 1, let index = indexOfScene(id: id) else { return }
        config.scenes.remove(at: index)
        if !config.scenes.indices.contains(config.currentSceneIndex) {
            config.currentSceneIndex = 0
        }
        config.currentPageIndex = 0
        if config.defaultSceneID == id {
            config.defaultSceneID = nil
        }
        save()
    }

    /// 复制场景(沿用全部页与绑定,新 id,名称加「副本」),插到原场景之后
    @discardableResult
    func duplicateScene(id: UUID) -> UUID? {
        guard let index = indexOfScene(id: id) else { return nil }
        var copy = config.scenes[index]
        copy.id = UUID()
        copy.name = config.scenes[index].name + " 副本"
        config.scenes.insert(copy, at: index + 1)
        save()
        return copy.id
    }

    /// 给场景追加一页(圆点 +1),返回其 id
    @discardableResult
    func addPage(toSceneIndex sceneIndex: Int) -> UUID? {
        guard config.scenes.indices.contains(sceneIndex) else { return nil }
        let id = UUID()
        config.scenes[sceneIndex].pages.append(Page(id: id, keys: Array(repeating: KeyConfig(), count: Self.keyCount)))
        save()
        return id
    }

    /// 删除场景内的一页(每场景至少保留 1 页);索引相应收紧
    func deletePage(sceneIndex: Int, pageIndex: Int) {
        guard config.scenes.indices.contains(sceneIndex),
              config.scenes[sceneIndex].pages.count > 1,
              config.scenes[sceneIndex].pages.indices.contains(pageIndex)
        else { return }
        config.scenes[sceneIndex].pages.remove(at: pageIndex)
        if sceneIndex == config.currentSceneIndex {
            if !config.scenes[sceneIndex].pages.indices.contains(config.currentPageIndex) {
                config.currentPageIndex = max(0, config.scenes[sceneIndex].pages.count - 1)
            }
        }
        save()
    }

    // MARK: 场景联动(前台应用自动切换)

    /// 绑定了指定前台应用的场景(nil = 无绑定)
    func sceneBoundToApp(_ bundleID: String) -> DeckScene? {
        config.scenes.first { $0.boundAppBundleIDs?.contains(bundleID) == true }
    }

    /// 读取某场景第 slot 个应用绑定(0-based,最多 3;nil = 未设)
    func sceneAppBinding(id: UUID, slot: Int) -> String? {
        guard let scene = scene(id: id), let bindings = scene.boundAppBundleIDs,
              slot < bindings.count, !bindings[slot].isEmpty
        else { return nil }
        return bindings[slot]
    }

    /// 设置某场景第 slot 个应用绑定;尾部空槽自动收紧,全空则置 nil
    func setSceneAppBinding(id: UUID, slot: Int, bundleID: String?) {
        guard let index = indexOfScene(id: id) else { return }
        var bindings = config.scenes[index].boundAppBundleIDs ?? []
        while bindings.count < 3 { bindings.append("") }
        bindings[slot] = bundleID ?? ""
        while bindings.last == "" { bindings.removeLast() }
        config.scenes[index].boundAppBundleIDs = bindings.isEmpty ? nil : bindings
        save()
    }

    /// 默认场景(前台应用无绑定时显示);nil = 不启用
    func setDefaultScene(id: UUID?) {
        config.defaultSceneID = id
        save()
    }

    // MARK: 场景内翻页 / 场景间切换的目标计算

    /// 当前页在场景内的序号(0-based)与场景内页数(页面指示键与圆点用)
    var currentPagePositionInScene: (position: Int, count: Int)? {
        let scene = currentScene
        guard scene.pages.indices.contains(config.currentPageIndex) else { return nil }
        return (config.currentPageIndex, scene.pages.count)
    }

    /// 场景内第 position 页(0-based)的 id(圆点指示器点击直达用)
    func pageIDInCurrentScene(position: Int) -> UUID? {
        let scene = currentScene
        guard scene.pages.indices.contains(position) else { return nil }
        return scene.pages[position].id
    }

    /// 任意场景内第 position 页(0-based)的 id(矩阵点按跨场景直达用)
    func pageIDInScene(_ sceneIndex: Int, position: Int) -> UUID? {
        guard config.scenes.indices.contains(sceneIndex),
              config.scenes[sceneIndex].pages.indices.contains(position) else { return nil }
        return config.scenes[sceneIndex].pages[position].id
    }

    /// 「前往页」按 Page.id 跨场景定位(兼容旧配置的动作;找不到 = 无操作)
    func pageLocation(id: UUID) -> (sceneIndex: Int, pageIndex: Int)? {
        for sceneIndex in config.scenes.indices {
            if let pageIndex = config.scenes[sceneIndex].pages.firstIndex(where: { $0.id == id }) {
                return (sceneIndex, pageIndex)
            }
        }
        return nil
    }

    /// 场景内翻页目标索引(循环;单页场景返回 nil)
    func targetPageIndex(offset: Int) -> Int? {
        let count = currentScene.pages.count
        guard count > 1 else { return nil }
        return ((config.currentPageIndex + offset) % count + count) % count
    }

    /// 切换场景目标索引(循环;单场景返回 nil)
    func targetSceneIndex(offset: Int) -> Int? {
        let count = config.scenes.count
        guard count > 1 else { return nil }
        return ((config.currentSceneIndex + offset) % count + count) % count
    }

    // MARK: 亮度相关

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

    /// 编辑器导航样式(nil = 经典);菜单直选,立即落盘
    var navStyle: NavigationStyle {
        get { config.navStyle ?? .classic }
        set {
            config.navStyle = newValue
            save()
        }
    }

    /// 亮度滑杆 0% 时键面涂黑(nil = 关);菜单直选,立即落盘
    var sliderZeroBlacksKeys: Bool {
        get { config.sliderZeroBlacksKeys ?? false }
        set {
            config.sliderZeroBlacksKeys = newValue
            save()
        }
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
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.error("配置文件读取失败:\(error, privacy: .public)")
            return nil
        }
        // 新旧格式探测:新模型字段有默认值,仅凭解码失败判旧格式不可靠,
        // 须按键名判定(有 pages 无 scenes = 旧单级结构,迁移为场景)
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any],
           dictionary["scenes"] == nil, dictionary["pages"] != nil
        {
            if let migrated = migrateLegacyConfig(from: data) {
                logger.info("已从旧版单级页面配置迁移到场景结构(\(migrated.scenes.count) 场景)")
                print("📜 已从旧版配置迁移:\(migrated.scenes.count) 个场景")
                return migrated
            }
            print("📜 未触发迁移(非旧格式或迁移失败)")
        }
        do {
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            logger.error("配置文件无法解析,将回退默认配置:\(error, privacy: .public)")
            return nil
        }
    }

    // MARK: 旧配置迁移(pages 平铺 → scenes 两级)

    private struct LegacyPage: Codable {
        var id: UUID?
        var keys: [KeyConfig]?
        var boundAppBundleIDs: [String]?
        var sceneName: String?
    }

    private struct LegacyAppConfig: Codable {
        var pages: [LegacyPage]
        var currentPageIndex: Int?
        var brightness: Int?
        var followSystemBrightness: Bool?
        var layout: LayoutParams?
        var defaultPageID: UUID?
        var autoScreenOffMinutes: Int?
    }

    /// 迁移规则:旧页按 sceneName 分组(保持首次出现顺序),每组成为一个场景;
    /// 页 id 原样保留(gotoPage 动作不失效);绑定取组内首个非空;当前场景/页按旧索引落位
    private static func migrateLegacyConfig(from data: Data) -> AppConfig? {
        guard let legacy = try? JSONDecoder().decode(LegacyAppConfig.self, from: data),
              !legacy.pages.isEmpty
        else { return nil }

        func sceneName(of page: LegacyPage) -> String {
            guard let name = page.sceneName, !name.isEmpty else { return "默认场景" }
            return name
        }

        var scenes: [DeckScene] = []
        var sceneOfPage: [Int: Int] = [:] // 旧页索引 → 场景索引
        for (index, page) in legacy.pages.enumerated() {
            let name = sceneName(of: page)
            var sceneIndex = scenes.firstIndex { $0.name == name }
            if sceneIndex == nil {
                scenes.append(DeckScene(
                    id: UUID(),
                    name: name,
                    boundAppBundleIDs: page.boundAppBundleIDs,
                    pages: []
                ))
                sceneIndex = scenes.count - 1
            }
            scenes[sceneIndex!].pages.append(Page(id: page.id, keys: page.keys ?? []))
            sceneOfPage[index] = sceneIndex!
        }

        var config = AppConfig(scenes: scenes, brightness: legacy.brightness ?? 80)
        config.followSystemBrightness = legacy.followSystemBrightness
        config.layout = legacy.layout
        config.autoScreenOffMinutes = legacy.autoScreenOffMinutes
        config.currentSceneIndex = sceneOfPage[legacy.currentPageIndex ?? 0] ?? 0
        config.currentPageIndex = legacy.currentPageIndex ?? 0
        if let defaultPageID = legacy.defaultPageID,
           let location = scenes.enumerated().compactMap(({ _, scene in
               scene.pages.firstIndex(where: { $0.id == defaultPageID }).map { _ in scene.id }
           })).first
        {
            config.defaultSceneID = location
        }
        return config
    }

    /// 数据完整性兜底:手改/旧版文件可能场景为空、页为空、索引越界、键数不符,
    /// 载入时统一拉回合法形状,并补齐场景/页面 id
    private static func normalize(_ config: inout AppConfig) {
        if config.scenes.isEmpty {
            config.scenes = [DeckScene(name: "默认页面", pages: [Page()])]
        }
        for sceneIndex in config.scenes.indices {
            if config.scenes[sceneIndex].id == nil { config.scenes[sceneIndex].id = UUID() }
            if config.scenes[sceneIndex].pages.isEmpty {
                config.scenes[sceneIndex].pages = [Page()]
            }
            for pageIndex in config.scenes[sceneIndex].pages.indices {
                if config.scenes[sceneIndex].pages[pageIndex].id == nil {
                    config.scenes[sceneIndex].pages[pageIndex].id = UUID()
                }
                let count = config.scenes[sceneIndex].pages[pageIndex].keys.count
                if count < keyCount {
                    config.scenes[sceneIndex].pages[pageIndex].keys += Array(repeating: KeyConfig(), count: keyCount - count)
                } else if count > keyCount {
                    config.scenes[sceneIndex].pages[pageIndex].keys.removeLast(count - keyCount)
                }
            }
        }
        if !config.scenes.indices.contains(config.currentSceneIndex) { config.currentSceneIndex = 0 }
        if !config.scenes[config.currentSceneIndex].pages.indices.contains(config.currentPageIndex) {
            config.currentPageIndex = 0
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
        return AppConfig(
            scenes: [DeckScene(id: UUID(), name: "默认页面", pages: [Page(keys: keys)])],
            brightness: 80
        )
    }

    private static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: configFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
