import AppKit
import Foundation
import StreamDockKit
import os

/// 场景/页面路由域:两级导航(场景 → 页面)、场景与页面的增删、以及按前台应用联动切换场景。
///
/// 纯搬移:所有切换方法的「先落配置、再整页上屏」次序、同场景/同页的早退守卫、
/// 联动时的日志文案与 oslog 记录都与拆分前逐字一致。
///
/// 上屏由持有者注入:路由器只改配置里的当前场景/当前页,画键面是 AppModel 的事
/// (它握着设备与插件宿主)。这样路由器不需要知道渲染的任何细节。
@MainActor
final class SceneRouter {
    /// 诊断日志钩子(与其它子系统一致:在持有者 init 里挂接)
    var onLog: ((String) -> Void)?

    private let config: ConfigStore
    private let device: DeviceController

    /// 整页下发(由 AppModel 在 init 里挂接:applyPageToDevice)。
    /// 与 onLog 同样走「构造后再挂接」而不是构造参数——AppModel 是 @Observable 类,
    /// 在自己的存储属性初始化表达式里捕获 self 会编译失败。
    var applyPage: (() -> Void)?
    /// 编辑器窗口是否可见(官方语义为「应用窗口关闭时」才做前台切换,配置期间不打扰)。
    /// 状态本身留在 AppModel:它是会被 UI 写的可观察属性,搬进普通对象会丢掉观察。
    var isEditorWindowVisible: () -> Bool = { true }

    init(config: ConfigStore, device: DeviceController) {
        self.config = config
        self.device = device
    }

    // MARK: - 切换

    /// 切换到指定场景;同场景重复切换无副作用
    func switchScene(to id: UUID) {
        guard let index = config.indexOfScene(id: id), index != config.config.currentSceneIndex else { return }
        config.setCurrentSceneIndex(index)
        applyPage?()
    }

    /// 循环切换场景(上一场景/下一场景;落到目标场景第一页)
    func switchScene(offset: Int) {
        guard let target = config.targetSceneIndex(offset: offset) else { return }
        config.setCurrentSceneIndex(target)
        applyPage?()
    }

    /// 切换到指定页(跨场景按 Page.id 定位;圆点点击直达用)
    func switchPage(to id: UUID) {
        guard let location = config.pageLocation(id: id) else { return }
        guard location.sceneIndex != config.config.currentSceneIndex
                || location.pageIndex != config.config.currentPageIndex else { return }
        config.setCurrentSceneIndex(location.sceneIndex)
        config.currentPageIndex = location.pageIndex
        applyPage?()
    }

    /// 场景内循环翻页(上一页/下一页)
    func switchPage(offset: Int) {
        guard let target = config.targetPageIndex(offset: offset) else { return }
        config.currentPageIndex = target
        applyPage?()
    }

    /// 兼容旧配置的 gotoPage 动作:跨场景按 Page.id 定位。
    /// 与 switchPage(to:) 差别在于**没有**「已在该页则早退」的守卫——旧实现总会重发整页,
    /// 这里刻意保留,避免纯重构引入上屏次数变化。
    func gotoLegacyPage(_ pageID: UUID) {
        if let location = config.pageLocation(id: pageID) {
            config.setCurrentSceneIndex(location.sceneIndex)
            config.currentPageIndex = location.pageIndex
            applyPage?()
        }
    }

    // MARK: - 场景增删

    func addScene() {
        let id = config.addScene()
        switchScene(to: id)
    }

    func duplicateScene(id: UUID) {
        _ = config.duplicateScene(id: id)
    }

    /// 删除场景;若删的是当前场景(索引被回退),设备需重画新当前场景
    func deleteScene(id: UUID) {
        config.deleteScene(id: id)
        applyPage?()
    }

    // MARK: - 页面增删

    /// 当前场景加一页(圆点 +1)并切到新页
    func addPageToCurrentScene() {
        let sceneIndex = config.config.currentSceneIndex
        guard config.addPage(toSceneIndex: sceneIndex) != nil else { return }
        config.currentPageIndex = config.currentScene.pages.count - 1
        applyPage?()
    }

    /// 给指定场景加一页(圆点 +1)并切到该场景新页
    func addPage(toScene id: UUID) {
        guard let sceneIndex = config.indexOfScene(id: id),
              config.addPage(toSceneIndex: sceneIndex) != nil
        else { return }
        switchScene(to: id)
        config.currentPageIndex = config.currentScene.pages.count - 1
        applyPage?()
    }

    /// 删除当前场景内的一页(每场景至少保留 1 页)
    func deletePageInCurrentScene(at pageIndex: Int) {
        config.deletePage(sceneIndex: config.config.currentSceneIndex, pageIndex: pageIndex)
        applyPage?()
    }

    // MARK: - 场景联动(前台应用自动切换场景)

    /// 前台应用变化:优先切到绑定了该应用的场景;无绑定且设了默认场景则回默认场景
    func autoSwitchPageForFrontmostApp() {
        guard !isEditorWindowVisible(), !device.isScreenOff else { return }
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        Self.oslog.debug("联动评估:前台=\(bundleID, privacy: .public)")
        let currentSceneID = config.currentSceneID
        if let bound = config.sceneBoundToApp(bundleID) {
            if bound.id != currentSceneID, let id = bound.id {
                onLog?("场景联动:「\(bundleID)」→ 场景「\(bound.name)」")
                switchScene(to: id)
            }
            return
        }
        if let defaultID = config.config.defaultSceneID,
           defaultID != currentSceneID,
           config.indexOfScene(id: defaultID) != nil {
            onLog?("场景联动:「\(bundleID)」无绑定 → 默认场景")
            switchScene(to: defaultID)
        }
    }

    /// 已安装应用清单(场景联动下拉用;/Applications + /System/Applications,按名称排序)
    nonisolated static func installedApps() -> [(bundleID: String, name: String)] {
        var directories = FileManager.default.urls(for: .applicationDirectory, in: .systemDomainMask)
        directories.append(URL(fileURLWithPath: "/System/Applications"))
        var seen = Set<String>()
        var apps: [(bundleID: String, name: String)] = []
        for directory in directories {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            ) else { continue }
            for url in items where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier,
                      bundleID != "com.opendeck.app", !seen.contains(bundleID)
                else { continue }
                seen.insert(bundleID)
                let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                    ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                    ?? url.deletingPathExtension().lastPathComponent
                apps.append((bundleID, name))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 与 AppModel 同名同参的 Logger:拆分前只有这一处 debug 记录,输出通道保持不变
    private static let oslog = Logger(subsystem: "opendeck", category: "device")
}
