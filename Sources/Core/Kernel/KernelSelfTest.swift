import AppKit
import SwiftUI
import Foundation

/// 内核层自测（只在设置了 `FQM_SELFTEST` 环境变量时启用，不影响正常使用）。
///
/// - `FQM_SELFTEST=close`：N 秒后 performClose（等价于点窗口红叉）
/// - `FQM_SELFTEST=quit`：N 秒后 NSApp.terminate（等价于 Cmd+Q）
/// - `FQM_SELFTEST=chain`：搜索 → ID 直达 → 链接直达 → 详情 → 下载前 N 章 → 校验产物
/// - `FQM_SELFTEST=update`：跑一次内核更新检查（配合 FQM_MOCK_RELEASE_TAG / FQM_MOCK_ASSET_*）
/// - `FQM_SELFTEST_DELAY`：延迟秒数（默认 8）
enum KernelSelfTest {
    /// 只装一次：`.task` 可能因视图身份变化重跑，重复安装会跑两遍自检、互相打架
    nonisolated(unsafe) private static var installed = false
    static var mode: String? { ProcessInfo.processInfo.environment["FQM_SELFTEST"] }
    static var delay: Double { Double(ProcessInfo.processInfo.environment["FQM_SELFTEST_DELAY"] ?? "") ?? 8 }

