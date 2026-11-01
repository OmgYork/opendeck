import AppKit
import os
import SwiftUI

// MARK: - 触控板手势与模态抑制

// 自 EditorView.swift 拆出(2026-11-01 瘦身):手势引擎与 Sheet 抑制开关,
// 与编辑器视图无布局耦合,单独成文件便于测试与阅读。

/// 任一 Sheet 打开 → 滑动手势让路,滚动交还给面板(键编辑 PI/调参/插件管理/场景联动)。
/// 用 ViewModifier 而非实例方法:链式调用查的是 View 值的类型,查不到 EditorView 的私有方法
struct ModalSwipeSuppression: ViewModifier {
    let monitor: SwipePageMonitor
    let editing: Bool
    let layout: Bool
    let manager: Bool
    let binding: Bool
    let template: Bool
    let logs: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: editing) { _, value in
                monitor.isSuppressed = value
            }
            .onChange(of: layout) { _, value in
                monitor.isSuppressed = value
            }
            .onChange(of: manager) { _, value in
                monitor.isSuppressed = value
            }
            .onChange(of: binding) { _, value in
                monitor.isSuppressed = value
            }
            .onChange(of: template) { _, value in
                monitor.isSuppressed = value
            }
            .onChange(of: logs) { _, value in
                monitor.isSuppressed = value
            }
    }
}

final class SwipePageMonitor {
    private var token: Any?
    /// 回调:isHorizontal(水平=切场景/垂直=场景内翻页)+ 方向(+1 下一/-1 上一)
    var onSwipe: ((_ isHorizontal: Bool, _ direction: Int) -> Void)?
    /// 模态抑制:Sheet(键编辑/调参/插件管理/场景联动)打开时手势让路,滚动交还给面板
    var isSuppressed = false
    /// 指针悬停在调色盘(停靠右列)内:滚动只作用于调色盘自身的 ScrollView,不触发翻页
    var isPointerOverPalette = false

    private var horizontalAccumulated: CGFloat = 0
    private var verticalAccumulated: CGFloat = 0
    /// 一次手指接触周期内至多步进 1
    private var flipped = false
    private var gestureActive = false
    /// 阈值:累积滚动量达到即触发(触控板一指行程约 10–30)
    private let threshold: CGFloat = 30
    /// 传统滚轮一格 = 一步:非精确增量单位是「行」,一格约 ±1~±3;若沿用触控板阈值 30
    /// 等于要滚 10~30 格才翻一页,体感即「滚轮没反应」(2026-10-17 用户反馈)
    private let wheelStep: CGFloat = 1
    /// 传统滚轮(无精确增量、无相位)的触发冷却
    private var wheelCooldownUntil = Date.distantPast
    /// 上一格滚轮时刻:两格间隔超 0.5s 视为新动作,清掉零星半行残余防误触
    private var lastWheelAt = Date.distantPast

