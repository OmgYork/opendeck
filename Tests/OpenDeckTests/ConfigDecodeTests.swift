import Foundation
import Testing
@testable import OpenDeck

// 配置解码回归:AppConfig 新增可选字段必须保持旧配置可解码(数据完整性最高优先级)。
// 此前历次加字段(followSystemBrightness/layout/autoScreenOffMinutes/defaultSceneID/navStyle)
// 都依赖「可选 + 默认值」模式而无测试覆盖,本文件补上该闸门。

struct ConfigDecodeTests {
    /// 旧配置(缺 navStyle/autoScreenOffMinutes/defaultSceneID 等键)解码 → 新字段回退默认,旧数据不丢
    @Test("旧配置缺新键解码兼容:navStyle 缺省 = 经典,场景数据完整")
    @MainActor
    func legacyConfigDecodes() throws {
        // 旧配置由应用写出:旧非可选字段(backgroundColorHex 等)全在,仅缺后来新增的可选键
        let json = """
        {
          "scenes" : [
            {
              "name" : "默认页面",
              "pages" : [ { "keys" : [ { "title" : "访达", "backgroundColorHex" : "#BF616A" } ] } ]
            }
          ],
          "currentSceneIndex" : 0,
          "currentPageIndex" : 0,
          "brightness" : 80
        }
        """
        let data = try #require(json.data(using: .utf8))
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(config.navStyle == nil)
        #expect(config.scenes.count == 1)
        #expect(config.scenes[0].pages.count == 1)
        #expect(config.scenes[0].pages[0].keys[0].title == "访达")
        #expect(config.autoScreenOffMinutes == nil)
        #expect(config.defaultSceneID == nil)
    }

    /// navStyle 三种样式编码往返稳定
    @Test("navStyle 编解码往返")
    @MainActor
    func navStyleRoundTrip() throws {
        for style in NavigationStyle.allCases {
            var config = AppConfig()
            config.navStyle = style
            let data = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            #expect(decoded.navStyle == style)
            #expect(decoded.scenes.count == 1)  // 其余字段不受影响
        }
    }

    /// 玻璃对位:旧配置缺键可解码;只写了 x/y 的旧对象 zoom 兜底 100;声明值往返稳定
    @Test("glassOffset 缺省兼容与编解码往返")
    @MainActor
    func glassOffsetRoundTrip() throws {
        let json = """
        {
          "scenes" : [ { "name" : "默认页面", "pages" : [ { "keys" : [] } ] } ],
          "currentSceneIndex" : 0,
          "currentPageIndex" : 0,
          "brightness" : 80
        }
        """
        let data = try #require(json.data(using: .utf8))
        let legacy = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(legacy.glassOffset == nil)
        #expect(legacy.scenes.count == 1)

        // 上一版配置只写过 x/y: zoom 必须按原尺寸兜底,不能整份配置解码失败
        let withOffsetOnly = """
        {
          "scenes" : [ { "name" : "默认页面", "pages" : [ { "keys" : [] } ] } ],
          "currentSceneIndex" : 0,
          "currentPageIndex" : 0,
          "brightness" : 80,
          "glassOffset" : { "x" : -3, "y" : 3 }
        }
        """
        let offsetData = try #require(withOffsetOnly.data(using: .utf8))
        let partial = try JSONDecoder().decode(AppConfig.self, from: offsetData)
        #expect(partial.glassOffset == GlassOffset(x: -3, y: 3, zoom: 100))

        var config = AppConfig()
        config.glassOffset = GlassOffset(x: -3, y: 3, zoom: 108)
        let round = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        #expect(round.glassOffset == GlassOffset(x: -3, y: 3, zoom: 108))
    }
}

// MARK: - §6.26 深度审计轮新增闸门

extension ConfigDecodeTests {
    /// 手编 JSON 漏写非可选骨架键(曾令整份解码失败 → 归档 + 全量重置):
    /// 现按默认兜底继续解码,数据不再被顶掉
    @Test("缺骨架键按默认兜底:漏 title/keys/name/pages/scenes/brightness 均可解码")
    @MainActor
    func missingSkeletonKeysDecodeWithDefaults() throws {
        // 键缺 title 与 backgroundColorHex
        let keyMissing = """
        { "iconPath" : null, "action" : null }
        """
        let key = try JSONDecoder().decode(KeyConfig.self, from: Data(keyMissing.utf8))
        #expect(key.title == "")
        #expect(key.backgroundColorHex == "#3B4252")

        // 页缺 keys
        let page = try JSONDecoder().decode(Page.self, from: Data("{ }".utf8))
        #expect(page.keys.count == 15)

        // 场景缺 name/pages
        let scene = try JSONDecoder().decode(DeckScene.self, from: Data("{ }".utf8))
        #expect(scene.name == "场景")
        #expect(scene.pages.count == 1)

        // 顶层缺 scenes/currentSceneIndex/currentPageIndex/brightness
        let top = try JSONDecoder().decode(AppConfig.self, from: Data("{ }".utf8))
        #expect(top.scenes.count == 1)
        #expect(top.currentSceneIndex == 0)
        #expect(top.currentPageIndex == 0)
        #expect(top.brightness == 80)
    }

