import SwiftUI

/// 七猫官方「剧本改编书单」（旧版 `.adapt-filters` + `.adapt-pager`，M2-b）。
///
/// 形态与番茄榜单一致：一行筛选组（改编方向/所属频道/作品分类/作品字数/是否完结/热门书单）
/// + 一行分页（上一页 / 第 N 页 / 下一页）+ 结果区（复用 AlbumCard/ResultsArea，不新造型）。
/// 短剧 IP 数据条属 M3，这里不做。
struct AdaptView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterRow
            statusLine
            ResultsArea(items: model.adaptBooks) { item in
                model.openDetail(item)
            }
        }
        .task { await model.loadAdaptIfNeeded() }
    }

    /// 筛选组：每组 = 「名称 ▾ 当前值」（名称来自菜单 label；空值一律显示「全部」）
    private var filterRow: some View {
        HStack(spacing: 6) {
            ForEach(model.adaptGroups) { group in
                HStack(spacing: 3) {
                    Text(group.label.isEmpty ? group.key : group.label)
                        .font(FMTheme.Font.bodySmall)
                        .foregroundStyle(FMTheme.textSecondary)
                        .fixedSize()
                    Picker("", selection: Binding(
                        get: { currentValue(group) },
                        set: { value in Task { await model.selectAdaptFilter(key: group.key, value: value) } }
                    )) {
                        // 官方选项里没有空值的组（如「改编方向」）界面补一个「全部」，
                        // 保证默认状态不显示空白，也不会出现「选择值匹配不到选项」
                        if !group.options.contains(where: { $0.value.isEmpty }) {
                            Text("全部").tag("")
                        }
                        ForEach(group.options, id: \.value) { option in
                            Text(option.label.isEmpty ? "全部" : option.label).tag(option.value)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 66) // M2-b fix2：六组 + 返回榜单要在一行 940pt 内排下
                }
                .fmDebugFrame("adapt-filter-\(group.key)")
            }
            Spacer(minLength: 0)
            Button("← 返回榜单") {
                model.mainView = .rank
            }
            .fmButton(.ghost)
            .help("返回榜单")
        }
        .padding(.bottom, 10)
        .padding(.trailing, FMLayout.scrollSlot) // 与网格同一条右基准线
        .fmDebugFrame("adapt-filters")
    }

    private func currentValue(_ group: QimaoModels.AdaptFilterGroup) -> String {
        switch group.key {
        case "direction": model.adaptFilter.direction
        case "channel": model.adaptFilter.channel
        case "category": model.adaptFilter.category
        case "words": model.adaptFilter.words
        case "is_over": model.adaptFilter.isOver
        case "ranking_type": model.adaptFilter.rankingType
        default: ""
        }
    }

    /// 状态 + 分页（旧版 `.adapt-pager`：上一页/下一页）
    private var statusLine: some View {
        HStack(spacing: 10) {
            if !model.adaptStatus.isEmpty {
                Text(model.adaptStatus)
                    .font(FMTheme.Font.bodySmall)
                    .foregroundStyle(model.adaptStatusIsError ? FMTheme.red : FMTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button("上一页") {
                Task { await model.adaptPage(delta: -1) }
            }
            .fmButton(.ghost, size: .small)
            .disabled(model.adaptPage <= 1)
            Text("第 \(model.adaptPage) 页")
                .font(FMTheme.Font.bodySmall)
                .foregroundStyle(FMTheme.textSecondary)
            Button("下一页") {
                Task { await model.adaptPage(delta: 1) }
            }
            .fmButton(.ghost, size: .small)
            .disabled(model.adaptBooks.isEmpty)
        }
        .frame(minHeight: 22, alignment: .leading)
        .padding(.bottom, FMLayout.statusBottomGap)
        .padding(.trailing, FMLayout.scrollSlot)
        .fmDebugFrame("adapt-pager")
    }
}