    func start() {
        end()
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func end() {
        if let token {
            NSEvent.removeMonitor(token)
        }
        token = nil
        horizontalAccumulated = 0
        verticalAccumulated = 0
        gestureActive = false
        flipped = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        // 模态上下文(Sheet 打开):手势让路,滚动交还给面板;抑制期动量也放行
        if isSuppressed { return event }
        // 指针在调色盘(停靠右列)内:滚动只作用于调色盘自身(其 ScrollView),不翻页
        if isPointerOverPalette { return event }

        let dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY

        // 惯性尾流(手指离开后的动量滚动):一律吞掉——"快扫连翻"的根源。
        // 动量结束、下一次 phase .began 到来才开启新的一次扫动。
        if event.momentumPhase != [] { return nil }

        // 分流依据是「有无手势相位」而非「是否精确增量」:机械滚轮无相位且非精确;
        // Logi Options+ 等平滑滚动驱动是精确增量但同样无相位——若按精确路由进触控板分支,
        // 手势永远等不到 .ended,翻一页后 flipped 卡死,滚轮从此失灵(2026-10-17 用户反馈)
        guard event.phase != [] else {
            return handleDiscrete(dx: dx, dy: dy, precise: event.hasPreciseScrollingDeltas)
        }

        // 触控板精确手势:一次接触周期(phase began→changed→ended)至多步进 1
        if event.phase == .began || !gestureActive {
            horizontalAccumulated = 0
            verticalAccumulated = 0
            flipped = false
            gestureActive = true
        }
        if event.phase == .ended {
            gestureActive = false // 周期结束:下一次事件(无论相位)开启新扫动
        }

        // 手势周期内的所有滚动一律吞掉(网格内容固定,页面不晃)
        if abs(dx) > abs(dy) {
            horizontalAccumulated += dx
            guard !flipped, abs(horizontalAccumulated) >= threshold else { return nil }
            flipped = true
            // 自然滚动:双指左扫 deltaX 为正 = 看右侧内容 = 下一场景
            let direction = horizontalAccumulated > 0 ? 1 : -1
            horizontalAccumulated = 0
            onSwipe?(true, direction)
            return nil
        }
        if abs(dy) >= abs(dx) {
            verticalAccumulated += dy
            guard !flipped, abs(verticalAccumulated) >= threshold else { return nil }
            flipped = true
            // 自然滚动:双指上扫 deltaY 为负 = 看下方内容 = 下一页。
            // deltaY 与 deltaX 符号约定相反(水平左扫为正),以真机实证为准,勿按直觉假设
            let direction = verticalAccumulated > 0 ? -1 : 1
            verticalAccumulated = 0
            onSwipe?(false, direction)
            return nil
        }
        return nil
    }

    /// 无相位的离散滚动(机械滚轮 / 平滑滚动驱动):一步一触发 + 0.35s 冷却防连翻,全程吞掉;
    /// 机械滚轮增量单位是行(一格 ±1~±3)→ 步长 1;精确增量单位是点 → 步长 20(一格约 10~40 点)。
    /// 诊断日志(默认级别,log show 可查):每个滚动突发首事件 + 每次触发,定位设备类别与方向
    private func handleDiscrete(dx: CGFloat, dy: CGFloat, precise: Bool) -> NSEvent? {
        let now = Date()
        if now.timeIntervalSince(lastWheelAt) > 0.5 {
            horizontalAccumulated = 0
            verticalAccumulated = 0
            Self.swipeLog.notice("离散滚动开始 precise=\(precise) dx=\(dx) dy=\(dy)")
        }
        lastWheelAt = now
        guard now >= wheelCooldownUntil else { return nil }
        let step: CGFloat = precise ? 20 : wheelStep
        if abs(dx) > abs(dy) {
            horizontalAccumulated += dx
            guard abs(horizontalAccumulated) >= step else { return nil }
            // 右滚(Shift+滚轮转水平)= 看右侧 = 下一场景
            let direction = horizontalAccumulated > 0 ? 1 : -1
            horizontalAccumulated = 0
            wheelCooldownUntil = now.addingTimeInterval(0.35)
            Self.swipeLog.notice("离散触发 水平 direction=\(direction)")
            onSwipe?(true, direction)
            return nil
        }
        if dy != 0 {
            verticalAccumulated += dy
            guard abs(verticalAccumulated) >= step else { return nil }
            // 滚轮下滚 = 内容下移 = 下一页(AppKit 符号:deltaY 正 = 向上滚)
            let direction = verticalAccumulated > 0 ? -1 : 1
            verticalAccumulated = 0
            wheelCooldownUntil = now.addingTimeInterval(0.35)
            Self.swipeLog.notice("离散触发 垂直 direction=\(direction) acc=\(dy)")
            onSwipe?(false, direction)
            return nil
        }
        return nil
    }

    private static let swipeLog = Logger(subsystem: "opendeck", category: "swipe")
}