    /// 手编文件跨场景重复 Page.id:normalize 去重(后者重生成),
    /// 否则 pageLocation/圆点直达按 first 命中会落错页
    @Test("normalize 对重复 Page.id 去重")
    @MainActor
    func normalizeDeduplicatesPageIDs() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-dupid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        let same = "11111111-1111-1111-1111-111111111111"
        let json = """
        {
          "scenes" : [
            { "name" : "A", "pages" : [ { "id" : "\(same)", "keys" : [] }, { "id" : "\(same)", "keys" : [] } ] },
            { "name" : "B", "pages" : [ { "id" : "\(same)", "keys" : [] } ] }
          ],
          "currentSceneIndex" : 0,
          "currentPageIndex" : 0,
          "brightness" : 80
        }
        """
        try Data(json.utf8).write(to: url)
        let store = ConfigStore(contentsOf: url)
        let ids = store.config.scenes.flatMap { $0.pages.compactMap(\.id) }
        #expect(Set(ids).count == ids.count, "去重后不应有重复: \(ids)")
    }

    /// 删除当前页之前的页:视图指针平移(旧实现只做越界钳制,看 B 删 A 会跳到 C)
    @Test("deletePage 删当前页之前的页时平移 currentPageIndex")
    @MainActor
    func deletePageShiftsCurrentIndex() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-delpage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        let json = """
        {
          "scenes" : [ { "name" : "A", "pages" : [ { "keys" : [] }, { "keys" : [] }, { "keys" : [] } ] } ],
          "currentSceneIndex" : 0,
          "currentPageIndex" : 1,
          "brightness" : 80
        }
        """
        try Data(json.utf8).write(to: url)
        let store = ConfigStore(contentsOf: url)
        store.deletePage(sceneIndex: 0, pageIndex: 0) // 删正在看的 B(index 1)之前的 A
        #expect(store.config.currentPageIndex == 0, "看 B 删 A 后应仍看 B: \(store.config.currentPageIndex)")
    }
}

// MARK: - §6.28 挂账清理轮:枚举前向宽容 + 归档清扫

extension ConfigDecodeTests {
    /// 高版本 app 写入的未知枚举 case 只降级**该键**(动作置空),整份配置照常解码——
    /// 旧行为 rawValue 解码 throw → 归档 + 全量重置,回退旧版构建一次就丢全部配置
    @Test("未知枚举 case:该键动作降级,配置主体存活")
    @MainActor
    func unknownEnumCaseDegradesSingleKey() throws {
        let json = """
        {
          "scenes" : [ { "name" : "A", "pages" : [ { "keys" : [
            { "title" : "新版本动作键", "backgroundColorHex" : "#BF616A", "action" : { "brandNewCase" : 7 } },
            { "title" : "正常键", "backgroundColorHex" : "#3B4252" }
          ] } ] } ],
          "currentSceneIndex" : 0,
          "currentPageIndex" : 0,
          "brightness" : 80
        }
        """
        let data = try #require(json.data(using: .utf8))
        let config = try JSONDecoder().decode(AppConfig.self, from: data)
        let keys = config.scenes[0].pages[0].keys
        #expect(keys[0].action == nil, "未知 case 应降级为无动作")
        #expect(keys[0].title == "新版本动作键", "键的其余字段不丢")
        #expect(keys[1].title == "正常键", "其余键不受影响")
    }

    /// 损坏归档只保留最近 10 份,启动时清扫过期归档(此前无限堆积)
    @Test("损坏归档清扫:超过 10 份删最旧")
    @MainActor
    func archiveSweepKeepsTen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opendeck-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 合法配置 + 12 份归档(时间戳递增,字典序 = 时间序)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        for index in 0..<12 {
            // 用插值而非 String(format:%d):%d 按 CInt(Int32) 截断,13 位毫秒值会变负数
            let name = "config.corrupt-\(1_700_000_000_000 + index)-undecodable.json"
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        _ = ConfigStore(contentsOf: dir.appendingPathComponent("config.json"))

        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("config.corrupt-") }
        #expect(remaining.count == 10, "应保留最近 10 份,实存 \(remaining.count) 名单:\(remaining.sorted())")
        // 保留的应是时间戳最新的那批
        #expect(remaining.contains("config.corrupt-1700000000011-undecodable.json"))
        #expect(!remaining.contains("config.corrupt-1700000000000-undecodable.json"))
    }
}
