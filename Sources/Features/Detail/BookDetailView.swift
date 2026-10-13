import AppKit
import SwiftUI

/// 书籍详情弹窗 —— 1:1 复刻旧版 Wails 的 `#modal-backdrop` + `.modal` + `.modal-body`
/// （index.html 128-178 / style.css 588-760），并按 M1.2 任务书改成**按内容定尺寸**：
///
///   · 面板高度 = 标题行 + 内容区高度 + 上下 padding（没有 min-height / 不撑窗口）
///   · 内容区高度 = 右列信息（ID 行→作者行→统计 chip→简介块→下载按钮行）的自然高度 H
///   · 封面高 = H，宽 = clamp(H×0.75, 230…380)，两者底边严格对齐（红框下沿）
///   · 标题行 / 作者行在内容区上方（旧版也是这个顺序），关闭按钮固定在面板右上
struct BookDetailView: View {
    @EnvironmentObject private var model: AppModel
    let item: SearchItem

    @State private var info: BookInfo?
    @State private var loadError: String?
    @State private var loading = false
    @State private var infoHeight: CGFloat = 0
    @State private var descTextHeight: CGFloat = 0
    @StateObject private var shortdrama = ShortdramaStore.shared
    @State private var showKeychainSheet = false
    /// M11：下载进度与按钮状态要随 `DownloadCenter` 的发布刷新
    /// （`AppModel.downloads` 只是持有引用，视图必须自己订阅这个 ObservableObject）。
    @ObservedObject private var downloads = DownloadCenter.shared
    /// M12：产物是否还在磁盘上要随 `LibraryStore` 刷新（外部删/移文件 → 按钮回「下载」态）。
    @ObservedObject private var library = LibraryStore.shared

    /// M1.11：详情弹窗**固定尺寸**，与下载管理共用 `FMTheme.modalWidth/modalHeight`（改一处两个一起变）

    /// 简介块内边距（上下各 14）
    private static let descPadding: CGFloat = 28
    private static let coverMinWidth: CGFloat = 230
    private static let coverMaxWidth: CGFloat = 380

    var body: some View {
        FMModalPanel(width: FMTheme.modalWidth, fixedHeight: FMTheme.modalHeight, minHeight: 0) {
            model.closeDetail()
        } content: {
            Group {
                if let info {
                    modalBody(info)
                } else if loading {
                    placeholder {
                        ProgressView()
                        Text("正在加载详情…").font(FMTheme.Font.body).foregroundStyle(FMTheme.textSecondary)
                    }
                } else {
                    placeholder {
                        Text("加载失败").font(FMTheme.Font.title).foregroundStyle(FMTheme.text)
                        Text(loadError ?? "内核正在启动，请稍候")
                            .font(FMTheme.Font.body)
                            .foregroundStyle(FMTheme.textSecondary)
                        Button("重试") { Task { await load() } }.fmButton(.primary)
                    }
                }
            }
        }
        .task(id: item.id) {
            // M12：每次进入详情先核对下载记录的内存快照（文件是否还在由 `DownloadButtonState` 实时看磁盘）
            library.reload()
            await load()
            // M3-b：番茄详情自动查短剧后台，在简介与下载按钮之间显示 IP 数据（旧版 main.js:719）
            if item.platform == .fanqie {
                await shortdrama.loadDetail(bookID: item.bookID, title: item.title)
            }
        }
        .onDisappear { shortdrama.clearDetail() }
        .sheet(isPresented: $showKeychainSheet) {
            ShortdramaKeychainSheet(onAuthorized: {
                Task { await shortdrama.loadDetail(bookID: item.bookID, title: item.title) }
            })
        }
    }

    // MARK: - 标题行 / 作者行（红框上方）+ 内容区（红框内）

