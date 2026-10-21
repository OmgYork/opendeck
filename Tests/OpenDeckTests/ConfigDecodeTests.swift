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
