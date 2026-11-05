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
    /// 合盖休眠锁(pmset -a disablesleep):按下即读当前态取反。
    /// 需要 /etc/sudoers.d/pmset-disablesleep 免密放行；执行与回读见 SleepGuard。
    case sleepGuard
    /// 插件动作:pluginID = .sdPlugin 目录名去后缀(= manifest UUID),contextID = 实例身份
    /// (分配时生成的 UUID,持久化于此,跨重启稳定;settings 存 pluginSettings/<pluginID>.json)
    case plugin(pluginID: String, actionUUID: String, contextID: String)
    /// 显示器 DDC/CI 动作(亮度/对比度/锐度/响应时间/输入源…):由 ActionRunner 直连显示器执行
    case monitor(MonitorCommand)
    /// 系统状态键(GPU/CPU 利用率、温度):整帧由 StatTileAnimator 驱动,按压无操作。
    /// 2026-11-01 从「保留槽固定仪表盘」动作化——槽位随配置走,可放任意键位、可清除
    case stat(StatKind)
    /// 键盘热力图键:读数来自 KeyAnalyze 自己的库,状态来自它自己的桥接/日志,
    /// 按下转发给它自己的入口(打开 dashboard / 重试统计)。见 KeyboardHeatmap*.swift
    case keyboardHeatmap
}

/// 待配置模板:功能调色盘的参数类磁贴(打开应用/网址/快捷指令/Shell/AppleScript/热键)
/// 落下后的占位态。占位期间 action 保持 nil(按下无动作),编辑器打开时按此预选类型;
/// 保存有效动作即清除(draftConfig 落定),取消编辑则保留占位。
enum KeyTemplate: String, Codable, Hashable, CaseIterable, Identifiable {
    case openApp
    case openURL
    case runShortcut
    case shellScript
    case appleScript
    case hotkey

    var id: String { rawValue }

    /// 六种带参模板的组装口径——KeyEditView 与 TemplateConfigSheet 共用同一函数(防漂移)。
    /// 空参不成动作,**含空脚本**(空脚本键 = 按下无反应的死键,不允许保存)。
    static func assemble(
        _ kind: KeyTemplate, appPath: String, urlString: String, shortcutName: String,
        scriptText: String, hotkeyKeyCode: Int?, hotkeyModifiers: [String]
    ) -> KeyAction? {
        // 含 let 语句的 case 会让 switch 退化成语句形式,全表显式 return
        switch kind {
        case .openApp:
            return appPath.isEmpty ? nil : .openApp(path: appPath)
        case .openURL:
            let trimmed = urlString.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : .openURL(trimmed)
        case .runShortcut:
            return shortcutName.isEmpty ? nil : .runShortcut(name: shortcutName)
        case .shellScript:
            return scriptText.isEmpty ? nil : .shellScript(scriptText)
        case .appleScript:
            return scriptText.isEmpty ? nil : .appleScript(scriptText)
        case .hotkey:
            return hotkeyKeyCode.map { .hotkey(keyCode: $0, modifiers: hotkeyModifiers) }
        }
    }
}

struct KeyConfig: Codable, Hashable {
    var title: String = ""
    var backgroundColorHex: String = "#3B4252"
    var iconPath: String? = nil
    var action: KeyAction? = nil
    /// 内建动效键面(可选,旧配置缺键可解码)。语义由渲染器决定,优先于 iconPath/title。
    var animation: KeyAnimation? = nil
    /// 待配置模板占位(可选,旧配置缺键可解码)。与 action 互斥:有 template 即无 action。
    var template: KeyTemplate? = nil