    private func modalBody(_ info: BookInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow(info)

            // M1.9：作者行不再贴在标题下，按用户要求挪到右列「ID 行」下面（见 infoColumn）
            // M1.11：内容区吃掉标题行之外的全部高度（固定面板）→ 右列底边贴面板底、
            // 封面高 = 这一块的高度，简介块在中间把剩余空间占满。
            HStack(alignment: .top, spacing: 30) {
                cover(info)
                infoColumn(info)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .fmDebugFrame("detail-info") // 取证：右列 frame（高应等于封面高）
                    .fmMeasure(FMInfoHeightKey.self)
            }
            .padding(.top, 10)
            .frame(maxHeight: .infinity, alignment: .top)
            .onPreferenceChange(FMInfoHeightKey.self) { height in
                infoHeight = height
                FMMetrics.report("info", height)
            }
        }
        .padding(34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// .m-title-row: h2 22/700 + 平台 chip
    private func titleRow(_ info: BookInfo) -> some View {
        HStack(spacing: 10) {
            Text(info.title)
                .font(FMTheme.Font.detailTitle)
                .foregroundStyle(FMTheme.text)
                .lineLimit(2)
            FMChip(text: info.platform.displayName) // M2-b fix1：平台 chip 跟书来源（番茄/七猫）
            Spacer(minLength: 0)
        }
        .padding(.trailing, 46) // 让开右上 ✕
    }

    /// 作者行 + 后台状态（M11 按用户批注：番茄题材标签**被后台状态替换**）：
    /// `作者: 玫瑰不予你   已完结 · 上架 2026-04`。
    /// 短剧模式关闭 / 未命中 / 后台字段为空时，回退显示番茄自己的题材标签（原样）。
    private func metaRow(_ info: BookInfo) -> some View {
        let status = shortdrama.detailHit.map { ShortdramaStrip.statusText($0) } ?? ""
        let trailing = status.isEmpty ? info.category : status
        return VStack(alignment: .leading, spacing: 0) {
            if !info.formerTitle.isEmpty {
                Text("曾用名: \(info.formerTitle)")
                    .font(FMTheme.Font.meta)
                    .foregroundStyle(FMTheme.textSecondary)
                    .opacity(0.8)
                    .padding(.top, 2)
            }
            HStack(spacing: 12) {
                Text("作者: \(info.author)")
                if !trailing.isEmpty { Text(trailing) }
            }
            .font(FMTheme.Font.bodySmall)
            .foregroundStyle(FMTheme.textSecondary)
            .padding(.top, 8)
        }
    }

    /// M11：后台标签胶囊行（`精品IP` 强调色 + 性别 + `category_list`）——
    /// 原来在后台数据块里，按用户批注**上移到作者行下面**（番茄题材标签的位置）。
    /// 视觉与番茄那排统计 chip 同款（`FMChip(stat: true)`）。
    @ViewBuilder
    private func shortdramaTagRow() -> some View {
        if let hit = shortdrama.detailHit {
            let tags = ShortdramaStrip.tags(hit)
            if !tags.isEmpty {
                FMFlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                        FMChip(text: tag.text, tone: tag.accent ? .accent : .plain, stat: true)
                            .fmDebugFrame("detail-sd-tag-\(index)") // 只读取证：逐 chip frame（判有没有被裁）
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
                .fmDebugFrame("detail-sd-tags")
            }
        }
    }

    /// .cover：高 = 右列信息高 H；宽 = clamp(H×0.75, 230…380)；底边与信息列对齐
    private func cover(_ info: BookInfo) -> some View {
        let height = max(infoHeight, 1)
        let width = min(Self.coverMaxWidth, max(Self.coverMinWidth, height * 0.75))
        return CoverImage(url: info.coverURL, cornerRadius: 14, mode: .fit)
            .frame(width: width, height: height)
            .fmDebugFrame("detail-cover") // M1.9 取证：封面 frame
            .shadow(color: FMTheme.shadowMd.color, radius: FMTheme.shadowMd.radius, y: FMTheme.shadowMd.y)
            .onAppear { FMMetrics.report("cover", height) }
            .onChange(of: height) { _, newValue in FMMetrics.report("cover", newValue) }
    }

    /// .m-info：ID 行 → 作者行 → 统计 chip → 简介块 → 下载按钮行（+ 下载结果行），高度即 H
    private func infoColumn(_ info: BookInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // .m-id-row { gap:8; font-size:12.5; monospace }
            HStack(spacing: 8) {
                Text("ID: \(info.bookID)")
                    .font(FMTheme.Font.metaMono)
                    .foregroundStyle(FMTheme.textSecondary)
                    .textSelection(.enabled)
                Button("复制") {
                    model.copyToPasteboard(info.bookID)
                    model.showToast("已复制小说 ID: \(info.bookID)")
                }
                .fmButton(.ghost, size: .small)
                Button("复制链接") {
                    model.copyToPasteboard(info.link.absoluteString)
                    model.showToast("已复制书籍链接")
                }
                .fmButton(.ghost, size: .small)
                Spacer(minLength: 0)
            }
            .fmDebugFrame("detail-id-row") // M1.9 取证：ID 行

            // M1.9：作者行（作者 + 题材/后台状态，含曾用名）——用户在详情弹窗上明确要求放在 ID 行下面
            // M11：紧跟其后是后台标签胶囊行（精品IP/性别/内容标签），再往下面是番茄那排统计 chip
            metaRow(info)
                .fmDebugFrame("detail-author-row") // M1.9 取证：作者行（应在 ID 行下面）
            shortdramaTagRow()

            // .m-stats { gap:6; margin:4px 0 12px }
            HStack(spacing: 6) {
                if !info.score.isEmpty { FMChip(text: info.score, stat: true) }
                if !info.words.isEmpty { FMChip(text: info.words, stat: true) }
                if !info.hot.isEmpty { FMChip(text: info.hot, stat: true) }
                if info.chapterCount > 0 { FMChip(text: "共 \(info.chapterCount) 章", stat: true) }
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
            .padding(.bottom, 12)
            .fmDebugFrame("detail-stats-row") // M11 取证：番茄那排统计 chip（应在后台标签行下面）

            // M1.11：简介块占据「统计 chip」到「下载按钮行」之间的剩余空间（不再 320 封顶）；
            // 简介短的就在这块里留白，长的高于这块时块内滚动。
            description(info)
                .frame(maxHeight: .infinity, alignment: .top)
                .fmDebugFrame("detail-desc") // 取证：简介块 frame（占中间剩余空间）
                .padding(.bottom, 20)

            // M3-b：简介块与下载按钮之间的短剧 IP 数据条 / 未加载提示（旧版 #m-sd-strip / #m-sd-hint）
            shortdramaSection(info)

            actions(info)
                .fmDebugFrame("detail-actions")
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// .desc：灰底圆角块。M1.11 起高度 = 中间剩余空间（不封顶），文字顶对齐，超长块内滚动。
    private func description(_ info: BookInfo) -> some View {
        ScrollView {
            Text(info.description.isEmpty ? "暂无简介" : info.description)
                .font(FMTheme.Font.body)
                .lineSpacing(5) // 行高 1.7
                .foregroundStyle(FMTheme.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fmMeasure(FMDescHeightKey.self)
                .onPreferenceChange(FMDescHeightKey.self) { height in
                    descTextHeight = height
                    FMMetrics.report("descText", height)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(FMTheme.fill, in: RoundedRectangle(cornerRadius: 10))
    }

    /// M12：详情页里**不再有后台数据块**——旧块（读者占比 / 申请·已上架·改编中 / 榜单标签）
    /// 的两行搬到下载按钮右侧（见 `ShortdramaSideLines`），剩下的榜单框按用户批注整块删除。
    /// 这里只保留未命中/未登录时的提示行（样式与行为不变）。
    @ViewBuilder
    private func shortdramaSection(_ info: BookInfo) -> some View {
        if info.platform == .fanqie {
            if shortdrama.detailHit == nil, let hint = shortdrama.detailHint {
                ShortdramaHintRow(
                    hint: hint,
                    needsKeychainFix: shortdrama.keychainNeedsFix,
                    needsFullDiskAccess: shortdrama.needsFullDiskAccess,
                    onIgnore: {
                        // 旧版 btn-sd-ignore：忽略后持久化（同时置 prompted），之后不再尝试
                        shortdrama.setIgnored(true)
                        shortdrama.clearDetail()
                    },
                    onAuthorize: { showKeychainSheet = true },
                    onOpenSettings: { shortdrama.openFullDiskAccessSettings() }
                )
                .padding(.bottom, 20)
                .fmDebugFrame("detail-sd-hint")
            }
        }
    }

    /// .m-actions { display:flex; gap:14; align-items:center }
    ///
    /// M12-b 版式：**[下载/访达按钮] [短剧两行] …… [失败提示]**
    ///   · 删掉旧的重复「共 N 章」（上方统计 chip 行已有）；
    ///   · 按钮 = 状态机（未下载蓝「下载」→ 下载中按钮内绿色填充 → 完成整体绿 + 文件夹图标）；
    ///   · 后台两行（读者占比 / 申请·已上架·改编中）从数据块搬到按钮右侧，两行叠放、整块高 = 按钮高；
    ///   · 完成态点绿色按钮 = 打开访达并选中产物（不再用默认应用打开 .txt）；
    ///   · 绿色按钮右边的放大镜图标按钮已删（用户选「甲」：功能并入主按钮）。
    private func actions(_ info: BookInfo) -> some View {
        let state = DownloadButtonState.resolve(
            bookID: info.bookID, title: info.title, author: info.author, chapterCount: info.chapterCount,
            downloads: downloads, library: library
        )
        let lines: ShortdramaSideLines? = (info.platform == .fanqie ? shortdrama.detailHit : nil)
            .map { ShortdramaSideLines(hit: $0, height: Self.downloadButtonHeight) }
        // M12-b 版式：[按钮] [两行] [失败提示]
        // 宽度不够时的压缩顺序：**先压两行（只缩不截），绝不压按钮文字**（按钮 fixedSize + layoutPriority(1)）。
        // 有短剧两行时由它吃掉中间剩余宽度（把右边两个控件顶到右边界），没两行时才用 Spacer。
        return HStack(alignment: .center, spacing: 12) {
            downloadButton(info, state: state)

            if let lines {
                lines
                    .padding(.leading, 6)
                    .fmDebugFrame("detail-sd-lines")
                trailing(state)
            } else {
                Spacer(minLength: 0)
                trailing(state)
            }
        }
    }

    /// 动作行右端：只剩失败提示（红字胶囊）。
    ///
    /// M12-b：完成态的放大镜图标按钮已删（用户选「甲」）——「打开访达」功能并入主按钮，
    /// 所以完成态行尾不再有任何控件。
    @ViewBuilder
    private func trailing(_ state: DownloadButtonState) -> some View {
        // 失败态：保留原有错误提示（按钮本身回「下载」，可重下）
        if case .failed(let message) = state {
            Text(message)
                .font(FMTheme.Font.body)
                .foregroundStyle(FMTheme.red)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fmDebugFrame("detail-result-text")
                .fmDebugValue("detail-result-text", message)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(FMTheme.redBg, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// M12：下载按钮高（与 `.fmButton(.primary, size: .big)` 的 48 一致）。
    /// 右侧短剧两行的整块高度也对齐到这个值。
    static let downloadButtonHeight: CGFloat = 48

    /// M12：按钮**最小宽度**（= 「下载」两字 36pt + 左右 padding 34×2）。
    /// 未下载/完成态都卡这个宽度 → 「打开」与「下载」同宽，两态之间**不跳变**，
    /// 也不会被右侧两行挤到裁字（配 `fixedSize(horizontal:)` 用）。
    static let downloadButtonMinWidth: CGFloat = 104

    /// M12：未下载态的按钮文案。
    static let downloadButtonTitle = "下载"
    /// M12-b：完成态按钮的悬停提示（完成态是纯图标按钮，靠它自解释）。
    static let doneButtonHelp = "打开访达"
    /// M12-b：完成态按钮里的图标 = 一个文件夹（用户 Q1：直接给文件夹 icon，不要文字）。
    ///
    /// 探活后再用（本机曾出现 `folder.badge.magnifyingglass` 渲染成空白按钮的坑）：
    /// `folder` → `folder.fill` → `square.grid.2x2` → `tray.full`，全不可用时返回 nil，
    /// 由调用方退回文字（绝不留一个空白图标按钮）。
    static var folderSymbolName: String? {
        for name in ["folder", "folder.fill", "square.grid.2x2", "tray.full"]
        where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return name
        }
        return nil
    }

    /// M12：下载按钮状态机（界面与自检同源）。
    ///   · `idle`    → 蓝底「下载」
    ///   · `running` → 蓝底 + **按钮内从左到右绿色填充**，文案 = 进度（不再有第二条独立进度条）
    ///   · `done`    → **整体绿常挂** + 文件夹图标，点击打开访达并选中产物
    ///   · `failed`  → 按钮回「下载」（可重下），错误文案在动作行右侧（旧行为保留）
    enum DownloadButtonState: Equatable {
        case idle
        case running(fraction: Double, text: String)
        case done(path: String)
        case failed(String)

        /// 按钮文案。**完成态不渲染文字**（改成文件夹图标），这里返回的是悬停/取证用的语义串。
        var title: String {
            switch self {
            case .idle, .failed: BookDetailView.downloadButtonTitle
            case .running(_, let text): text
            case .done: BookDetailView.doneButtonHelp
            }
        }

        var isDone: Bool {
            if case .done = self { return true }
            return false
        }

        /// 非 nil = 下载中（按钮内绿色填充的宽度比例）
        var fillFraction: Double? {
            if case .running(let fraction, _) = self { return fraction }
            return nil
        }

        /// 判定顺序：进行中 → 磁盘上真有产物（绿色常挂）→ 上一次失败 → 未下载。
        /// 产物核对**每次渲染都做**（含每次重新进入详情），所以外部删/移文件后自动回到「下载」。
        /// 进度分母：内核给了 total 就用它；只报「已下载 N 章」时（全本下载）退回用书本章节总数。
        @MainActor
        static func resolve(bookID: String, title: String, author: String, chapterCount: Int = 0,
                            downloads: DownloadCenter, library: LibraryStore) -> DownloadButtonState {
            if let task = downloads.activeTask(for: bookID) {
                return .running(fraction: fraction(task: task, chapterCount: chapterCount),
                                text: progressText(task: task, chapterCount: chapterCount))
            }
            if let path = existingFile(bookID: bookID, title: title, author: author,
                                       downloads: downloads, library: library) {
                return .done(path: path)
            }
            if let task = downloads.task(for: bookID), task.state == "失败" {
                return .failed(task.message ?? "下载失败")
            }
            return .idle
        }

        /// 按钮里的绿色填充比例（0…1）。
        static func fraction(task: DownloadCenter.DownloadTask, chapterCount: Int) -> Double {
            if task.progress.total > 0 { return task.progress.fraction }
            guard chapterCount > 0 else { return 0 }
            return min(1, Double(task.progress.saved) / Double(chapterCount))
        }

        /// 下载中按钮上的文案：**紧凑**（给右侧两行留宽度，绝不裁字）：
        /// `准备中…` / `下载中` / `下载中 43%`（详细章节数在下载管理面板里看）。
        static func progressText(task: DownloadCenter.DownloadTask, chapterCount: Int) -> String {
            if task.state == "准备中…" { return "准备中…" }
            let fraction = fraction(task: task, chapterCount: chapterCount)
            guard fraction > 0 else { return "下载中" }
            return "下载中 \(Int((fraction * 100).rounded()))%"
        }

        /// 磁盘上真实存在的产物：① 本会话刚完成的任务 ② 下载记录（`书名 作者 [ID].txt`）。
        /// 文件被删/被移 → 返回 nil（按钮回「下载」态）。
        @MainActor
        static func existingFile(bookID: String, title: String, author: String,
                                 downloads: DownloadCenter, library: LibraryStore) -> String? {
            let fm = FileManager.default
            if let task = downloads.task(for: bookID), task.state == "下载完成",
               let path = task.filePath, fm.fileExists(atPath: path) {
                return path
            }
            let expected = FMFormat.downloadFileName(title: title, author: author, bookID: bookID)
            for item in library.items where item.record.path.hasSuffix(expected) {
                if fm.fileExists(atPath: item.record.path) { return item.record.path }
            }
            return nil
        }
    }

    /// M12-b：未下载 = 蓝底「下载」；下载中 = 蓝底 + 按钮内从左到右绿色填充；
    /// 完成 = 整体绿 + **文件夹图标**（不再有「打开」文字）。
    /// 尺寸/字号/圆角/阴影与 `.fmButton(.primary, size: .big)` 一致。
    @ViewBuilder
    private func downloadButton(_ info: BookInfo, state: DownloadButtonState) -> some View {
        let running = state.fillFraction != nil
        Button {
            switch state {
            case .done(let path):
                // M12-b：点击 = 打开访达并定位/选中产物（不再用默认应用打开 .txt）
                if !Self.revealDownloadedFile(path: path) { model.showToast("找不到文件：\(path)") }
            case .running:
                break // 下载中不重复触发（保持原行为：不取消）
            case .idle, .failed:
                model.startDownload(title: info.title, author: info.author, bookID: info.bookID, platform: info.platform)
            }
        } label: {
            // 完成态：文件夹图标（探活失败则退回文字，绝不空白）
            if state.isDone, let symbol = Self.folderSymbolName {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .fmDebugFrame("detail-download-button-icon") // 取证：图标 frame（居中、不裁不溢出）
                    .padding(.horizontal, 34)
                    .frame(minWidth: Self.downloadButtonMinWidth)
                    .frame(height: Self.downloadButtonHeight)
                    .background(FMTheme.green) // 完成态整体绿常挂（无进度填充）
                    .clipShape(RoundedRectangle(cornerRadius: FMTheme.radius, style: .continuous))
                    .shadow(color: FMTheme.shadowSm.color, radius: FMTheme.shadowSm.radius, y: FMTheme.shadowSm.y)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text(state.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9) // 极端情况兜底：只缩不截
                    .fmDebugFrame("detail-download-button-text") // 取证：文字自己要多宽（被压扁就会小于这个值）
                    .padding(.horizontal, 34)
                    .frame(minWidth: Self.downloadButtonMinWidth)
                    .frame(height: Self.downloadButtonHeight)
                    .background(alignment: .leading) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                state.isDone ? FMTheme.green : FMTheme.accent
                                if let fraction = state.fillFraction {
                                    FMTheme.green
                                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: FMTheme.radius, style: .continuous))
                    .shadow(color: FMTheme.shadowSm.color, radius: FMTheme.shadowSm.radius, y: FMTheme.shadowSm.y)
                    // 取自然宽：HStack 再挤也挤不到按钮文字（只取 ideal，不看建议宽）
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .buttonStyle(.plain)
        // 宽度不够时先压右边两行；按钮文字优先级更高
        .layoutPriority(1)
        .help(running ? "正在下载…" : (state.isDone ? Self.doneButtonHelp : "下载整本 TXT"))
        .fmDebugFrame("detail-download-button") // 取证：按钮 frame（高 48）
        .fmDebugValue("detail-download-button-title", state.title) // 取证：按钮语义文案（完成态不渲染文字）
        .fmDebugValue("detail-download-button-tone", state.isDone ? "green" : (running ? "filling" : "blue"))
        .fmDebugValue("detail-download-button-symbol", state.isDone ? (Self.folderSymbolName ?? "（无文件夹图标 → 退回文字）") : "-")
    }

    /// M12-b：完成态点绿色按钮 = 打开访达并定位/选中产物（= 原「在 Finder 中显示」的行为，
    /// 自检与按钮同源；返回值 = 文件存在且访达选中动作返回成功）。
    /// **不再**用 `NSWorkspace.open`（默认应用打开 .txt）。
    @discardableResult
    static func revealDownloadedFile(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return true
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity)
            .padding(60)
    }

    private func load() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            // M2-b：按结果来源平台取详情（七猫走 QimaoBridge，界面完全共用）
            switch item.platform {
            case .qimao:
                info = try await QimaoBridge.bookInfo(id: item.bookID)
            case .fanqie:
                info = try await FanqieAPI.shared.bookInfo(id: item.bookID)
            }
            AppModel.lastDetailInfo = info
        } catch {
            info = nil
            loadError = AppModel.friendlyMessage(for: error)
        }
    }
}