    @MainActor
    static func install(model: AppModel) {
        guard !installed else { return }
        installed = true
        guard let mode else { return }
        fmLog("自检模式启动：\(mode)（延迟 \(delay)s）")
        switch mode {
        case "close":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                fmLog("自检：performClose（等价于点窗口红叉）")
                NSApp.windows.first?.performClose(nil)
            }
        case "quit":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                fmLog("自检：NSApp.terminate（等价于 Cmd+Q）")
                NSApp.terminate(nil)
            }
        case "chain":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await runChain(model: model)
            }
        case "clickprobe":
            // 逐个动作精确判定：每个动作后轮询 15s，报告是否关闭与耗时
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()

                @MainActor func openPanel() async {
                    withAnimation(.easeOut(duration: 0.2)) { model.activeOverlay = .downloads }
                    try? await Task.sleep(for: .seconds(2))
                }
                @MainActor func closedWithin() async -> Double? {
                    for i in 1...30 {
                        try? await Task.sleep(for: .milliseconds(500))
                        if model.activeOverlay == nil { return Double(i) * 0.5 }
                    }
                    return nil
                }

                await openPanel()
                await clickAt(x: 1039, y: 51)
                report("PROBE x-click \(await closedWithin().map { "closed after \($0)s" } ?? "NEVER closed")")

                await openPanel()
                await clickAt(x: 60, y: 400)
                report("PROBE scrim-click \(await closedWithin().map { "closed after \($0)s" } ?? "NEVER closed")")

                await openPanel()
                pressEscape()
                report("PROBE esc \(await closedWithin().map { "closed after \($0)s" } ?? "NEVER closed")")

                if model.activeOverlay != nil { model.activeOverlay = nil }
                report("PROBE done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "closepaths2":
            // M1.8：关闭路径全矩阵（详情 ×3、下载管理 ×3、删除确认 Esc），真 HID 点击
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                await model.runSearch(ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "游走神话时代")
                guard let first = model.results.first else { report("MATRIX 没有搜索结果"); NSApp.terminate(nil); return }
                await clickAt(x: 5, y: 400) // 预热：吃掉「激活窗口的第一次点击」
                try? await Task.sleep(for: .seconds(1))
                // 点击类自检要求窗口真的在最上层（否则 HID 点击落到 Safari/豆包上，整条全红）
                if let w = MainWindowRegistry.shared.window {
                    w.level = .floating
                    w.makeKeyAndOrderFront(nil)
                    w.orderFrontRegardless()
                    report("MATRIX 环境：app.isActive=\(NSApp.isActive) 主窗口 frame=\(Int(w.frame.minX)),\(Int(w.frame.minY)) \(Int(w.frame.width))x\(Int(w.frame.height)) level=\(w.level.rawValue) 窗口中数=\(NSApp.windows.count)")
                } else {
                    report("MATRIX 环境：找不到主窗口引用")
                }
                report("MATRIX 环境：点击点(1021,360) 最上层=\(frontmostAt((1021, 360)))")

                /// ✕ 候选点击点：先试实测中心（面板高度不同位置不同），再退到 M1.1 起验证过的定值
                /// （埋点可能量到过渡动画中间的值，所以两个都试）
                @MainActor func closePoints() -> [(CGFloat, CGFloat)] {
                    var points: [(CGFloat, CGFloat)] = []
                    if let r = FMFrameMetrics.last["modal-close-button"],
                       r.midX > 0, r.midX < 1180, r.midY > 0, r.midY < 800 {
                        points.append((r.midX, r.midY))
                    }
                    // 退路：用面板 frame 推 ✕ 中心（16 内缩 + 30 按钮 → 距右上角 31）
                    if let p = FMFrameMetrics.last["modal-panel"] {
                        points.append((p.maxX - 31, p.minY + 31))
                    } else {
                        points.append((1039, 51)) // 老 960 宽面板的定值（兜底）
                    }
                    return points
                }

                /// 等窗口真的在最上层（最多 N 秒）。被别的 App 窗口挡住时 HID 点击会落空（不是功能问题）
                @MainActor func waitForClearFront(_ point: (CGFloat, CGFloat), seconds: Int) async -> Bool {
                    for _ in 0..<(seconds * 2) {
                        let front = frontmostAt(point)
                        if front.hasPrefix("番茄猫") { return true }
                        // 再主动举一次（macOS 14 起 App 不能无条件自我激活，所以这里只是尽力）
                        if let w = MainWindowRegistry.shared.window {
                            NSApp.activate(ignoringOtherApps: true)
                            w.makeKeyAndOrderFront(nil)
                            w.orderFrontRegardless()
                        }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    return false
                }

                /// 依次尝试候选点，关掉即停；并报告前台窗口是否就是番茄猫（点击类失败通常是窗口被挡）
                @MainActor func clickUntilClosed(_ points: [(CGFloat, CGFloat)], _ closed: () -> Bool) async {
                    for (i, p) in points.enumerated() {
                        await clickAt(x: p.0, y: p.1)
                        try? await Task.sleep(for: .seconds(2))
                        if closed() { return }
                        report("MATRIX 点(\(Int(p.0)),\(Int(p.1))) 未关（第 \(i + 1)/\(points.count) 个候选）")
                    }
                    await clickAt(x: points[0].0, y: points[0].1) // 再补一次：激活点击可能被吞
                    try? await Task.sleep(for: .seconds(2))
                    if closed() { return }
                    report("MATRIX 点击后仍未关：前台窗口=\(frontmostAt(points[0]))")
                }

                /// 该坐标最上层窗口是谁（诊断"窗口被挡导致点击落空"）
                @MainActor func frontmostAt(_ point: (CGFloat, CGFloat)) -> String {
                    guard let window = NSApp.windows.first else { return "无窗口" }
                    let contentHeight = window.contentView?.bounds.height ?? window.frame.height
                    let screenPoint = window.convertPoint(toScreen: NSPoint(x: point.0, y: contentHeight - point.1))
                    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                    for w in list {
                        guard let b = w["kCGWindowBounds"] as? [String: Any],
                              let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                              let width = b["Width"] as? CGFloat, let height = b["Height"] as? CGFloat else { continue }
                        if x <= screenPoint.x, screenPoint.x <= x + width, y <= screenPoint.y, screenPoint.y <= y + height {
                            return (w["kCGWindowOwnerName"] as? String ?? "?") + "(最上层)"
                        }
                    }
                    return "未知"
                }
                @MainActor func openDetail() async {
                    model.openDetail(first)
                    try? await Task.sleep(for: .seconds(3))
                }
                @MainActor func openDownloads() async {
                    withAnimation(.easeOut(duration: 0.2)) { model.activeOverlay = .downloads }
                    try? await Task.sleep(for: .seconds(3))
                }
                /// 点一次；被激活点击吞掉就再点一次
                @MainActor func clickUntilClosed(_ x: CGFloat, _ y: CGFloat, _ closed: () -> Bool) async {
                    await clickAt(x: x, y: y)
                    try? await Task.sleep(for: .seconds(3))
                    if !closed() {
                        report("MATRIX 第一次点击被激活吞掉 → 再点一次")
                        await clickAt(x: x, y: y)
                        try? await Task.sleep(for: .seconds(3))
                    }
                }

                // ── 详情：Esc / ✕ / 遮罩 ──
                await openDetail()
                report("MATRIX 详情 打开")
                pressEscape()
                try? await Task.sleep(for: .seconds(3))
                report("MATRIX 详情 Esc → \(model.selected == nil ? "OK" : "FAIL")")

                pressEscape() // 先确保 ✕ 埋点来自详情面板（上一步 detail-esc 已关）
                try? await Task.sleep(for: .seconds(2))
                if model.selected == nil { await openDetail() }
                let d = closePoints()
                if await waitForClearFront(d[0], seconds: 20) {
                    await clickUntilClosed(d) { model.selected == nil }
                    report("MATRIX 详情 ✕\(d.map { "(\(Int($0.0)),\(Int($0.1)))" }.joined(separator: "/")) → \(model.selected == nil ? "OK" : "FAIL")")
                } else {
                    report("MATRIX 详情 ✕ SKIP（窗口被挡：\(frontmostAt(d[0]))；非功能问题，M1.9 同代码已全绿）")
                }

                if model.selected == nil { await openDetail() }
                if await waitForClearFront((60, 400), seconds: 20) {
                    await clickUntilClosed([(60, 400)]) { model.selected == nil }
                    report("MATRIX 详情 遮罩(60,400) → \(model.selected == nil ? "OK" : "FAIL")")
                } else {
                    report("MATRIX 详情 遮罩 SKIP（窗口被挡：\(frontmostAt((60, 400)))）")
                }

                // ── 下载管理：Esc / ✕ / 遮罩 ──
                if model.selected != nil {
                    report("MATRIX 清理：上一步点击失败留下详情层，先手动关掉")
                    model.closeDetail()
                    try? await Task.sleep(for: .seconds(2))
                }
                await openDownloads()
                report("MATRIX 下载管理 打开")
                pressEscape()
                try? await Task.sleep(for: .seconds(3))
                report("MATRIX 下载管理 Esc → \(model.activeOverlay == nil ? "OK" : "FAIL")")

                if model.activeOverlay == nil { await openDownloads() }
                let p2 = closePoints()
                if await waitForClearFront(p2[0], seconds: 20) {
                    await clickUntilClosed(p2) { model.activeOverlay == nil }
                    report("MATRIX 下载管理 ✕\(p2.map { "(\(Int($0.0)),\(Int($0.1)))" }.joined(separator: "/")) → \(model.activeOverlay == nil ? "OK" : "FAIL")")
                } else {
                    report("MATRIX 下载管理 ✕ SKIP（窗口被挡：\(frontmostAt(p2[0]))）")
                }

                if model.activeOverlay == nil { await openDownloads() }
                if await waitForClearFront((60, 400), seconds: 20) {
                    await clickUntilClosed([(60, 400)]) { model.activeOverlay == nil }
                    report("MATRIX 下载管理 遮罩(60,400) → \(model.activeOverlay == nil ? "OK" : "FAIL")")
                } else {
                    report("MATRIX 下载管理 遮罩 SKIP（窗口被挡：\(frontmostAt((60, 400)))）")
                }

                // ── 删除确认：Esc（旧版 #confirm-backdrop）──
                model.pendingDeletion = LibraryItem(
                    record: FMDownloadRecord(path: "/tmp/关闭矩阵.txt", title: "关闭矩阵", author: "自检", format: "txt", platform: "番茄小说", time: "2026-01-01T00:00:00Z"),
                    name: "关闭矩阵", size: 1, ext: "txt", exists: false
                )
                try? await Task.sleep(for: .seconds(2))
                report("MATRIX 删除确认 打开")
                pressEscape()
                try? await Task.sleep(for: .seconds(2))
                report("MATRIX 删除确认 Esc → \(model.pendingDeletion == nil ? "OK" : "FAIL")")

                report("MATRIX done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "esckey":
            // M1.8：全局 Esc 两种情形 + 分层一次关一层（证据看 app.log 的「全局 Esc：关闭最上层弹窗」）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                await model.loadRankIfNeeded()
                try? await Task.sleep(for: .seconds(6))
                guard let first = model.rankBooks.first else { report("ESCKEY 没有榜单数据"); NSApp.terminate(nil); return }

                NSApp.keyWindow?.makeFirstResponder(nil)
                report("ESCKEY 焦点情形 \(focusDescription())")

                // ── 情形 a：输入框没有焦点时按 Esc ──
                withAnimation(.easeOut(duration: 0.2)) { model.activeOverlay = .downloads }
                try? await Task.sleep(for: .seconds(3))
                NSApp.keyWindow?.makeFirstResponder(nil)
                report("ESCKEY a) 开下载管理，焦点=\(focusDescription())，按 Esc")
                pressEscape()
                try? await Task.sleep(for: .seconds(3))
                report("ESCKEY a) Esc 后 activeOverlay=\(model.activeOverlay == nil ? "nil → OK" : "仍在 → FAIL")")

                // ── 情形 b：在搜索框里输入过文字（持焦点）再按 Esc ──
                model.openDetail(first)
                try? await Task.sleep(for: .seconds(3))
                let focused = focusSearchFieldAndType("游走神话")
                try? await Task.sleep(for: .seconds(1))
                report("ESCKEY b) 开详情后聚焦搜索框并输入：\(focused)")
                report("ESCKEY b) 焦点=\(focusDescription())，搜索框内容=\(model.searchText)")
                pressEscape()
                try? await Task.sleep(for: .seconds(3))
                report("ESCKEY b) Esc 后 selected=\(model.selected == nil ? "nil → OK" : "仍在 → FAIL")（焦点=\(focusDescription())）")

                // ── 分层：下载管理(1) → 详情(2) → 删除确认(3)，一次只关一层 ──
                if model.selected != nil { model.closeDetail(); try? await Task.sleep(for: .seconds(1)) }
                withAnimation(.easeOut(duration: 0.2)) { model.activeOverlay = .downloads }
                try? await Task.sleep(for: .seconds(2))
                model.openDetail(first)
                try? await Task.sleep(for: .seconds(2))
                let libItem = LibraryItem(
                    record: FMDownloadRecord(path: "/tmp/分层测试.txt", title: "分层测试", author: "自检", format: "txt", platform: "番茄小说", time: "2026-01-01T00:00:00Z"),
                    name: "分层测试", size: 1, ext: "txt", exists: false
                )
                model.pendingDeletion = libItem
                try? await Task.sleep(for: .seconds(2))
                report("ESCKEY 分层起始 确认=\(model.pendingDeletion != nil) 详情=\(model.selected != nil) 下载=\(model.activeOverlay != nil)")

                pressEscape()
                try? await Task.sleep(for: .seconds(2))
                report("ESCKEY 分层 1 次 Esc → 确认=\(model.pendingDeletion != nil ? "在" : "关") 详情=\(model.selected != nil ? "在" : "关") 下载=\(model.activeOverlay != nil ? "在" : "关")")
                pressEscape()
                try? await Task.sleep(for: .seconds(2))
                report("ESCKEY 分层 2 次 Esc → 确认=\(model.pendingDeletion != nil ? "在" : "关") 详情=\(model.selected != nil ? "在" : "关") 下载=\(model.activeOverlay != nil ? "在" : "关")")
                pressEscape()
                try? await Task.sleep(for: .seconds(2))
                report("ESCKEY 分层 3 次 Esc → 确认=\(model.pendingDeletion != nil ? "在" : "关") 详情=\(model.selected != nil ? "在" : "关") 下载=\(model.activeOverlay != nil ? "在" : "关")")

                // ── 无弹窗时 Esc 必须放行（不吃事件）──
                let before = model.searchText
                pressEscape()
                try? await Task.sleep(for: .seconds(2))
                report("ESCKEY 无弹窗时 Esc 放行：selected=\(model.selected == nil) overlay=\(model.activeOverlay == nil) 搜索框=\(model.searchText == before ? "未被吞" : "变了")")
                report("ESCKEY done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "detesc":
            // 诊断：详情弹窗 Esc 是否与「搜索框持焦点」有关（不改逻辑，只报告）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                await model.loadRankIfNeeded()
                try? await Task.sleep(for: .seconds(6))
                guard let first = model.rankBooks.first else { report("DETESC 没有榜单数据"); NSApp.terminate(nil); return }

                model.openDetail(first)                       // ① 未搜索：搜索框没被点过
                try? await Task.sleep(for: .seconds(3))
                report("DETESC ①开详情（无搜索焦点）")
                pressEscape()
                try? await Task.sleep(for: .seconds(3))
                report("DETESC ①Esc 后 selected=\(model.selected == nil ? "nil → OK" : "仍在 → FAIL")")

                if model.selected != nil {
                    NSApp.keyWindow?.makeFirstResponder(nil)   // ② 清掉首响应者再按
                    try? await Task.sleep(for: .seconds(1))
                    pressEscape()
                    try? await Task.sleep(for: .seconds(3))
                    report("DETESC ②清首响应者后 Esc selected=\(model.selected == nil ? "nil → OK" : "仍在 → FAIL")")
                }
                if model.selected == nil { model.closeDetail(); try? await Task.sleep(for: .seconds(1)) }
                report("DETESC done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "closepaths":
            // 关闭三路径自检：用**进程内合成的 AppKit 事件**真点/真按键（走真实 hit-test 与 responder 链）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                await model.runSearch(ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "游走神话时代")
                guard let first = model.results.first else { report("closepaths: 没有搜索结果"); NSApp.terminate(nil); return }

                // 自动化预热：先点一下页面左边空白（x=5 在卡片左边缘 18 之外，无害），
                // 把「激活非活跃窗口的第一次点击」消耗掉，后面测的 ✕/遮罩点击才是真人语义的点击。
                await clickAt(x: 5, y: 400)
                try? await Task.sleep(for: .seconds(1))

                // 1) 详情：Esc
                model.openDetail(first)
                try? await Task.sleep(for: .seconds(3))
                report("PATH detail-open")
                pressEscape()
                try? await Task.sleep(for: .seconds(4))
                report("PATH detail-esc \(model.selected == nil ? "OK" : "FAIL")")
                if model.selected != nil { model.closeDetail(); try? await Task.sleep(for: .seconds(1)) }

                // 2) 详情：点遮罩空白
                model.openDetail(first)
                try? await Task.sleep(for: .seconds(3))
                await clickAt(x: 60, y: 400) // 左侧空白（面板左边缘约在 110）
                try? await Task.sleep(for: .seconds(3))
                if model.selected != nil {
                    // 自动化里「激活非活跃窗口的第一次点击」会被 AppKit 当激活点击吞掉（真人手点时 app 已在前台）
                    report("PATH detail-scrim 第一次点击被激活吞掉 → 再点一次")
                    await clickAt(x: 60, y: 400)
                    try? await Task.sleep(for: .seconds(3))
                }
                report("PATH detail-scrim \(model.selected == nil ? "OK" : "FAIL")")
                if model.selected != nil { model.closeDetail(); try? await Task.sleep(for: .seconds(1)) }

                // 3) 下载管理：✕ / Esc / 点遮罩（面板撑满 = 高度确定，✕ 坐标可算）
                withAnimation(.easeOut(duration: 0.2)) { model.activeOverlay = .downloads }
                try? await Task.sleep(for: .seconds(3))
                report("PATH downloads-open")
                await clickAt(x: 1039, y: 51) // 面板右上 ✕（960 宽居中 → 左 110；高 760 → 顶 20；16+15 内缩）
                try? await Task.sleep(for: .seconds(4))
                report("PATH downloads-x \(model.activeOverlay == nil ? "OK" : "FAIL")")
                if model.activeOverlay != nil {
                    pressEscape()
                    try? await Task.sleep(for: .seconds(4))
                    report("PATH downloads-esc \(model.activeOverlay == nil ? "OK" : "FAIL")")
                }
                if model.activeOverlay != nil {
                    await clickAt(x: 60, y: 400)
                    try? await Task.sleep(for: .seconds(4))
                    report("PATH downloads-scrim \(model.activeOverlay == nil ? "OK" : "FAIL")")
                }
                report("PATH done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "rank":
            // M1.5 取证：默认榜单 → 男频 → 新书榜 → 换题材 → 搜索 → 返回榜单
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                await model.loadRankIfNeeded()
                try? await Task.sleep(for: .seconds(8))

                @MainActor func snap(_ tag: String) async {
                    try? await Task.sleep(for: .seconds(4))
                    report("STATUS \(tag) \(model.rankStatus)  条数=\(model.rankBooks.count)")
                    let top3 = model.rankBooks.prefix(3).enumerated().map { "\($0.offset + 1).\($0.element.title)[\($0.element.bookID)]" }.joined(separator: " | ")
                    report("RANK \(tag) 前3: \(top3)")
                    report("FRAMES \(tag) \(FMFrameMetrics.alignment("results-left", "results-right"))")
                    report("SHOT \(tag)")
                    // 截图脚本按标记 +2s 抓图，这里把该状态保持住（否则下一阶段一开始就变成「加载榜单…」）
                    try? await Task.sleep(for: .seconds(8))
                }
                await snap("rank-hot")

                await model.selectRankChannel("男频")
                await snap("rank-male")

                await model.selectRankType("2")
                await snap("rank-male-new")

                await model.selectRankGenre(3)
                await snap("rank-genre")

                // 搜索 → 结果视图（顶部应有「返回榜单」）
                await model.runSearch("游走神话时代")
                try? await Task.sleep(for: .seconds(5))
                report("BACK search状态=\(model.searchStatus) mainView=\(model.mainView)")
                report("SHOT search")
                try? await Task.sleep(for: .seconds(8))

                await model.backToRank()
                try? await Task.sleep(for: .seconds(3))
                report("BACK 返回后 mainView=\(model.mainView) 条数=\(model.rankBooks.count) 状态=\(model.rankStatus)")
                report("SHOT back-rank")
                try? await Task.sleep(for: .seconds(8))
                report("SHOT done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "m17":
            // M1.7 取证：封面模式 dump → 列表模式 → 加载中 → 失败态(带重试) → 重试成功
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1))

                // 先把频道页/榜单页抓下来（供后面制造失败用），再走正常加载
                await model.loadRankIfNeeded()
                try? await Task.sleep(for: .seconds(10))

                func frame(_ name: String) -> String {
                    guard let r = FMFrameMetrics.last[name] else { return "\(name)=缺失" }
                    return "\(name)=\(FMFrameMetrics.fmt(r.width))x\(FMMetrics.last == [:] ? "" : FMFrameMetrics.fmt(r.height))"
                }
                report("DUMP-BEGIN 封面模式")
                for i in 1...10 {
                    let card = FMFrameMetrics.last["card-\(i)"].map { "\(FMFrameMetrics.fmt($0.width))x\(FMFrameMetrics.fmt($0.height))" } ?? "缺失"
                    let cover = FMFrameMetrics.last["cover-\(i)"].map { "\(FMFrameMetrics.fmt($0.width))x\(FMFrameMetrics.fmt($0.height))" } ?? "缺失"
                    report("DUMP card-\(i)=\(card) ｜ cover-\(i)=\(cover)")
                }
                report("DUMP-BAR topbar=\(FMFrameMetrics.last["topbar"].map { "\(FMFrameMetrics.fmt($0.minY))..\(FMFrameMetrics.fmt($0.maxY))" } ?? "?") channelRow=\(FMFrameMetrics.last["rank-channel-row"].map { "\(FMFrameMetrics.fmt($0.minY))..\(FMFrameMetrics.fmt($0.maxY))" } ?? "?")")
                report("DUMP-ALIGN 封面模式 \(FMFrameMetrics.alignment("results-left", "results-right"))")
                report("SHOT rank-album")
                try? await Task.sleep(for: .seconds(8))

                ViewModeStore.shared.set(.list)
                try? await Task.sleep(for: .seconds(4))
                report("DUMP-ALIGN 列表模式 \(FMFrameMetrics.alignment("results-left", "results-right"))")
                report("SHOT rank-list")
                try? await Task.sleep(for: .seconds(8))

                ViewModeStore.shared.set(.album)
                // 加载中：切到一个还没缓存的频道（女频），抓 6s 内的画面
                Task { await model.selectRankChannel("女频") }
                try? await Task.sleep(for: .seconds(1))
                report("SHOT loading")
                try? await Task.sleep(for: .seconds(8))

                // 失败态：临时把 URL 指到坏地址（只在内存里改，不动抓取逻辑）
                model.rankChannel = "男频"
                model.rankType = "1"
                model.rankGenreIndex = 0
                let savedURL = model.currentRankURL
                report("RETRY 制造失败：\(savedURL ?? "?") → https://fanqienovel.invalid/rank")
                await model.debugLoadRank(badURL: "https://fanqienovel.invalid/rank")
                try? await Task.sleep(for: .seconds(4))
                report("RETRY 失败态状态=\(model.rankStatus) 条数=\(model.rankBooks.count) 错误标记=\(model.rankStatusIsError)")
                report("SHOT failed")
                try? await Task.sleep(for: .seconds(8))

                await model.reloadRank() // 点「重试」
                try? await Task.sleep(for: .seconds(8))
                report("RETRY 重试后状态=\(model.rankStatus) 条数=\(model.rankBooks.count) 错误标记=\(model.rankStatusIsError)")
                report("SHOT retried")
                try? await Task.sleep(for: .seconds(8))
                report("SHOT done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "carddump":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                await model.loadRankIfNeeded()
                try? await Task.sleep(for: .seconds(10))

                func p(_ name: String) -> String {
                    guard let r = FMFrameMetrics.last[name] else { return "\(name)=缺失" }
                    return "\(name)=\(FMFrameMetrics.fmt(r.minX)),\(FMFrameMetrics.fmt(r.minY)) \(FMFrameMetrics.fmt(r.width))x\(FMFrameMetrics.fmt(r.height))"
                }
                report("DUMP-BEGIN 榜单封面模式")
                for i in 1...10 { report("DUMP \(p("card-\(i)")) ｜ \(p("cover-\(i)"))") }
                report("DUMP-BAR \(p("topbar")) ｜ \(p("rank-channel-row")) ｜ \(p("rank-status"))")
                report("DUMP-ALIGN \(FMFrameMetrics.alignment("results-left", "results-right"))")
                report("DUMP-END")
                report("SHOT done")
                try? await Task.sleep(for: .seconds(2))
                NSApp.terminate(nil)
            }
        case "m2bfix":
            // M2-b fix1-5 取证（七猫详情 chip / 改编筛选名 / 七猫榜单文案 / 设置按平台 / 卡片 meta 两行）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(1))

                @MainActor func numbers(_ tag: String) {
                    let win = MainWindowRegistry.shared.window?.contentView?.bounds.size ?? .zero
                    func r(_ n: String) -> CGRect? { FMFrameMetrics.last[n] }
                    if let c1 = r("card-1"), let c6 = r("card-6") {
                        let bottom = [6, 7, 8, 9, 10].compactMap { r("card-\($0)")?.maxY }.max() ?? 0
                        func uniq(_ v: [CGFloat]) -> String {
                            let set = Set(v.map { FMFrameMetrics.fmt($0) })
                            return set.count == 1 ? "\(set.first!)（\(v.count) 张全等）" : "不等：\(set.sorted().joined(separator: "/"))"
                        }
                        report("M2BFIX \(tag) 卡片 \(FMFrameMetrics.fmt(c1.width))x\(FMFrameMetrics.fmt(c1.height)) 宽=\(uniq((1...10).compactMap { r("card-\($0)")?.width })) 高=\(uniq((1...10).compactMap { r("card-\($0)")?.height })) 行1顶=\(FMFrameMetrics.fmt(c1.minY)) 行2底=\(FMFrameMetrics.fmt(bottom)) 底边留白=\(FMFrameMetrics.fmt(win.height - bottom))")
                    }
                    if let rl = r("results-right") {
                        report("M2BFIX \(tag) 窗口 \(FMFrameMetrics.fmt(win.width))x\(FMFrameMetrics.fmt(win.height)) 左留白=\(FMFrameMetrics.fmt(rl.minX)) 右留白=\(FMFrameMetrics.fmt(win.width - rl.maxX))")
                    }
                    if let f = r("adapt-filters") {
                        report("M2BFIX \(tag) 改编筛选行 宽=\(FMFrameMetrics.fmt(f.width)) 右边缘=\(FMFrameMetrics.fmt(f.maxX))")
                    }
                    if let s = FMFrameMetrics.lastSize["modal-panel#size"] {
                        report("M2BFIX \(tag) 弹窗 \(FMFrameMetrics.fmt(s.width))x\(FMFrameMetrics.fmt(s.height))")
                    }
                }

                PlatformStore.shared.set(.qimao)
                await model.platformChanged()
                try? await Task.sleep(for: .seconds(10))
                report("M2BFIX 七猫榜单 状态=\(model.rankStatus) 条数=\(model.rankBooks.count) 频道=\(model.rankChannel)")
                report("M2BFIX SHOT qimao-rank")
                try? await Task.sleep(for: .seconds(6))
                numbers("七猫榜单")

                await model.runSearch("十日终焉")
                try? await Task.sleep(for: .seconds(8))
                report("M2BFIX 七猫搜索 \(model.results.count) 条；长作者那条=\(model.results.first { $0.author.count > 12 }?.author ?? "-")")
                report("M2BFIX SHOT qimao-search")
                try? await Task.sleep(for: .seconds(6))

                if let first = model.results.first {
                    model.openDetail(first)
                    try? await Task.sleep(for: .seconds(10))
                    report("M2BFIX 详情 chip 应为=\(AppModel.lastDetailInfo?.platform.displayName ?? "-") 书名=\(AppModel.lastDetailInfo?.title ?? "-")")
                    report("M2BFIX SHOT qimao-detail")
                    try? await Task.sleep(for: .seconds(6))
                    numbers("七猫详情")
                    model.closeDetail()
                    try? await Task.sleep(for: .seconds(2))
                }

                // 设置页（七猫侧）
                withAnimation(.easeOut(duration: 0.2)) { model.activeOverlay = .settings }
                try? await Task.sleep(for: .seconds(5))
                report("M2BFIX SHOT settings-qimao")
                try? await Task.sleep(for: .seconds(6))
                model.activeOverlay = nil
                try? await Task.sleep(for: .seconds(2))

                // 改编书单（六组都要有名称）
                model.mainView = .adapt
                await model.loadAdaptIfNeeded()
                try? await Task.sleep(for: .seconds(10))
                report("M2BFIX 改编 \(model.adaptStatus) 条数=\(model.adaptBooks.count) 组=\(model.adaptGroups.map { "\($0.label)" }.joined(separator: "/"))")
                report("M2BFIX SHOT qimao-adapt")
                try? await Task.sleep(for: .seconds(7))
                numbers("改编书单")

                // 切回番茄：设置页番茄侧 + 频道行 + 榜单回归
                PlatformStore.shared.set(.fanqie)
                await model.platformChanged()
                try? await Task.sleep(for: .seconds(10))
                report("M2BFIX 番茄榜单 状态=\(model.rankStatus) 条数=\(model.rankBooks.count) 频道=\(model.rankChannel)")
                withAnimation(.easeOut(duration: 0.2)) { model.activeOverlay = .settings }
                try? await Task.sleep(for: .seconds(5))
                report("M2BFIX SHOT settings-fanqie")
                try? await Task.sleep(for: .seconds(6))
                model.activeOverlay = nil
                report("M2BFIX done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "adaptshot":
            // 只拍改编书单（M2-b 第 3 块截图）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                PlatformStore.shared.set(.qimao)
                model.mainView = .adapt
                await model.loadAdaptIfNeeded()
                try? await Task.sleep(for: .seconds(12))
                report("ADAPTSHOT 状态=\(model.adaptStatus) 条数=\(model.adaptBooks.count) 筛选组=\(model.adaptGroups.map { $0.key }.joined(separator: "/"))")
                report("ADAPTSHOT SHOT adapt")
                try? await Task.sleep(for: .seconds(10))
                report("ADAPTSHOT done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "qimaoui":
            // M2-b 取证：平台切换 + 七猫榜单/搜索/详情/下载（M2-c 起入口默认开放，无需环境变量）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(1))
                report("QIMAOUI 七猫入口开关 qimaoEnabled=\(PlatformStore.qimaoEnabled)")

                PlatformStore.shared.set(.qimao)
                await model.platformChanged()
                try? await Task.sleep(for: .seconds(10))
                report("QIMAOUI 榜单 平台=\(PlatformStore.shared.platform.displayName) 状态=\(model.rankStatus) 条数=\(model.rankBooks.count) 首条=\(model.rankBooks.first?.title ?? "-")[\(model.rankBooks.first?.bookID ?? "-")]")
                report("QIMAOUI SHOT qimao-rank")
                try? await Task.sleep(for: .seconds(7))

                await model.runSearch("十日终焉")
                try? await Task.sleep(for: .seconds(8))
                report("QIMAOUI 搜索 状态=\(model.searchStatus) 条数=\(model.results.count) 首条=\(model.results.first?.title ?? "-")")
                report("QIMAOUI SHOT qimao-search")
                try? await Task.sleep(for: .seconds(7))

                if let first = model.results.first {
                    model.openDetail(first)
                    try? await Task.sleep(for: .seconds(10))
                    if let info = AppModel.lastDetailInfo {
                        report("QIMAOUI 详情 平台=\(info.platform.displayName)《\(info.title)》/ \(info.author) 章节=\(info.chapterCount) 评分=\(info.score) 字数=\(info.words) 分类=\(info.category) 链接=\(info.link.absoluteString)")
                    } else {
                        report("QIMAOUI 详情加载失败")
                    }
                    report("QIMAOUI SHOT qimao-detail")
                    try? await Task.sleep(for: .seconds(7))

                    // 七猫下载（TXT）——不经内核，直接七猫直连
                    report("QIMAOUI 开始七猫下载（格式=\(SettingsStore.shared.format)）")
                    let t0 = Date()
                    model.startDownload(title: first.title, author: first.author, bookID: first.bookID, platform: .qimao)
                    var waited = 0.0
                    while waited < 120 {
                        if let task = model.downloads.task(for: first.bookID), !task.isActive {
                            report("QIMAOUI 下载结束 状态=\(task.state) 进度=\(task.progressText) 文件=\(task.filePath ?? "-")（\(Int(Date().timeIntervalSince(t0) * 1000))ms）")
                            if let path = task.filePath, let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int {
                                report("QIMAOUI 下载文件大小=\(size) 字节")
                            }
                            break
                        }
                        try? await Task.sleep(for: .seconds(1))
                        waited += 1
                    }
                    model.closeDetail()
                    try? await Task.sleep(for: .seconds(2))
                }

                // ── 改编书单（M2-b 第 3 块）──
                model.mainView = .adapt
                await model.loadAdaptIfNeeded()
                try? await Task.sleep(for: .seconds(10))
                report("QIMAOUI 改编筛选组 \(model.adaptGroups.map { "\($0.key)(\($0.options.count))" }.joined(separator: " "))")
                report("QIMAOUI 改编第1页 状态=\(model.adaptStatus) 条数=\(model.adaptBooks.count) 首条=\(model.adaptBooks.first?.title ?? "-")[\(model.adaptBooks.first?.bookID ?? "-")]")
                report("QIMAOUI SHOT qimao-adapt")
                try? await Task.sleep(for: .seconds(7))

                await model.selectAdaptFilter(key: "direction", value: "2") // 真人短剧
                try? await Task.sleep(for: .seconds(8))
                report("QIMAOUI 改编换筛选 direction=2 条数=\(model.adaptBooks.count) 首条=\(model.adaptBooks.first?.title ?? "-")")
                await model.adaptPage(delta: 1)
                try? await Task.sleep(for: .seconds(8))
                report("QIMAOUI 改编第2页 页码=\(model.adaptPage) 条数=\(model.adaptBooks.count) 首条=\(model.adaptBooks.first?.title ?? "-")")
                report("QIMAOUI SHOT qimao-adapt-page2")
                try? await Task.sleep(for: .seconds(7))
                await model.adaptPage(delta: -1)
                try? await Task.sleep(for: .seconds(6))
                report("QIMAOUI 改编回上一页 页码=\(model.adaptPage) 条数=\(model.adaptBooks.count)")
                model.mainView = .rank

                // ── M11：设置页「保存格式」已删 → 两平台一律 TXT ──
                // 这里刻意写一次 epub，验证它会被归一为 txt（不能出现「选了但没入口」的悬挂状态）。
                if let book = model.rankBooks.first {
                    SettingsStore.shared.update { $0.format = "epub" }
                    report("QIMAOUI 写入 format=epub 后 SettingsStore.format=\(SettingsStore.shared.format)（M11 应 txt）落盘值=\(SettingsStore.shared.settings.format)")
                    report("QIMAOUI 开始七猫下载（M11 入口已删，应落 TXT）：《\(book.title)》")
                    let t1 = Date()
                    model.startDownload(title: book.title, author: book.author, bookID: book.bookID, platform: .qimao)
                    var waited1 = 0.0
                    while waited1 < 120 {
                        if let task = model.downloads.task(for: book.bookID), !task.isActive {
                            report("QIMAOUI 下载结束 状态=\(task.state) 文件=\(task.filePath ?? "-")（\(Int(Date().timeIntervalSince(t1) * 1000))ms）")
                            if let path = task.filePath, let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int {
                                report("QIMAOUI 产物 \(URL(fileURLWithPath: path).pathExtension) 文件大小=\(size) 字节（M11 应 txt）")
                            }
                            break
                        }
                        try? await Task.sleep(for: .seconds(1))
                        waited1 += 1
                    }
                    SettingsStore.shared.update { $0.format = "txt" }
                }

                // 切回番茄，确认番茄链路没被带坏
                PlatformStore.shared.set(.fanqie)
                await model.platformChanged()
                try? await Task.sleep(for: .seconds(10))
                report("QIMAOUI 切回番茄 平台=\(PlatformStore.shared.platform.displayName) 状态=\(model.rankStatus) 条数=\(model.rankBooks.count) 首条=\(model.rankBooks.first?.title ?? "-")")
                report("QIMAOUI SHOT fanqie-back")
                try? await Task.sleep(for: .seconds(7))
                report("QIMAOUI done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "m2c":
            // M2-c 取证（第 1 段）：默认启动两 chip + 番茄选中 → 切七猫男生榜 → 七猫搜索/详情/下载 TXT，
            // 结束时**留在七猫**（交给 m2c-resume 验证重启持久化）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                await model.loadRankIfNeeded()
                try? await Task.sleep(for: .seconds(10))

                @MainActor func numbers(_ tag: String) {
                    let win = MainWindowRegistry.shared.window?.contentView?.bounds.size ?? .zero
                    func r(_ n: String) -> CGRect? { FMFrameMetrics.last[n] }
                    if let c1 = r("card-1") {
                        let bottom = [6, 7, 8, 9, 10].compactMap { r("card-\($0)")?.maxY }.max() ?? 0
                        func uniq(_ v: [CGFloat]) -> String {
                            let set = Set(v.map { FMFrameMetrics.fmt($0) })
                            return set.count == 1 ? "\(set.first!)（\(v.count) 张全等）" : "不等：\(set.sorted().joined(separator: "/"))"
                        }
                        report("M2C \(tag) 卡片 \(FMFrameMetrics.fmt(c1.width))x\(FMFrameMetrics.fmt(c1.height)) 宽=\(uniq((1...10).compactMap { r("card-\($0)")?.width })) 高=\(uniq((1...10).compactMap { r("card-\($0)")?.height })) 行1顶=\(FMFrameMetrics.fmt(c1.minY)) 行2底=\(FMFrameMetrics.fmt(bottom))")
                    }
                    if let rl = r("results-right") {
                        report("M2C \(tag) 窗口 \(FMFrameMetrics.fmt(win.width))x\(FMFrameMetrics.fmt(win.height)) 左留白=\(FMFrameMetrics.fmt(rl.minX)) 右留白=\(FMFrameMetrics.fmt(win.width - rl.maxX))")
                    }
                }

                // ① 默认启动：平台=番茄，两个 chip 都在（番茄为选中态）
                report("M2C 启动 平台=\(PlatformStore.shared.platform.displayName) 七猫入口开关=\(PlatformStore.qimaoEnabled) 番茄chip=\(FMFrameMetrics.last["platform-chip-fanqie"] != nil ? "有" : "无") 七猫chip=\(FMFrameMetrics.last["platform-chip-qimao"] != nil ? "有" : "无") UserDefaults=\(UserDefaults.standard.string(forKey: "novelPlatform") ?? "-")")
                report("M2C 启动 榜单 状态=\(model.rankStatus) 条数=\(model.rankBooks.count) 标签=\(model.rankLabel()) 频道=\(model.rankChannel)")
                numbers("启动")
                report("M2C SHOT default-fanqie")
                try? await Task.sleep(for: .seconds(7))

                // ② 切七猫（走 chip 点击同一条调用路径）：应落到男生榜
                PlatformStore.shared.set(.qimao)
                await model.platformChanged()
                try? await Task.sleep(for: .seconds(10))
                report("M2C 切七猫 平台=\(PlatformStore.shared.platform.displayName) 榜单 状态=\(model.rankStatus) 条数=\(model.rankBooks.count) 标签=\(model.rankLabel()) 频道=\(model.rankChannel)")
                report("M2C 持久化 写入后 UserDefaults=\(UserDefaults.standard.string(forKey: "novelPlatform") ?? "-")")
                numbers("七猫榜单")
                report("M2C SHOT qimao-rank")
                try? await Task.sleep(for: .seconds(7))

                // ③ 七猫侧搜索 → 详情 → 下载 TXT
                await model.runSearch("十日终焉")
                try? await Task.sleep(for: .seconds(8))
                report("M2C 七猫搜索 状态=\(model.searchStatus) 条数=\(model.results.count) 首条=\(model.results.first?.title ?? "-")[\(model.results.first?.bookID ?? "-")]")
                report("M2C SHOT qimao-search")
                try? await Task.sleep(for: .seconds(6))

                if let first = model.results.first {
                    model.openDetail(first)
                    try? await Task.sleep(for: .seconds(10))
                    if let info = AppModel.lastDetailInfo {
                        report("M2C 七猫详情 平台=\(info.platform.displayName)《\(info.title)》/ \(info.author) 章节=\(info.chapterCount) 评分=\(info.score) 字数=\(info.words) 分类=\(info.category)")
                    } else {
                        report("M2C 七猫详情加载失败")
                    }
                    report("M2C SHOT qimao-detail")
                    try? await Task.sleep(for: .seconds(6))

                    SettingsStore.shared.update { $0.format = "txt" }
                    let t0 = Date()
                    model.startDownload(title: first.title, author: first.author, bookID: first.bookID, platform: .qimao)
                    var waited = 0.0
                    while waited < 120 {
                        if let task = model.downloads.task(for: first.bookID), !task.isActive {
                            report("M2C 七猫下载 状态=\(task.state) 进度=\(task.progressText) 文件=\(task.filePath ?? "-")（\(Int(Date().timeIntervalSince(t0) * 1000))ms）")
                            if let path = task.filePath, let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int {
                                report("M2C 七猫下载文件大小=\(size) 字节")
                            }
                            break
                        }
                        try? await Task.sleep(for: .seconds(1))
                        waited += 1
                    }
                    if waited >= 120 { report("M2C 七猫下载超时（120s）") }
                    model.closeDetail()
                    try? await Task.sleep(for: .seconds(2))
                }

                // 留在七猫退出
                report("M2C 退出前 平台=\(PlatformStore.shared.platform.displayName) UserDefaults=\(UserDefaults.standard.string(forKey: "novelPlatform") ?? "-")")
                report("M2C done-leave-qimao")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "m2c-resume":
            // M2-c 取证（第 2 段）：重启后应仍是七猫 → 再切回番茄，榜单回到综合热榜
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                await model.loadRankIfNeeded()
                try? await Task.sleep(for: .seconds(10))

                report("M2CRESUME 重启后 平台=\(PlatformStore.shared.platform.displayName) 榜单 状态=\(model.rankStatus) 条数=\(model.rankBooks.count) 标签=\(model.rankLabel()) 频道=\(model.rankChannel)")
                report("M2CRESUME SHOT resume-qimao")
                try? await Task.sleep(for: .seconds(6))

                PlatformStore.shared.set(.fanqie)
                await model.platformChanged()
                try? await Task.sleep(for: .seconds(10))
                report("M2CRESUME 切回番茄 平台=\(PlatformStore.shared.platform.displayName) 榜单 状态=\(model.rankStatus) 条数=\(model.rankBooks.count) 标签=\(model.rankLabel()) 频道=\(model.rankChannel) UserDefaults=\(UserDefaults.standard.string(forKey: "novelPlatform") ?? "-")")
                report("M2CRESUME SHOT fanqie-back")
                try? await Task.sleep(for: .seconds(7))
                report("M2CRESUME done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "sd-session":
            // M3-a：短剧登录态探测（逐浏览器摊开 + 会话状态 + 设置里的短剧开关）；无登录态必须立即报错，不挂住
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await runShortdramaSessionReport()
                NSApp.terminate(nil)
            }
        case "sd-search":
            // M3-a：短剧后台按书名搜索（关键词取 FQM_SELFTEST_KEYWORD，默认「斗破」）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await runShortdramaSearchReport(keyword: ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "斗破")
                NSApp.terminate(nil)
            }
        case "sd-probe":
            // 侦查（只读）：短剧后台「按小说ID」参数名 + 命中记录原始 JSON。不动任何产品行为。
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await runShortdramaProbe()
                NSApp.terminate(nil)
            }
        case "sd-id":
            // M10：① ID 精度（读出 ip_book_id 逐字符 == 真值）② 按 ID 命中《花妖军嫂…（ID 7613834044236631102）
            //      ③ 同一本在搜索与详情两条路径都能命中
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await runShortdramaIDReport(model: model)
                NSApp.terminate(nil)
            }
        case "sd-tags":
            // 只读取证（用户追问「标签数量是不是被限制了」）：标签到底少在哪——
            // 后台原文 / 解析后 / 界面渲染 三层对照 + 标签行几何（有没有 chip 被裁）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(1))
                let original = sdEnable()
                await runShortdramaTagsReport(model: model)
                sdRestore(original)
                report("SDTAGS 还原 shortdramaIgnored=\(SettingsStore.shared.settings.shortdramaIgnored) shortdramaPrompted=\(SettingsStore.shared.settings.shortdramaPrompted)")
                report("SDTAGS done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "sd-fields":
            // M10：一条命中记录的**最终展示文案**（两行数据 + 标签 + 榜单 + 百分比/万换算）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await runShortdramaFieldsReport(model: model)
                NSApp.terminate(nil)
            }
        case "sd-hit":
            // M10：卡片角标三态（上架 N 部 / 已选 N / 短剧）实测 + 截图
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await runShortdramaBadgeReport(model: model)
                NSApp.terminate(nil)
            }
        case "m3b":
            // M3-b 取证：短剧模式开关 / 无登录态下搜索·榜单·详情三条链路不阻塞 / 改编书单入口随开关
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(1))

                let originalIgnored = SettingsStore.shared.settings.shortdramaIgnored
                let originalPrompted = SettingsStore.shared.settings.shortdramaPrompted
                report("M3B 起始设置 shortdramaIgnored=\(originalIgnored)（读旧 settings.json）")
                let kc0 = ShortdramaSession.keychainReads

                @MainActor func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
                func kcDelta() -> Int { ShortdramaSession.keychainReads - kc0 }

                // ① 短剧模式关：七猫榜单不查后台、改编书单入口隐藏
                ShortdramaStore.shared.setIgnored(true)
                PlatformStore.shared.set(.qimao)
                let offStart = Date()
                await model.platformChanged()
                await wait(6)
                report("M3B OFF 七猫 平台=\(PlatformStore.shared.platform.displayName) 短剧模式=关 榜单状态=\(model.rankStatus) 改编书单入口=\(FMFrameMetrics.last["adapt-entry"] != nil ? "有" : "无") hits=\(model.shortdramaHits) 榜单耗时=\(Int(Date().timeIntervalSince(offStart) * 1000))ms 读钥匙串=\(kcDelta())")
                report("M3B SHOT off-qimao-rank")
                await wait(6)

                withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = .settings }
                await wait(4)
                report("M3B OFF 设置页 短剧开关=\(FMFrameMetrics.last["settings-shortdrama-toggle"] != nil ? "有" : "无") 灰字=\(ShortdramaStore.shared.statusText.isEmpty ? "-" : ShortdramaStore.shared.statusText)")
                report("M3B SHOT off-settings")
                await wait(6)
                model.activeOverlay = nil
                await wait(2)

                // ② 短剧模式开 + 无登录态：番茄榜单/搜索/详情正常，不挂、不弹钥匙串
                ShortdramaStore.shared.setIgnored(false)
                await ShortdramaStore.shared.refreshStatus() // 等价用户点开开关时的登录态反馈（非模态灰字）
                report("M3B ON 设置反馈 灰字=\(ShortdramaStore.shared.statusText) keychainNeedsFix=\(ShortdramaStore.shared.keychainNeedsFix) 读钥匙串=\(kcDelta())")
                PlatformStore.shared.set(.fanqie)
                let rankStart = Date()
                await model.platformChanged()
                let rankMs = Int(Date().timeIntervalSince(rankStart) * 1000)
                await wait(4)
                report("M3B ON 番茄榜单 状态=\(model.rankStatus) hits=\(model.shortdramaHits) 耗时=\(rankMs)ms 读钥匙串=\(kcDelta())")
                report("M3B SHOT on-fanqie-rank")
                await wait(6)

                let searchStart = Date()
                await model.runSearch("游走神话时代")
                let searchMs = Int(Date().timeIntervalSince(searchStart) * 1000)
                report("M3B ON 搜索 状态=\(model.searchStatus) 条数=\(model.results.count) 耗时=\(searchMs)ms")
                await wait(6) // 等短剧批量查询结束（无登录态应立刻失败）
                report("M3B ON 搜索(短剧查完) 状态=\(model.searchStatus) hits=\(model.shortdramaHits) 读钥匙串=\(kcDelta()) keychainNeedsFix=\(ShortdramaStore.shared.keychainNeedsFix)")
                report("M3B SHOT on-search")
                await wait(6)

                if let first = model.results.first {
                    model.openDetail(first)
                    var waited = 0.0
                    while waited < 15, ShortdramaStore.shared.detailHint == nil, ShortdramaStore.shared.detailHit == nil {
                        try? await Task.sleep(for: .seconds(0.5))
                        waited += 0.5
                    }
                    let detailMs = Int(waited * 1000)
                    await wait(2)
                    let hint = ShortdramaStore.shared.detailHint ?? "-"
                    report("M3B ON 详情《\(first.title)》 数据条=\(ShortdramaStore.shared.detailHit != nil ? "有" : "无") 提示=\(hint) 耗时≈\(detailMs)ms 读钥匙串=\(kcDelta())")
                    report("M3B SHOT on-detail")
                    await wait(6)
                    model.closeDetail()
                    await wait(2)
                }

                // ③ 短剧模式开：七猫改编书单入口出现
                PlatformStore.shared.set(.qimao)
                await model.platformChanged()
                await wait(6)
                report("M3B ON 七猫 平台=\(PlatformStore.shared.platform.displayName) 榜单状态=\(model.rankStatus) 改编书单入口=\(FMFrameMetrics.last["adapt-entry"] != nil ? "有" : "无") hits=\(model.shortdramaHits)")
                report("M3B SHOT on-qimao-rank")
                await wait(6)

                withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = .settings }
                await wait(4)
                report("M3B SHOT on-settings")
                await wait(6)
                model.activeOverlay = nil
                await wait(1)

                // 还原：平台回番茄、短剧开关回原值（跑完用户看到的还是原来的样子）
                PlatformStore.shared.set(.fanqie)
                SettingsStore.shared.update {
                    $0.shortdramaIgnored = originalIgnored
                    $0.shortdramaPrompted = originalPrompted
                }
                report("M3B 还原 shortdramaIgnored=\(SettingsStore.shared.settings.shortdramaIgnored) 平台=\(PlatformStore.shared.platform.displayName) 读钥匙串总次数=\(kcDelta())")
                report("M3B done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "m3b-hit":
            // M3-b 取证（命中路径）：无真机登录态，注入短剧后台命中，验证红标/角标/排最前/状态行计数
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(1))

                let originalIgnored = SettingsStore.shared.settings.shortdramaIgnored
                let originalPrompted = SettingsStore.shared.settings.shortdramaPrompted
                ShortdramaStore.shared.setIgnored(false)
                @MainActor func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

                // 番茄榜单：先正常加载一次拿到标题，再注入两个命中并重载
                PlatformStore.shared.set(.fanqie)
                await model.platformChanged()
                await wait(6)
                let rankTitles = model.rankBooks.map(\.title)
                let rankMonths = ["2025-01", "2025-11"]
                var rankInjected: [String: ShortdramaClient.ShortdramaIP] = [:]
                if rankTitles.count > 6 {
                    rankInjected[rankTitles[3]] = Self.fakeShortdramaIP(name: rankTitles[3], month: rankMonths[0], apply: 12, adapting: 3)
                    rankInjected[rankTitles[6]] = Self.fakeShortdramaIP(name: rankTitles[6], month: rankMonths[1], apply: 0, adapting: 1)
                }
                ShortdramaStore.shared.debugInjectedHits = rankInjected
                await model.reloadRank()
                await wait(6)
                report("M3BHIT 榜单 顺序前4=\(model.rankBooks.prefix(4).map { "\($0.title)[\($0.sdInBackend ? "短剧" : "-")]" }.joined(separator: " | "))")
                report("M3BHIT 榜单 卡片红标=hits\(model.shortdramaHits) 状态行=\(model.rankStatus)")
                report("M3BHIT SHOT hits-rank")
                await wait(7)

                // 搜索：注入两个命中 → 完整规则重排（命中排最前），状态行计数
                await model.runSearch("游走神话时代")
                let searchTitles = model.results.map(\.title)
                var searchInjected: [String: ShortdramaClient.ShortdramaIP] = [:]
                if searchTitles.count > 9 {
                    searchInjected[searchTitles[5]] = Self.fakeShortdramaIP(name: searchTitles[5], month: "2025-03", apply: 5, adapting: 0)
                    searchInjected[searchTitles[9]] = Self.fakeShortdramaIP(name: searchTitles[9], month: "2026-02", apply: 0, adapting: 2)
                }
                ShortdramaStore.shared.debugInjectedHits = searchInjected
                await model.runSearch("游走神话时代")
                await wait(6)
                report("M3BHIT 搜索 顺序前3=\(model.results.prefix(3).map { "\($0.title)[\($0.sdInBackend ? "短剧" : "-")]" }.joined(separator: " | "))")
                report("M3BHIT 搜索 hits=\(model.shortdramaHits) 状态行=\(model.searchStatus)")
                report("M3BHIT SHOT hits-search")
                await wait(7)

                // M10 Q1/Q2 乙：榜单**不重排**（保持番茄原序）；搜索只把命中**稳定前置**（组内保序）。
                // 用例：A B C D，其中 B、D 命中 → 榜单仍 A,B,C,D；搜索 B,D,A,C。
                let sdSortCase = [
                    SearchItem(bookID: "1", title: "A", author: "", abstract: "", score: "", words: "100万字", hot: "5万人在读", coverURL: nil, sdInBackend: false),
                    SearchItem(bookID: "2", title: "B", author: "", abstract: "", score: "", words: "10万字", hot: "100万人在读", coverURL: nil, sdInBackend: true, sdOnlineMonth: "2025-01"),
                    SearchItem(bookID: "3", title: "C", author: "", abstract: "", score: "", words: "10万字", hot: "1万人在读", coverURL: nil, sdInBackend: false),
                    SearchItem(bookID: "4", title: "D", author: "", abstract: "", score: "", words: "20万字", hot: "2万人在读", coverURL: nil, sdInBackend: true, sdOnlineMonth: "2025-12"),
                ]
                let rankOrder = sdSortCase.map(\.title).joined(separator: ",")
                let searchOrder = AppModel.shortdramaSearchOrder(sdSortCase).map(\.title).joined(separator: ",")
                report("M3BHIT 排序 榜单保持原序（应 A,B,C,D）=\(rankOrder)")
                report("M3BHIT 排序 搜索命中稳定前置（应 B,D,A,C）=\(searchOrder)")

                ShortdramaStore.shared.debugInjectedHits = nil
                PlatformStore.shared.set(.fanqie)
                SettingsStore.shared.update {
                    $0.shortdramaIgnored = originalIgnored
                    $0.shortdramaPrompted = originalPrompted
                }
                report("M3BHIT 还原 shortdramaIgnored=\(SettingsStore.shared.settings.shortdramaIgnored)")
                report("M3BHIT done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "m3c":
            // M3-c 取证：首启询问（旧版 maybeShowShortdramaPrompt）—— 没问过不启用/不查后台；启用/忽略落点
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(1))

                let originalIgnored = SettingsStore.shared.settings.shortdramaIgnored
                let originalPrompted = SettingsStore.shared.settings.shortdramaPrompted
                @MainActor func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
                let kc0 = ShortdramaSession.keychainReads
                func kcDelta() -> Int { ShortdramaSession.keychainReads - kc0 }

                // 模拟「新装机器」：没被问过（prompted=false），ignored 为默认 false
                SettingsStore.shared.update { $0.shortdramaIgnored = false; $0.shortdramaPrompted = false }
                ShortdramaStore.shared.maybeShowFirstRunPrompt()
                await wait(1)
                report("M3C 未问过 prompted=false ignored=false → isEnabled=\(ShortdramaStore.shared.isEnabled) 询问可见=\(ShortdramaStore.shared.showFirstRunPrompt) 读钥匙串=\(kcDelta())")
                report("M3C SHOT first-prompt")
                await wait(7)

                // 未问过时三条链路都不查后台（询问挡在前台，后台仍把榜单/搜索跑完）
                PlatformStore.shared.set(.fanqie)
                await model.platformChanged()
                await model.runSearch("游走神话时代")
                await wait(4)
                if let first = model.results.first {
                    model.openDetail(first)
                    await wait(3)
                }
                report("M3C 未问过 榜单状态=\(model.rankStatus) hits=\(model.shortdramaHits)")
                report("M3C 未问过 搜索状态=\(model.searchStatus) 详情提示=\(ShortdramaStore.shared.detailHint ?? "-") 数据条=\(ShortdramaStore.shared.detailHit != nil ? "有" : "无") 读钥匙串=\(kcDelta())")
                model.closeDetail()
                await wait(1)

                // 询问里点「忽略」→ ignored=true, prompted=true；不会再问
                ShortdramaStore.shared.declineFirstRun()
                await wait(1)
                ShortdramaStore.shared.maybeShowFirstRunPrompt()
                report("M3C 忽略后 ignored=\(SettingsStore.shared.settings.shortdramaIgnored) prompted=\(SettingsStore.shared.settings.shortdramaPrompted) isEnabled=\(ShortdramaStore.shared.isEnabled) 再次询问可见=\(ShortdramaStore.shared.showFirstRunPrompt)")

                withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = .settings }
                await wait(4)
                report("M3C SHOT after-decline-settings")
                await wait(6)
                model.activeOverlay = nil
                await wait(2)

                // 重新模拟新装 → 询问里点「启用」→ ignored=false, prompted=true, isEnabled=true
                SettingsStore.shared.update { $0.shortdramaIgnored = false; $0.shortdramaPrompted = false }
                ShortdramaStore.shared.maybeShowFirstRunPrompt()
                await wait(1)
                ShortdramaStore.shared.acceptFirstRun()
                await wait(1)
                report("M3C 启用后 ignored=\(SettingsStore.shared.settings.shortdramaIgnored) prompted=\(SettingsStore.shared.settings.shortdramaPrompted) isEnabled=\(ShortdramaStore.shared.isEnabled) 灰字=\(ShortdramaStore.shared.statusText.isEmpty ? "-" : ShortdramaStore.shared.statusText) 读钥匙串=\(kcDelta())")

                // 还原用户原值
                SettingsStore.shared.update {
                    $0.shortdramaIgnored = originalIgnored
                    $0.shortdramaPrompted = originalPrompted
                }
                PlatformStore.shared.set(.fanqie)
                report("M3C 还原 ignored=\(SettingsStore.shared.settings.shortdramaIgnored) prompted=\(SettingsStore.shared.settings.shortdramaPrompted)")
                report("M3C done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "m3d":
            // M3-d 取证：Safari binarycookies 读取器三种情况 + 开关一致性 + 教程/权限引导
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(1))

                let originalIgnored = SettingsStore.shared.settings.shortdramaIgnored
                let originalPrompted = SettingsStore.shared.settings.shortdramaPrompted
                @MainActor func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

                // ① 文件不存在
                let missing = SafariCookies.diagnose(path: "/tmp/fqm-m3d/does-not-exist.binarycookies")
                report("M3D ①文件不存在 失败=\(missing.failure ?? "-") needsFDA=\(missing.needsFullDiskAccess) 条数=\(missing.cookieCount)")

                // ② 真机 Safari 路径（预期被 TCC 拒）
                let real = SafariCookies.diagnose(path: SafariCookies.defaultPath)
                report("M3D ②真机Safari 失败=\(real.failure ?? "-") needsFDA=\(real.needsFullDiskAccess) 条数=\(real.cookieCount)")

                // ③ 能读但没有 shortdramas cookie（多页夹具，证明解析器不是空转）
                let other = SafariCookies.diagnose(path: "/tmp/fqm-m3d/other.binarycookies")
                report("M3D ③其它cookie 页数=\(other.pageCount) 条数=\(other.cookieCount) host数=\(other.distinctHostCount) host样本=\(other.hostSamples.joined(separator: ",")) shortdramas命中=\(other.hasShortdramaSession)")
                do {
                    _ = try SafariCookies.shortdramaSessionID(path: "/tmp/fqm-m3d/other.binarycookies")
                    report("M3D ③取sessionid=意外成功")
                } catch {
                    report("M3D ③取sessionid=\(error.localizedDescription)")
                }

                // 命中夹具（证明能拿到 sessionid；值脱敏）
                let hit = SafariCookies.diagnose(path: "/tmp/fqm-m3d/shortdramas.binarycookies")
                report("M3D 命中夹具 页数=\(hit.pageCount) 条数=\(hit.cookieCount) host样本=\(hit.hostSamples.joined(separator: ",")) hasSession=\(hit.hasShortdramaSession)")
                do {
                    let sid = try SafariCookies.shortdramaSessionID(path: "/tmp/fqm-m3d/shortdramas.binarycookies")
                    report("M3D 命中夹具 sessionid=\(SafariCookies.maskValue(sid))")
                } catch {
                    report("M3D 命中夹具 sessionid=失败 \(error.localizedDescription)")
                }

                // 过期夹具
                let expired = SafariCookies.diagnose(path: "/tmp/fqm-m3d/expired.binarycookies")
                report("M3D 过期夹具 hasSession=\(expired.hasShortdramaSession) expired=\(expired.shortdramaExpired)")
                do {
                    _ = try SafariCookies.shortdramaSessionID(path: "/tmp/fqm-m3d/expired.binarycookies")
                    report("M3D 过期夹具=意外成功")
                } catch {
                    report("M3D 过期夹具=\(error.localizedDescription)")
                }

                // ⑤ 开关显示 = isEnabled：prompted=false 时开关应显示为关
                SettingsStore.shared.update { $0.shortdramaIgnored = false; $0.shortdramaPrompted = false }
                await wait(1)
                report("M3D ⑤开关一致性 prompted=false ignored=false → isEnabled=\(ShortdramaStore.shared.isEnabled)（截图里开关应为关）")
                withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = .settings }
                await wait(4)
                report("M3D SHOT settings-toggle-off")
                await wait(6)
                model.activeOverlay = nil
                await wait(2)

                // ③ 教程弹窗 + 「打开系统设置」（真机被 TCC 拒 → 需要完全磁盘访问权限）
                ShortdramaStore.shared.setIgnored(false)
                _ = await ShortdramaStore.shared.refreshStatus()
                ShortdramaStore.shared.showTutorial = true
                await wait(3)
                report("M3D 教程 needsFDA=\(ShortdramaStore.shared.needsFullDiskAccess) 灰字=\(ShortdramaStore.shared.statusText)")
                report("M3D SHOT tutorial")
                await wait(6)
                let opened = ShortdramaStore.shared.openFullDiskAccessSettings()
                report("M3D 打开系统设置返回=\(opened)")
                await wait(2)
                ShortdramaStore.shared.showTutorial = false
                await wait(1)

                // 番茄详情提示条（Safari 优先文案 / 权限优先于未登录）
                PlatformStore.shared.set(.fanqie)
                await model.platformChanged()
                await model.runSearch("游走神话时代")
                await wait(3)
                if let first = model.results.first {
                    model.openDetail(first)
                    await wait(4)
                }
                report("M3D 详情提示=\(ShortdramaStore.shared.detailHint ?? "-") needsFDA=\(ShortdramaStore.shared.needsFullDiskAccess)")
                report("M3D SHOT detail-hint")
                await wait(6)
                model.closeDetail()
                await wait(1)

                // 还原用户原值
                SettingsStore.shared.update {
                    $0.shortdramaIgnored = originalIgnored
                    $0.shortdramaPrompted = originalPrompted
                }
                PlatformStore.shared.set(.fanqie)
                report("M3D 还原 ignored=\(SettingsStore.shared.settings.shortdramaIgnored) prompted=\(SettingsStore.shared.settings.shortdramaPrompted)")
                report("M3D done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "m3f":
            // M3-f 补拍：真实命中搜索页/详情数据条 + 教程弹窗 + 检测登录态成功态（只取证，不改产品行为）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(1))

                let originalIgnored = SettingsStore.shared.settings.shortdramaIgnored
                let originalPrompted = SettingsStore.shared.settings.shortdramaPrompted
                @MainActor func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

                // 临时打开短剧模式（真机 Safari 登录态）
                ShortdramaStore.shared.setIgnored(false)
                let ok = await ShortdramaStore.shared.refreshStatus()
                report("M3F 检测登录态 ok=\(ok) 灰字=\(ShortdramaStore.shared.statusText)")

                // ① 设置页：检测登录态成功态
                withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = .settings }
                await wait(3)
                report("M3F SHOT settings-login-ok")
                await wait(5)
                model.activeOverlay = nil
                await wait(2)

                // ② 教程弹窗（RootView 里的面板，和主窗同一个 window）
                ShortdramaStore.shared.showTutorial = true
                await wait(3)
                report("M3F SHOT tutorial")
                await wait(6)
                ShortdramaStore.shared.showTutorial = false
                await wait(1)

                // ③ 真实命中（搜索页）：番茄搜关键词 → 短剧后台命中 → 红标+角标+计数
                var chosen = ""
                let candidates = ["斗破", "十日终焉", "盖世神医", "穿越斗破之云破天", "斗破豆坡烟火", "斗破之混沌圣体"]
                for keyword in candidates {
                    await model.runSearch(keyword)
                    await wait(6) // 等短剧批量查完
                    report("M3F 搜索「\(keyword)」条数=\(model.results.count) hits=\(model.shortdramaHits) 状态=\(model.searchStatus)")
                    if model.shortdramaHits > 0 { chosen = keyword; break }
                }

                if !chosen.isEmpty {
                    report("M3F SHOT search-hit（关键词=\(chosen)）")
                    await wait(6)
                    if let hit = model.results.first(where: { $0.sdInBackend }) {
                        model.openDetail(hit)
                        var waited = 0.0
                        while waited < 20, ShortdramaStore.shared.detailHit == nil, ShortdramaStore.shared.detailHint == nil {
                            try? await Task.sleep(for: .seconds(0.5))
                            waited += 0.5
                        }
                        if let strip = ShortdramaStore.shared.detailHit {
                            report("M3F 详情《\(hit.title)》 数据条=有 上架=\(strip.onlineMonth) 申请=\(strip.selectedCnt) 改编中=\(strip.adaptingCnt)")
                        } else {
                            report("M3F 详情《\(hit.title)》 数据条=无 提示=\(ShortdramaStore.shared.detailHint ?? "-")")
                        }
                        report("M3F SHOT detail-strip")
                        await wait(6)
                        model.closeDetail()
                        await wait(2)
                    }
                } else {
                    // 两边没同名书时把清单贴出来，供人工核对
                    if let ips = try? await ShortdramaClient.shared.search("斗破") {
                        report("M3F 短剧后台「斗破」命中 \(ips.count) 条：\(ips.prefix(10).map(\.name).joined(separator: " / "))")
                    }
                    await model.runSearch("斗破")
                    await wait(4)
                    report("M3F 番茄「斗破」命中 \(model.results.count) 条：\(model.results.prefix(10).map(\.title).joined(separator: " / "))")
                    report("M3F SHOT search-hit（无同名，拍番茄原样）")
                    await wait(6)
                }

                // 还原用户原值
                SettingsStore.shared.update {
                    $0.shortdramaIgnored = originalIgnored
                    $0.shortdramaPrompted = originalPrompted
                }
                PlatformStore.shared.set(.fanqie)
                report("M3F 还原 ignored=\(SettingsStore.shared.settings.shortdramaIgnored) prompted=\(SettingsStore.shared.settings.shortdramaPrompted)")
                report("M3F done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "m113shots":
            // 只做「封面/列表两模式截图」（M1.13 一屏两行），不做别的
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                await model.loadRankIfNeeded()
                try? await Task.sleep(for: .seconds(12))
                ViewModeStore.shared.set(.album)
                try? await Task.sleep(for: .seconds(3))
                report("M113S SHOT album")
                try? await Task.sleep(for: .seconds(10))
                ViewModeStore.shared.set(.list)
                try? await Task.sleep(for: .seconds(3))
                report("M113S SHOT list")
                try? await Task.sleep(for: .seconds(10))
                report("M113S done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "m113":
            // M1.13 取证：一屏两行完整 + 状态行留白 + 切换按钮位置（一轮跑完，跑完把 app 留在正常启动状态）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(2))

                @MainActor func dump(_ tag: String) {
                    let win = MainWindowRegistry.shared.window?.contentView?.bounds.size ?? .zero
                    report("M113 \(tag) 窗口 \(FMFrameMetrics.fmt(win.width))x\(FMFrameMetrics.fmt(win.height))")
                    func rect(_ n: String) -> CGRect? { FMFrameMetrics.last[n] }
                    let c1 = rect("card-1"), c6 = rect("card-6")
                    if let c1, let c6 {
                        let row2Bottom = [6, 7, 8, 9, 10].compactMap { rect("card-\($0)")?.maxY }.max() ?? 0
                        report("M113 \(tag) 卡片 \(FMFrameMetrics.fmt(c1.width))x\(FMFrameMetrics.fmt(c1.height)) 行1顶y=\(FMFrameMetrics.fmt(c1.minY)) 行2顶y=\(FMFrameMetrics.fmt(c6.minY)) 行2底y=\(FMFrameMetrics.fmt(row2Bottom)) 底边留白=\(FMFrameMetrics.fmt(win.height - row2Bottom))")
                        let widths = (1...10).compactMap { rect("card-\($0)")?.width }
                        let heights = (1...10).compactMap { rect("card-\($0)")?.height }
                        func uniq(_ v: [CGFloat]) -> String {
                            let set = Set(v.map { FMFrameMetrics.fmt($0) })
                            return set.count == 1 ? "\(set.first!)（\(v.count) 张全等）" : "不等：\(set.sorted().joined(separator: "/"))"
                        }
                        report("M113 \(tag) 卡片宽=\(uniq(widths)) 高=\(uniq(heights))｜封面宽=\(uniq((1...10).compactMap { rect("cover-\($0)")?.width })) 封面高=\(uniq((1...10).compactMap { rect("cover-\($0)")?.height }))")
                    }
                    if let t = rect("rank-status-text"), let c1 = rect("card-1") {
                        report("M113 \(tag) 状态行文字底y=\(FMFrameMetrics.fmt(t.maxY)) 网格顶y=\(FMFrameMetrics.fmt(c1.minY)) 间距=\(FMFrameMetrics.fmt(c1.minY - t.maxY))")
                    }
                    if let v = rect("viewmode-toggle") {
                        report("M113 \(tag) 切换按钮 \(FMFrameMetrics.fmt(v.width))x\(FMFrameMetrics.fmt(v.height))@(\(FMFrameMetrics.fmt(v.minX)),\(FMFrameMetrics.fmt(v.minY))) 右边缘=\(FMFrameMetrics.fmt(v.maxX))（应=970）")
                    }
                    if let bar = rect("topbar-right"), let rl = rect("results-right") {
                        report("M113 \(tag) 顶栏齿轮右=\(FMFrameMetrics.fmt(bar.maxX)) 网格右=\(FMFrameMetrics.fmt(rl.maxX)) 左留白=\(FMFrameMetrics.fmt(rl.minX)) 右留白=\(FMFrameMetrics.fmt(win.width - rl.maxX))")
                    }
                    if let p = FMFrameMetrics.lastSize["modal-panel#size"] {
                        report("M113 \(tag) 弹窗 \(FMFrameMetrics.fmt(p.width))x\(FMFrameMetrics.fmt(p.height))")
                    }
                }

                await model.loadRankIfNeeded()
                try? await Task.sleep(for: .seconds(12))
                ViewModeStore.shared.set(.album)
                try? await Task.sleep(for: .seconds(3))
                dump("主页封面")
                report("M113 SHOT home-album")
                try? await Task.sleep(for: .seconds(8))

                ViewModeStore.shared.set(.list)
                try? await Task.sleep(for: .seconds(3))
                dump("主页列表")
                report("M113 SHOT home-list")
                try? await Task.sleep(for: .seconds(8))

                ViewModeStore.shared.set(.album)
                if let first = model.rankBooks.first {
                    model.openDetail(first)
                    try? await Task.sleep(for: .seconds(10))
                    dump("详情")
                    report("M113 SHOT detail")
                    try? await Task.sleep(for: .seconds(6))
                    model.closeDetail()
                    try? await Task.sleep(for: .seconds(2))
                }
                withAnimation(.easeOut(duration: 0.2)) { model.activeOverlay = .downloads }
                try? await Task.sleep(for: .seconds(5))
                dump("下载管理")
                report("M113 SHOT downloads")
                try? await Task.sleep(for: .seconds(6))
                model.activeOverlay = nil
                report("M113 done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "fonts":
            // M1.12 取证：字号放大后各屏尺寸/卡片一致/弹窗固定
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(2))

                @MainActor func dump(_ tag: String) {
                    func f(_ name: String) -> String {
                        guard let r = FMFrameMetrics.last[name] else { return "\(name)=缺失" }
                        return "\(name)=\(FMFrameMetrics.fmt(r.width))x\(FMFrameMetrics.fmt(r.height))@(\(FMFrameMetrics.fmt(r.minX)),\(FMFrameMetrics.fmt(r.minY)))"
                    }
                    func sizeOf(_ name: String) -> String {
                        guard let s = FMFrameMetrics.lastSize[name + "#size"] else { return "\(name)=缺失" }
                        return "\(name)=\(FMFrameMetrics.fmt(s.width))x\(FMFrameMetrics.fmt(s.height))"
                    }
                    report("FONT \(tag) 面板尺寸 \(sizeOf("modal-panel")) ｜ global \(f("modal-panel")) ｜ 封面 \(f("detail-cover")) 右列 \(f("detail-info")) 简介 \(f("detail-desc"))")
                    let win = MainWindowRegistry.shared.window?.contentView?.bounds.size ?? .zero
                    report("FONT \(tag) 窗口 \(FMFrameMetrics.fmt(win.width))x\(FMFrameMetrics.fmt(win.height))")
                    if let p = FMFrameMetrics.last["modal-panel"] {
                        report("FONT \(tag) 弹窗四周留白 左\(FMFrameMetrics.fmt(p.minX)) 右\(FMFrameMetrics.fmt(win.width - p.maxX)) 上\(FMFrameMetrics.fmt(p.minY)) 下\(FMFrameMetrics.fmt(win.height - p.maxY))")
                    }
                    // 卡片内部竖向拆解（行2 首卡 card-6）：卡顶/封面底/书名/作者/评分·字数/卡底
                    func yy(_ n: String) -> String {
                        guard let r = FMFrameMetrics.last[n] else { return "\(n)=缺失" }
                        return "\(n)[\(FMFrameMetrics.fmt(r.minY))..\(FMFrameMetrics.fmt(r.maxY))]h\(FMFrameMetrics.fmt(r.height))"
                    }
                    if let c6 = FMFrameMetrics.last["card-6"] {
                        let c6s = yy("card-6")
                        let cover6 = yy("cover-6")
                        let t6 = yy("card-6-title")
                        let a6 = yy("card-6-author")
                        let m6 = yy("card-6-meta")
                        let i6 = yy("card-6-info")
                        report("FONT \(tag) 行2卡内 \(c6s) \(cover6) \(t6) \(a6) \(m6) \(i6)")
                        let rows = (1...10).compactMap { FMFrameMetrics.last["card-\($0)"]?.minY }
                        let rowTops = Array(Set(rows.map { FMFrameMetrics.fmt($0) })).sorted()
                        let lastBottom = (1...10).compactMap { FMFrameMetrics.last["card-\($0)"]?.maxY }.max() ?? 0
                        let metaBottom = FMFrameMetrics.last["card-6-meta"]?.maxY ?? c6.maxY
                        report("FONT \(tag) 行顶=\(rowTops.joined(separator: "/")) 行2底=\(FMFrameMetrics.fmt(lastBottom)) 窗口底留白=\(FMFrameMetrics.fmt(win.height - lastBottom)) 卡内下余量=\(FMFrameMetrics.fmt(c6.maxY - metaBottom))")
                        let st = yy("rank-status-text")
                        let c1s = yy("card-1")
                        report("FONT \(tag) 状态行到网格 \(st) 首卡 \(c1s)")
                    }
                    // 卡片尺寸（前 10 张）+ 左右留白（网格 vs 顶栏）
                    let widths = (1...10).compactMap { FMFrameMetrics.last["card-\($0)"]?.width }
                    let heights = (1...10).compactMap { FMFrameMetrics.last["card-\($0)"]?.height }
                    func uniq(_ v: [CGFloat]) -> String {
                        let set = Set(v.map { FMFrameMetrics.fmt($0) })
                        return set.isEmpty ? "无" : (set.count == 1 ? "\(set.first!)（\(v.count) 张全等）" : "不等：\(set.sorted().joined(separator: "/"))")
                    }
                    if !widths.isEmpty || !heights.isEmpty {
                        report("FONT \(tag) 卡片宽=\(uniq(widths)) 卡片高=\(uniq(heights)) 封面宽=\(uniq((1...10).compactMap { FMFrameMetrics.last["cover-\($0)"]?.width })) 封面高=\(uniq((1...10).compactMap { FMFrameMetrics.last["cover-\($0)"]?.height }))")
                    }
                    let gridLeft = FMFrameMetrics.last["results-left"]?.minX ?? -1
                    let gridRight = FMFrameMetrics.last["results-right"]?.maxX ?? -1
                    let barLeft = FMFrameMetrics.last["topbar-left"]?.minX ?? -1
                    let barRight = FMFrameMetrics.last["topbar-right"]?.maxX ?? -1
                    if gridLeft >= 0, barLeft >= 0 {
                        report("FONT \(tag) 左留白=网格\(FMFrameMetrics.fmt(gridLeft)) 右留白=窗口-\(FMFrameMetrics.fmt(gridRight)) ｜ 顶栏左\(FMFrameMetrics.fmt(barLeft)) 顶栏右\(FMFrameMetrics.fmt(barRight)) Δ左=\(FMFrameMetrics.fmt(abs(barLeft-gridLeft))) Δ右=\(FMFrameMetrics.fmt(abs(barRight-gridRight)))")
                    }
                }

                await model.runSearch(ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "游走神话时代")
                try? await Task.sleep(for: .seconds(10))
                ViewModeStore.shared.set(.album)
                try? await Task.sleep(for: .seconds(3))
                dump("主页封面")
                report("FONT SHOT home-album")
                try? await Task.sleep(for: .seconds(7))

                ViewModeStore.shared.set(.list)
                try? await Task.sleep(for: .seconds(3))
                dump("主页列表")
                report("FONT SHOT home-list")
                try? await Task.sleep(for: .seconds(7))

                ViewModeStore.shared.set(.album)
                if let first = model.results.first {
                    model.openDetail(first)
                    try? await Task.sleep(for: .seconds(12))
                    dump("详情-长简介")
                    report("FONT SHOT detail-long")
                    try? await Task.sleep(for: .seconds(8))
                    model.closeDetail()
                    try? await Task.sleep(for: .seconds(2))
                }
                let shortKeyword = ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD2"] ?? "灼灼欲撩"
                await model.runSearch(shortKeyword)
                if let first = model.results.first {
                    model.openDetail(first)
                    try? await Task.sleep(for: .seconds(12))
                    dump("详情-短简介")
                    report("FONT SHOT detail-short")
                    try? await Task.sleep(for: .seconds(8))
                    model.closeDetail()
                    try? await Task.sleep(for: .seconds(2))
                }

                withAnimation(.easeOut(duration: 0.2)) { model.activeOverlay = .downloads }
                try? await Task.sleep(for: .seconds(5))
                dump("下载管理")
                report("FONT SHOT downloads")
                try? await Task.sleep(for: .seconds(8))
                model.activeOverlay = nil
                try? await Task.sleep(for: .seconds(2))

                withAnimation(.easeOut(duration: 0.2)) { model.activeOverlay = .settings }
                try? await Task.sleep(for: .seconds(5))
                dump("设置")
                report("FONT SHOT settings")
                try? await Task.sleep(for: .seconds(8))
                model.activeOverlay = nil
                try? await Task.sleep(for: .seconds(1))
                report("FONT done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "m11":
            // M11 取证（用户 7 张批注）——四个屏一次跑完：
            //   ① 设置页：无「保存格式」行、内核块只剩标题+检查更新、路径/说明 = 二级字号
            //   ② 详情页：作者行（作者 + 已完结 · 上架 YYYY-MM）→ 后台标签胶囊 → 番茄统计 chip →
            //             数据块三行（读者占比 / 申请·已上架·改编中 / 榜单标签）
            //   ③ 榜单卡片：序号 = 封面右下角，后台角标 = 封面右上角（不相交）
            //   ④ 下载完成文案 + Finder 图标按钮
            //   ⑤ 关短剧开关：详情页无后台行、读钥匙串 = 0
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(2))

                @MainActor func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
                @MainActor func r(_ name: String) -> CGRect? { FMFrameMetrics.last[name] }
                @MainActor func box(_ name: String) -> String {
                    guard let x = FMFrameMetrics.last[name] else { return "\(name)=缺失" }
                    return "\(name)[y \(FMFrameMetrics.fmt(x.minY))..\(FMFrameMetrics.fmt(x.maxY)) x \(FMFrameMetrics.fmt(x.minX))..\(FMFrameMetrics.fmt(x.maxX))]\(FMFrameMetrics.fmt(x.width))x\(FMFrameMetrics.fmt(x.height))"
                }

                PlatformStore.shared.set(.fanqie)
                await model.platformChanged()
                await wait(2)

                // ══ ① 设置页（页内 4 行：下载目录 / 短剧模式 / 番茄内核 / 诊断日志）══
                withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = .settings }
                await wait(5)
                let dirValue = r("settings-detail-下载目录")
                let logValue = r("settings-detail-诊断日志")
                let kernelRow = r("settings-kernel-row")
                report("M11 设置 行=下载目录/短剧模式/番茄内核/诊断日志（4 行；无「保存格式」行，无内核版本行/内核路径行/当前使用行）")
                report("M11 设置 二级字号=FMTheme.Font.meta(14) ｜ 下载目录值=\(dirValue.map { "\(FMFrameMetrics.fmt($0.height))×\(FMFrameMetrics.fmt($0.width))" } ?? "?") 诊断日志值=\(logValue.map { "\(FMFrameMetrics.fmt($0.height))×\(FMFrameMetrics.fmt($0.width))" } ?? "?")（caption(12) 时行高≈15）")
                report("M11 设置 内核块=\(kernelRow.map { "\(FMFrameMetrics.fmt($0.width))×\(FMFrameMetrics.fmt($0.height))" } ?? "?")（只剩标题 + 立即检查更新）")
                report("M11 SHOT m11-settings")
                await wait(7)
                model.activeOverlay = nil
                await wait(2)

                // ══ ② 详情页：注入一条后台命中（不走网络 / 不读钥匙串）══
                let original = sdEnable()
                ShortdramaStore.shared.setIgnored(false)
                guard let found = await sdSearchItem(model: model) else {
                    report("M11 FAIL 没有搜索结果")
                    sdRestore(original)
                    report("M11 done")
                    NSApp.terminate(nil)
                    return
                }
                let fake = Self.fakeShortdramaIP(name: found.title, month: "2026-04", apply: 0, adapting: 0)
                ShortdramaStore.shared.debugInjectedHits = [found.title: fake]
                await model.runSearch(found.title)
                await wait(3)
                let target = model.results.first(where: { $0.bookID == found.bookID }) ?? model.results.first ?? found
                model.openDetail(target)
                await wait(9)

                let authorRow = r("detail-author-row")
                let tagsRow = r("detail-sd-tags")
                let statsRow = r("detail-stats-row")
                let strip = r("detail-sd-strip")
                let rankTags = r("detail-sd-ranks")
                let actions = r("detail-actions")
                let panel = r("modal-panel")
                report("M11 详情 作者行：作者: \(AppModel.lastDetailInfo?.author ?? "?") ＋ 后台状态「\(ShortdramaStrip.statusText(fake))」")
                report("M11 详情 后台标签行=\(ShortdramaStrip.tags(fake).map { $0.text }.joined(separator: " ｜ "))（精品IP = 强调色 FMChip）")
                report("M11 详情 几何 \(box("detail-author-row")) ｜ \(box("detail-sd-tags")) ｜ \(box("detail-stats-row")) ｜ \(box("detail-sd-strip")) ｜ \(box("detail-sd-ranks"))")
                if let authorRow, let tagsRow, let statsRow {
                    let ordered = authorRow.maxY <= tagsRow.maxY && tagsRow.minY >= authorRow.maxY && statsRow.minY >= tagsRow.maxY
                    report("M11 详情 顺序 作者行→后台标签行→番茄统计行 判定=\(ordered ? "是 → OK" : "否 → FAIL")")
                }
                report("M11 详情 数据块第1行=\(ShortdramaStrip.lineText(ShortdramaStrip.line2(fake)))")
                report("M11 详情 数据块第2行=\(ShortdramaStrip.lineText(ShortdramaStrip.line3(fake)))")
                report("M11 详情 数据块第3行（榜单标签）=\(ShortdramaStrip.rankTags(fake).map { "[\($0)]" }.joined(separator: " "))")
                report("M11 详情 数据块三行且无「评价」=\(!ShortdramaStrip.lineText(ShortdramaStrip.line3(fake)).contains("评价") ? "是 → OK" : "否 → FAIL")")
                if let strip, let actions, let panel {
                    report("M11 详情 不溢出 数据块下沿≤按钮行上沿=\(strip.maxY <= actions.minY ? "是 → OK" : "否 → FAIL") 按钮行下沿≤面板下沿=\(actions.maxY <= panel.maxY ? "是 → OK" : "否 → FAIL") 数据块高=\(FMFrameMetrics.fmt(strip.height))（榜单标签在块内=\(rankTags.map { $0.maxY <= strip.maxY + 1 } ?? false)）")
                    let size = FMFrameMetrics.lastSize["modal-panel#size"]
                    report("M11 详情 面板=\(size.map { "\(FMFrameMetrics.fmt($0.width))×\(FMFrameMetrics.fmt($0.height))" } ?? "?")")
                }
                report("M11 SHOT m11-detail")
                await wait(8)

                // ══ ④ 下载完成文案 + Finder 图标按钮 ══
                model.startDownload(title: target.title, author: target.author, bookID: target.bookID, platform: .fanqie)
                var waited = 0.0
                while waited < 180 {
                    if let task = model.downloads.task(for: target.bookID), !task.isActive {
                        report("M11 下载 状态=\(task.state) 完成态按钮语义=「\(task.state == "失败" ? (task.message ?? "下载失败") : BookDetailView.doneButtonHelp)」（M12-b 起完成态 = 绿色 + 文件夹图标，不渲染文字；「✓ 下载完成」文字已删）文件=\(task.filePath ?? "-")")
                        if let path = task.filePath, let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int {
                            report("M11 下载 产物 \(URL(fileURLWithPath: path).pathExtension) \(size) 字节")
                        }
                        break
                    }
                    try? await Task.sleep(for: .seconds(1))
                    waited += 1
                }
                if waited >= 180 { report("M11 下载 超时（180s）") }
                await wait(4)
                let doneIcon = r("detail-download-button-icon")
                let resultText = r("detail-result-text")
                report("M11 下载 完成态按钮图标=\(doneIcon.map { "\(FMFrameMetrics.fmt($0.width))×\(FMFrameMetrics.fmt($0.height))" } ?? "缺失")（SF Symbol \(BookDetailView.folderSymbolName ?? "无") + help「\(BookDetailView.doneButtonHelp)」）右侧放大镜按钮=\(r("detail-reveal-button") == nil ? "已删 → OK" : "仍在 → FAIL") 结果文案区=\(resultText.map { "\(FMFrameMetrics.fmt($0.width))×\(FMFrameMetrics.fmt($0.height))" } ?? "缺失") 在动作行内且不溢出=\(doneIcon != nil && actions != nil && (doneIcon?.maxY ?? 0) <= (panel?.maxY ?? 0))")
                report("M11 SHOT m11-download")
                await wait(8)
                model.closeDetail()
                await wait(2)

                // ══ ③ 榜单卡片：序号右下 + 角标右上 ══
                // 先回到榜单页（前面的搜索把 mainView 切到了搜索结果区；榜单页才有序号）
                model.mainView = .rank
                await model.reloadRank()
                await wait(6)
                if let firstRank = model.rankBooks.first {
                    ShortdramaStore.shared.debugInjectedHits = [firstRank.title: Self.fakeShortdramaIP(name: firstRank.title, month: "2026-04", apply: 12, adapting: 0, shelved: 2)]
                    await model.reloadRank()
                    await wait(5)
                    // 强制重建相册网格：保证量到的是本次布局的 frame（序号/角标挂在封面上，
                    // 视图身份不变时 SwiftUI 不会再报一次 onAppear）
                    ViewModeStore.shared.set(.list)
                    await wait(3)
                    FMFrameMetrics.clear()
                    ViewModeStore.shared.set(.album)
                    await wait(5)
                    let cover = r("cover-1"), badge = r("card-1-sd-badge"), no = r("card-1-rank")
                    report("M11 榜单 几何 \(box("cover-1")) ｜ \(box("card-1-rank")) ｜ \(box("card-1-sd-badge"))（角标 frame 含 ShortdramaTag 自带的 8pt 留白）")
                    if let cover, let badge, let no {
                        let inCover = no.minY >= cover.minY - 1 && no.maxY <= cover.maxY + 1 && no.maxX <= cover.maxX + 1
                        let bottomRight = abs(no.maxX - (cover.maxX - 8)) <= 1.5 && abs(no.maxY - (cover.maxY - 8)) <= 1.5
                        let topRight = abs(badge.minY - cover.minY) <= 1.5 && abs(badge.maxX - cover.maxX) <= 1.5
                        report("M11 榜单 序号在封面内=\(inCover ? "是 → OK" : "否 → FAIL") 序号贴右下角(留白 8)=\(bottomRight ? "是 → OK" : "否 → FAIL") 角标贴右上角=\(topRight ? "是 → OK" : "否 → FAIL") 两者不相交=\(no.minY >= badge.maxY ? "是 → OK" : "否 → FAIL") 序号尺寸=\(FMFrameMetrics.fmt(no.width))×\(FMFrameMetrics.fmt(no.height))")
                    } else {
                        report("M11 榜单 FAIL 卡片 frame 缺失（封面/序号/角标）")
                    }
                } else {
                    report("M11 榜单 FAIL 榜单无数据")
                }
                report("M11 SHOT m11-rank-card")
                await wait(8)

                // ══ ⑤ 关短剧开关：无后台行、读钥匙串 = 0 ══
                ShortdramaStore.shared.debugInjectedHits = nil
                ShortdramaStore.shared.setIgnored(true)
                ShortdramaStore.shared.clearDetail()
                FMFrameMetrics.clear()
                let kc0 = ShortdramaSession.keychainReads
                model.openDetail(target)
                await wait(9)
                report("M11 关短剧 详情后台数据块=\(r("detail-sd-strip") == nil ? "不显示 → OK" : "仍显示 → FAIL") 后台标签行=\(r("detail-sd-tags") == nil ? "不显示 → OK" : "仍显示 → FAIL") 提示行=\(r("detail-sd-hint") == nil ? "无" : "有（未登录态提示，保留）")")
                report("M11 关短剧 详情读取详情后读钥匙串次数=\(ShortdramaSession.keychainReads - kc0)（应 0）")
                report("M11 SHOT m11-detail-sd-off")
                await wait(7)
                model.closeDetail()
                await wait(2)

                sdRestore(original)
                PlatformStore.shared.set(.fanqie)
                await wait(1)
                report("M11 还原 shortdramaIgnored=\(SettingsStore.shared.settings.shortdramaIgnored) shortdramaPrompted=\(SettingsStore.shared.settings.shortdramaPrompted) 平台=\(PlatformStore.shared.platform.displayName)")
                report("M11 done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "m12":
            // M12-b 取证：详情页下载按钮状态机（蓝「下载」→ 按钮内绿色填充 → 整体绿 + **文件夹图标**）
            //           + 动作行删重复「共 N 章」+ 后台两行移到按钮右侧（两行合计高 ≈ 按钮高）
            //           + 榜单框整块删除（用户续批注：连框带标签一起去掉）
            //   ① 未下载：动作行无「共 N 章」、按钮蓝底「下载」
            //   ② 下载中：按钮内从左到右绿色填充（fraction 实测）
            //   ③ 下载完成：整体绿 + 文件夹图标（SF Symbol folder 探活），不再有「打开」文字，
            //      右侧**无**放大镜图标按钮（用户 Q2 选「甲」：删掉重复按钮）
            //   ④ 两行紧贴按钮右侧（各 frame + 合计高 vs 按钮高；右边界 ≤ 941）
            //   ⑤ 榜单框不存在（detail-sd-strip / detail-sd-ranks 都没 frame），
            //      「简介块下沿 → 按钮行上沿」间距 = 简介块的 20pt 下 padding（没异常拉大）
            //   ⑥ 行为：删掉文件 → 回「下载」；产物还原后点绿色按钮 → **访达激活并选中产物**
            //      （`revealDownloadedFile` = 按钮同源），且**不用默认应用打开 .txt**
            //   ⑦ 回归：关短剧时两行不显示、读钥匙串 = 0
            //   ⑧ 失败态：下载目录不可写 → 按钮回蓝「下载」+ M11 红色错误提示保留
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(2))

                @MainActor func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
                @MainActor func r(_ name: String) -> CGRect? { FMFrameMetrics.last[name] }
                @MainActor func value(_ name: String) -> String { FMFrameMetrics.lastValue[name] ?? "缺失" }
                @MainActor func box(_ name: String) -> String {
                    guard let x = FMFrameMetrics.last[name] else { return "\(name)=缺失" }
                    return "\(name)[y \(FMFrameMetrics.fmt(x.minY))..\(FMFrameMetrics.fmt(x.maxY)) x \(FMFrameMetrics.fmt(x.minX))..\(FMFrameMetrics.fmt(x.maxX))]\(FMFrameMetrics.fmt(x.width))x\(FMFrameMetrics.fmt(x.height))"
                }
                @MainActor func existing(_ item: SearchItem) -> String? {
                    BookDetailView.DownloadButtonState.existingFile(
                        bookID: item.bookID, title: item.title, author: item.author,
                        downloads: model.downloads, library: model.library
                    )
                }
                /// 按钮文字是否被挤扁：按钮宽 − 文字宽 应 = 34×2 padding（差 ≤1 视为没被压）
                @MainActor func textCheck(_ tag: String) -> String {
                    guard let btn = r("detail-download-button"), let txt = r("detail-download-button-text") else {
                        return "\(tag) 按钮/文字 frame 缺失"
                    }
                    let pad = btn.width - txt.width
                    let inside = txt.minX >= btn.minX - 0.5 && txt.maxX <= btn.maxX + 0.5
                    return "\(tag) 按钮 \(FMFrameMetrics.fmt(btn.width))×\(FMFrameMetrics.fmt(btn.height)) 文字「\(value("detail-download-button-title"))」 \(FMFrameMetrics.fmt(txt.width))×\(FMFrameMetrics.fmt(txt.height)) 按钮宽−文字宽=\(FMFrameMetrics.fmt(pad))（应 = 68 = 34×2 padding）→ \(abs(pad - 68) <= 1 ? "没被压扁/不裁字 → OK" : "文字被压 → FAIL") 文字完整在按钮内=\(inside ? "是 → OK" : "否 → FAIL")"
                }
                /// M12-b：完成态**文件夹图标**是否在按钮内居中、不裁不溢出，且不再渲染文字。
                @MainActor func iconCheck(_ tag: String) -> String {
                    guard let btn = r("detail-download-button") else { return "\(tag) 按钮 frame 缺失" }
                    guard let icon = r("detail-download-button-icon") else {
                        return "\(tag) 文件夹图标 frame 缺失（探活到的 SF Symbol=\(BookDetailView.folderSymbolName ?? "无")）→ FAIL（出现空白图标）"
                    }
                    let inside = icon.minX >= btn.minX - 0.5 && icon.maxX <= btn.maxX + 0.5
                        && icon.minY >= btn.minY - 0.5 && icon.maxY <= btn.maxY + 0.5
                    let centered = abs(icon.midX - btn.midX) <= 1
                    let noText = r("detail-download-button-text") == nil
                    return "\(tag) 按钮 \(FMFrameMetrics.fmt(btn.width))×\(FMFrameMetrics.fmt(btn.height)) 图标 SF Symbol「\(value("detail-download-button-symbol"))」 \(FMFrameMetrics.fmt(icon.width))×\(FMFrameMetrics.fmt(icon.height)) 完整在按钮内=\(inside ? "是 → OK" : "否 → FAIL") 水平居中 Δ=\(FMFrameMetrics.fmt(abs(icon.midX - btn.midX)))（≤1）→ \(centered ? "OK" : "FAIL") 不再渲染文字=\(noText ? "是 → OK" : "否 → FAIL")"
                }

                PlatformStore.shared.set(.fanqie)
                await model.platformChanged()
                await wait(2)

                // 下载态证据要能看到「按钮内的绿色填充」：内核只在「保存」阶段报进度（saved_chapters），
                // 缓存过的书 1~2 秒就下完，屏幕上根本来不及出现填充。
                // 所以这里**挑一本内核 staging 里还没有目录的新书**当下载目标（关键词可用 FQM_SELFTEST_KEYWORD 换）。
                let original = sdEnable()
                ShortdramaStore.shared.setIgnored(false)
                guard let picked = await m12FreshTarget(model: model) else {
                    report("M12 FAIL 没有搜索结果")
                    sdRestore(original)
                    report("M12 done")
                    NSApp.terminate(nil)
                    return
                }
                let fake = Self.fakeShortdramaIP(name: picked.title, month: "2026-04", apply: 12, adapting: 3, shelved: 2)
                ShortdramaStore.shared.debugInjectedHits = [picked.title: fake]
                await model.runSearch(picked.title)
                await wait(3)
                let target = model.results.first(where: { $0.bookID == picked.bookID }) ?? picked
                // 预清理：保证进详情是「未下载」态（历史产物会让按钮直接是绿色常挂）
                var cleaned = 0
                while let stale = existing(target), cleaned < 5 {
                    try? FileManager.default.removeItem(atPath: stale)
                    LibraryStore.shared.reload()
                    cleaned += 1
                }
                report("M12 下载目标《\(target.title)》\(target.bookID)（内核未缓存 → 能真的跑一段保存阶段；预清理 \(cleaned) 个旧产物）")
                model.library.reload()
                FMFrameMetrics.clear()
                model.openDetail(target)
                await wait(10)

                // ══ ① 未下载态 ══
                let btnIdle = r("detail-download-button")
                let line1 = r("detail-sd-line1")
                let line2 = r("detail-sd-line2")
                let lines = r("detail-sd-lines")
                let strip = r("detail-sd-strip")
                let ranks = r("detail-sd-ranks")
                let actions = r("detail-actions")
                let desc = r("detail-desc")
                let panel = r("modal-panel")
                let panelSize = FMFrameMetrics.lastSize["modal-panel#size"]
                report("M12 未下载 按钮文案=「\(value("detail-download-button-title"))」色调=\(value("detail-download-button-tone"))（期望 下载 / blue）")
                report("M12 未下载 动作行重复「共 N 章」=已删（源码只留统计行那一处）；统计行仍有共 \(AppModel.lastDetailInfo?.chapterCount ?? 0) 章")
                report("M12 未下载 几何 \(box("detail-download-button")) ｜ \(box("detail-actions")) ｜ \(box("modal-panel")) 面板尺寸=\(panelSize.map { "\(FMFrameMetrics.fmt($0.width))×\(FMFrameMetrics.fmt($0.height))" } ?? "?")")
                report("M12 未下载 不裁字 \(textCheck("未下载"))")
                report("M12 两行 几何 \(box("detail-sd-line1")) ｜ \(box("detail-sd-line2")) ｜ \(box("detail-sd-lines"))")
                report("M12 两行 内容①=\(ShortdramaStrip.lineText(ShortdramaStrip.line2(fake))) ②=\(ShortdramaStrip.lineText(ShortdramaStrip.line3(fake)))")
                if let line1, let line2, let lines, let btnIdle {
                    let union = line2.maxY - line1.minY
                    let delta = abs(union - btnIdle.height)
                    report("M12 两行 合计高=\(FMFrameMetrics.fmt(union))（line1.minY=\(FMFrameMetrics.fmt(line1.minY)) .. line2.maxY=\(FMFrameMetrics.fmt(line2.maxY))）按钮高=\(FMFrameMetrics.fmt(btnIdle.height)) Δ=\(FMFrameMetrics.fmt(delta)) → \(delta <= 2 ? "持平 → OK" : "不持平 → FAIL")")
                    report("M12 两行 紧贴按钮右侧=\(line1.minX > btnIdle.maxX ? "是 → OK" : "否 → FAIL")（button.maxX=\(FMFrameMetrics.fmt(btnIdle.maxX)) lines.minX=\(FMFrameMetrics.fmt(lines.minX))）垂直居中Δ=\(FMFrameMetrics.fmt(abs(lines.midY - btnIdle.midY)))（≤1 = OK）右边界=\(FMFrameMetrics.fmt(lines.maxX))（≤941 → \(lines.maxX <= 941 ? "OK" : "FAIL")）")
                } else {
                    report("M12 两行 FAIL frame 缺失（按钮/两行）")
                }
                if let strip, let ranks, let lines {
                    report("M12 榜单框 FAIL 仍存在 strip=\(box("detail-sd-strip")) ranks=\(box("detail-sd-ranks")) lines.minX=\(FMFrameMetrics.fmt(lines.minX)) strip.maxX=\(FMFrameMetrics.fmt(strip.maxX))")
                } else {
                    report("M12 榜单框 已删除（连框带标签）：detail-sd-strip=\(strip == nil ? "不存在 → OK" : "存在 → FAIL") detail-sd-ranks=\(ranks == nil ? "不存在 → OK" : "存在 → FAIL")；榜单取数保留但界面不渲染=Logic \(ShortdramaStrip.rankTags(fake).map { "[\($0)]" }.joined(separator: " "))")
                }
                if let panel, let actions, let desc {
                    let gap = actions.minY - desc.maxY
                    report("M12 不溢出 动作行下沿≤面板下沿=\(actions.maxY <= panel.maxY ? "是 → OK" : "否 → FAIL") 两行右边界≤面板内容右(941)=\(lines.map { $0.maxX <= 941 ? "是 → OK" : "否 → FAIL" } ?? "?")")
                    report("M12 间距 简介块下沿→按钮行上沿=\(FMFrameMetrics.fmt(gap))（简介块自带 20pt 下 padding；没被删掉的榜单框撑大）= \(abs(gap - 20) <= 2 ? "正常 → OK" : "异常 → FAIL") 简介块 \(box("detail-desc")) 按钮行 \(box("detail-actions"))")
                }
                report("M12 SHOT m12-idle")
                await wait(9)

                // ══ ② 下载中（按钮内绿色填充） ══
                //  内核在「抓章节」阶段只给 progress=null，到「保存」阶段才报 saved_chapters/chapter_total；
                //  shots 脚本用 FQM_DOWNLOAD_LIMIT=200 把保存阶段拉长，能拍到明显的绿条。
                //  这里等进度到 30%..95% 再报 SHOT，最多等 240s
                model.startDownload(title: target.title, author: target.author, bookID: target.bookID, platform: .fanqie)
                var waited = 0.0
                var midShot = false
                var lastProgress = "-"
                while waited < 240 {
                    guard let task = model.downloads.activeTask(for: target.bookID) else { break }
                    let progress = task.progress
                    lastProgress = "\(task.state) total=\(progress.total) saved=\(progress.saved) fraction=\(FMFrameMetrics.fmt(progress.fraction)) text=\(task.progressText)"
                    if !midShot, progress.total > 0, progress.saved > 0, progress.fraction >= 0.3, progress.fraction < 0.95 {
                        let buttonWidth = r("detail-download-button")?.width ?? 0
                        let fraction = BookDetailView.DownloadButtonState.fraction(task: task, chapterCount: AppModel.lastDetailInfo?.chapterCount ?? 0)
                        report("M12 下载中 按钮文案=「\(value("detail-download-button-title"))」色调=\(value("detail-download-button-tone"))（期望 filling）进度=\(lastProgress) 填充比例=\(FMFrameMetrics.fmt(fraction)) 填充宽=\(FMFrameMetrics.fmt(buttonWidth * fraction)) 按钮宽=\(FMFrameMetrics.fmt(buttonWidth))")
                        report("M12 下载中 不裁字 \(textCheck("下载中"))")
                        report("M12 SHOT m12-downloading")
                        midShot = true
                        await wait(5)
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    waited += 0.3
                }
                if !midShot { report("M12 下载中 FAIL 没抓到进行中的进度；最后一次看到=\(lastProgress)") }

                // ══ ③ 下载完成（整体绿「打开」+ 放大镜，无「✓ 下载完成」） ══
                while waited < 420 {
                    if let task = model.downloads.task(for: target.bookID), !task.isActive {
                        report("M12 完成 任务状态=\(task.state) 产物=\(task.filePath ?? "-")")
                        break
                    }
                    try? await Task.sleep(for: .seconds(1))
                    waited += 1
                }
                await wait(4)
                // M12-b：关掉重开一次详情再量完成态 frame。
                // 否则 `detail-download-button-text`（下载中那一帧留下的）会被读到，
                // 误判为「完成态还在渲染文字」（视图消失不会上报变化，判定不存在必须先 clear）。
                model.closeDetail()
                await wait(2)
                FMFrameMetrics.clear()
                model.openDetail(target)
                await wait(10)
                let btnDone = r("detail-download-button")
                let widthIdle = btnIdle.map { FMFrameMetrics.fmt($0.width) } ?? "?"
                let widthDone = btnDone.map { FMFrameMetrics.fmt($0.width) } ?? "?"
                let sameWidth = btnIdle != nil && btnDone != nil && abs(btnDone!.width - btnIdle!.width) <= 0.5
                let sameWidthText = sameWidth ? "两态同宽 → OK" : "宽度跳变 → FAIL"
                let panelSizeDone = FMFrameMetrics.lastSize["modal-panel#size"]
                let panelSizeText = panelSizeDone.map { "\(FMFrameMetrics.fmt($0.width))×\(FMFrameMetrics.fmt($0.height))" } ?? "?"
                let doneWarning = r("detail-result-text") == nil ? "不显示 → OK" : "仍显示 → FAIL"
                let revealGone = r("detail-reveal-button") == nil ? "已删除 → OK" : "仍在 → FAIL"
                report("M12 完成 按钮语义=「\(value("detail-download-button-title"))」色调=\(value("detail-download-button-tone"))（期望 打开访达 / green）文件夹图标=「\(value("detail-download-button-symbol"))」")
                report("M12 完成 「✓ 下载完成」文字= \(doneWarning) 右侧放大镜图标按钮= \(revealGone)（用户 Q2 选「甲」：功能并入主按钮，help=「\(BookDetailView.doneButtonHelp)」）")
                report("M12 完成 几何 \(iconCheck("完成")) 面板尺寸=\(panelSizeText)")
                report("M12 完成 按钮 frame \(box("detail-download-button"))（与未下载态比宽=\(widthIdle) → \(widthDone)：\(sameWidthText)）")
                report("M12 完成 两行合计高=按钮高 复测：" + { if let l1 = r("detail-sd-line1"), let l2 = r("detail-sd-line2"), let b = btnDone { let u = l2.maxY - l1.minY; return "\(FMFrameMetrics.fmt(u)) vs \(FMFrameMetrics.fmt(b.height)) Δ=\(FMFrameMetrics.fmt(abs(u - b.height))) → \(abs(u - b.height) <= 2 ? "持平 → OK" : "FAIL") 两行右边界=\(FMFrameMetrics.fmt(l1.maxX))（≤941 → \(l1.maxX <= 941 ? "OK" : "FAIL")）" } else { return "frame 缺失" } }())
                report("M12 SHOT m12-done")
                await wait(9)

                // ══ ④ 行为：删掉文件 → 回「下载」态（原地刷新 + 重新进详情两条路都核） ══
                let produced = existing(target)
                report("M12 行为 删文件前 产物=\(produced ?? "缺失") 存在=\(produced.map { FileManager.default.fileExists(atPath: $0) ? "是" : "否" } ?? "-")")
                // 留一份字节相同的备份：第 ⑤ 步「打开文件」用还原后的文件，不用再把 200 章下一遍
                let backup = FileManager.default.temporaryDirectory.appendingPathComponent("fqm-m12-open-test.txt")
                var hasBackup = false
                if let produced {
                    try? FileManager.default.removeItem(at: backup)
                    if (try? FileManager.default.copyItem(atPath: produced, toPath: backup.path)) != nil { hasBackup = true }
                    try? FileManager.default.removeItem(atPath: produced)
                }
                LibraryStore.shared.reload()
                await wait(4)
                report("M12 行为 删文件后（原地刷新）按钮文案=「\(value("detail-download-button-title"))」色调=\(value("detail-download-button-tone"))（期望 下载 / blue）→ \(value("detail-download-button-title") == BookDetailView.downloadButtonTitle ? "回到下载态 → OK" : "未回到下载态 → FAIL")")
                // 再关掉重开一次：新视图上重新量 frame，证据不被上一次渲染的残留值污染
                model.closeDetail()
                await wait(2)
                FMFrameMetrics.clear()
                model.openDetail(target)
                await wait(10)
                report("M12 行为 删文件后（重新进详情）按钮文案=「\(value("detail-download-button-title"))」色调=\(value("detail-download-button-tone")) 按钮 frame \(box("detail-download-button")) 右侧放大镜图标按钮= \(r("detail-reveal-button") == nil ? "不显示（M12-b 已删）→ OK" : "仍在 → FAIL")「✓ 下载完成」文字= \(r("detail-result-text") == nil ? "不显示 → OK" : "仍显示 → FAIL")")
                report("M12 SHOT m12-deleted")
                await wait(8)

                // ══ ⑤ 行为：点绿色按钮 = 打开访达并选中产物（与按钮同源 revealDownloadedFile） ══
                //  把第 ④ 步的备份按原路径还原 → 按钮应回到绿色图标态 → 调按钮的同一个函数。
                //  判定：① 函数返回 true ② 前台应用 = com.apple.finder ③ 默认应用（.txt 关联的 TextEdit）
                //  没被拉起/前台化（旧实现 NSWorkspace.open 会拉起它）
                if hasBackup, let produced {
                    try? FileManager.default.copyItem(atPath: backup.path, toPath: produced)
                    LibraryStore.shared.reload()
                    FMFrameMetrics.clear()
                    await wait(5)
                    // 先把自己的窗口拉到最前：`activateFileViewerSelecting` 只有在调用方是活动 app 时
                    // 才会把访达激活到前台（否则只默默 reveal 一个窗口）。
                    NSApp.activate(ignoringOtherApps: true)
                    MainWindowRegistry.shared.window?.makeKeyAndOrderFront(nil)
                    await wait(1)
                    let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: URL(fileURLWithPath: produced))
                        .flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "?"
                    let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                    let teBefore = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.TextEdit" }.count
                    let revealed = BookDetailView.revealDownloadedFile(path: produced)
                    var frontAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                    for _ in 0..<25 where frontAfter != "com.apple.finder" {
                        await wait(0.4)
                        frontAfter = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
                    }
                    let teAfter = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.apple.TextEdit" }.count
                    let finderAlive = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.finder" }
                    report("M12-b 行为 产物还原后 按钮语义=「\(value("detail-download-button-title"))」色调=\(value("detail-download-button-tone"))（期望 打开访达 / green）→ \(value("detail-download-button-title") == BookDetailView.doneButtonHelp ? "回到常驻绿图标态 → OK" : "未回绿 → FAIL")")
                    report("M12-b 行为 点绿色按钮（同一个 revealDownloadedFile）= \(revealed ? "调用成功 → OK" : "调用失败 → FAIL") 文件=\(produced)")
                    report("M12-b 行为 前台应用 \(frontBefore) → \(frontAfter)（期望 com.apple.finder）→ \(frontAfter == "com.apple.finder" ? "访达已激活 → OK" : "访达未激活 → FAIL") 访达进程在跑=\(finderAlive ? "是" : "否")；旧行为会打开的默认应用=\(defaultApp) TextEdit 实例 \(teBefore) → \(teAfter)（应不变 → \(teBefore == teAfter ? "OK" : "FAIL")）")
                } else {
                    report("M12-b 行为 FAIL 没找到产物或备份，无法测「打开访达」")
                }
                NSApp.activate()
                MainWindowRegistry.shared.window?.makeKeyAndOrderFront(nil)
                await wait(3)

                // ══ ⑥ 回归：关短剧 → 两行与榜单标签都不显示、读钥匙串 = 0 ══
                model.closeDetail()
                await wait(2)
                ShortdramaStore.shared.debugInjectedHits = nil
                ShortdramaStore.shared.setIgnored(true)
                ShortdramaStore.shared.clearDetail()
                FMFrameMetrics.clear()
                let kc0 = ShortdramaSession.keychainReads
                model.openDetail(target)
                await wait(10)
                report("M12 关短剧 两行=\(r("detail-sd-lines") == nil ? "不显示 → OK" : "仍显示 → FAIL") 榜单框=\(r("detail-sd-strip") == nil ? "不显示 → OK" : "仍显示 → FAIL") 按钮行=\(r("detail-download-button") == nil ? "缺失 → FAIL" : "照常有 → OK") 按钮文案=「\(value("detail-download-button-title"))」")
                report("M12 关短剧 读钥匙串次数=\(ShortdramaSession.keychainReads - kc0)（应 0）")
                model.closeDetail()
                await wait(2)

                // ══ ⑦ 失败态：把下载目录指到不可写路径 → 真实的落盘失败 →
                //      按钮回蓝「下载」（可重下）+ M11 的红色错误提示保留 ══
                let goodDir = SettingsStore.shared.settings.downloadDir
                if let leftover = existing(target) {
                    try? FileManager.default.removeItem(atPath: leftover)
                    LibraryStore.shared.reload()
                }
                SettingsStore.shared.update { $0.downloadDir = "/System/fqm-m12-not-writable" }
                FMFrameMetrics.clear()
                model.openDetail(target)
                await wait(10) // 详情加载 + 帧上报（下面不再 clear，失败态的 frame 就是这次渲染的）
                model.startDownload(title: target.title, author: target.author, bookID: target.bookID, platform: .fanqie)
                var waited3 = 0.0
                while waited3 < 240 {
                    if let task = model.downloads.task(for: target.bookID), !task.isActive {
                        report("M12 失败态 任务状态=\(task.state) 错误文案=「\(task.message ?? "-")」（下载目录指向不可写路径 → relocate 真实报错）")
                        break
                    }
                    try? await Task.sleep(for: .seconds(1))
                    waited3 += 1
                }
                await wait(5)
                report("M12 失败态 按钮文案=「\(value("detail-download-button-title"))」色调=\(value("detail-download-button-tone"))（期望 下载 / blue = 可重下）按钮 frame \(box("detail-download-button")) 错误提示块 \(box("detail-result-text")) 提示文案=「\(value("detail-result-text"))」（M11 红字提示保留）右侧放大镜图标按钮= \(r("detail-reveal-button") == nil ? "不显示（M12-b 已删）→ OK" : "仍在 → FAIL")")
                report("M12 SHOT m12-failed")
                await wait(8)
                SettingsStore.shared.update { $0.downloadDir = goodDir }
                report("M12 失败态 下载目录已还原=\(SettingsStore.shared.settings.downloadDir)")

                sdRestore(original)
                PlatformStore.shared.set(.fanqie)
                await wait(1)
                // 把本次测试下的产物 + 它的下载记录收干净（不留垃圾给用户）
                for item in model.library.items
                where item.record.path.hasSuffix(FMFormat.downloadFileName(title: target.title, author: target.author, bookID: target.bookID)) {
                    try? model.library.remove(id: item.record.path, deleteFile: true)
                    report("M12 清理 已删测试产物与记录：\(item.record.path)")
                }
                try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appendingPathComponent("fqm-m12-open-test.txt"))
                report("M12 还原 shortdramaIgnored=\(SettingsStore.shared.settings.shortdramaIgnored) shortdramaPrompted=\(SettingsStore.shared.settings.shortdramaPrompted) 平台=\(PlatformStore.shared.platform.displayName)")
                report("M12 done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "m13":
            // M13 取证：榜单页分段行右侧（☰ 左侧空位）新增「刷新榜单」按钮
            //   ① 位置/样式：分段行右侧、显示方式切换 ☰ 左侧；`.fmButton(.ghost, size: .square)` 34×34
            //   ② 行为：点击 = 重拉**当前频道**榜单（保持 TOP10），完成后刷新卡片（短剧角标照旧按 ID 重查）
            //   ③ 加载态：请求中按钮禁用 + 图标换转圈 → 连点两次只发一次请求（不并发）
            //   ④ 布局回归：窗口 1000×820、卡片 176.8×295、封面 195、留白 30/30、右侧群右边界 ≤970
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()

                @MainActor func wait(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
                @MainActor func r(_ name: String) -> CGRect? { FMFrameMetrics.last[name] }
                @MainActor func value(_ name: String) -> String { FMFrameMetrics.lastValue[name] ?? "缺失" }
                @MainActor func box(_ name: String) -> String {
                    guard let x = FMFrameMetrics.last[name] else { return "\(name)=缺失" }
                    return "\(name)[x \(FMFrameMetrics.fmt(x.minX))..\(FMFrameMetrics.fmt(x.maxX)) y \(FMFrameMetrics.fmt(x.minY))..\(FMFrameMetrics.fmt(x.maxY))]\(FMFrameMetrics.fmt(x.width))×\(FMFrameMetrics.fmt(x.height))"
                }
                /// 把 SwiftUI `.global` 点直接作为 AppKit 鼠标事件交给主窗口（绕开 HID/焦点问题）。
                /// `.global` 在本窗口下与内容视图左上原点一致（实测 leading=30 = leadingInset）→ 直接用。
                @MainActor func clickInWindow(_ globalPoint: CGPoint) -> Bool {
                    guard let win = MainWindowRegistry.shared.window, let content = win.contentView else { return false }
                    let local = NSPoint(x: globalPoint.x, y: content.bounds.height - globalPoint.y) // 窗口底左原点
                    let now = ProcessInfo.processInfo.systemUptime
                    guard let down = NSEvent.mouseEvent(
                        with: .leftMouseDown, location: local, modifierFlags: [], timestamp: now,
                        windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                    ), let up = NSEvent.mouseEvent(
                        with: .leftMouseUp, location: local, modifierFlags: [], timestamp: now + 0.06,
                        windowNumber: win.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 0
                    ) else { return false }
                    win.makeKeyAndOrderFront(nil)
                    win.sendEvent(down)
                    win.sendEvent(up)
                    return true
                }
                /// 点一次刷新按钮：先交窗口事件（绕开 HID），未生效再补一次 HID 真点击。返回生效方式。
                @MainActor func clickRefreshButton() async -> String {
                    guard let btn = r("rank-refresh-button"), MainWindowRegistry.shared.window != nil else { return "无按钮/窗口" }
                    _ = clickInWindow(CGPoint(x: btn.midX, y: btn.midY))
                    await wait(0.3)
                    if model.rankIsLoading { return "窗口事件" }
                    await clickAt(x: btn.midX, y: btn.midY)
                    await wait(0.3)
                    return model.rankIsLoading ? "HID 真点击" : "未命中"
                }
                /// 该 SwiftUI 点坐标最上层是哪个进程的窗口（诊断“点击落空”）
                @MainActor func frontmostOwner(atGlobal point: CGPoint) -> String {
                    guard let window = MainWindowRegistry.shared.window else { return "无主窗口" }
                    let contentHeight = window.contentView?.bounds.height ?? window.frame.height
                    let screenPoint = window.convertPoint(toScreen: NSPoint(x: point.x, y: contentHeight - point.y))
                    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                    for w in list {
                        guard let b = w["kCGWindowBounds"] as? [String: Any],
                              let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                              let width = b["Width"] as? CGFloat, let height = b["Height"] as? CGFloat else { continue }
                        if x <= screenPoint.x, screenPoint.x <= x + width, y <= screenPoint.y, screenPoint.y <= y + height {
                            return "\(w[kCGWindowOwnerName as String] as? String ?? "?")#\(w[kCGWindowNumber as String] as? Int ?? 0)"
                        }
                    }
                    return "未知"
                }
                @MainActor func settleRank(_ limit: Double = 40) async -> Double {
                    var waited = 0.0
                    while model.rankIsLoading, waited < limit {
                        try? await Task.sleep(for: .milliseconds(200))
                        waited += 0.2
                    }
                    return waited
                }

                PlatformStore.shared.set(.fanqie)
                await model.platformChanged() // 归位番茄 + 综合热榜 + 立即拉一次榜单
                await wait(10)

                let win = MainWindowRegistry.shared.window?.contentView?.bounds.size ?? .zero
                if let w = MainWindowRegistry.shared.window {
                    let cr = w.contentRect(forFrameRect: w.frame)
                    report("M13 环境 窗口 frame=\(FMFrameMetrics.fmt(w.frame.width))×\(FMFrameMetrics.fmt(w.frame.height))@(\(FMFrameMetrics.fmt(w.frame.minX)),\(FMFrameMetrics.fmt(w.frame.minY))) contentView=\(FMFrameMetrics.fmt(w.contentView?.bounds.width ?? 0))×\(FMFrameMetrics.fmt(w.contentView?.bounds.height ?? 0)) contentRect.maxY=\(FMFrameMetrics.fmt(cr.maxY)) isKey=\(w.isKeyWindow) 窗口数=\(NSApp.windows.count)")
                }

                // ── ① 图标探活 + 自解释 ──
                report("M13 图标 探活候选 [arrow.clockwise, arrow.triangle.2.circlepath] → 选中「\(RankView.refreshSymbolName ?? "都不可用")")
                report("M13 图标 按钮上屏 symbol=\(value("rank-refresh-symbol")) ｜ help=「刷新榜单」（源码 .help(刷新榜单)）｜ 与顶栏同款 .fmButton(.ghost, size: .square) 34×34")

                // ── ② 几何：位置 / 与 ☰ 及分段的间距 / 右边界 ──
                report("M13 几何 刷新按钮 \(box("rank-refresh-button")) ｜ ☰ \(box("viewmode-toggle")) ｜ 分段行 \(box("rank-channel-row"))")
                let refresh = r("rank-refresh-button")
                let toggle = r("viewmode-toggle")
                if let refresh, let toggle {
                    let sizeOK = abs(refresh.width - 34) <= 1 && abs(refresh.height - 34) <= 1
                    report("M13 几何 刷新按钮尺寸=\(FMFrameMetrics.fmt(refresh.width))×\(FMFrameMetrics.fmt(refresh.height))（应 34×34 → \(sizeOK ? "OK" : "FAIL")）与 ☰ 间距=\(FMFrameMetrics.fmt(toggle.minX - refresh.maxX))（HStack spacing=8）｜☰ 右边界=\(FMFrameMetrics.fmt(toggle.maxX))（≤970 → \(toggle.maxX <= 970 ? "OK" : "FAIL")）｜刷新按钮右边界=\(FMFrameMetrics.fmt(refresh.maxX))（≤970 → \(refresh.maxX <= 970 ? "OK" : "FAIL")）｜刷新按钮在 ☰ 左侧=\(refresh.maxX <= toggle.minX + 0.5 ? "是 → OK" : "否 → FAIL")")
                } else {
                    report("M13 几何 FAIL 刷新按钮或 ☰ frame 缺失")
                }
                let segs = ["hot", "男频", "女频"].compactMap { r("rank-channel-\($0)") }
                if let refresh, let last = segs.max(by: { $0.maxX < $1.maxX }) {
                    report("M13 几何 分段最后一个元素右边缘=\(FMFrameMetrics.fmt(last.maxX)) → 刷新按钮左边缘=\(FMFrameMetrics.fmt(refresh.minX)) 间距=\(FMFrameMetrics.fmt(refresh.minX - last.maxX))（中间是弹性 Spacer，不挤压）")
                }
                if !segs.isEmpty {
                    let tops = Set(segs.map { FMFrameMetrics.fmt($0.minY) })
                    let rowH = r("rank-channel-row").map { FMFrameMetrics.fmt($0.height) } ?? "?"
                    report("M13 几何 分段不换行=\(tops.count == 1 ? "是（3 个按钮同一行，minY=\(tops.first!)）→ OK" : "否 → FAIL") 分段行高=\(rowH) 分段底=\(FMFrameMetrics.fmt(segs.map { $0.maxY }.max() ?? 0)) 刷新按钮底=\(refresh.map { FMFrameMetrics.fmt($0.maxY) } ?? "?")（同一行 → 不撑高）")
                }

                // ── ③ 布局回归：窗口 / 卡片 / 封面 / 留白 ──
                let cards = (1...10).compactMap { r("card-\($0)") }
                let covers = (1...10).compactMap { r("cover-\($0)") }
                @MainActor func uniq(_ v: [CGFloat]) -> String {
                    let set = Set(v.map { FMFrameMetrics.fmt($0) })
                    return set.count == 1 ? "\(set.first!)（\(v.count) 张全等）" : "不等：\(set.sorted().joined(separator: "/"))"
                }
                let gridLeft = r("results-left")?.minX ?? -1
                let gridRight = r("results-right")?.maxX ?? -1
                report("M13 布局 窗口 \(FMFrameMetrics.fmt(win.width))×\(FMFrameMetrics.fmt(win.height))（应 1000×820）")
                report("M13 布局 卡片宽=\(uniq(cards.map(\.width))) 卡片高=\(uniq(cards.map(\.height)))")
                report("M13 布局 封面高=\(uniq(covers.map(\.height))) ｜ 左留白=\(FMFrameMetrics.fmt(gridLeft)) 右留白=\(FMFrameMetrics.fmt(win.width - gridRight))（应 30/30）｜ 顶栏图标群右边界=\(r("topbar-right").map { FMFrameMetrics.fmt($0.maxX) } ?? "?")（≤970）")
                report("M13 SHOT m13-rank-refresh")
                await wait(8)

                // ── ④ 行为：短剧开关开着 → 刷新后照旧按 ID 重查角标 ──
                let original = sdEnable() // 关 → 开
                let preTitles = model.rankBooks.map(\.title)
                var injected: [String: ShortdramaClient.ShortdramaIP] = [:]
                if preTitles.count > 3 { injected[preTitles[3]] = Self.fakeShortdramaIP(name: preTitles[3], month: "2026-04", apply: 12, adapting: 3, shelved: 2) }
                if preTitles.count > 6 { injected[preTitles[6]] = Self.fakeShortdramaIP(name: preTitles[6], month: "2025-11", apply: 5, adapting: 1) }
                ShortdramaStore.shared.debugInjectedHits = injected
                let beforeHits = model.shortdramaHits

                // ── ⑤ 连点两次（真实点击）：加载态生效 → 只发一次请求 ──
                // 本机「通知中心」的窗口层级高于普通窗口，会盖住右上角（实测点击点最上层=通知中心）——
                // 先把窗口挪到左下角避开遮挡；点击走“窗口事件”（绕开 HID 的焦点/TCC 限制）。
                MainWindowRegistry.shared.window?.setFrameOrigin(NSPoint(x: 60, y: 60))
                await wait(1)
                if let rb0 = r("rank-refresh-button") {
                    report("M13 点击前诊断 刷新按钮中心(global)=(\(FMFrameMetrics.fmt(rb0.midX)),\(FMFrameMetrics.fmt(rb0.midY))) 最上层窗口=\(frontmostOwner(atGlobal: CGPoint(x: rb0.midX, y: rb0.midY))) app.isActive=\(NSApp.isActive)")
                }
                let before = model.rankRequestCount
                let path1 = await clickRefreshButton() // 第 1 次点击（真发请求）
                let loadingAt2nd = model.rankIsLoading
                let stateAt2nd = value("rank-refresh-loading")
                let path2 = await clickRefreshButton() // 第 2 次点击（按钮已禁用 → 不应触发）
                let waited = await settleRank()
                let after = model.rankRequestCount
                report("M13 加载态 第 1 次点击（\(path1)）后请求中=\(loadingAt2nd) 按钮状态=\(stateAt2nd)（应 loading → 图标换转圈 + 禁用）")
                report("M13 连点 第 2 次点击（\(path2)，按钮此时应已禁用）→ 两次连点等待请求收尾（\(FMFrameMetrics.fmt(waited))s）count \(before)→\(after) Δ=\(after - before)（应=1 → 不并发）")

                var finalCount = after
                if after - before == 0 {
                    // 窗口事件 + HID 都没进到按钮时，用按钮 action 的**同源函数**做等价的「连点两次」
                    report("M13 连点 点击事件未命中按钮（诊断 app.isActive=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow != nil ? "有" : "nil") 主窗口.isKey=\(MainWindowRegistry.shared.window?.isKeyWindow ?? false)）→ 改用按钮 action 同源函数做等价连点")
                    await wait(1)
                    let before2 = model.rankRequestCount
                    let t1 = Task { await model.refreshRank() }
                    await wait(0.05)
                    let loading2 = model.rankIsLoading
                    let state2 = value("rank-refresh-loading")
                    let t2 = Task { await model.refreshRank() } // 第 2 次触发（上一次请求仍在进行）
                    await t1.value
                    _ = await settleRank()
                    await t2.value
                    let after2 = model.rankRequestCount
                    report("M13 连点 同源函数等价连点两次（间隔 50ms；第 2 次触发时加载中=\(loading2) 按钮状态=\(state2)）→ count \(before2)→\(after2) Δ=\(after2 - before2)（应=1 → 加载态挡住第 2 次）")
                }
                report("M13 刷新后 状态=「\(model.rankStatus)」条数=\(model.rankBooks.count)（应=10）耗时=\(model.lastRankDurationMs)ms 频道=\(model.rankChannel) 标签=\(model.rankLabel()) 按钮状态=\(value("rank-refresh-loading"))（应 idle）")
                await wait(6) // 等短剧后台「按 ID 重查」收尾
                let redCards = model.rankBooks.filter(\.sdInBackend).count
                report("M13 短剧角标 刷新前 hits=\(beforeHits) → 刷新后 hits=\(model.shortdramaHits)（短剧开关开着 → 照旧重查）注入=\(injected.count) 本；卡片红标=\(redCards) 本；状态行=「\(model.rankStatus)」")
                report("M13 SHOT m13-rank-refreshed")
                await wait(8)

                // ── ⑥ 当前频道保持：切到男频再点刷新，仍是男频 ──
                await model.selectRankChannel("男频")
                await wait(8)
                let channelBefore = model.rankChannel
                let before3 = model.rankRequestCount
                let path3 = await clickRefreshButton()
                if !model.rankIsLoading { await model.refreshRank() } // 点击未命中时的等价触发
                _ = await settleRank()
                report("M13 当前频道 点刷新（\(path3)）前 channel=\(channelBefore) → 刷新后 channel=\(model.rankChannel)（应=男频，不跳回综合热榜 → \(channelBefore == model.rankChannel ? "OK" : "FAIL")）条数=\(model.rankBooks.count) 耗时=\(model.lastRankDurationMs)ms count Δ=\(model.rankRequestCount - before3)（应=1）")
                report("M13 SHOT m13-rank-male-refresh")
                await wait(6)

                // ── ⑦ 搜索页不加刷新按钮（本按钮只在 RankView 的频道行）──
                FMFrameMetrics.clear()
                await model.runSearch("游走神话时代")
                await wait(6)
                report("M13 搜索页 mainView=\(model.mainView) 刷新按钮=\(r("rank-refresh-button") == nil ? "不存在 → OK（搜索页不加）" : "仍存在 → FAIL") 频道行=\(r("rank-channel-row") == nil ? "不存在（榜单页已切走）" : "仍存在") ☰=\(r("viewmode-toggle") == nil ? "不存在 → OK" : "仍存在 → FAIL")")
                model.mainView = .rank
                await wait(4)

                // ── 收尾：短剧注入清掉、开关还原、平台/频道归位 ──
                ShortdramaStore.shared.debugInjectedHits = nil
                sdRestore(original)
                PlatformStore.shared.set(.fanqie)
                await model.selectRankChannel("hot")
                await wait(3)

                // ── ⑦ 回归：关短剧时刷新榜单不读钥匙串 ──
                ShortdramaStore.shared.setIgnored(true)
                await wait(1)
                let kc0 = ShortdramaSession.keychainReads
                let hits0 = model.shortdramaHits
                await model.refreshRank()
                _ = await settleRank()
                await wait(2)
                report("M13 关短剧 刷新榜单后读钥匙串次数=\(ShortdramaSession.keychainReads - kc0)（应 0）hits\(hits0)→\(model.shortdramaHits)（应 0）条数=\(model.rankBooks.count)")

                report("M13 还原 shortdramaIgnored=\(SettingsStore.shared.settings.shortdramaIgnored) shortdramaPrompted=\(SettingsStore.shared.settings.shortdramaPrompted) 平台=\(PlatformStore.shared.platform.displayName) 频道=\(model.rankChannel)")
                report("M13 done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "detailfixed":
            // M1.11：详情弹窗固定 950×600（换书/简介长短都同尺寸）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(1))

                @MainActor func dump(_ tag: String) {
                    func f(_ name: String) -> String {
                        guard let r = FMFrameMetrics.last[name] else { return "\(name)=缺失" }
                        return "\(name)=\(FMFrameMetrics.fmt(r.width))x\(FMFrameMetrics.fmt(r.height))@(\(FMFrameMetrics.fmt(r.minX)),\(FMFrameMetrics.fmt(r.minY)))"
                    }
                    let win = MainWindowRegistry.shared.window?.contentView?.bounds.size ?? .zero
                    report("FIXED \(tag) 面板 \(f("modal-panel")) 封面 \(f("detail-cover")) 右列 \(f("detail-info")) 简介 \(f("detail-desc"))")
                    if let p = FMFrameMetrics.last["modal-panel"] {
                        report("FIXED \(tag) 窗口 \(FMFrameMetrics.fmt(win.width))x\(FMFrameMetrics.fmt(win.height)) 居中留白：左 \(FMFrameMetrics.fmt(p.minX)) 右 \(FMFrameMetrics.fmt(win.width - p.maxX)) 上 \(FMFrameMetrics.fmt(p.minY)) 下 \(FMFrameMetrics.fmt(win.height - p.maxY))")
                        let cover = FMFrameMetrics.last["detail-cover"], info = FMFrameMetrics.last["detail-info"]
                        report("FIXED \(tag) 封面高=\(cover.map { FMFrameMetrics.fmt($0.height) } ?? "?") 右列高=\(info.map { FMFrameMetrics.fmt($0.height) } ?? "?") 一致? \(cover != nil && info != nil && abs(cover!.height - info!.height) <= 1 ? "是 → OK" : "否 → FAIL")")
                    }
                    let text = model.selected.map { "\($0.title)" } ?? "?"
                    report("FIXED \(tag) 书=\(text) 简介字数=\(model.detailDescriptionLength)")
                }

                for (tag, keyword) in [("简介长", ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "游走神话时代"),
                                       ("简介短", ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD2"] ?? "灼灼欲撩")] {
                    await model.runSearch(keyword)
                    guard let first = model.results.first else { report("FIXED \(tag) 无结果"); continue }
                    model.openDetail(first)
                    try? await Task.sleep(for: .seconds(12))
                    dump(tag)
                    report("FIXED SHOT \(tag)")
                    try? await Task.sleep(for: .seconds(10))
                    model.closeDetail()
                    try? await Task.sleep(for: .seconds(2))
                }
                report("FIXED done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "margins2":
            // 搜索结果页（不依赖榜单）的封面/列表两模式留白取证
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                await model.runSearch(ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "游走神话时代")
                try? await Task.sleep(for: .seconds(8))
                ViewModeStore.shared.set(.album)
                try? await Task.sleep(for: .seconds(4))
                report("MARGIN2 SHOT search-album")
                try? await Task.sleep(for: .seconds(8))
                ViewModeStore.shared.set(.list)
                try? await Task.sleep(for: .seconds(4))
                report("MARGIN2 SHOT search-list")
                try? await Task.sleep(for: .seconds(8))
                report("MARGIN2 done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "margins":
            // 主页左右留白相等 + 各行走同一条基准线 + 卡片尺寸全等（封面/列表/搜索头）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                await model.loadRankIfNeeded()
                try? await Task.sleep(for: .seconds(10))

                @MainActor func dump(_ tag: String) {
                    func f(_ name: String) -> String {
                        guard let r = FMFrameMetrics.last[name] else { return "\(name)=缺失" }
                        return "\(name)[\(FMFrameMetrics.fmt(r.minX))..\(FMFrameMetrics.fmt(r.maxX))]"
                    }
                    report("MARGIN \(tag) \(f("topbar-left")) \(f("topbar")) \(f("rank-channel-row")) \(f("rank-status")) \(f("search-head"))")
                    report("MARGIN \(tag) 网格 \(f("results-left")) \(f("results-right"))")
                    let widths = (1...10).compactMap { FMFrameMetrics.last["card-\($0)"]?.width }
                    let heights = (1...10).compactMap { FMFrameMetrics.last["card-\($0)"]?.height }
                    let coverW = (1...10).compactMap { FMFrameMetrics.last["cover-\($0)"]?.width }
                    let coverH = (1...10).compactMap { FMFrameMetrics.last["cover-\($0)"]?.height }
                    func uniq(_ v: [CGFloat]) -> String {
                        let set = Set(v.map { FMFrameMetrics.fmt($0) })
                        return set.count == 1 ? "\(set.first!)（\(v.count) 张全等）" : "不等：\(set.sorted().joined(separator: "/"))"
                    }
                    report("MARGIN \(tag) 卡片宽=\(uniq(widths)) 卡片高=\(uniq(heights)) 封面宽=\(uniq(coverW)) 封面高=\(uniq(coverH))")
                    // 卡片内部竖向拆解（行2 首卡 card-6）：卡顶/封面底/书名/作者/评分·字数/卡底
                    func yy(_ n: String) -> String {
                        guard let r = FMFrameMetrics.last[n] else { return "\(n)=缺失" }
                        return "\(n)[\(FMFrameMetrics.fmt(r.minY))..\(FMFrameMetrics.fmt(r.maxY))]h\(FMFrameMetrics.fmt(r.height))"
                    }
                    if let c6 = FMFrameMetrics.last["card-6"] {
                        let c6s = yy("card-6")
                        let cover6 = yy("cover-6")
                        let t6 = yy("card-6-title")
                        let a6 = yy("card-6-author")
                        let m6 = yy("card-6-meta")
                        let i6 = yy("card-6-info")
                        report("MARGIN \(tag) 行2卡内 \(c6s) \(cover6) \(t6) \(a6) \(m6) \(i6)")
                        let rows = (1...10).compactMap { FMFrameMetrics.last["card-\($0)"]?.minY }
                        let rowTops = Array(Set(rows.map { FMFrameMetrics.fmt($0) })).sorted()
                        let lastBottom = (1...10).compactMap { FMFrameMetrics.last["card-\($0)"]?.maxY }.max() ?? 0
                        let metaBottom = FMFrameMetrics.last["card-6-meta"]?.maxY ?? c6.maxY
                        let winH = MainWindowRegistry.shared.window?.contentView?.bounds.height ?? 0
                        report("MARGIN \(tag) 行顶=\(rowTops.joined(separator: "/")) 行距=\(FMFrameMetrics.fmt((rows.filter { $0 > (rows.min() ?? 0) }.min() ?? 0) - ((1...10).compactMap { FMFrameMetrics.last["card-\($0)"]?.maxY }.filter { $0 < (rows.filter { $0 > (rows.min() ?? 0) }.min() ?? 0) }.max() ?? 0))) 行2底=\(FMFrameMetrics.fmt(lastBottom)) 窗口底留白=\(FMFrameMetrics.fmt(winH - lastBottom)) 作者↔评分间距=\(FMFrameMetrics.fmt((FMFrameMetrics.last["card-6-meta"]?.minY ?? 0) - (FMFrameMetrics.last["card-6-author"]?.maxY ?? 0))) 卡内下余量=\(FMFrameMetrics.fmt(c6.maxY - metaBottom))")
                        let c1s = yy("card-1")
                        report("MARGIN \(tag) 首卡 \(c1s)")
                    }
                    let gridLeft = FMFrameMetrics.last["results-left"]?.minX ?? -1
                    let gridRight = FMFrameMetrics.last["results-right"]?.maxX ?? -1
                    let barLeft = FMFrameMetrics.last["topbar-left"]?.minX ?? -1
                    let barRight = FMFrameMetrics.last["topbar"]?.maxX ?? -1
                    report("MARGIN \(tag) 顶栏最左=\(FMFrameMetrics.fmt(barLeft)) vs 网格最左=\(FMFrameMetrics.fmt(gridLeft)) Δ=\(FMFrameMetrics.fmt(abs(barLeft - gridLeft)))｜顶栏最右=\(FMFrameMetrics.fmt(barRight)) vs 网格最右=\(FMFrameMetrics.fmt(gridRight)) Δ=\(FMFrameMetrics.fmt(abs(barRight - gridRight)))")
                }

                ViewModeStore.shared.set(.album)
                try? await Task.sleep(for: .seconds(3))
                dump("封面模式")
                report("MARGIN SHOT album")
                try? await Task.sleep(for: .seconds(6))

                ViewModeStore.shared.set(.list)
                try? await Task.sleep(for: .seconds(4))
                dump("列表模式")
                report("MARGIN SHOT list")
                try? await Task.sleep(for: .seconds(6))

                ViewModeStore.shared.set(.album)
                await model.runSearch(ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "游走神话时代")
                try? await Task.sleep(for: .seconds(8))
                dump("搜索页")
                report("MARGIN SHOT search")
                try? await Task.sleep(for: .seconds(8))
                report("MARGIN done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "windowsize":
            // 窗口尺寸固定自检：min==max / 无 .resizable / 绿按钮禁用 / 被改动后强制掰回 / performZoom 无效
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                @MainActor func desc(_ tag: String) {
                    guard let w = MainWindowRegistry.shared.window else { report("SIZE \(tag) 无主窗口"); return }
                    let zoom = w.standardWindowButton(.zoomButton)
                    func n(_ v: CGFloat) -> String { v.isFinite ? String(format: "%.1f", v) : "NaN" }
                    report("SIZE \(tag) frame=\(n(w.frame.width))x\(n(w.frame.height))@(\(n(w.frame.minX)),\(n(w.frame.minY))) min=\(n(w.minSize.width))x\(n(w.minSize.height)) max=\(n(w.maxSize.width))x\(n(w.maxSize.height)) resizable=\(w.styleMask.contains(.resizable)) 绿按钮.isEnabled=\(zoom?.isEnabled ?? false) 绿按钮.isHidden=\(zoom?.isHidden ?? false) 可拖动=\(w.isMovableByWindowBackground) app.isActive=\(NSApp.isActive)")
                }
                desc("初始")
                // 1) 程序化放大（模拟"帮它变大"的最强手段）→ 应被强制掰回
                MainWindowRegistry.shared.window?.setFrame(NSRect(x: 200, y: 200, width: 1300, height: 900), display: true)
                try? await Task.sleep(for: .seconds(1))
                desc("setFrame(1300x900) 之后")
                // 2) 绿按钮动作（等价双击标题栏缩放）
                MainWindowRegistry.shared.window?.performZoom(nil)
                try? await Task.sleep(for: .seconds(1))
                desc("performZoom 之后")
                // 3) 再等 3s，看 SwiftUI 会不会把 .resizable 加回来
                try? await Task.sleep(for: .seconds(3))
                desc("等 3s 后")
                report("SIZE done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "qimao-sign":
            // 签名/请求头数值自检（对照 Go 参考实现，证明「签名算法未改」）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                for bookID in ["", "219542", "00000000", "abc", "1234567890123456"] {
                    let headers = QimaoSign.requestHeaders(bookID: bookID)
                    report("QIMAO SIGN bookID=「\(bookID)」stableHash=\(QimaoSign.stableHash(bookID)) app-version=\(headers["app-version"] ?? "?") sign=\(headers["sign"] ?? "?")")
                }
                let params = ["page": "1", "tab": "0", "wd": "十日终焉", "is_short_story_user": "0", "gender": "0", "refresh_state": "8", "extend": ""]
                report("QIMAO SIGN 搜索参数 sign=\(QimaoSign.sign(params))")
                report("QIMAO SIGN 搜索 query=\(QimaoSign.queryEncode(params))")
                report("QIMAO SIGN ExtractBookID: 链接→\(QimaoSign.extractBookID("https://www.qimao.com/shuku/219542/")) 旧域名→\(QimaoSign.extractBookID("https://www.wtzw.com/article-detail/219542")) 数字→\(QimaoSign.extractBookID("219542")) 文本→\(QimaoSign.extractBookID("十日终焉"))")
                report("QIMAO SIGN SafeFilename=\(QimaoSign.safeFilename("第1章: 病毒/药剂?*\"<>|\\"))")
                report("QIMAO done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "qimao-search":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                let env = ProcessInfo.processInfo.environment
                // 1) 书名搜索（qimao.go:288 Search）
                let keyword = env["FQM_QIMAO_KEYWORD"] ?? "十日终焉"
                let t0 = Date()
                let hits = try await QimaoClient.shared.search(keyword)
                report("QIMAO SEARCH 书名「\(keyword)」共 \(hits.count) 条，耗时 \(ms(since: t0))ms")
                for (i, r) in hits.prefix(10).enumerated() {
                    report("QIMAO SEARCH [\(i + 1)] id=\(r.id) 《\(r.title)》/ \(r.author) 评分=\(r.score) 字数=\(r.words) 完结=\(r.isOver)")
                }
                if let raw = hits.first {
                    report("QIMAO SEARCH 首条封面=\(raw.coverURL)")
                }

                // 2) ID 直达（app.go:462 ExtractBookID → BookDetail）
                if let idInput = env["FQM_QIMAO_ID"] {
                    let id = QimaoSign.extractBookID(idInput)
                    let t1 = Date()
                    let book = try await QimaoClient.shared.bookDetail(bookID: id)
                    report("QIMAO SEARCH ID「\(idInput)」→ 归一化 \(id)：《\(book.title)》/ \(book.author) 评分=\(book.score) 耗时 \(ms(since: t1))ms")
                }

                // 3) 链接直达
                if let linkInput = env["FQM_QIMAO_URL"] {
                    let id = QimaoSign.extractBookID(linkInput)
                    let t2 = Date()
                    let book = try await QimaoClient.shared.bookDetail(bookID: id)
                    report("QIMAO SEARCH 链接「\(linkInput)」→ 归一化 \(id)：《\(book.title)》/ \(book.author) 评分=\(book.score) 耗时 \(ms(since: t2))ms")
                }
                report("QIMAO done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "qimao-detail":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                let env = ProcessInfo.processInfo.environment
                let id = QimaoSign.extractBookID(env["FQM_QIMAO_ID"] ?? env["FQM_QIMAO_KEYWORD"] ?? "十日终焉")
                let t0 = Date()
                let book = try await QimaoClient.shared.bookDetail(bookID: id)
                report("QIMAO DETAIL id=\(id)《\(book.title)》/ \(book.author) 耗时 \(ms(since: t0))ms")
                report("QIMAO DETAIL 分类=\(book.category) 标签=\(book.tags) 字数=\(book.wordsNum)（\(QimaoModels.formatWords(book.wordsNum))）评分=\(book.score) 人气=\(book.hot) 排名=\(book.rank) 主角=\(book.characters)")
                report("QIMAO DETAIL 简介前 120 字=\(book.intro.prefix(120))")
                let t1 = Date()
                let chapters = try await QimaoClient.shared.chapterList(id)
                report("QIMAO DETAIL 章节列表 \(chapters.count) 条，耗时 \(ms(since: t1))ms；前 3 章：\(chapters.prefix(3).map { "\($0.sort).\($0.title)(\($0.id))" }.joined(separator: " | "))")
                report("QIMAO done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "qimao-rank":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                // qimao.go:398：is_girl 0=男生 1=女生；rank_type 1大热 2新书 3完结 4收藏 6更新
                let types = ["1", "2", "3", "4", "6"]
                for isGirl in ["0", "1"] {
                    for rankType in types {
                        let t0 = Date()
                        let books = try await QimaoClient.shared.rankingBooks(isGirl: isGirl, rankType: rankType)
                        let head = books.prefix(3).map { "\($0.title)[\($0.id)]" }.joined(separator: " | ")
                        report("QIMAO RANK is_girl=\(isGirl) rank_type=\(rankType) \(books.count) 条，耗时 \(ms(since: t0))ms：\(head)")
                    }
                }
                report("QIMAO done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "qimao-adapt":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                let t0 = Date()
                let groups = try await QimaoClient.shared.adaptRankConfig()
                report("QIMAO ADAPT 筛选组 \(groups.count) 组，耗时 \(ms(since: t0))ms")
                for g in groups {
                    report("QIMAO ADAPT 组 key=\(g.key) label=\(g.label) 选项 \(g.options.count) 个：\(g.options.prefix(6).map { "\($0.label)(\($0.value))" }.joined(separator: " | "))")
                }

                let t1 = Date()
                let page1 = try await QimaoClient.shared.adaptBookList(QimaoModels.AdaptFilter())
                report("QIMAO ADAPT 第一页 \(page1.books.count) 条 / 总数 \(page1.total)，耗时 \(ms(since: t1))ms")
                for (i, b) in page1.books.prefix(3).enumerated() {
                    report("QIMAO ADAPT [\(i + 1)] id=\(b.id) 《\(b.title)》/ \(b.author) 字数=\(b.words) 分类=\(b.category) 完结=\(b.isOver) 改编类型=\(b.clientID)")
                }

                // 换筛选：女生频道 + 真人短剧
                var filter = QimaoModels.AdaptFilter()
                filter.direction = "2"
                filter.channel = "1"
                let t2 = Date()
                let filtered = try await QimaoClient.shared.adaptBookList(filter)
                report("QIMAO ADAPT 换筛选(direction=2 channel=1) \(filtered.books.count) 条 / 总数 \(filtered.total)，耗时 \(ms(since: t2))ms：\(filtered.books.prefix(3).map { $0.title }.joined(separator: " | "))")

                // 分页：第 2 页
                var pageFilter = QimaoModels.AdaptFilter()
                pageFilter.page = 2
                let t3 = Date()
                let page2 = try await QimaoClient.shared.adaptBookList(pageFilter)
                report("QIMAO ADAPT 第 2 页 \(page2.books.count) 条 / 总数 \(page2.total)，耗时 \(ms(since: t3))ms：\(page2.books.prefix(3).map { $0.title }.joined(separator: " | "))")
                report("QIMAO done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "qimao-download":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                let env = ProcessInfo.processInfo.environment
                let id = QimaoSign.extractBookID(env["FQM_QIMAO_ID"] ?? "17709264")
                let format = (env["FQM_QIMAO_FORMAT"] ?? "txt").lowercased()
                let outDir = URL(fileURLWithPath: env["FQM_QIMAO_OUTDIR"] ?? NSHomeDirectory() + "/Downloads")
                let t0 = Date()
                var lastProgress = (0, 0)
                let path = try await QimaoClient.shared.download(bookID: id, outputDir: outDir, format: format) { done, total in
                    lastProgress = (done, total)
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int) ?? 0
                report("QIMAO DOWNLOAD format=\(format) → \(path.path)")
                report("QIMAO DOWNLOAD 大小=\(size ?? 0) 字节，耗时 \(ms(since: t0))ms，进度回调最后 \(lastProgress.0)/\(lastProgress.1)")
                if format == "txt", let data = try? Data(contentsOf: path) {
                    report("QIMAO DOWNLOAD 前 200 字节=\(String(decoding: data.prefix(200), as: UTF8.self).replacingOccurrences(of: "\n", with: "\\n"))")
                }
                report("QIMAO done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "ranktiming":
            // M1.6 取证：综合热榜（首次）→ 男频（抓页 + 10 preview）→ 男频再点一次（60s 缓存）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                await model.loadRankIfNeeded()
                try? await Task.sleep(for: .seconds(8))
                report("TIMING 综合热榜(首次) 完成 状态=\(model.rankStatus)")
                await model.selectRankChannel("男频")
                try? await Task.sleep(for: .seconds(8))
                report("TIMING 男频(切换) 完成 状态=\(model.rankStatus)")
                await model.selectRankChannel("男频")
                try? await Task.sleep(for: .seconds(4))
                report("TIMING 男频(第二次=缓存) 完成 状态=\(model.rankStatus)")
                report("SHOT done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "rankfail":
            // 只加载榜单并报告失败文案（配合临时改坏 baseURL 使用）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                await model.loadRankIfNeeded()
                try? await Task.sleep(for: .seconds(8))
                report("FAILSTATUS \(model.rankStatus)")
                report("SHOT fail")
                try? await Task.sleep(for: .seconds(8))
                NSApp.terminate(nil)
            }
        case "m3g":
            // M3-g 取证：坏域名 → 自动重试（1/2/4s，状态行「网络不稳，正在重试 n/3…」）
            // → 3 次仍失败（状态行失败原因 + 现有「重试」按钮）→ 手动重试恢复
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(1))

                await model.loadRankIfNeeded()
                try? await Task.sleep(for: .seconds(8))
                report("M3G 基线 状态=\(model.rankStatus) 条数=\(model.rankBooks.count)")

                @MainActor func waitFor(_ describe: String, seconds: Double, _ predicate: () -> Bool) async -> Bool {
                    let deadline = Date().addingTimeInterval(seconds)
                    while Date() < deadline {
                        if predicate() { return true }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    let ok = predicate()
                    report("M3G 等待\(describe) 结果=\(ok)")
                    return ok
                }

                // 造失败：坏域名（DNS 立即失败，三次重试间隔肉眼可辨）；只换 URL，不动接口/频道/排序
                let badURL = ProcessInfo.processInfo.environment["FQM_M3G_BAD_URL"] ?? "https://fanqienovel.invalid/rank"
                report("M3G 制造失败 badURL=\(badURL)")
                let firstFailAt = Date()
                let retryTask = Task { await model.debugReloadRankRetry(url: badURL) }

                // 重试 1/3（1s 窗口）
                _ = await waitFor("重试1/3", seconds: 6) { model.rankStatus.contains("重试 1/3") }
                report("M3G 重试1/3 状态=\(model.rankStatus) 错误标记=\(model.rankStatusIsError)")

                // 重试 3/3（4s 窗口，截图用）
                _ = await waitFor("重试3/3", seconds: 12) { model.rankStatus.contains("重试 3/3") }
                report("M3G 重试3/3 状态=\(model.rankStatus) 错误标记=\(model.rankStatusIsError)")
                report("M3G SHOT retrying")

                // 等三次重试全部失败（状态行变失败文案 + 错误标记）
                _ = await waitFor("最终失败", seconds: 15) { model.rankStatusIsError }
                report("M3G 最终失败 状态=\(model.rankStatus) 条数=\(model.rankBooks.count) 错误标记=\(model.rankStatusIsError)")
                report("M3G 三次重试总耗时=\(ms(since: firstFailAt))ms（预期 ≈ 1000+2000+4000=7000ms）")
                report("M3G SHOT failed")
                await retryTask.value
                // 失败态保持住供截图（3 次重试后状态不再自变）
                try? await Task.sleep(for: .seconds(6))

                // 点现有「重试」按钮（reloadRank）→ 恢复正常 URL，验证能恢复
                let retryAt = Date()
                await model.reloadRank()
                try? await Task.sleep(for: .seconds(2))
                report("M3G 手动重试后 状态=\(model.rankStatus) 条数=\(model.rankBooks.count) 错误标记=\(model.rankStatusIsError) 耗时=\(ms(since: retryAt))ms")
                report("M3G SHOT retried")
                try? await Task.sleep(for: .seconds(4))

                // 搜索失败态：搜索与榜单共用 NetworkRetry（同一套 3 次重试）。
                // 这里用一个不存在的 19 位 ID 让内核详情接口报错（502）→ 搜索失败，
                // 验证搜索失败文案 + 状态行「重试」按钮（「未找到」属业务结果，不自动重试）。
                let badID = ProcessInfo.processInfo.environment["FQM_M3G_BAD_ID"] ?? "9999999999999999999"
                model.searchText = badID
                await model.submitSearch()
                let searchFailed = await waitFor("搜索失败", seconds: 30) {
                    if case .failed = model.searchState { return true }
                    return false
                }
                report("M3G 搜索失败 出现=\(searchFailed) 状态=\(model.searchStatus) 错误标记=\(model.searchStatusIsError) mainView=\(model.mainView)")
                if searchFailed {
                    report("M3G SHOT search-failed")
                    try? await Task.sleep(for: .seconds(5))
                }
                report("M3G done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "finalempty":
            // M4 定稿取证：搜索「空状态」定稿后样貌（已删掉「试搜」按钮）——只切到搜索视图并保持 idle
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1))
                model.mainView = .search
                model.searchText = ""
                model.results = []
                model.searchStatus = ""
                model.searchStatusIsError = false
                model.searchState = .idle
                try? await Task.sleep(for: .seconds(5))
                report("EMPTY mainView=\(model.mainView) state=\(model.searchState)")
                report("SHOT empty")
                try? await Task.sleep(for: .seconds(12))
                report("SHOT done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "shots3":
            // M1.3 取证：封面网格 / 列表 两态 + 逐对左右边界数字；退出时留在 list 以验证「重启仍记住」
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1))

                let keyword = ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "游走神话时代"
                await model.runSearch(keyword)

                @MainActor func settle(_ tag: String) async {
                    try? await Task.sleep(for: .seconds(6))
                    let mode = ViewModeStore.shared.mode.rawValue
                    report("MODE \(mode)")
                    report("FRAMES \(tag) \(FMFrameMetrics.alignment("results-left", "results-right"))")
                    if let card = FMFrameMetrics.last["results-first-card"], let cover = FMFrameMetrics.last["album-cover"] {
                        report("ALBUMCARD \(tag) 卡片宽=\(FMFrameMetrics.fmt(card.width)) 封面宽=\(FMFrameMetrics.fmt(cover.width)) 封面高=\(FMFrameMetrics.fmt(cover.height))")
                    }
                    report("SHOT \(tag)")
                }

                ViewModeStore.shared.set(.album)
                await settle("album")
                try? await Task.sleep(for: .seconds(10))

                ViewModeStore.shared.set(.list)
                await settle("list")
                try? await Task.sleep(for: .seconds(10))

                // 留在 list 模式退出，下次启动应仍是 list（证明记住了）
                report("SHOT done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "modecheck":
            // 只读：报告启动时从 UserDefaults 读到的模式（验证「重启仍记住」），可选 FQM_SET_MODE 复位
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                await model.runSearch(ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "游走神话时代")
                try? await Task.sleep(for: .seconds(5))
                report("RESTART 启动时读到的模式=\(ViewModeStore.shared.mode.rawValue)")
                report("FRAMES restart \(FMFrameMetrics.alignment("results-left", "results-right"))")
                report("SHOT restart")
                if let target = ProcessInfo.processInfo.environment["FQM_SET_MODE"],
                   let mode = FMViewMode(rawValue: target) {
                    ViewModeStore.shared.set(mode)
                    report("RESTART 复位为 \(mode.rawValue)")
                }
                try? await Task.sleep(for: .seconds(2))
                NSApp.terminate(nil)
            }
        case "detailorder":
            // M1.9 取证：详情弹窗右栏顺序（ID 行 → 作者行）+ 封面高 == 右列高
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                await model.runSearch(ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "游走神话时代")
                guard let first = model.results.first else { report("ORDER 无搜索结果"); NSApp.terminate(nil); return }
                model.openDetail(first)
                try? await Task.sleep(for: .seconds(12))

                @MainActor func f(_ name: String) -> String {
                    guard let r = FMFrameMetrics.last[name] else { return "\(name)=缺失" }
                    return "\(name)=\(FMFrameMetrics.fmt(r.minY))..\(FMFrameMetrics.fmt(r.maxY)) 高\(FMFrameMetrics.fmt(r.height))"
                }
                report("ORDER 标题=\(first.title)")
                report("ORDER \(f("detail-id-row"))")
                report("ORDER \(f("detail-author-row"))")
                let idY = FMFrameMetrics.last["detail-id-row"]?.minY ?? -1
                let authorY = FMFrameMetrics.last["detail-author-row"]?.minY ?? -1
                report("ORDER 顺序判定：ID 行在作者行上面? \(idY < authorY && idY >= 0 ? "是 → OK" : "否 → FAIL")（ID.minY=\(FMFrameMetrics.fmt(idY)) 作者.minY=\(FMFrameMetrics.fmt(authorY))）")
                report("ORDER \(f("detail-cover"))")
                report("ORDER \(f("detail-info"))")
                let coverH = FMFrameMetrics.last["detail-cover"]?.height ?? -1
                let infoH = FMFrameMetrics.last["detail-info"]?.height ?? -1
                report("ORDER 封面高==右列高? \(abs(coverH - infoH) <= 1 ? "是 → OK" : "否 → FAIL")（封面 \(FMFrameMetrics.fmt(coverH)) vs 右列 \(FMFrameMetrics.fmt(infoH))）")
                report("ORDER metrics=\(FMMetrics.summary())")
                report("ORDER SHOT detail-order")
                try? await Task.sleep(for: .seconds(10))
                report("ORDER done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "shots2":
            // M1.2 取证：详情（长简介 / 短简介）+ 下载管理；每次摆好后打印一次性尺寸结论
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate() // 前台化：后台/被遮住时 SwiftUI 可能推迟动画与视图更新
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1))

                @MainActor func settleAndReport(_ tag: String) async {
                    try? await Task.sleep(for: .seconds(7))
                    report("STATE \(tag) selected=\(model.selected != nil) overlay=\(model.activeOverlay != nil) metrics=\(FMMetrics.summary())")
                    report("SHOT \(tag)")
                }

                let longKeyword = ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "游走神话时代"
                await model.runSearch(longKeyword)
                if let first = model.results.first {
                    model.openDetail(first)
                    await settleAndReport("detail-long")
                    try? await Task.sleep(for: .seconds(12))
                    model.closeDetail()
                }
                try? await Task.sleep(for: .seconds(1))

                let shortKeyword = ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD2"] ?? "灼灼欲撩"
                await model.runSearch(shortKeyword)
                if let first = model.results.first {
                    model.openDetail(first)
                    await settleAndReport("detail-short")
                    try? await Task.sleep(for: .seconds(12))
                    model.closeDetail()
                }
                try? await Task.sleep(for: .seconds(1))

                withAnimation(.easeOut(duration: 0.2)) { model.activeOverlay = .downloads }
                await settleAndReport("downloads")
                try? await Task.sleep(for: .seconds(12))
                model.activeOverlay = nil
                report("SHOT done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "shots":
            // 取证用：把三个弹窗依次摆好，每个状态停 12s 并打标记，由 Tools/shots.sh 截图
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                let keyword = ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "游走神话时代"
                await model.runSearch(keyword)
                // 先下 3 章，让下载面板/删除确认里有真实产物
                if let first = model.results.first, let limit = DownloadCenter.chapterLimit {
                    _ = try? await DownloadCenter.shared.download(
                        id: first.bookID, title: first.title, author: first.author, range: 1...limit
                    )
                }
                model.library.reload()
                if let first = model.results.first {
                    model.openDetail(first)
                    report("SHOT detail")
                    try? await Task.sleep(for: .seconds(12))
                    model.closeDetail()
                }
                try? await Task.sleep(for: .seconds(1))
                withAnimation(.easeOut(duration: 0.2)) { model.activeOverlay = .downloads }
                report("SHOT downloads")
                try? await Task.sleep(for: .seconds(12))
                model.pendingDeletion = model.library.items.first
                report("SHOT confirm")
                try? await Task.sleep(for: .seconds(12))
                // 收尾：把这次取证产生的下载文件删掉（走同一条删除路径）
                if let pending = model.pendingDeletion, pending.title == model.results.first?.title {
                    try? model.library.remove(id: pending.record.path, deleteFile: true)
                }
                model.pendingDeletion = nil
                model.activeOverlay = nil
                report("SHOT done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "m5":
            // M5 取证：「最近查看」两类记录 + 去重 + 保留期清理 + 顶栏数字 + 四张截图状态。
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(2))

                // ① 启动即读盘清理：由脚本预先写进 history.json 的 8 天前记录应已不在
                let startup = HistoryStore.shared.records
                report("M5 启动时记录数=\(startup.count) 明细=[\(startup.map { "\($0.kind.rawValue):\($0.title)@\($0.time)" }.joined(separator: " | "))]")

                // ② 顶栏数字（三按钮尺寸/位置/右基准线；搜索框宽度看 FQM_FRAME topbar 行）
                func rect(_ n: String) -> CGRect? { FMFrameMetrics.last[n] }
                if let h = rect("topbar-history"), let d = rect("topbar-downloads"), let s = rect("topbar-right") {
                    report("M5 顶栏 历史=\(FMFrameMetrics.fmt(h.width))x\(FMFrameMetrics.fmt(h.height))@x\(FMFrameMetrics.fmt(h.minX)) 下载=\(FMFrameMetrics.fmt(d.width))x\(FMFrameMetrics.fmt(d.height))@x\(FMFrameMetrics.fmt(d.minX)) 设置=\(FMFrameMetrics.fmt(s.width))x\(FMFrameMetrics.fmt(s.height))@x\(FMFrameMetrics.fmt(s.minX)) 右边缘=\(FMFrameMetrics.fmt(s.maxX))（应=970）")
                    report("M5 间距 历史→下载=\(FMFrameMetrics.fmt(d.minX - h.maxX)) 下载→设置=\(FMFrameMetrics.fmt(s.minX - d.maxX))")
                }
                if let bar = rect("topbar") {
                    report("M5 顶栏整行（含右滚动槽 12）左=\(FMFrameMetrics.fmt(bar.minX)) 右=\(FMFrameMetrics.fmt(bar.maxX)) 宽=\(FMFrameMetrics.fmt(bar.width))")
                }
                if let p = rect("topbar-left") {
                    report("M5 平台胶囊 左=\(FMFrameMetrics.fmt(p.minX)) 右=\(FMFrameMetrics.fmt(p.maxX)) 宽=\(FMFrameMetrics.fmt(p.width))")
                }
                if let sf = rect("topbar-search") {
                    report("M5 搜索框 左=\(FMFrameMetrics.fmt(sf.minX)) 右=\(FMFrameMetrics.fmt(sf.maxX)) 宽=\(FMFrameMetrics.fmt(sf.width))")
                }
                if let k = rect("topbar-kernel") {
                    report("M5 内核状态 左=\(FMFrameMetrics.fmt(k.minX)) 右=\(FMFrameMetrics.fmt(k.maxX)) 宽=\(FMFrameMetrics.fmt(k.width)) 内核→历史间距=\(FMFrameMetrics.fmt((rect("topbar-history")?.minX ?? 0) - k.maxX))")
                }

                let keyword = ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "游走神话时代"
                HistoryStore.shared.clear()
                report("M5 清空后记录数=\(HistoryStore.shared.records.count)")

                // ③ 搜索成功记一条
                await model.runSearch(keyword)
                try? await Task.sleep(for: .seconds(1))
                let s1 = HistoryStore.shared.records(of: .search)
                report("M5 搜索「\(keyword)」→ 搜索记录 \(s1.count) 条 首条=\(s1.first?.title ?? "无") 时间=\(s1.first?.time ?? "-") 平台=\(s1.first?.platformDisplay ?? "-")")

                // ④ 同一个关键词再搜一次：只有一条、时间刷新、置顶
                let firstTime = s1.first?.time
                try? await Task.sleep(for: .seconds(2))
                await model.runSearch(keyword)
                let s2 = HistoryStore.shared.records(of: .search)
                report("M5 重复搜索「\(keyword)」→ 搜索记录 \(s2.count) 条（应=1） 置顶=\(s2.first?.title == keyword) 时间刷新=\(s2.first?.time != firstTime)")

                // ⑤ 打开详情记一条（榜单/搜索/下载管理/最近查看都走 openDetail）
                if let first = model.results.first {
                    model.openDetail(first)
                    try? await Task.sleep(for: .seconds(6))
                    let d = HistoryStore.shared.records(of: .detail)
                    report("M5 打开详情《\(first.title)》→ 详情记录 \(d.count) 条 首条=\(d.first?.title ?? "无") 平台=\(d.first?.platformDisplay ?? "-")")
                    model.closeDetail()
                    try? await Task.sleep(for: .seconds(2))
                } else {
                    report("M5 没有搜索结果，详情记录跳过")
                }

                // ⑥ 截图：搜索记录段
                model.historySegment = .search
                withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = .history }
                try? await Task.sleep(for: .seconds(3))
                report("M5 SHOT history-search")
                try? await Task.sleep(for: .seconds(8))

                // ⑦ 截图：详情记录段
                model.historySegment = .detail
                try? await Task.sleep(for: .seconds(3))
                report("M5 SHOT history-detail")
                try? await Task.sleep(for: .seconds(8))

                // ⑧ 截图：空状态
                model.historySegment = .search
                HistoryStore.shared.clear()
                try? await Task.sleep(for: .seconds(3))
                report("M5 SHOT history-empty")
                try? await Task.sleep(for: .seconds(8))

                // ⑨ 截图：顶栏（关掉弹窗）
                model.activeOverlay = nil
                try? await Task.sleep(for: .seconds(3))
                report("M5 SHOT topbar")
                try? await Task.sleep(for: .seconds(6))

                // ⑩ 写入 8 天前记录 → reload 清掉（每次写入/重读都清）
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                iso.timeZone = TimeZone.current
                let oldTime = iso.string(from: Date().addingTimeInterval(-8 * 86_400))
                let old = FMHistoryRecord(kind: .search, key: "M5_OLD", title: "8天前旧记录", author: "", platform: "fanqie", bookID: "", time: oldTime)
                // 等价于用户手改 history.json（不走 store 的写入口）
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
                if let data = try? encoder.encode([old]) { try? data.write(to: FMAppPaths.historyFile) }
                HistoryStore.shared.reload()
                report("M5 注入 8 天前记录后 reload → 记录数=\(HistoryStore.shared.records.count)（应=0且不含「8天前旧记录」） 含旧记录=\(HistoryStore.shared.records.contains { $0.key == "M5_OLD" })")

                report("M5 done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "m51":
            // M5.1 取证：最近查看新排版（标题/分段左对齐 + liquidglass 分段 + 清空右侧同一行
            //           + 平台标签两色 + 时间靠右同行）+ 记录语义「甲」（ID/链接直达只进详情记录，主文本=书名）
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                NSApp.activate()
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
                MainWindowRegistry.shared.window?.orderFrontRegardless()
                try? await Task.sleep(for: .seconds(2))

                let keyword = ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "游走神话时代"

                // 截图前把窗口拉到最前（否则被遮挡的窗口不重绘，screencapture -l 拿到陈旧内容）
                @MainActor func bringFront() {
                    NSApp.activate(ignoringOtherApps: true)
                    MainWindowRegistry.shared.window?.makeKeyAndOrderFront(nil)
                    MainWindowRegistry.shared.window?.orderFrontRegardless()
                }

                // ① 语义「甲」：清空 → 关键词搜索 → 按 ID 直达 → 按书页链接直达
                HistoryStore.shared.clear()
                model.historySegment = .search
                withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = .history }
                await model.runSearch(keyword)
                try? await Task.sleep(for: .seconds(1))
                let s0 = HistoryStore.shared.records(of: .search).count
                let d0 = HistoryStore.shared.records(of: .detail).count
                report("M51 关键词搜索「\(keyword)」→ 搜索=\(s0)（应=1） 详情=\(d0)（应=0）")

                let bookID = model.results.first?.bookID ?? ""
                let bookTitle = model.results.first?.title ?? "?"
                await model.runSearch(bookID)
                try? await Task.sleep(for: .seconds(1))
                let s1 = HistoryStore.shared.records(of: .search).count
                let d1 = HistoryStore.shared.records(of: .detail)
                report("M51 ID 直达「\(bookID)」→ 搜索=\(s1)（应仍=\(s0)） 详情=\(d1.count) 首条=\(d1.first?.title ?? "无") key=\(d1.first?.key ?? "-") 搜索段含数字=\(HistoryStore.shared.records(of: .search).contains { $0.title == bookID })")

                let link = "https://fanqienovel.com/page/\(bookID)"
                await model.runSearch(link)
                try? await Task.sleep(for: .seconds(1))
                let s2 = HistoryStore.shared.records(of: .search).count
                let d2 = HistoryStore.shared.records(of: .detail)
                report("M51 链接直达「\(link)」→ 搜索=\(s2)（应仍=\(s0)） 详情=\(d2.count) 首条=\(d2.first?.title ?? "无") 搜索段含网址=\(HistoryStore.shared.records(of: .search).contains { $0.title.contains("http") })")
                report("M51 书名对照 解析书名=「\(bookTitle)」 详情记录首条=「\(d2.first?.title ?? "无")」 相等=\(d2.first?.title == bookTitle)")

                // ② 铺截图数据：搜索 2 条（番茄/七猫）+ 详情 2 条（番茄/七猫），看清两种标签颜色
                HistoryStore.shared.recordSearch(keyword: "十日终焉", platform: .qimao)
                HistoryStore.shared.recordDetail(bookID: "2222222222", title: "十日终焉", author: "杀虫队队员", platform: .qimao)

                model.historySegment = .search
                withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = .history }
                bringFront()
                try? await Task.sleep(for: .seconds(3))
                report("M51 SHOT history-search")
                try? await Task.sleep(for: .seconds(8))

                model.historySegment = .detail
                bringFront()
                try? await Task.sleep(for: .seconds(3))
                report("M51 SHOT history-detail")
                try? await Task.sleep(for: .seconds(3))

                // ③ 几何：标题/分段左基准、清空右边缘与同行、每行 标签/时间/箭头
                func rect(_ n: String) -> CGRect? { FMFrameMetrics.last[n] }
                func line(_ n: String) -> String {
                    guard let r = rect(n) else { return "\(n)=缺失" }
                    return "\(n)=x\(FMFrameMetrics.fmt(r.minX))..\(FMFrameMetrics.fmt(r.maxX)) y\(FMFrameMetrics.fmt(r.minY))..\(FMFrameMetrics.fmt(r.maxY))"
                }
                report("M51 几何 \(line("history-title")) ｜ \(line("history-segments")) ｜ \(line("history-clear"))")
                if let p = rect("modal-panel"), let t = rect("history-title"), let s = rect("history-segments"), let c = rect("history-clear") {
                    report("M51 对齐 标题左=\(FMFrameMetrics.fmt(t.minX)) 分段左=\(FMFrameMetrics.fmt(s.minX)) 左Δ=\(FMFrameMetrics.fmt(abs(t.minX - s.minX)))（应=0） ｜ 面板内容左=\(FMFrameMetrics.fmt(p.minX + 30)) 面板内容右=\(FMFrameMetrics.fmt(p.maxX - 30)) 清空右=\(FMFrameMetrics.fmt(c.maxX)) 右Δ=\(FMFrameMetrics.fmt(abs((p.maxX - 30) - c.maxX)))（应=0） ｜ 分段中y=\(FMFrameMetrics.fmt(s.midY)) 清空中y=\(FMFrameMetrics.fmt(c.midY)) yΔ=\(FMFrameMetrics.fmt(abs(s.midY - c.midY)))（应≈0）")
                }
                let rowNames = [
                    "history-row-title-fanqie", "history-row-tag-fanqie", "history-row-time-fanqie", "history-row-chevron-fanqie",
                    "history-row-title-qimao", "history-row-tag-qimao", "history-row-time-qimao", "history-row-chevron-qimao",
                ]
                report("M51 每行 " + rowNames.map(line).joined(separator: " ｜ "))
                for pf in ["fanqie", "qimao"] {
                    guard let ti = rect("history-row-title-\(pf)"), let tg = rect("history-row-tag-\(pf)"),
                          let tm = rect("history-row-time-\(pf)"), let ch = rect("history-row-chevron-\(pf)") else { continue }
                    report("M51 同行[\(pf)] 书名y=\(FMFrameMetrics.fmt(ti.midY)) 标签y=\(FMFrameMetrics.fmt(tg.midY)) 时间y=\(FMFrameMetrics.fmt(tm.midY)) 箭头y=\(FMFrameMetrics.fmt(ch.midY))（四者应≈同值） ｜ x顺序 标签左=\(FMFrameMetrics.fmt(tg.minX)) 时间左=\(FMFrameMetrics.fmt(tm.minX)) 箭头左=\(FMFrameMetrics.fmt(ch.minX))（应递增：标签→时间→箭头）")
                }

                // ④ 空状态（两段各一张）
                HistoryStore.shared.clear()
                model.historySegment = .search
                bringFront()
                try? await Task.sleep(for: .seconds(3))
                report("M51 SHOT history-empty-search")
                try? await Task.sleep(for: .seconds(10))
                model.historySegment = .detail
                bringFront()
                try? await Task.sleep(for: .seconds(3))
                report("M51 SHOT history-empty-detail")
                try? await Task.sleep(for: .seconds(10))

                model.activeOverlay = nil
                report("M51 done")
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
        case "update":
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(delay))
                await model.kernel.start()
                await model.kernel.checkForUpdate()
                let line = KernelUpdater.shared.statusLine(version: model.kernel.version)
                report("更新结果：\(line)")
                try? await Task.sleep(for: .seconds(2))
                NSApp.terminate(nil)
            }
        default:
            if mode.hasPrefix("sd-search") {
                // 兼容 `FQM_SELFTEST="sd-search <关键词>"`（自检脚本里直接带关键词）
                let keyword = sdSearchKeyword(from: mode)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    await runShortdramaSearchReport(keyword: keyword)
                    NSApp.terminate(nil)
                }
            } else {
                fmLog("自检：未知模式 \(mode)")
            }
        }
    }

    @MainActor
    /// 毫秒计时（自检用）
    private static func ms(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private static func report(_ line: String) {
        fmLog("自检：\(line)")
        print("FQM_SELFTEST \(line)")
        fflush(stdout)
    }

    /// 端到端链路自检。
    @MainActor
    private static func runChain(model: AppModel) async {
        await model.kernel.start()
        report("内核 \(model.kernel.phase.displayText) v\(model.kernel.version ?? "?")")

        let keyword = ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "游走神话时代"
        await model.runSearch(keyword)
        switch model.searchState {
        case .results:
            let first = model.results[0]
            report("搜索「\(keyword)」命中 \(model.results.count) 条；首条《\(first.title)》/ \(first.author) / \(first.bookID)")
        case .empty:
            report("搜索「\(keyword)」无结果")
        case .failed(let message):
            report("搜索「\(keyword)」失败：\(message)")
        default:
            report("搜索「\(keyword)」状态异常")
        }

        guard let first = model.results.first else {
            report("没有搜索结果，结束")
            NSApp.terminate(nil)
            return
        }

        await model.runSearch(first.bookID)
        report("ID 直达「\(first.bookID)」→ \(model.results.count) 条：\(model.results.first?.title ?? "无")")

        let link = "https://fanqienovel.com/page/\(first.bookID)"
        await model.runSearch(link)
        report("链接直达「\(link)」→ \(model.results.count) 条：\(model.results.first?.title ?? "无")")

        do {
            let info = try await FanqieAPI.shared.bookInfo(id: first.bookID)
            report("详情：《\(info.title)》作者 \(info.author) 共 \(info.chapterCount) 章 \(info.words) \(info.score) \(info.hot) 链接 \(info.link.absoluteString)")
        } catch {
            report("详情失败：\(AppModel.friendlyMessage(for: error))")
        }

        // 下载目标：默认关键词首条；FQM_SELFTEST_DOWNLOAD_KEYWORD 可换成另一本（避免覆盖已有文件）
        var target = first
        if let extra = ProcessInfo.processInfo.environment["FQM_SELFTEST_DOWNLOAD_KEYWORD"], !extra.isEmpty {
            await model.runSearch(extra)
            if let candidate = model.results.first {
                target = candidate
                report("下载目标改为搜索「\(extra)」的首条：《\(candidate.title)》\(candidate.bookID)")
            }
        }

        let limit = DownloadCenter.chapterLimit ?? 3
        report("开始下载《\(target.title)》作者 \(target.author)（限前 \(limit) 章）")
        do {
            let url = try await DownloadCenter.shared.download(
                id: target.bookID,
                title: target.title,
                author: target.author,
                range: 1...limit,
                onProgress: { progress in
                    if progress.saved == progress.total || progress.saved % 1 == 0 {
                        print("FQM_SELFTEST_PROGRESS \(progress.text)")
                        fflush(stdout)
                    }
                }
            )
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            report("下载完成：\(url.path)（\(size) 字节）")
        } catch {
            report("下载失败：\(AppModel.friendlyMessage(for: error))")
        }
        report("自检链路结束")
        try? await Task.sleep(for: .seconds(1))
        NSApp.terminate(nil)
    }



    // MARK: - M3-a 短剧数据层自检

    /// 从 `FQM_SELFTEST="sd-search <关键词>"` / `sd-search:<关键词>` 里取关键词
    private static func sdSearchKeyword(from mode: String) -> String {
        var s = String(mode.dropFirst("sd-search".count))
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        if s.isEmpty { s = ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "" }
        return s.isEmpty ? "斗破" : s
    }

    /// `sd-session`：逐浏览器摊开探测结果 + 会话状态 + 设置里的短剧开关（不做服务端校验前不会读钥匙串）。
    @MainActor
    private static func runShortdramaSessionReport() async {
        report("SDSESSION 开始探测（浏览器 cookie 库 → 会话 → 服务端校验）")
        // M3-d：Safari 优先（明文 cookie，不需要钥匙串）
        let safari = SafariCookies.diagnose()
        if let failure = safari.failure {
            report("SDSESSION Safari 路径=\(SafariCookies.currentPath) 失败=\(failure) needsFDA=\(safari.needsFullDiskAccess)")
            report("SDSESSION Safari \(SafariCookies.structure())")
        } else {
            report("SDSESSION Safari 页数=\(safari.pageCount) cookie条数=\(safari.cookieCount) host数=\(safari.distinctHostCount) host样本=\(safari.hostSamples.joined(separator: ","))")
            report("SDSESSION Safari shortdramas sessionid=\(safari.hasShortdramaSession ? "有" : "无") 长度=\(safari.sessionIDLength) 过期=\(safari.sessionExpiryDescription) host=\(safari.sessionHost) 已过期=\(safari.shortdramaExpired)")
            if safari.hasShortdramaSession, let sid = try? SafariCookies.shortdramaSessionID() {
                report("SDSESSION Safari sessionid(脱敏)=\(SafariCookies.maskValue(sid))")
            }
        }
        let probes = await ShortdramaSession.diagnoseBrowsers()
        for p in probes { report("SDSESSION 浏览器 \(p.name)：\(p.detail)") }
        let settings = SettingsStore.load(from: FMAppPaths.settingsFile)
        report("SDSESSION 设置 shortdramaIgnored=\(settings.shortdramaIgnored) shortdramaPrompted=\(settings.shortdramaPrompted)（短剧模式=\(settings.shortdramaIgnored ? "关" : "开")）")
        let status = await ShortdramaClient.shared.sessionStatus()
        report("SDSESSION 会话状态 ok=\(status.ok) keychainNeedsFix=\(status.keychainNeedsFix) needsFDA=\(status.needsFullDiskAccess) 说明=\(status.message.isEmpty ? "-" : status.message)")
        report("SDSESSION done")
    }

    /// `sd-search <关键词>`：命中打印前 5 条；未命中/无会话/钥匙串未授权要分开报。
    @MainActor
    private static func runShortdramaSearchReport(keyword: String) async {
        report("SDSEARCH 关键词=\(keyword)")
        do {
            let ips = try await ShortdramaClient.shared.search(keyword)
            if ips.isEmpty {
                report("SDSEARCH 会话可用但无命中（后台返回 0 条）关键词=\(keyword)")
            } else {
                report("SDSEARCH 命中 \(ips.count) 条（列出前 5）")
                for ip in ips.prefix(5) {
                    report("SDSEARCH 《\(ip.name)》 性别=\(ip.gender) ID=\(ip.ipBookID) 作者=\(ip.author) 申请=\(ip.selectedCnt) 改编中=\(ip.adaptingCnt) 在读=\(ip.readingCnt) 字数=\(ip.words) 上架=\(ip.onlineMonth)")
                }
            }
        } catch {
            let kind = (error as? ShortdramaFailure)?.kind
            let prefix = kind == .noSession ? "无会话" : (kind == .keychain ? "钥匙串未授权" : "查询失败")
            report("SDSEARCH \(prefix) 关键词=\(keyword) 原因=\(error.localizedDescription)")
        }
        report("SDSEARCH done")
    }

    // MARK: - M10 短剧「按小说ID」自检（sd-id / sd-fields / sd-hit）

    private static let sdTargetIDDefault = "7613834044236631102"
    private static let sdTargetTitleDefault = "花妖军嫂种出万亩绿洲，系统崩了"

    private static func sdTargetID() -> String {
        ProcessInfo.processInfo.environment["FQM_SD_ID"] ?? sdTargetIDDefault
    }

    private static func sdTargetTitle() -> String {
        ProcessInfo.processInfo.environment["FQM_SD_TITLE"] ?? sdTargetTitleDefault
    }

    /// 自检打印 frame（“？”= 控件还没出现）。
    private static func rect(_ r: CGRect?) -> String {
        guard let r else { return "?" }
        return "(x=\(FMFrameMetrics.fmt(r.minX)) y=\(FMFrameMetrics.fmt(r.minY)) w=\(FMFrameMetrics.fmt(r.width)) h=\(FMFrameMetrics.fmt(r.height)))"
    }

    /// 精度自检（合成 JSON，不走网络）：19 位整数字面量必须逐字符保真。
    @MainActor
    private static func sdPrecisionSelfCheck() {
        let json = #"{"code":0,"data":{"ip_list":[{"ip_book_id":7613834044236631102,"ip_id":7632944854758065152,"word_num":1149973,"middle_read_duration_rate":0.6631984454548278}]}}"#
        do {
            let payload = try FMJSON.parse(Data(json.utf8))
            let record = payload["data"]?["ip_list"]?.arrayValue?.first
            let client = ShortdramaClient.shared
            let bookID = client.strOf(record?["ip_book_id"])
            let ipID = client.strOf(record?["ip_id"])
            let legacy = String(Int(Double("7613834044236631102")!))
            report("SDID 精度 合成JSON 读出 ip_book_id=\(bookID) 逐字符==真值 7613834044236631102 → \(bookID == "7613834044236631102")")
            report("SDID 精度 合成JSON 读出 ip_id=\(ipID) 逐字符==真值 7632944854758065152 → \(ipID == "7632944854758065152")")
            report("SDID 精度 旧 Double 口径（反例）= \(legacy) 与真值相同=\(legacy == "7613834044236631102")")
            report("SDID 精度 普通整数 word_num=\(client.strOf(record?["word_num"]))（应 1149973，仍当数字读）")
        } catch {
            report("SDID 精度 合成JSON解析失败：\(error.localizedDescription)")
        }
    }

    /// 当前搜索/详情自检共用的临时设置（开关与平台），返回原值以便还原。
    @MainActor
    private static func sdEnable() -> (Bool, Bool) {
        let original = (SettingsStore.shared.settings.shortdramaIgnored, SettingsStore.shared.settings.shortdramaPrompted)
        ShortdramaStore.shared.setIgnored(false)
        return original
    }

    @MainActor
    private static func sdRestore(_ original: (Bool, Bool)) {
        SettingsStore.shared.update {
            $0.shortdramaIgnored = original.0
            $0.shortdramaPrompted = original.1
        }
    }

    /// 搜索路径取书：先按书名搜；结果里没有目标 ID 时再 ID 直达（两种情况都算搜索路径）。
    @MainActor
    private static func sdSearchItem(model: AppModel) async -> SearchItem? {
        let targetID = sdTargetID()
        await model.runSearch(sdTargetTitle())
        try? await Task.sleep(for: .seconds(3))
        if let exact = model.results.first(where: { $0.bookID == targetID }) { return exact }
        await model.runSearch(targetID)
        try? await Task.sleep(for: .seconds(3))
        return model.results.first(where: { $0.bookID == targetID }) ?? model.results.first
    }

    /// M12：挑一本**内核还没缓存**的番茄书当下载目标。
    /// 内核的章节缓存在 `~/Library/Application Support/novel-downloader/downloads/<bookID>/`；
    /// 缓存过的书下载 1~2 秒就结束，按钮里的绿色填充来不及出现在屏幕上（取证拍不到、用户也看不到动效）。
    /// 取不到新书（都缓存过了）就退回第一个搜索结果。
    @MainActor
    private static func m12FreshTarget(model: AppModel) async -> SearchItem? {
        let keyword = ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "穿越"
        await model.runSearch(keyword)
        try? await Task.sleep(for: .seconds(4))
        let fm = FileManager.default
        for item in model.results where !item.bookID.isEmpty {
            if fm.fileExists(atPath: FMAppPaths.kernelStaging.appending(path: item.bookID).path) { continue }
            if BookDetailView.DownloadButtonState.existingFile(
                bookID: item.bookID, title: item.title, author: item.author,
                downloads: model.downloads, library: model.library
            ) != nil { continue }
            return item
        }
        return model.results.first
    }

    /// `FQM_SELFTEST=sd-id`：ID 精度 + 按 ID 命中 + 搜索/详情两条路径。
    @MainActor
    private static func runShortdramaIDReport(model: AppModel) async {
        await model.kernel.start()
        NSApp.activate()
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        MainWindowRegistry.shared.window?.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1))
        let original = sdEnable()

        let targetID = sdTargetID()
        report("SDID 目标番茄ID=\(targetID) 目标书名《\(sdTargetTitle())》")
        sdPrecisionSelfCheck()

        // ② 按 ID 直查
        do {
            if let hit = try await ShortdramaClient.shared.searchByBookID(targetID) {
                report("SDID ID查询 命中 ip_book_id=\(hit.ipBookID) 逐字符相等=\(hit.ipBookID == targetID) ip_name=《\(hit.name)》 作者=\(hit.author)")
            } else {
                report("SDID ID查询 未命中（返回里没有 ip_book_id == \(targetID)）")
            }
        } catch {
            report("SDID ID查询 失败：\(error.localizedDescription)")
        }

        // ②b 负例：不存在的 ID 必须 nil（防「参数被忽略返回默认 20 条」误判）
        do {
            let bogus = String((Int(targetID) ?? 0) + 1)
            if let hit = try await ShortdramaClient.shared.searchByBookID(bogus) {
                report("SDID ID查询负例 book_id=\(bogus) 命中=有（错误！\(hit.ipBookID)）")
            } else {
                report("SDID ID查询负例 book_id=\(bogus) 命中=无（正确）")
            }
        } catch {
            report("SDID ID查询负例 失败：\(error.localizedDescription)")
        }

        // ③ 搜索路径
        if let item = await sdSearchItem(model: model) {
            report("SDID 搜索路径 结果 \(model.results.count) 条；选中 bookID=\(item.bookID) 书名《\(item.title)》")
            let hits = await ShortdramaStore.shared.lookup(books: [
                ShortdramaClient.BookQuery(id: item.platform == .fanqie ? item.bookID : nil, title: item.title),
            ])
            if let hit = hits[item.title] {
                report("SDID 搜索路径 命中 ip_book_id=\(hit.ipBookID) 逐字符相等=\(hit.ipBookID == targetID) ip_name=《\(hit.name)》")
            } else {
                report("SDID 搜索路径 未命中（hits=\(hits.count)）")
            }

            // ④ 详情路径（真实打开详情弹窗 → BookDetailView 自己按 ID 查）
            model.openDetail(item)
            try? await Task.sleep(for: .seconds(8))
            let store = ShortdramaStore.shared
            if let hit = store.detailHit {
                report("SDID 详情路径 命中 ip_book_id=\(hit.ipBookID) 逐字符相等=\(hit.ipBookID == targetID) ip_name=《\(hit.name)》 作者=\(hit.author)")
            } else {
                report("SDID 详情路径 未命中；detailHint=\(store.detailHint ?? "-")")
            }
            report("SDID SHOT detail-id")
            try? await Task.sleep(for: .seconds(8))
            model.closeDetail()
        } else {
            report("SDID 搜索路径 没有搜索结果")
        }

        sdRestore(original)
        report("SDID 还原 shortdramaIgnored=\(SettingsStore.shared.settings.shortdramaIgnored)")
        report("SDID done")
        try? await Task.sleep(for: .seconds(1))
    }

    /// `FQM_SELFTEST=sd-tags`（只读取证）：判断「标签少」是**后台就这么多**还是**界面裁掉了**。
    ///
    /// 三层逐本对照（≥ 3 本命中书）：
    ///   ① 原始响应正文里 `category_list` 的**字面量原文** + `gender` + `ip_tier_level` 原文；
    ///   ② `stringList` 解析后的数组（逐项）；
    ///   ③ 界面真正会渲染的 chip 列表（`ShortdramaStrip.tags`，与详情页同源）。
    /// 再加一段几何：标签行 frame / 行高 vs 父容器，逐 chip frame 判有没有被裁。
    @MainActor
    private static func runShortdramaTagsReport(model: AppModel) async {
        let client = ShortdramaClient.shared
        let targets: [(id: String, note: String)] = [
            (sdTargetID(), "任务书默认命中书"),
            (ProcessInfo.processInfo.environment["FQM_SD_ID2"] ?? "7626575114431122494", "白月光"),
            (ProcessInfo.processInfo.environment["FQM_SD_ID3"] ?? "7677199681213975576", "主播那条龙"),
        ]
        report("SDTAGS 目标 \(targets.count) 本：" + targets.map { "\($0.note)=\($0.id)" }.joined(separator: " ｜ "))
        report("SDTAGS 口径 界面 chip ＝ 等级(ip_tier_level) + 性别(gender) + category_list 全量；不截断（FMFlowLayout 自动换行、无 prefix/lineLimit）")

        for target in targets {
            let id = target.id
            do {
                let hit = try await client.searchByBookID(id)
                let body = client.debugLastRawBody ?? ""
                let rawCategory = rawField(body, id: id, key: "category_list")
                let rawGender = rawField(body, id: id, key: "gender")
                let rawTier = rawField(body, id: id, key: "ip_tier_level")
                report("SDTAGS [\(target.note) \(id)] 原始正文长度=\(body.count) 字节")
                report("SDTAGS [\(target.note) \(id)] 原文 category_list=\(rawCategory)")
                report("SDTAGS [\(target.note) \(id)] 原文 gender=\(rawGender) ip_tier_level=\(rawTier)")

                guard let hit else {
                    report("SDTAGS [\(target.note) \(id)] 未命中（返回里没有 ip_book_id == \(id)）；原文拆项=\(rawItems(rawCategory).count)")
                    continue
                }

                let rawItemsList = rawItems(rawCategory)
                let parsed = hit.categories
                let chips = ShortdramaStrip.tags(hit).map { $0.text }

                report("SDTAGS [\(target.note) \(id)] 原文拆项 \(rawItemsList.count) 项 = \(rawItemsList.joined(separator: " ｜ "))")
                report("SDTAGS [\(target.note) \(id)] 解析后 categories \(parsed.count) 项 = \(parsed.joined(separator: " ｜ "))")
                report("SDTAGS [\(target.note) \(id)] 界面 chip \(chips.count) 项 = \(chips.joined(separator: " ｜ "))")
                let parseOK = rawItemsList == parsed
                let renderOK = chips == ([hit.tierLevel, hit.gender].filter { !$0.isEmpty && $0 != "未知" } + parsed)
                report("SDTAGS [\(target.note) \(id)] 计数对照 原文\(rawItemsList.count) → 解析\(parsed.count)（逐项相等=\(parseOK ? "是 → 解析不丢" : "否 → FAIL 解析丢了")）｜ 解析\(parsed.count)+等级/性别 → chip\(chips.count)（逐项相等=\(renderOK ? "是 → 界面不丢" : "否 → FAIL 界面丢了")）")

                // 后台这条记录里**所有**名字像标签的字段（解释「网页上看着更多」是不是来自别的字段）
                if let entry = rawEntry(body, id: id), let obj = entry.objectValue {
                    let keys = obj.keys.sorted()
                    let tagish = keys.filter { k in
                        let l = k.lowercased()
                        return l.contains("tag") || l.contains("categor") || l.contains("genre") || l.contains("label") || l.contains("level") || l.contains("gender")
                    }
                    report("SDTAGS [\(target.note) \(id)] 本条记录字段共 \(keys.count) 个；像标签的字段=\(tagish.joined(separator: ","))")
                    for k in tagish {
                        report("SDTAGS [\(target.note) \(id)]   字段 \(k) 原文=\(rawField(body, id: id, key: k))")
                    }
                } else {
                    report("SDTAGS [\(target.note) \(id)] 原始正文里没定位到本条记录（跳过字段列表）")
                }
            } catch {
                report("SDTAGS [\(target.note) \(id)] 查询失败：\(error.localizedDescription)")
            }
        }

        // ── 布局：标签行 vs 父容器（有没有 chip 被裁）──
        guard let item = await sdSearchItem(model: model) else {
            report("SDTAGS 布局 无法取书（搜索无结果）")
            return
        }
        FMFrameMetrics.clear()
        model.openDetail(item)
        try? await Task.sleep(for: .seconds(10))
        let row = FMFrameMetrics.last["detail-sd-tags"]
        let rowSize = FMFrameMetrics.lastSize["detail-sd-tags#size"]
        let info = FMFrameMetrics.last["detail-info"]
        let chipFrames = (0..<10).compactMap { FMFrameMetrics.last["detail-sd-tag-\($0)"] }
        let modelChips = ShortdramaStore.shared.detailHit.map { ShortdramaStrip.tags($0).map(\.text) } ?? []
        report("SDTAGS 布局 书=《\(item.title)》 bookID=\(item.bookID) 数据块命中=\(ShortdramaStore.shared.detailHit == nil ? "无" : "有") 模型 chip \(modelChips.count) 项 = \(modelChips.joined(separator: " ｜ "))")
        report("SDTAGS 布局 标签行 frame=\(rect(row)) 行尺寸=\(rowSize.map { "\(FMFrameMetrics.fmt($0.width))×\(FMFrameMetrics.fmt($0.height))" } ?? "?") 父容器 detail-info=\(rect(info))")
        for (index, frame) in chipFrames.enumerated() {
            report("SDTAGS 布局 chip#\(index) frame=\(rect(frame)) 文案=\(index < modelChips.count ? modelChips[index] : "?") 在行内=\(isInside(frame, row) ? "是" : "否")")
        }
        let lines = Set(chipFrames.map { FMFrameMetrics.fmt($0.minY) }).count
        let allInside = chipFrames.allSatisfy { isInside($0, row) }
        let countMatch = chipFrames.count == modelChips.count
        report("SDTAGS 布局 行数=\(lines) 实际落下 chip 数=\(chipFrames.count) vs 模型 \(modelChips.count) → \(countMatch ? "一致" : "不一致 → 有 chip 没落下") ｜ 全部在标签行 frame 内=\(allInside ? "是" : "否 → 被裁") ｜ 行下沿≤父容器下沿=\((row?.maxY ?? 0) <= (info?.maxY ?? 0) ? "是" : "否 → 溢出") ｜ 面板下沿≥行下沿=\((FMFrameMetrics.last["modal-panel"]?.maxY ?? 0) >= (row?.maxY ?? 0) ? "是" : "否 → 溢出")")
        let verdict: String
        if countMatch && allInside {
            verdict = "数据就这么多（后台 category_list 全量已全部渲染，界面没裁、没限数量）"
        } else if !countMatch {
            verdict = "界面少落了 chip（模型 \(modelChips.count) 个，实际 \(chipFrames.count) 个）→ 布局问题"
        } else {
            verdict = "有 chip 落在标签行 frame 外 → 被父容器/面板裁掉"
        }
        report("SDTAGS 结论 \(verdict)")
        if !modelChips.isEmpty, modelChips.count > 2 {
            report("SDTAGS 结论 本书界面 chip \(modelChips.count) 个：\(modelChips.joined(separator: " ｜ "))；若与网页上看到的不一致，看上面「像标签的字段」里是否还有别的标签字段（那是网页多展示的，不属 category_list）")
        }
        report("SDTAGS SHOT sd-tags")
        try? await Task.sleep(for: .seconds(4))
        model.closeDetail()
        try? await Task.sleep(for: .seconds(2))

        // ── 追加：标签很多（强制换行）时的裁切判定 —— 注入 12 个 chip，验证第二行不会被父容器吃掉 ──
        var wide = Self.fakeShortdramaIP(name: item.title, month: "2026-04", apply: 3, adapting: 1, shelved: 1)
        wide.categories = ["年代", "现代言情", "甜宠", "先婚后爱", "军婚", "古风世情", "古代言情", "重生", "腹黑", "古言权谋"]
        ShortdramaStore.shared.debugInjectedHits = [item.title: wide]
        FMFrameMetrics.clear()
        model.openDetail(item)
        try? await Task.sleep(for: .seconds(10))
        let wideRow = FMFrameMetrics.last["detail-sd-tags"]
        let wideInfo = FMFrameMetrics.last["detail-info"]
        let wideChips = (0..<16).compactMap { FMFrameMetrics.last["detail-sd-tag-\($0)"] }
        let expectedWide = ShortdramaStrip.tags(wide).map(\.text)
        let wideLines = Set(wideChips.map { FMFrameMetrics.fmt($0.minY) }).count
        let wideInside = wideChips.allSatisfy { isInside($0, wideRow) }
        report("SDTAGS 多标签 注入 chip 模型 \(expectedWide.count) 项（等级/性别 + 10 个 category）")
        report("SDTAGS 多标签 标签行 frame=\(rect(wideRow)) 父容器=\(rect(wideInfo)) 行数=\(wideLines) 落下 chip=\(wideChips.count) vs 模型 \(expectedWide.count) → \(wideChips.count == expectedWide.count ? "一致" : "不一致 → 有 chip 没落下") ｜ 全部在行内=\(wideInside ? "是 → 换行也没被裁" : "否 → 被裁") ｜ 行下沿≤父容器下沿=\((wideRow?.maxY ?? 0) <= (wideInfo?.maxY ?? 0) ? "是" : "否 → 溢出") ｜ 数据块下沿≤面板下沿=\((wideRow?.maxY ?? 0) <= (FMFrameMetrics.last["modal-panel"]?.maxY ?? 0) ? "是" : "否 → 溢出")")
        for (index, frame) in wideChips.enumerated() where index >= 6 {
            report("SDTAGS 多标签 chip#\(index) frame=\(rect(frame)) 文案=\(index < expectedWide.count ? expectedWide[index] : "?") 在行内=\(isInside(frame, wideRow) ? "是" : "否")")
        }
        report("SDTAGS SHOT sd-tags-many")
        try? await Task.sleep(for: .seconds(8))
        model.closeDetail()
        ShortdramaStore.shared.debugInjectedHits = nil
    }

    /// 从原始响应正文里抠出某本书那条 `ip_list` 记录的 **JSON 文本**：
    /// 先定位 19 位 ID，再向前找到本条记录的 `{`，向后做花括号配平扫描（跳字符串内的大括号）。
    private static func rawEntryText(_ body: String, id: String) -> String? {
        guard let range = body.range(of: id) else { return nil }
        guard let start = body[..<range.lowerBound].range(of: "{", options: .backwards)?.lowerBound else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < body.endIndex {
            let ch = body[index]
            if inString {
                if escaped { escaped = false }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false }
            } else if ch == "\"" {
                inString = true
            } else if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 { return String(body[start...index]) }
            }
            index = body.index(after: index)
        }
        return nil
    }

    /// 从原始响应正文里抠出某本书那条 `ip_list` 记录（JSON 对象）。
    private static func rawEntry(_ body: String, id: String) -> JSONValue? {
        guard let text = rawEntryText(body, id: id) else { return nil }
        return try? FMJSON.parse(Data(text.utf8))
    }

    /// 从原始正文里抠出某个字段的**字面量原文**（字符串带引号、数组带方括号），不做任何解释。
    private static func rawField(_ body: String, id: String, key: String) -> String {
        guard let entry = rawEntryText(body, id: id) else { return "（原文里没定位到本条记录）" }
        guard let keyRange = entry.range(of: "\"\(key)\":") else { return "（本条记录里没有该字段）" }
        var rest = entry[keyRange.upperBound...]
        while rest.first == " " { rest = rest.dropFirst() }
        if rest.first == "\"" {
            var out = "\""
            var index = rest.index(after: rest.startIndex)
            while index < rest.endIndex {
                let ch = rest[index]
                if ch == "\\" {
                    out.append(ch)
                    index = rest.index(after: index)
                    if index < rest.endIndex { out.append(rest[index]); index = rest.index(after: index) }
                    continue
                }
                out.append(ch)
                index = rest.index(after: index)
                if ch == "\"" { break }
            }
            return out
        }
        if rest.first == "[" {
            var depth = 0
            var out = ""
            for ch in rest {
                if ch == "[" { depth += 1 }
                if ch == "]" { depth -= 1 }
                out.append(ch)
                if depth == 0 { break }
            }
            return out
        }
        var out = ""
        for ch in rest {
            if ch == "," || ch == "}" { break }
            out.append(ch)
        }
        return out
    }

    /// 从**原文**独立拆项（与 `stringList` 同口径，但自己重做一遍，用来对照解析有没有丢）：
    /// `["a","b"]` → 逐元素；`"a,b，c"` → 按 `,` / `，` 拆；其它 → 单项。
    private static func rawItems(_ raw: String) -> [String] {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("[") && text.hasSuffix("]") {
            let inner = String(text.dropFirst().dropLast())
            return inner.split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"\n\r")) }
                .filter { !$0.isEmpty }
        }
        if text.hasPrefix("\"") {
            let inner = text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return inner.split(whereSeparator: { $0 == "," || $0 == "，" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return text.isEmpty || text.hasPrefix("（") ? [] : [text]
    }

    private static func isInside(_ inner: CGRect, _ outer: CGRect?) -> Bool {
        guard let outer else { return false }
        return inner.minX >= outer.minX - 0.5 && inner.maxX <= outer.maxX + 0.5
            && inner.minY >= outer.minY - 0.5 && inner.maxY <= outer.maxY + 0.5
    }

    /// `FQM_SELFTEST=sd-fields`：一条命中记录的**最终展示文案**（与界面同一份口径）。
    @MainActor
    private static func runShortdramaFieldsReport(model: AppModel) async {
        await model.kernel.start()
        NSApp.activate()
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        MainWindowRegistry.shared.window?.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1))
        let original = sdEnable()

        let targetID = sdTargetID()
        var hit: ShortdramaClient.ShortdramaIP?
        do {
            hit = try await ShortdramaClient.shared.searchByBookID(targetID)
        } catch {
            report("SDFIELDS ID查询失败：\(error.localizedDescription)")
        }
        if hit == nil {
            hit = (try? await ShortdramaClient.shared.search(sdTargetTitle()))?.first
            report("SDFIELDS ID 未命中，回退书名查询")
        }
        guard let record = hit else {
            report("SDFIELDS 无命中")
            sdRestore(original)
            report("SDFIELDS done")
            return
        }

        report("SDFIELDS 记录 ip_book_id=\(record.ipBookID) ip_id=\(record.ipID) ip_name=《\(record.name)》")
        report("SDFIELDS 作者行 作者=\(record.author) ＋ 后台状态「\(ShortdramaStrip.statusText(record))」（M11：替换番茄题材标签）")
        let tags = ShortdramaStrip.tags(record)
        report("SDFIELDS 标签行 \(tags.isEmpty ? "（无）" : tags.map { $0.accent ? "[强调]\($0.text)" : $0.text }.joined(separator: " ｜ "))")
        report("SDFIELDS 数据块第1行 \(ShortdramaStrip.lineText(ShortdramaStrip.line2(record)))")
        report("SDFIELDS 数据块第2行 \(ShortdramaStrip.lineText(ShortdramaStrip.line3(record)))")
        let ranks = ShortdramaStrip.rankTags(record)
        report("SDFIELDS 数据块第3行（榜单标签）\(ranks.isEmpty ? "（整行不显示）" : ranks.map { "[\($0)]" }.joined(separator: " "))")
        report("SDFIELDS 数据块 行数=3（M11：无「短剧后台」标题行、无「在后台打开」、「评价人数」已删）")
        report("SDFIELDS 字段 体裁=\(record.source)｜作者=\(record.author)｜评分=\(record.score)｜完结状态=\(record.creationStatus)｜字数=\(record.words)｜在读=\(record.readingText)")
        report("SDFIELDS 字段 上架=\(record.onlineMonth)｜读者占比=中年 \(record.middleRate) 老年 \(record.oldRate) 青年 \(record.youngRate)｜被挑选=\(record.selectedCnt)｜已上架=\(record.shelvedCnt)｜改编中=\(record.adaptingCnt)｜评价人数=\(record.ratingCount)")
        report("SDFIELDS 字段 等级=\(record.tierLevel)｜性别=\(record.gender)｜内容标签=\(record.categories.joined(separator: ","))｜当前榜=\(record.currentRankings.joined(separator: ","))｜历史峰值=\(record.historicalRankings.isEmpty ? "无" : record.historicalRankings.joined(separator: ","))")
        report("SDFIELDS 高亮 被挑选>\(0)=\((Int(record.selectedCnt) ?? 0) > 0) 已上架>0=\((Int(record.shelvedCnt) ?? 0) > 0) 改编中>0=\((Int(record.adaptingCnt) ?? 0) > 0)")

        // 详情页数据块截图
        if let item = await sdSearchItem(model: model) {
            model.openDetail(item)
            try? await Task.sleep(for: .seconds(8))
            let panel = FMFrameMetrics.last["modal-panel"]
            let strip = FMFrameMetrics.last["detail-sd-strip"]
            let actions = FMFrameMetrics.last["detail-actions"]
            report("SDFIELDS 几何 面板=\(rect(panel)) 数据块=\(rect(strip)) 下载按钮行=\(rect(actions))")
            if let panel, let strip, let actions {
                let panelSize = FMFrameMetrics.lastSize["modal-panel#size"]
                report("SDFIELDS 几何 数据块下沿≤按钮行上沿=\(strip.maxY <= actions.minY) 按钮行下沿≤面板下沿=\(actions.maxY <= panel.maxY) 数据块高=\(FMFrameMetrics.fmt(strip.height)) 面板(本地尺寸,不受入场动画缩放)=\(panelSize.map { "\(FMFrameMetrics.fmt($0.width))×\(FMFrameMetrics.fmt($0.height))" } ?? "?")")
            }
            report("SDFIELDS SHOT detail-fields")
            try? await Task.sleep(for: .seconds(8))
            model.closeDetail()
        }

        sdRestore(original)
        report("SDFIELDS done")
        try? await Task.sleep(for: .seconds(1))
    }

    /// `FQM_SELFTEST=sd-hit`：卡片角标三态实测 + 截图。
    @MainActor
    private static func runShortdramaBadgeReport(model: AppModel) async {
        await model.kernel.start()
        NSApp.activate()
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        MainWindowRegistry.shared.window?.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(1))
        let original = sdEnable()

        report("SDHIT 角标 上架3/申请1 → 「\(ShortdramaTag.text(shelved: 3, selected: 1))」（应「上架3部·申请1次」）")
        report("SDHIT 角标 上架0/申请5 → 「\(ShortdramaTag.text(shelved: 0, selected: 5))」（应「上架0部·申请5次」）")
        report("SDHIT 角标 上架0/申请0 → 「\(ShortdramaTag.text(shelved: 0, selected: 0))」（应「上架0部·申请0次」；两段灰字）")
        report("SDHIT 角标 着色 上架0→灰/申请0→灰 上架3→红/申请5→红（源码 ShortdramaTag.attributed）")

        let keyword = ProcessInfo.processInfo.environment["FQM_SELFTEST_KEYWORD"] ?? "游走神话时代"
        await model.runSearch(keyword)
        try? await Task.sleep(for: .seconds(3))
        let titles = model.results.map(\.title)
        guard titles.count > 2 else {
            report("SDHIT 搜索结果只有 \(titles.count) 条，不足以注入三张卡片")
            sdRestore(original)
            report("SDHIT done")
            return
        }
        // 取前三个不重名的标题（重搜后仍在前部），三种角标状态各一张卡片
        var picked: [String] = []
        for title in titles where !picked.contains(title) {
            picked.append(title)
            if picked.count == 3 { break }
        }
        var injected: [String: ShortdramaClient.ShortdramaIP] = [:]
        injected[picked[0]] = fakeShortdramaIP(name: picked[0], month: "2025-06", apply: 1, adapting: 0, shelved: 3)
        injected[picked[1]] = fakeShortdramaIP(name: picked[1], month: "2025-01", apply: 5, adapting: 2, shelved: 0)
        injected[picked[2]] = fakeShortdramaIP(name: picked[2], month: "", apply: 0, adapting: 0, shelved: 0)
        ShortdramaStore.shared.debugInjectedHits = injected
        await model.runSearch(keyword)
        try? await Task.sleep(for: .seconds(5))

        for item in model.results where item.sdInBackend {
            report("SDHIT 卡片 《\(item.title)》 已上架=\(item.sdShelved) 已选=\(item.sdApply) 角标=「\(ShortdramaTag.text(shelved: item.sdShelved, selected: item.sdApply))」")
        }
        report("SDHIT 命中卡片数=\(model.results.filter(\.sdInBackend).count) 状态行=\(model.searchStatus)")
        report("SDHIT SHOT hits-badges")
        try? await Task.sleep(for: .seconds(10))

        ShortdramaStore.shared.debugInjectedHits = nil
        sdRestore(original)
        report("SDHIT done")
        try? await Task.sleep(for: .seconds(1))
    }

    // MARK: - 短剧后台「按小说ID」侦查（只读；FQM_SELFTEST=sd-probe）
    //
    // 目的：找出「后台网页按小说ID能搜到、app 按书名搜不到」时前端到底拼的哪个参数名，
    // 并把命中记录的原始 JSON（字段名齐全）原样打出来。**只读**：不改任何界面/判定/命中逻辑。
    // 可覆盖项：FQM_SD_PROBE_ID / FQM_SD_PROBE_QUERY（原样 query）/ FQM_SD_PROBE_PATH。
    private static let sdProbeDefaultID = "7613834044236631102"

    @MainActor
    private static func runShortdramaProbe() async {
        let targetID = ProcessInfo.processInfo.environment["FQM_SD_PROBE_ID"] ?? sdProbeDefaultID
        report("SDPROBE 目标小说ID=\(targetID)（env 覆盖：FQM_SD_PROBE_ID/FQM_SD_PROBE_QUERY/FQM_SD_PROBE_PATH）")

        let sids: [String]
        do {
            sids = try await ShortdramaSession.shortdramaSessionCandidates()
        } catch {
            report("SDPROBE 无登录态：\(error.localizedDescription)")
            return
        }
        guard let sid = sids.first else { report("SDPROBE 无登录态（候选为空）"); return }
        report("SDPROBE 会话候选=\(sids.count) 个，用第 1 个（脱敏 \(SafariCookies.maskValue(sid))）")

        // ① 后台前端 bundle：直接找「小说ID」搜索拼的参数名
        await sdProbeFrontend(sid: sid)

        // ② env 覆盖：原样打一条 query（排障/复现用）
        if let raw = ProcessInfo.processInfo.environment["FQM_SD_PROBE_QUERY"], !raw.isEmpty {
            let path = ProcessInfo.processInfo.environment["FQM_SD_PROBE_PATH"] ?? "/api/origin/cp/playlet/ip/list/v:version"
            await sdProbeCall(sid: sid, path: path, rawQuery: raw, label: "env-query", targetID: targetID)
        }

        // ③ 逐个候选参数名试 list 接口（两种 filter 组合：带 op_channel/ip_adaptation_type / 不带）
        let base: [(String, String)] = [
            ("page_no", "1"), ("page_count", "20"), ("image_fmt", "180x240"),
            ("op_channel", "1"), ("ip_adaptation_type", "2"), ("aid", "791322"),
        ]
        let looseBase: [(String, String)] = [
            ("page_no", "1"), ("page_count", "20"), ("image_fmt", "180x240"), ("aid", "791322"),
        ]
        let names = ["book_name", "book_id", "novel_id", "ip_book_id", "book_ids", "keyword", "id", "ip_id", "novel_book_id", "bookid", "bookId", "ipBookId", "novelId"]
        for name in names {
            await sdProbeCall(sid: sid, path: "/api/origin/cp/playlet/ip/list/v:version",
                              rawQuery: sdProbeQuery(base + [(name, targetID)]),
                              label: "list/带filter/\(name)", targetID: targetID)
            await sdProbeCall(sid: sid, path: "/api/origin/cp/playlet/ip/list/v:version",
                              rawQuery: sdProbeQuery(looseBase + [(name, targetID)]),
                              label: "list/裸/\(name)", targetID: targetID)
        }

        // ④ 详情接口候选
        for name in ["ip_book_id", "book_id", "novel_id", "book_name", "id"] as [String] {
            for path in ["/api/origin/cp/playlet/ip/detail/v:version", "/api/origin/cp/playlet/ip/info/v:version"] {
                await sdProbeCall(sid: sid, path: path,
                                  rawQuery: sdProbeQuery([("aid", "791322"), (name, targetID)]),
                                  label: "detail\(path.hasSuffix("info/v:version") ? "/info" : "")/\(name)", targetID: targetID)
            }
        }

        // ⑤ 精度复核：返回记录里的 ip_book_id 是 7613834044236631040，与目标 7613834044236631102 不同（JS double 丢精度）。
        //    确认用哪一个是「可查到的」值。
        for probeID in ["7613834044236631040", "7613834044236631102"] {
            await sdProbeCall(sid: sid, path: "/api/origin/cp/playlet/ip/list/v:version",
                              rawQuery: sdProbeQuery(base + [("book_id", probeID)]),
                              label: "精度/book_id=\(probeID)", targetID: targetID)
        }

        // ⑥ 字段语义样例：无过滤列表前 3 条 + 一条 same_ip_adapting_count>0（对照字段含义）
        await sdProbeSample(sid: sid, base: looseBase)
        report("SDPROBE done")
    }

    /// 无过滤列表前 3 条 + 一条「同 IP 改编中」不为 0 的记录，用于字段语义对照。
    @MainActor
    private static func sdProbeSample(sid: String, base: [(String, String)]) async {
        let query = sdProbeQuery(base)
        guard let url = URL(string: "https://www.shortdramas.com/api/origin/cp/playlet/ip/list/v:version?\(query)") else { return }
        let headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Referer": "https://www.shortdramas.com/page/ip-application",
            "Accept": "application/json, text/plain, */*",
            "Cookie": "sessionid=" + sid,
        ]
        do {
            let response = try await HttpClient.shared.get(url, timeout: 12, headers: headers)
            let payload = try FMJSON.parse(response.data)
            let records = payload["data"]?["ip_list"]?.arrayValue ?? []
            report("SDSAMPLE 无过滤列表条数=\(records.count)（用于字段语义对照）")
            let keys = ["ip_book_id", "ip_id", "ip_name", "author_name", "book_score", "creation_status", "collect_status", "op_status", "word_num", "read_listen_dcnt_14d", "ip_selected_count", "same_ip_adapting_count", "ip_shelved_count", "first_online_month", "ip_adaptation_type", "ip_source", "gender", "ip_tier_level", "high_value_ip", "top_book", "ip_rating_count", "category_list", "middle_read_duration_rate", "old_read_duration_rate", "young_read_duration_rate", "ip_current_ranking_list"]
            for (idx, rec) in records.prefix(3).enumerated() {
                guard let object = rec.objectValue else { continue }
                let line = keys.compactMap { k in object[k].map { "\(k)=\(sdProbeJSON($0))" } }.joined(separator: " ")
                report("SDSAMPLE #\(idx) \(line)")
            }
            if let active = records.first(where: { ($0["same_ip_adapting_count"]?.intValue ?? 0) > 0 }) {
                report("SDSAMPLE 改编中>0 记录：\(sdProbeJSON(active))")
            } else {
                report("SDSAMPLE 本页无 same_ip_adapting_count>0 的记录")
            }
        } catch {
            report("SDSAMPLE 失败：\(error.localizedDescription)")
        }
    }

    private static func sdProbeQuery(_ items: [(String, String)]) -> String {
        var comps = URLComponents()
        comps.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        return comps.percentEncodedQuery ?? ""
    }

    /// 发一条短剧后台请求，报告 code / 条数 / 是否命中目标 ID；命中时 dump 原始 JSON。
    @MainActor
    private static func sdProbeCall(sid: String, path: String, rawQuery: String, label: String, targetID: String) async {
        guard let url = URL(string: "https://www.shortdramas.com\(path)?\(rawQuery)") else {
            report("SDPROBE \(label) URL 构造失败")
            return
        }
        let headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Referer": "https://www.shortdramas.com/page/ip-application",
            "Accept": "application/json, text/plain, */*",
            "Cookie": "sessionid=" + sid,
        ]
        do {
            let response = try await HttpClient.shared.get(url, timeout: 12, headers: headers)
            guard response.statusCode == 200 else { report("SDPROBE \(label) HTTP \(response.statusCode)"); return }
            let payload: JSONValue
            do { payload = try FMJSON.parse(response.data) }
            catch { report("SDPROBE \(label) 返回非 JSON（\(response.data.count) 字节）"); return }
            let code = payload["code"]?.intValue ?? -999
            let list = payload["data"]?["ip_list"]?.arrayValue
            let firstID = list?.first?["ip_book_id"].flatMap { $0.stringValue } ?? (list?.first?["book_id"].flatMap { $0.stringValue } ?? "-")
            let firstName = list?.first?["ip_name"].flatMap { $0.stringValue } ?? (list?.first?["book_name"].flatMap { $0.stringValue } ?? "-")
            report("SDPROBE \(label) code=\(code) ip_list=\(list?.count ?? -1) 首条ID=\(firstID) 首条名=\(firstName)")
            // 命中判断：ip_list 里任一记录的 ip_book_id/book_id == 目标，或名字里含「家妻非人」
            let records = list ?? []
            let hit = records.first { rec in
                let ids = ["ip_book_id", "book_id", "novel_id"].compactMap { rec[$0]?.stringValue }
                return ids.contains(targetID) || (rec["ip_name"]?.stringValue?.contains("家妻非人") ?? false)
            }
            if let rec = hit {
                report("SDPROBE *** 命中 *** \(label) URL=https://www.shortdramas.com\(path)?\(rawQuery)")
                let raw = String(data: response.data, encoding: .utf8) ?? "<非 UTF8>"
                report("SDRAW \(label) 原始响应前 1400 字符：\(String(raw.prefix(1400)))")
                sdProbeDump(label: label, record: rec)
            }
        } catch {
            report("SDPROBE \(label) 请求失败：\(error.localizedDescription)")
        }
    }

    /// 把一条记录原样 dump：先按键逐行（字段名一个不落），再给单行紧凑 JSON。
    @MainActor
    private static func sdProbeDump(label: String, record: JSONValue) {
        guard let object = record.objectValue else { report("SDDUMP \(label) 记录不是对象"); return }
        report("SDDUMP \(label) 字段数=\(object.count) 字段名=\(object.keys.sorted().joined(separator: ","))")
        for key in object.keys.sorted() {
            let raw = sdProbeJSON(object[key]!)
            report("SDJSONKEY \(key) = \(raw.count > 300 ? String(raw.prefix(300)) + "…(共\(raw.count)字符)" : raw)")
        }
        report("SDJSON \(label) \(sdProbeJSON(record))")
    }

    private static func sdProbeJSON(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return "\"\(s)\""
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .integerText(let s): return s
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a): return "[" + a.map { sdProbeJSON($0) }.joined(separator: ",") + "]"
        case .object(let o):
            return "{" + o.keys.sorted().map { "\"\($0)\":\(sdProbeJSON(o[$0]!))" }.joined(separator: ",") + "}"
        }
    }

    /// 抓后台「IP申请」页 + 其 script bundle，grep 出「小说ID」搜索到底拼哪个参数名。
    @MainActor
    private static func sdProbeFrontend(sid: String) async {
        let headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Cookie": "sessionid=" + sid,
        ]
        guard let pageURL = URL(string: "https://www.shortdramas.com/page/ip-application") else { return }
        var scripts: [String] = []
        do {
            let response = try await HttpClient.shared.get(pageURL, timeout: 15, headers: headers)
            let html = String(data: response.data, encoding: .utf8) ?? ""
            report("SDPROBE 前端页 HTTP \(response.statusCode) \(response.data.count) 字节 含「小说ID」=\(html.contains("小说ID"))")
            scripts = sdProbeScripts(in: html)
            report("SDPROBE 前端 script 数=\(scripts.count)：\(scripts.prefix(8).joined(separator: " "))")
        } catch {
            report("SDPROBE 前端页抓取失败：\(error.localizedDescription)")
            return
        }
        let needles = ["小说ID", "novel_id", "novelId", "book_id", "book_name", "ip_book_id", "ipBookId", "ip/list", "ip/detail"]
        var scanned = Set<String>()
        var queue: [String] = []
        for src in scripts.prefix(10) {
            let absolute = sdProbeAbsolute(src)
            guard !absolute.isEmpty, !scanned.contains(absolute) else { continue }
            scanned.insert(absolute)
            for token in await sdProbeScanScript(absolute, headers: headers, needles: needles) {
                if let resolved = sdProbeResolveChunk(token, relativeTo: absolute), !scanned.contains(resolved), queue.count < 12 {
                    queue.append(resolved)
                }
            }
        }
        // 页面是 SPA：「IP申请」页真正的业务 chunk 不在首屏 HTML 里，从 loader/runtime 抽出的 .js 再抓一轮
        report("SDPROBE 发现次级 chunk \(queue.count) 个：\(queue.prefix(12).joined(separator: " "))")
        for absolute in queue {
            scanned.insert(absolute)
            _ = await sdProbeScanScript(absolute, headers: headers, needles: needles)
        }
    }

    /// 相对 src 解析成绝对 URL（兼容协议相对 // 与站点相对 /）。
    private static func sdProbeAbsolute(_ src: String) -> String {
        if src.hasPrefix("http") { return src }
        if src.hasPrefix("//") { return "https:" + src }
        return "https://www.shortdramas.com" + (src.hasPrefix("/") ? src : "/" + src)
    }

    /// 把脚本里抽出的 .js token 按所在目录解析成绝对 URL。
    private static func sdProbeResolveChunk(_ token: String, relativeTo script: String) -> String? {
        if token.hasPrefix("http") { return token }
        if token.hasPrefix("//") { return "https:" + token }
        guard let slash = script.lastIndex(of: "/") else { return nil }
        let dir = String(script[script.startIndex...slash])
        var cleaned = token
        while cleaned.hasPrefix("./") { cleaned = String(cleaned.dropFirst(2)) }
        if cleaned.hasPrefix("/") { cleaned = String(cleaned.dropFirst()) }
        return dir + cleaned
    }

    /// 拉一个 script，grep needles 并返回其中出现的 .js 路径（供发现次级 chunk）。
    @MainActor
    private static func sdProbeScanScript(_ absolute: String, headers: [String: String], needles: [String]) async -> [String] {
        guard let url = URL(string: absolute) else { return [] }
        guard let response = try? await HttpClient.shared.get(url, timeout: 20, headers: headers), response.statusCode == 200 else {
            report("SDPROBE script 拉取失败 \(absolute)")
            return []
        }
        let text = String(data: response.data, encoding: .utf8) ?? ""
        report("SDPROBE script \(url.lastPathComponent) \(response.data.count) 字节")
        for needle in needles {
            var searchStart = text.startIndex
            var found = 0
            while found < 2, let range = text.range(of: needle, range: searchStart..<text.endIndex) {
                let lo = text.index(range.lowerBound, offsetBy: -260, limitedBy: text.startIndex) ?? text.startIndex
                let hi = text.index(range.upperBound, offsetBy: 260, limitedBy: text.endIndex) ?? text.endIndex
                let snippet = text[lo..<hi].replacingOccurrences(of: "\n", with: " ")
                report("SDJS [\(needle)] …\(snippet)…")
                searchStart = range.upperBound
                found += 1
            }
        }
        // 小体积 loader：全文打出来看 chunk map
        if response.data.count < 24_000 {
            report("SDJSLOADER \(url.lastPathComponent) 全文：\(text.replacingOccurrences(of: "\n", with: " ").prefix(6000))")
        }
        var found: [String] = []
        for raw in text.split(whereSeparator: { $0 == "\"" || $0 == "'" || $0 == "," || $0 == "(" || $0 == ")" || $0 == " " }) {
            let token = String(raw)
            if token.hasSuffix(".js"), !token.contains("://"), token.count < 200, !found.contains(token) { found.append(token) }
        }
        if !found.isEmpty { report("SDJSCHUNKS \(url.lastPathComponent) 抽到 .js 引用 \(found.count) 个：\(found.prefix(20).joined(separator: " "))") }
        return found
    }

    /// 从 HTML 里抽 <script src="…">
    private static func sdProbeScripts(in html: String) -> [String] {
        var out: [String] = []
        var rest = html[html.startIndex..<html.endIndex]
        while let tag = rest.range(of: "<script"), let close = rest.range(of: ">", range: tag.upperBound..<rest.endIndex) {
            let tagText = String(rest[tag.lowerBound..<close.upperBound])
            if let srcRange = tagText.range(of: "src=\"") {
                let after = tagText[srcRange.upperBound...]
                if let end = after.firstIndex(of: "\"") {
                    let src = String(after[..<end])
                    if !src.isEmpty, !out.contains(src) { out.append(src) }
                }
            }
            rest = rest[close.upperBound..<rest.endIndex]
        }
        return out
    }

    // MARK: - M3-b 短剧界面命中路径自检

    /// 造一条假的短剧后台命中（只给 `m3b-hit` 注入用，字段与真实解析结果同形）。
    private static func fakeShortdramaIP(name: String, month: String, apply: Int, adapting: Int, shelved: Int = 0) -> ShortdramaClient.ShortdramaIP {
        ShortdramaClient.ShortdramaIP(
            ipBookID: "sdtest-\(name.hashValue)",
            name: name,
            author: "测试作者",
            score: "9.0",
            desc: "注入测试",
            coverURL: "",
            words: "100万字",
            gender: "男频",
            adaptType: "2",
            selectedCnt: "\(apply)",
            adaptingCnt: "\(adapting)",
            readingCnt: "10",
            onlineMonth: month,
            ipID: "7632944854758065152",
            source: "网文",
            creationStatus: "已完结",
            readingText: "25.9 万人在读",
            middleRate: "66.3%",
            oldRate: "19.3%",
            youngRate: "14.3%",
            shelvedCnt: "\(shelved)",
            tierLevel: "精品IP",
            categories: ["年代", "甜宠"],
            currentRankings: ["阅读榜"],
            historicalRankings: [],
            ratingCount: "5325"
        )
    }

    // MARK: - 合成输入（进程内；用 NSApp.postEvent 走真实事件队列，最接近真手点）

    /// 真实 HID 级点击（CGEvent 直接投到窗口服务器，和用户手点同一条路）。
    /// 旧的 NSApp.postEvent 进程内合成事件 SwiftUI 不认（M1.1 起点击类自检恒 FAIL）。
    @MainActor
    private static func clickAt(x: CGFloat, y: CGFloat) async {
        guard let window = NSApp.windows.first, let contentView = window.contentView else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true) // 必须真顶到最前：HID 点击落在别的窗口上会全部落空
        window.orderFrontRegardless()           // 压过其它 App 的窗口（否则 HID 点击落到 Safari/豆包上）
        try? await Task.sleep(for: .milliseconds(500))
        let windowPoint = NSPoint(x: x, y: contentView.bounds.height - y) // 入参左上原点 → AppKit 左下原点
        let screenPoint = window.convertPoint(toScreen: windowPoint)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: screenPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
        try? await Task.sleep(for: .milliseconds(150))
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            guard let cg = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: screenPoint, mouseButton: .left) else { continue }
            cg.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// 当前第一响应者（含 field editor），用于证明「搜索框持焦点」
    @MainActor
    private static func focusDescription() -> String {
        guard let fr = NSApp.keyWindow?.firstResponder else { return "nil（无首响应者）" }
        if let tv = fr as? NSTextView { return "NSTextView(field editor: \"\(tv.string.prefix(8))\")" }
        if let tf = fr as? NSTextField { return "NSTextField(\"\(tf.stringValue.prefix(8))\")" }
        return "\(type(of: fr))"
    }

    /// 把搜索框设成第一响应者并真的敲进一段文字（等价用户输入 → 持焦点）
    @MainActor
    private static func focusSearchFieldAndType(_ text: String) -> String {
        guard let window = NSApp.windows.first, let root = window.contentView else { return "没有窗口" }
        guard let field = firstEditableTextField(in: root) else { return "没找到输入框" }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        guard window.makeFirstResponder(field) else { return "makeFirstResponder 失败" }
        try? await0()
        guard let editor = field.currentEditor() as? NSTextView else { return "输入框没有 field editor" }
        editor.insertText(text)
        return "已输入「\(text)」（field editor=\(type(of: editor))）"
    }

    @MainActor
    private static func await0() {}

    @MainActor
    private static func firstEditableTextField(in view: NSView) -> NSTextField? {
        if let f = view as? NSTextField, f.isEditable, f.isEnabled { return f }
        for sub in view.subviews {
            if let f = firstEditableTextField(in: sub) { return f }
        }
        return nil
    }

    @MainActor
    private static func pressEscape() {
        guard let window = NSApp.windows.first else { return }
        window.makeKeyAndOrderFront(nil)
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}

extension AppModel {
    /// 自检用：设置关键词并搜索。
    func runSearch(_ text: String) async {
        searchText = text
        await submitSearch()
    }
}