    /// 手写解码:非可选 + 默认值的字段缺键时按默认兜底。
    /// 合成 Codable 不使用属性默认值——手编 config.json 漏写某个 "title" 曾让整份解码
    /// 失败 → 归档 + 全量重置,代价与损失完全不成比例。
    /// 枚举三字段(action/animation/template)再宽容一层:高版本 app 写入的未知 case
    /// (rawValue 关联值枚举前向不兼容)只降级**该键**,不引爆整份配置归档重置
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        backgroundColorHex = try container.decodeIfPresent(String.self, forKey: .backgroundColorHex) ?? "#3B4252"
        iconPath = try container.decodeIfPresent(String.self, forKey: .iconPath)
        action = Self.lenientDecode(KeyAction.self, container, .action, label: "动作")
        animation = Self.lenientDecode(KeyAnimation.self, container, .animation, label: "动效")
        template = Self.lenientDecode(KeyTemplate.self, container, .template, label: "模板")
    }

    /// 枚举宽容解码:key 存在但解码失败(未知 case/关联值形态变化)→ nil + 日志。
    /// 损失面 = 单键动作(保存即按新格式重写),换取配置主体存活
    private static func lenientDecode<T: Decodable, Key: CodingKey>(_ type: T.Type, _ container: KeyedDecodingContainer<Key>, _ key: Key, label: String) -> T? {
        guard container.contains(key) else { return nil }
        do {
            return try container.decodeIfPresent(T.self, forKey: key)
        } catch {
            Self.lenientLogger.error("配置含未知\(label)类型(高版本 app 写入?),该键\(label)已降级为空:\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static let lenientLogger = Logger(subsystem: "opendeck", category: "config")

    init(
        title: String = "",
        backgroundColorHex: String = "#3B4252",
        iconPath: String? = nil,
        action: KeyAction? = nil,
        animation: KeyAnimation? = nil,
        template: KeyTemplate? = nil
    ) {
        self.title = title
        self.backgroundColorHex = backgroundColorHex
        self.iconPath = iconPath
        self.action = action
        self.animation = animation
        self.template = template
    }
}

/// 键面内建动效。目前只有一种:LG 显示器输入源切换(Mac DP ↔ PC HDMI1)。
/// 与 Toggle Monitor 快捷指令配合:键面显示当前输入源,按压后播放信号迁移动效。
enum KeyAnimation: String, Codable, Hashable, CaseIterable {
    case monitorInput

    var label: String {
        switch self {
        case .monitorInput: return "显示器输入切换(Mac / PC)"
        }
    }
}

/// 场景内的一页(15 键)。场景的第一页之外即「圆点」——内容超过一屏时的延伸页。
struct Page: Codable, Hashable {
    /// 稳定引用 id(「前往页面」动作兼容用);normalize 补齐
    var id: UUID? = nil
    var keys: [KeyConfig] = Array(repeating: KeyConfig(), count: 15)  // index = row*5+column

    /// 手写解码:缺 "keys" 按全空页兜底(手编 JSON 删掉 keys 曾引爆整份配置)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
        keys = try container.decodeIfPresent([KeyConfig].self, forKey: .keys)
            ?? Array(repeating: KeyConfig(), count: 15)
    }

    init(id: UUID? = nil, keys: [KeyConfig] = Array(repeating: KeyConfig(), count: 15)) {
        self.id = id
        self.keys = keys
    }
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

    /// 手写解码:name/pages 缺键按默认兜底(理由同 KeyConfig)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "场景"
        boundAppBundleIDs = try container.decodeIfPresent([String].self, forKey: .boundAppBundleIDs)
        pages = try container.decodeIfPresent([Page].self, forKey: .pages) ?? [Page()]
    }

    init(id: UUID? = nil, name: String = "场景", boundAppBundleIDs: [String]? = nil, pages: [Page] = [Page()]) {
        self.id = id
        self.name = name
        self.boundAppBundleIDs = boundAppBundleIDs
        self.pages = pages
    }
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

/// 玻璃对位补偿(视觉坐标:正 = 右/上;zoom = 百分比,100 = 原尺寸)。
/// 键板玻璃窗口相对 framebuffer 有轻微偏心:下发前整帧缩放+平移,
/// 空出的边带由设备侧用边缘像素延展填满;全默认值 = 不补偿。
struct GlassOffset: Codable, Equatable {
    var x: Int = 0
    var y: Int = 0
    var zoom: Int = 100

    static let zero = GlassOffset()

    /// 手写解码:旧配置里的 glassOffset 只有 x/y(无 zoom),必须按 100 兜底
    init(x: Int = 0, y: Int = 0, zoom: Int = 100) {
        self.x = x
        self.y = y
        self.zoom = zoom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decodeIfPresent(Int.self, forKey: .x) ?? 0
        y = try container.decodeIfPresent(Int.self, forKey: .y) ?? 0
        zoom = try container.decodeIfPresent(Int.self, forKey: .zoom) ?? 100
    }
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
    /// 玻璃对位补偿(可选保证旧配置缺键可解码);nil/缺省 = 0,0
    var glassOffset: GlassOffset? = nil
    /// 配置结构版本:normalize 时补当前值。旧配置缺键解码为 nil(视为 v1),
    /// 下一次需要破坏性迁移时据此判定,不再靠键名嗅探
    var schemaVersion: Int? = nil
    /// 模板草稿(键 = KeyTemplate.rawValue):就绪态持久化,落键/手动清除时移除
    var templateDrafts: [String: KeyConfig]? = nil
    /// 首启引导已关闭(nil/缺省 = 未关闭)
    var onboardingDismissed: Bool? = nil

    /// 手写解码:四个非可选骨架字段(scenes/双索引/亮度)缺键按默认兜底,理由同 KeyConfig
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scenes = try container.decodeIfPresent([DeckScene].self, forKey: .scenes) ?? [DeckScene()]
        currentSceneIndex = try container.decodeIfPresent(Int.self, forKey: .currentSceneIndex) ?? 0
        currentPageIndex = try container.decodeIfPresent(Int.self, forKey: .currentPageIndex) ?? 0
        brightness = try container.decodeIfPresent(Int.self, forKey: .brightness) ?? 80
        followSystemBrightness = try container.decodeIfPresent(Bool.self, forKey: .followSystemBrightness)
        layout = try container.decodeIfPresent(LayoutParams.self, forKey: .layout)
        defaultSceneID = try container.decodeIfPresent(UUID.self, forKey: .defaultSceneID)
        autoScreenOffMinutes = try container.decodeIfPresent(Int.self, forKey: .autoScreenOffMinutes)
        navStyle = try container.decodeIfPresent(NavigationStyle.self, forKey: .navStyle)
        sliderZeroBlacksKeys = try container.decodeIfPresent(Bool.self, forKey: .sliderZeroBlacksKeys)
        glassOffset = try container.decodeIfPresent(GlassOffset.self, forKey: .glassOffset)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
        templateDrafts = try container.decodeIfPresent([String: KeyConfig].self, forKey: .templateDrafts)
        onboardingDismissed = try container.decodeIfPresent(Bool.self, forKey: .onboardingDismissed)
    }

    init(
        scenes: [DeckScene] = [DeckScene()],
        currentSceneIndex: Int = 0,
        currentPageIndex: Int = 0,
        brightness: Int = 80
    ) {
        self.scenes = scenes
        self.currentSceneIndex = currentSceneIndex
        self.currentPageIndex = currentPageIndex
        self.brightness = brightness
    }
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
    /// 默认落盘路径:~/Library/Application Support/OpenDeck/config.json
    private static let defaultFileURL: URL = {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("OpenDeck/config.json")
    }()

    /// 实际读写路径(测试注入临时文件用,默认即 defaultFileURL)
    private let fileURL: URL
    /// 配置文件路径只读暴露(自动备份的变更检测哈希用)
    var configFileURL: URL { fileURL }
    /// 全新安装(本次 init 时 config.json 不存在/不可解析):首启引导的判定依据
    private(set) var isFreshInstall = false

    convenience init() {
        // 暂存导入在**任何配置读取之前**应用:新实例从第一行代码起就是导入后的世界
        // (§6.29;只挂默认路径入口,测试注入的 init(contentsOf:) 不受影响)
        ConfigPorter.applyPendingImport(appSupport: ConfigPorter.appSupportRoot)
        self.init(contentsOf: Self.defaultFileURL)
    }

    /// 注入路径装载:测试用(临时文件);缺失/损坏走与默认路径完全同一套容错
    init(contentsOf url: URL) {
        fileURL = url
        switch Self.loadConfiguration(from: url) {
        case .ok(var loaded):
            Self.normalize(&loaded)
            config = loaded
            Self.sweepArchives(at: url.deletingLastPathComponent())
        case .resetAllowed:
            isFreshInstall = true
            config = Self.defaultConfig()
            // 首次启动(或配置损坏且已成功归档)立即落盘,保证后续启动读到的是真实文件
            // normalize 补场景/页面 id 等派生字段,与读盘路径行为一致
            Self.normalize(&config)
            save()
            Self.sweepArchives(at: url.deletingLastPathComponent())
        case .resetBlocked:
            // 损坏 + 归档失败:原文件是用户配置的唯一副本,绝不主动用默认配置覆盖。
            // 内存回退默认让 app 能跑,现场留在磁盘上等用户处置(fault 日志已上报)
            isFreshInstall = true
            config = Self.defaultConfig()
            Self.normalize(&config)
            onAnomaly?("配置损坏且归档失败:\(url.path) 原文件保留未覆盖,本次会话使用默认配置")
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

    /// 只更新内存(不落盘):布局调参的实时预览;落盘交给「完成」按钮
    func setLayoutInMemory(_ value: LayoutParams) {
        config.layout = value
    }

    /// 玻璃对位补偿(缺省 = 0,0);调参面板每步落盘
    var glassOffset: GlassOffset {
        get { config.glassOffset ?? .zero }
        set {
            config.glassOffset = newValue
            save()
        }
    }

    /// 只更新内存(不落盘):玻璃校准的实时调参;落盘由 AppModel 防抖触发
    func setGlassOffsetInMemory(_ value: GlassOffset) {
        config.glassOffset = value
    }

    /// 模板草稿(按 KeyTemplate 取回;无法识别的 raw 忽略)
    var templateDrafts: [KeyTemplate: KeyConfig] {
        var result: [KeyTemplate: KeyConfig] = [:]
        for (raw, key) in config.templateDrafts ?? [:] {
            if let kind = KeyTemplate(rawValue: raw) { result[kind] = key }
        }
        return result
    }

    /// 保存/清除模板草稿(nil = 清除,落盘)
    func setTemplateDraft(_ kind: KeyTemplate, _ key: KeyConfig?) {
        var drafts = config.templateDrafts ?? [:]
        if let key {
            drafts[kind.rawValue] = key
        } else {
            drafts.removeValue(forKey: kind.rawValue)
        }
        config.templateDrafts = drafts.isEmpty ? nil : drafts
        save()
    }

    /// 首启引导开关(持久记忆:关过一次就不再出现)
    var onboardingDismissed: Bool {
        get { config.onboardingDismissed ?? false }
        set {
            config.onboardingDismissed = newValue
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
    /// 删除场景;返回被删的是否是正在查看的场景(调用方据此决定是否需要整页重渲)
    @discardableResult
    func deleteScene(id: UUID) -> Bool {
        guard config.scenes.count > 1, let index = indexOfScene(id: id) else { return false }
        let wasCurrent = index == config.currentSceneIndex
        config.scenes.remove(at: index)
        // 保持「正在看的场景」不动:删的是当前页之前的场景时,后续场景整体前移,索引要跟着 -1;
        // 删的正是当前场景时,落到同位置(原 index 处,已夹到合法范围)
        if index < config.currentSceneIndex {
            config.currentSceneIndex -= 1
        }
        if !config.scenes.indices.contains(config.currentSceneIndex) {
            config.currentSceneIndex = 0
        }
        config.currentPageIndex = 0
        if config.defaultSceneID == id {
            config.defaultSceneID = nil
        }
        save()
        return wasCurrent
    }

    /// 复制场景(沿用全部页与绑定,新 id,名称加「副本」),插到原场景之后。
    /// Page.id 必须重生成:页点是按 id 稳定引用的,克隆共享 id 会让导航跳回原场景。
    /// 插入会把被看场景之后的索引整体 +1,currentSceneIndex 同步平移,视野不动。
    @discardableResult
    func duplicateScene(id: UUID) -> UUID? {
        guard let index = indexOfScene(id: id) else { return nil }
        var copy = config.scenes[index]
        copy.id = UUID()
        copy.name = config.scenes[index].name + " 副本"
        copy.pages = copy.pages.map { page in
            var page = page
            page.id = UUID()
            return page
        }
        config.scenes.insert(copy, at: index + 1)
        if index + 1 <= config.currentSceneIndex {
            config.currentSceneIndex += 1
        }
        save()
        return copy.id
    }

    /// 给场景追加一页(圆点 +1),返回其 id;25 页封顶——
    /// 无限加圆点会稀释导航(页点一屏放不下),上限封在数据层,UI 层超限只见日志
    @discardableResult
    func addPage(toSceneIndex sceneIndex: Int) -> UUID? {
        guard config.scenes.indices.contains(sceneIndex) else { return nil }
        guard config.scenes[sceneIndex].pages.count < 25 else {
            Self.logger.info("场景页数已达上限(25),拒绝继续添加")
            return nil
        }
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
            // 删当前页之前的页:视图指针平移,否则删 [A,B,C] 的 A 而在看 B 会跳到 C
            if pageIndex < config.currentPageIndex {
                config.currentPageIndex -= 1
            }
            if !config.scenes[sceneIndex].pages.indices.contains(config.currentPageIndex) {
                config.currentPageIndex = max(0, config.scenes[sceneIndex].pages.count - 1)
            }
        }
        save()
    }

    /// 场景内页面重排序(from → to;from == to no-op)。
    /// 当前指针按 Page.id 重新定位:移动的是当前页 → 指针跟过去;移动别的页跨过当前页 → 补偿。
    /// 用 id 重定位比手推偏移可靠(两种移动方向的边界一次写对)
    func movePage(sceneIndex: Int, from: Int, to: Int) {
        guard config.scenes.indices.contains(sceneIndex),
              config.scenes[sceneIndex].pages.indices.contains(from),
              config.scenes[sceneIndex].pages.indices.contains(to),
              from != to
        else { return }
        let currentPageID = sceneIndex == config.currentSceneIndex
            ? config.scenes[sceneIndex].pages.indices.contains(config.currentPageIndex)
                ? config.scenes[sceneIndex].pages[config.currentPageIndex].id
                : nil
            : nil
        config.scenes[sceneIndex].pages.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        if sceneIndex == config.currentSceneIndex, let currentPageID,
           let newIndex = config.scenes[sceneIndex].pages.firstIndex(where: { $0.id == currentPageID }) {
            config.currentPageIndex = newIndex
        }
        save()
    }

    /// 场景重排序(from → to);当前场景指针按场景 id 重新定位(芯片顺序变了,视野场景不变)
    func moveScene(from: Int, to: Int) {
        guard config.scenes.indices.contains(from), config.scenes.indices.contains(to), from != to else { return }
        let currentSceneID = config.scenes.indices.contains(config.currentSceneIndex)
            ? config.scenes[config.currentSceneIndex].id
            : nil
        config.scenes.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        if let currentSceneID,
           let newIndex = config.scenes.firstIndex(where: { $0.id == currentSceneID }) {
            config.currentSceneIndex = newIndex
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

    /// 原子写盘:先写临时文件再换名。失败经 onAnomaly 上升(LogSheet 可见),
    /// 否则磁盘满/只读卷期间 UI 一切照常,重启丢变更且无痕
    func save() {
        do {
            let encoder = JSONEncoder()
            // 人工可读可改:调试期直接手编辑 config.json 是常见操作
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try Self.ensureDirectory(for: fileURL)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("配置保存失败:\(error, privacy: .public)")
            onAnomaly?("配置保存失败(内存态未丢,磁盘未更新):\(error.localizedDescription)")
        }
    }

    /// 异常上行钩子(保存失败/损坏归档失败等):AppModel 注线到运行日志环,
    /// 让「静默失败时代结束」的可见错误通道覆盖配置域
    var onAnomaly: ((String) -> Void)?

    // MARK: - 私有

    /// 载入结果:resetBlocked = 损坏且归档失败,原文件是用户配置的唯一副本,
    /// 不得用默认配置覆盖(init 侧内存回退默认但不落盘,保住现场)
    private enum LoadOutcome {
        case ok(AppConfig)
        case resetAllowed
        case resetBlocked
    }

    private static func loadConfiguration(from url: URL) -> LoadOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .resetAllowed }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.error("配置文件读取失败:\(error, privacy: .public)")
            return archiveCorruptFile(url: url, data: nil, reason: "unreadable") ? .resetAllowed : .resetBlocked
        }
        // 新旧格式探测:新模型字段有默认值,仅凭解码失败判旧格式不可靠,
        // 须按键名判定(有 pages 无 scenes = 旧单级结构,迁移为场景)
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dictionary = object as? [String: Any],
           dictionary["scenes"] == nil, dictionary["pages"] != nil
        {
            if let migrated = migrateLegacyConfig(from: data) {
                logger.info("已从旧版单级页面配置迁移到场景结构(\(migrated.scenes.count) 场景)")
                return .ok(migrated)
            }
            logger.info("未触发旧格式迁移(非旧格式或迁移失败)")
        }
        do {
            return .ok(try JSONDecoder().decode(AppConfig.self, from: data))
        } catch {
            logger.error("配置文件无法解析,归档后回退默认配置:\(error, privacy: .public)")
            return archiveCorruptFile(url: url, data: data, reason: "undecodable") ? .resetAllowed : .resetBlocked
        }
    }

    /// 损坏配置归档:回退默认前先把原文件留底到同目录(config.corrupt-<时间戳>-<原因>.json)。
    /// 数据完整性最高优先级——手编 JSON 写错、外部工具写坏都属正常事故,
    /// 宁可目录里多一个损坏文件,绝不悄悄覆掉用户配置。返回 false = 归档失败(调用方必须护场)。
    private static func archiveCorruptFile(url: URL, data: Data?, reason: String) -> Bool {
        // 毫秒戳:秒级时间戳同秒碰撞会静默覆盖前一份归档
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let archiveURL = url.deletingLastPathComponent()
            .appendingPathComponent("config.corrupt-\(stamp)-\(reason).json")
        do {
            if let data {
                try data.write(to: archiveURL, options: .atomic)
            } else {
                try FileManager.default.copyItem(at: url, to: archiveURL)
            }
            logger.error("损坏配置已归档:\(archiveURL.path, privacy: .public)")
            return true
        } catch {
            // 归档失败也绝不静默——这是数据完整性的最后防线
            logger.fault("损坏配置归档失败,原文件仍在 \(url.path, privacy: .public):\(error, privacy: .public)")
            return false
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
        if config.schemaVersion == nil { config.schemaVersion = 2 } // 旧配置补版本标(下次迁移的判定依据)
        if config.scenes.isEmpty {
            config.scenes = [DeckScene(name: "默认页面", pages: [Page()])]
        }
        // id 补齐 + 跨场景去重:手编文件可能造成重复 Page.id,pageLocation/pageIDInCurrentScene
        // 都按 first 命中,重复 id 会让矩阵点按/圆点直达/gotoPage 落错页
        var seenSceneIDs = Set<UUID>()
        var seenPageIDs = Set<UUID>()
        for sceneIndex in config.scenes.indices {
            let sceneID: UUID
            switch config.scenes[sceneIndex].id {
            case .some(let id) where seenSceneIDs.contains(id):
                sceneID = UUID() // 重复场景 id 重生成,后者让位
            case .some(let id):
                sceneID = id
            case nil:
                sceneID = UUID()
            }
            config.scenes[sceneIndex].id = sceneID
            seenSceneIDs.insert(sceneID)
            if config.scenes[sceneIndex].pages.isEmpty {
                config.scenes[sceneIndex].pages = [Page()]
            }
            for pageIndex in config.scenes[sceneIndex].pages.indices {
                let pageID: UUID
                switch config.scenes[sceneIndex].pages[pageIndex].id {
                case .some(let id) where seenPageIDs.contains(id):
                    pageID = UUID() // 重复页 id 同法处理
                case .some(let id):
                    pageID = id
                case nil:
                    pageID = UUID()
                }
                config.scenes[sceneIndex].pages[pageIndex].id = pageID
                seenPageIDs.insert(pageID)
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

    /// 损坏归档清扫:只保留最近 archiveKeepCount 份(文件名含毫秒时间戳,字典序即时间序)。
    /// 归档原本无限堆积;清理失败仅记日志,不影响主流程
    private static func sweepArchives(at directory: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        let archives = entries
            .filter { $0.hasPrefix("config.corrupt-") && $0.hasSuffix(".json") }
            .sorted(by: >)
        guard archives.count > archiveKeepCount else { return }
        for name in archives.dropFirst(archiveKeepCount) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        if archives.count - archiveKeepCount > 0 {
            logger.info("已清扫 \(archives.count - archiveKeepCount) 份过期损坏归档")
        }
    }

    private static let archiveKeepCount = 10

    private static func ensureDirectory(for url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}
