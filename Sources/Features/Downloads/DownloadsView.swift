import AppKit
import SwiftUI

/// 已下载弹窗 —— 1:1 复刻旧版 `#lib-backdrop`（index.html 113-126 / style.css 588-620）
/// M1.12：与详情弹窗**同尺寸固定**（`FMTheme.modalWidth × modalHeight` = 950×600），列表区吃剩余空间。
///
/// 删除确认用同一个 `#confirm-backdrop` 结构（430 宽，见 RootView 里的 FMConfirmDialog）。
struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var listHeight: CGFloat = 0

    private var isEmptyList: Bool {
        model.library.items.isEmpty && model.downloads.tasks.isEmpty
    }

    var body: some View {
        // M1.2：高度按内容（标题 + 按钮行 + 列表自然高度），不再撑满窗口；空列表给最小高度
        FMModalPanel(width: FMTheme.modalWidth, fixedHeight: FMTheme.modalHeight, minHeight: 0) {
            withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = nil }
        } content: {
            // .panel-body { padding:28px 30px 30px; flex:1; overflow-y:auto }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(FMTheme.Font.sectionSmall)
                        .foregroundStyle(FMTheme.textSecondary)
                    Text("已下载")
                        .font(FMTheme.Font.title)
                        .foregroundStyle(FMTheme.text)
                }
                .padding(.bottom, 16)

                HStack(spacing: 8) {
                    Button("刷新") { model.library.reload() }.fmButton(.ghost)
                    Button("打开下载目录") { model.revealDownloadDirectory() }.fmButton(.ghost)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 16)

                ScrollView {
                    VStack(spacing: 0) {
                        if !model.downloads.tasks.isEmpty {
                            ForEach(model.downloads.tasks.reversed()) { task in
                                taskRow(task)
                            }
                        }
                        if model.library.items.isEmpty && model.downloads.tasks.isEmpty {
                            Text("还没有下载记录")
                                .font(FMTheme.Font.control)
                                .foregroundStyle(FMTheme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                        } else {
                            ForEach(model.library.items) { item in
                                libraryRow(item)
                            }
                        }
                    }
                    .fmMeasure(FMListHeightKey.self)
                }
                .onPreferenceChange(FMListHeightKey.self) { height in
                    listHeight = height
                    FMMetrics.report("list", height)
                }
                // M1.12：固定面板后列表吃掉剩余空间（空列表也不塌，靠里面的空态文案撑住）
                .frame(maxHeight: .infinity)
            }
            .padding(.top, 28)
            .padding(.horizontal, 30)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// .result-item { 白卡片 / 1px 边框 / 圆角 12 / padding 15 18 / margin-bottom 10 / shadow-sm }
    private func rowContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FMTheme.card, in: RoundedRectangle(cornerRadius: FMTheme.radius))
            .overlay(
                RoundedRectangle(cornerRadius: FMTheme.radius)
                    .strokeBorder(FMTheme.separator, lineWidth: 1)
            )
            .shadow(color: FMTheme.shadowSm.color, radius: FMTheme.shadowSm.radius, y: FMTheme.shadowSm.y)
            .padding(.bottom, 10)
    }

    private func taskRow(_ task: DownloadCenter.DownloadTask) -> some View {
        rowContainer {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(FMTheme.Font.sectionSmall)
                        .foregroundStyle(FMTheme.text)
                        .lineLimit(1)
                    Text("\(task.author) · \(task.progressText)")
                        .font(FMTheme.Font.metaMono)
                        .foregroundStyle(FMTheme.textSecondary)
                    if let message = task.message {
                        Text(message).font(FMTheme.Font.metaMono).foregroundStyle(FMTheme.red).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if task.isActive {
                    FMProgressBar(fraction: task.progress.fraction, text: "")
                        .frame(width: 160)
                    Button("取消") { model.downloads.cancel(task.id) }.fmButton(.ghost, size: .small)
                } else if let path = task.filePath {
                    Button("在 Finder 中显示") { model.library.revealInFinder(id: path) }
                        .fmButton(.ghost, size: .small)
                }
            }
        }
    }

    private func libraryRow(_ item: LibraryItem) -> some View {
        rowContainer {
            HStack(spacing: 14) {
                Image(systemName: "doc.text")
                    .font(FMTheme.Font.sectionSmall)
                    .foregroundStyle(FMTheme.textSecondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(FMTheme.Font.sectionSmall)
                        .foregroundStyle(FMTheme.text)
                        .lineLimit(1)
                    Text("\(item.author) · \(item.ext.uppercased()) · \(FMFormat.fileSize(item.size)) · \(FMFormat.shortTime(item.record.time))")
                        .font(FMTheme.Font.metaMono)
                        .foregroundStyle(FMTheme.textSecondary)
                    Text(item.record.path)
                        .font(FMTheme.Font.micro)
                        .foregroundStyle(FMTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if !item.exists {
                    Text("文件已丢失").font(FMTheme.Font.metaMono).foregroundStyle(FMTheme.red)
                }
                Button("在 Finder 中显示") { model.library.revealInFinder(id: item.record.path) }
                    .fmButton(.ghost, size: .small)
                    .disabled(!item.exists)
                Button("删除") { model.pendingDeletion = item }
                    .fmButton(.danger, size: .small)
            }
        }
    }
}
