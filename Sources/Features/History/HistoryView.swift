import SwiftUI

/// 「最近查看」弹窗（M5 / M5.1）—— 与「下载管理」同款面板（950×600 / 同标题栏 / 同 ✕）。
/// 头部：标题与两个分段「搜索记录 / 详情记录」左对齐；分段用 liquidglass 玻璃胶囊（同顶栏平台 chip）；
/// 「清空记录」与分段同一行靠右。列表时间倒序，每条 = 左侧图标+书名，右侧「平台标签 + 时间」同行靠右 + › 箭头。
/// 某段为空显示该段专属空状态。
struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var history = HistoryStore.shared

    private var items: [FMHistoryRecord] { history.records(of: model.historySegment) }

    var body: some View {
        FMModalPanel(width: FMTheme.modalWidth, fixedHeight: FMTheme.modalHeight, minHeight: 0) {
            withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = nil }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                // 标题（与下面两个分段共用弹窗内容左边距 30，左基准线一致）
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(FMTheme.Font.sectionSmall)
                        .foregroundStyle(FMTheme.textSecondary)
                    Text("最近查看")
                        .font(FMTheme.Font.title)
                        .foregroundStyle(FMTheme.text)
                }
                .fmDebugFrame("history-title")
                .padding(.bottom, 14)

                // 分段（liquidglass 玻璃胶囊，左对齐）+ 清空记录（同一行、靠右、与分段垂直居中）
                HStack(spacing: 8) {
                    segmentControl
                    Spacer(minLength: 8)
                    Button("清空记录") { history.clear() }
                        .fmButton(.ghost, size: .small)
                        .disabled(history.records.isEmpty)
                        .help("清空搜索记录与详情记录")
                        .fmDebugFrame("history-clear")
                }
                .padding(.bottom, 16)

                ScrollView {
                    VStack(spacing: 0) {
                        if items.isEmpty {
                            VStack(spacing: 8) {
                                Text("近 7 天没有记录")
                                    .font(FMTheme.Font.control)
                                    .foregroundStyle(FMTheme.textSecondary)
                                Text(model.historySegment == .search
                                     ? "搜索成功后的关键词会出现在这里。"
                                     : "打开过的书会出现在这里。")
                                    .font(FMTheme.Font.meta)
                                    .foregroundStyle(FMTheme.textTertiary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                        } else {
                            ForEach(items) { record in
                                historyRow(record)
                            }
                        }
                    }
                    .fmMeasure(FMListHeightKey.self)
                }
                .frame(maxHeight: .infinity)
            }
            .padding(.top, 28)
            .padding(.horizontal, 30)
            .padding(.bottom, 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    /// 两个分段：液态玻璃胶囊（半透明底 + 选中项更实/带高光），与顶栏平台 chip 同一套语言。
    private var segmentControl: some View {
        HStack(spacing: 4) {
            segmentChip(.search, "搜索记录")
            segmentChip(.detail, "详情记录")
        }
        .padding(4)
        .fmGlass(.regular, in: Capsule())
        .fmDebugFrame("history-segments")
    }

    private func segmentChip(_ kind: FMHistoryRecord.Kind, _ label: String) -> some View {
        let selected = model.historySegment == kind
        return Button {
            guard !selected else { return }
            withAnimation(.easeOut(duration: 0.15)) { model.historySegment = kind }
        } label: {
            Text(label)
                .font(FMTheme.Font.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .fmDebugFrame("history-segment-\(kind.rawValue)")
    }

    /// 平台小胶囊：番茄＝品牌红，七猫＝靛蓝（低饱和底 + 同色系文字）。
    private func platformTag(_ record: FMHistoryRecord) -> some View {
        let isQimao = record.platform == Platform.qimao.rawValue
        return Text(isQimao ? "七猫" : "番茄")
            .font(FMTheme.Font.caption.weight(.medium))
            .foregroundStyle(isQimao ? FMTheme.indigo : FMTheme.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(isQimao ? FMTheme.indigoBg : FMTheme.redBg, in: Capsule())
            .fixedSize()
            .fmDebugFrame("history-row-tag-\(isQimao ? "qimao" : "fanqie")")
    }

    /// 与「下载管理」的 .result-item 同款白卡片；整行可点，点了切平台并重搜 / 重开详情。
    /// 布局：左 图标 + 书名（单行截断）；右 平台标签 + 时间 + ›，与书名同一行、整体靠右。
    private func historyRow(_ record: FMHistoryRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: record.kind == .search ? "magnifyingglass" : "book")
                .font(FMTheme.Font.sectionSmall)
                .foregroundStyle(FMTheme.textSecondary)
            Text(record.title)
                .font(FMTheme.Font.sectionSmall)
                .foregroundStyle(FMTheme.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .fmDebugFrame("history-row-title-\(record.platform)")
            Spacer(minLength: 8)
            platformTag(record)
            Text(FMFormat.relativeTime(record.date))
                .font(FMTheme.Font.metaMono)
                .foregroundStyle(FMTheme.textSecondary)
                .fixedSize()
                .fmDebugFrame("history-row-time-\(record.platform)")
            Image(systemName: "chevron.right")
                .font(FMTheme.Font.meta)
                .foregroundStyle(FMTheme.textTertiary)
                .fmDebugFrame("history-row-chevron-\(record.platform)")
        }
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
        .contentShape(Rectangle())
        .onTapGesture { Task { await model.openHistory(record) } }
        .fmDebugFrame("history-row-\(record.kind.rawValue)")
    }
}
