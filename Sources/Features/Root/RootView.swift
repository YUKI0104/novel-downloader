import SwiftUI

/// 单页搜索窗（规格 7 信息架构 / 旧版 index.html 布局）：
/// 顶栏（平台 + 搜索框 + 内核胶囊 + 下载 + 设置），下面是搜索列表区；
/// 弹窗 = 遮罩（黑 30% + 模糊）+ 实色面板，**不再是自创的玻璃形变浮层**（M1.1 任务书第 3 节）。
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var shortdrama = ShortdramaStore.shared

    var body: some View {
        ZStack {
            WindowBackdrop()

            // 顶栏与结果区共用同一组 inset：最左=番茄小说胶囊左边缘，最右=设置齿轮右边缘
            VStack(spacing: FMLayout.verticalSpacing) {
                TopBar()
                // 主页默认榜单（旧版一致）；搜索后切到搜索结果视图
                switch model.mainView {
                case .rank:
                    RankView()
                case .search:
                    SearchContentView()
                case .adapt:
                    AdaptView()
                }
            }
            .padding(.leading, FMLayout.leadingInset)
            .padding(.trailing, FMLayout.trailingInset)
            .padding(.top, FMLayout.topInset)
            .padding(.bottom, FMLayout.bottomInset)

            modalLayer

            toastLayer
        }
        // 注意：这里的内容 min 必须**小于**窗口固定高度。窗口尺寸的唯一来源是
        // FMLayout.windowHeight（WindowBackdrop 强制 min==max==固定值）；若把内容 min
        // 也提到 820，.windowResizability(.contentSize) 会按「内容 820 + 标题栏 32」
        // 反复把窗口顶到 852，和 enforce() 抢成一个 820↔852 的抖动环（M7 实测）。
        // 所以这里继续留在 700，绝不跟着 windowHeight 走。
        .frame(minWidth: 1000, minHeight: 700)
    }

    // MARK: - 弹窗层

    @ViewBuilder
    private var modalLayer: some View {
        // 详情 / 下载管理 / 设置
        if let overlay = model.activeOverlay {
            ZStack {
                FMModalScrim { closeOverlay() }
                    .transition(.fmModalScrim)

                switch overlay {
                case .downloads:
                    DownloadsView()
                        .padding(20)
                        .transition(.fmModalPanel)
                case .history:
                    HistoryView()
                        .padding(20)
                        .transition(.fmModalPanel)
                case .settings:
                    SettingsView()
                        .padding(20)
                        .transition(.fmModalPanel)
                case .kernelIssue:
                    KernelIssueOverlay()
                        .transition(.fmModalPanel)
                }
            }
            .zIndex(1)
        }

        if let selected = model.selected {
            ZStack {
                FMModalScrim { model.closeDetail() }
                    .transition(.fmModalScrim)
                BookDetailView(item: selected)
                    .padding(20)
                    .transition(.fmModalPanel)
            }
            .zIndex(2)
        }

        // 删除确认（旧版 #confirm-backdrop，独立一层，压在下载管理之上）
        if let item = model.pendingDeletion {
            ZStack {
                FMModalScrim { model.pendingDeletion = nil }
                    .transition(.fmModalScrim)
                FMModalPanel(width: 430, minHeight: 0, cornerRadius: 16, showsCloseButton: false) {
                    model.pendingDeletion = nil
                } content: {
                    FMConfirmDialog(
                        title: "删除「\(item.title)」?",
                        message: item.exists
                            ? "「同时删除文件」：本地文件也会被永久删除。\n\(item.record.path)"
                            : "文件已经不在磁盘上了。",
                        onCancel: { model.pendingDeletion = nil },
                        actions: [
                            .init(title: "仅移除记录", kind: .ghost) { delete(item, deleteFile: false) },
                            .init(title: "同时删除文件", kind: .danger) { delete(item, deleteFile: true) },
                        ]
                    )
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .transition(.fmModalPanel)
            }
            .zIndex(3)
        }

        // M3-c：短剧首启询问（旧版 #sd-first-backdrop，最高一层；没问过才显示）
        if shortdrama.showFirstRunPrompt {
            ZStack {
                // 旧版这个 backdrop 不响应点击关闭（只能选启用/忽略）
                FMModalScrim {}
                    .transition(.fmModalScrim)
                FMModalPanel(width: 430, minHeight: 0, cornerRadius: 16, showsCloseButton: false) {
                    shortdrama.declineFirstRun()
                } content: {
                    FMConfirmDialog(
                        title: "启用短剧模式?",
                        message: "是否使用「短剧后台IP查询」功能?\n\n启用后,打开番茄书籍详情时会自动查询该小说是否已被改编成短剧,以及申请人数、同IP改编中项目等信息。\n本功能需在 Safari 登录 www.shortdramas.com（也支持 Chrome / Edge 等 Chromium 浏览器）。",
                        cancelTitle: "忽略",
                        onCancel: { shortdrama.declineFirstRun() },
                        actions: [
                            .init(title: "启用", kind: .primary) { shortdrama.acceptFirstRun() },
                        ]
                    )
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .transition(.fmModalPanel)
                .fmDebugFrame("sd-first-prompt")
            }
            .zIndex(5)
        }

        // M3-d：短剧模式使用教程（打开开关 / 检测登录态失败时）
        if shortdrama.showTutorial {
            ZStack {
                FMModalScrim { shortdrama.showTutorial = false }
                    .transition(.fmModalScrim)
                FMModalPanel(width: 470, minHeight: 0, cornerRadius: 16, showsCloseButton: false) {
                    shortdrama.showTutorial = false
                } content: {
                    ShortdramaTutorialContent(
                        needsFullDiskAccess: shortdrama.needsFullDiskAccess,
                        onOpenSettings: { shortdrama.openFullDiskAccessSettings() },
                        onClose: { shortdrama.showTutorial = false }
                    )
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .transition(.fmModalPanel)
                .fmDebugFrame("sd-tutorial")
            }
            .zIndex(5)
        }
    }

    /// 旧版 #toast：右下角深色圆角条
    @ViewBuilder
    private var toastLayer: some View {
        if let toast = model.toast {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text(toast)
                        .font(FMTheme.Font.control)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(
                            Color(hex: 0x28282C).opacity(0.92),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                        .shadow(color: FMTheme.shadowLg.color, radius: FMTheme.shadowLg.radius, y: FMTheme.shadowLg.y)
                        .padding(.trailing, 24)
                        .padding(.bottom, 28)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .zIndex(4)
        }
    }

    private func closeOverlay() {
        withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = nil }
    }

    private func delete(_ item: LibraryItem, deleteFile: Bool) {
        do {
            try model.library.remove(id: item.record.path, deleteFile: deleteFile)
            model.showToast(deleteFile ? "已删除文件并移除记录" : "已移除记录，文件保留")
        } catch {
            model.showToast("删除失败: \(FriendlyError.text(error))")
        }
        model.pendingDeletion = nil
    }
}
