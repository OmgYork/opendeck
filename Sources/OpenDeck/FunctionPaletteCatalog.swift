import Foundation

// MARK: - 功能调色盘目录（单一事实源）
//
// 从「显示器功能托盘」泛化而来的全功能调色盘目录：所有可拖拽/点选的磁贴在此登记，
// 载荷解析只有 item(forPayload:) 一个入口（槽位绑定、磁贴渲染、点选提示共用，
// 不再各自手写分支——旧实现三处分支必须人肉同步，这里收敛成一处）。
//
// 载荷格式（纯文本承载，超集兼容旧格式）：
// - "<MonitorCommand.rawValue>"  显示器 DDC 命令（MonitorCommand 仍是其唯一事实源，派生不落枚举）
// - "composite:<id>"             复合磁贴（动作+动效完整配方，见 MonitorCompositeCatalog）
// - "action:<name>"              即用动作，落下即可用
// - "action:mediaKey:<value>"    即用媒体动作（6 个取值，与 ActionRunner.mediaKeyCodes 同域）
// - "template:<kind>"            待配置模板：落下后 action = nil、template 占位，
//                                点开编辑器按模板预选类型补参数
//
// 磁贴 = 落键语义 1:1：item 的 title/action/animation/template 就是 bindPayload
// 写入槽位的内容（仅底色/自定义图标沿用槽位现状）。

/// 调色盘一枚磁贴：即用动作（action != nil）或待配置模板（template != nil）二选一。
/// 构造入口都在 extension（主体不声明 init，保住逐成员合成 init）。
struct FunctionPaletteItem: Identifiable, Hashable {
    /// 拖拽/点选统一载荷
    let payload: String
    /// 键帽标题（落下后写入 KeyConfig.title）
    let title: String
    /// tooltip 备注
    let note: String?
    /// 落键动作（即用项；模板项恒为 nil）
    let action: KeyAction?
    /// 待配置模板占位（模板项；即用项为 nil）
    let template: KeyTemplate?
    /// 落键附带的动效键面（显示器输入类命令等）
    let animation: KeyAnimation?

    var id: String { payload }
}

extension FunctionPaletteItem {
    /// 即用项
    static func ready(
        _ payload: String, _ title: String, note: String? = nil,
        animation: KeyAnimation? = nil, action: KeyAction
    ) -> FunctionPaletteItem {
        FunctionPaletteItem(payload: payload, title: title, note: note,
                            action: action, template: nil, animation: animation)
    }

    /// 模板项（action 恒为 nil，占位期间键不可用）
    static func template(
        _ kind: KeyTemplate, _ title: String, note: String? = nil
    ) -> FunctionPaletteItem {
        FunctionPaletteItem(payload: "template:\(kind.rawValue)", title: title, note: note,
                            action: nil, template: kind, animation: nil)
    }

    /// 显示器命令派生（旧格式 <MonitorCommand.rawValue>）
    init(command: MonitorCommand) {
        self.init(payload: command.rawValue, title: command.title, note: command.spec.note,
                  action: .monitor(command), template: nil,
                  animation: command.carriesInputAnimation ? .monitorInput : nil)
    }

    /// 复合磁贴派生（"composite:<id>"）
    init(tile: MonitorCompositeTile) {
        self.init(payload: tile.payload, title: tile.title, note: tile.note,
                  action: tile.action, template: nil, animation: tile.animation)
    }
}

/// 调色盘顶层分类。显示器分类特殊：由 MonitorCommand / MonitorCompositeCatalog
/// 直接派生并保留二级分组，不在此枚举；其余分类为扁平磁贴列表。
struct FunctionPaletteCategory: Identifiable, Hashable {
    /// 折叠状态 key（EditorView/视图的 collapsedSections 用）
    let key: String
    let title: String
    let items: [FunctionPaletteItem]

    var id: String { key }
}

enum FunctionPaletteCatalog {
    /// 「自定义」页签镜像的槽位清单(0-based index;即面板 1-based 槽位 2/3/5/11/13,用户指定)。
    /// 磁贴 = 这些槽位当下的实时镜像,拖拽 = 整键复刻(见 EditorView.bindPayload 的 slot: 分支)。
    static let customSlotIndices: [Int] = [1, 2, 4, 10, 12]

    /// 显示器之外的扁平分类（渲染顺序即数组顺序）
    static let flatCategories: [FunctionPaletteCategory] = [
        FunctionPaletteCategory(key: "nav", title: "翻页 / 场景", items: [
            .ready("action:previousPage", "上一页", action: .previousPage),
            .ready("action:nextPage", "下一页", action: .nextPage),
            .ready("action:pageIndicator", "页面指示", note: "键面动态显示 N/M", action: .pageIndicator),
            .ready("action:previousScene", "上一场景", action: .previousScene),
            .ready("action:nextScene", "下一场景", action: .nextScene),
        ]),
        FunctionPaletteCategory(key: "media", title: "媒体控制", items: [
            .ready("action:mediaKey:playPause", "播放 / 暂停", action: .mediaKey("playPause")),
            .ready("action:mediaKey:next", "下一曲", action: .mediaKey("next")),
            .ready("action:mediaKey:previous", "上一曲", action: .mediaKey("previous")),
            .ready("action:mediaKey:volumeUp", "增大音量", action: .mediaKey("volumeUp")),
            .ready("action:mediaKey:volumeDown", "减小音量", action: .mediaKey("volumeDown")),
            .ready("action:mediaKey:mute", "静音", action: .mediaKey("mute")),
        ]),
        FunctionPaletteCategory(key: "system", title: "系统", items: [
            .ready("action:stat:gpu", "GPU", note: "实时利用率,整帧 2s 刷新", action: .stat(.gpu)),
            .ready("action:stat:cpu", "CPU", note: "实时利用率,整帧 2s 刷新", action: .stat(.cpu)),
            .ready("action:stat:temp", "温度", note: "CPU 温度,整帧 2s 刷新", action: .stat(.temp)),
            .ready("action:screenOff", "熄屏", note: "任意按键唤醒", action: .screenOff),
            .ready("action:sleepGuard", "合盖休眠锁",
                   note: "需要 /etc/sudoers.d/pmset-disablesleep 免密放行", action: .sleepGuard),
        ]),
        FunctionPaletteCategory(key: "template", title: "模板（拖入后配置）", items: [
            .template(.openApp, "打开应用", note: "点击配置应用，配好后拖到键位"),
            .template(.openURL, "打开网址", note: "点击填写网址，配好后拖到键位"),
            .template(.runShortcut, "快捷指令", note: "点击填写名称，配好后拖到键位"),
            .template(.shellScript, "Shell 脚本", note: "点击编写脚本，配好后拖到键位"),
            .template(.appleScript, "AppleScript", note: "点击编写脚本，配好后拖到键位"),
            .template(.hotkey, "热键", note: "点击录制组合键，配好后拖到键位"),
        ]),
    ]

    /// 载荷 → 磁贴（唯一解析入口；旧格式 <MonitorCommand.rawValue> / "composite:<id>" 继续有效）
    static func item(forPayload raw: String) -> FunctionPaletteItem? {
        // 扁平分类直查（载荷互不碰撞由 FunctionPaletteTests 守护）
        for category in flatCategories {
            if let item = category.items.first(where: { $0.payload == raw }) { return item }
        }
        // 旧格式派生：复合磁贴 / 显示器命令
        if let tile = MonitorCompositeCatalog.tile(payload: raw) {
            return FunctionPaletteItem(tile: tile)
        }
        if let command = MonitorCommand(rawValue: raw) {
            return FunctionPaletteItem(command: command)
        }
        return nil
    }
}
