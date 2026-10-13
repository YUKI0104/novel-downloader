import SwiftUI

/// 搜索结果显示区（旧版 index.html:101-108 的 `#search-results` + `.search-head`）：
/// 顶部一行 = 状态文字在左、「返回榜单」按钮在右；下面是结果区（封面网格 / 列表）。
/// 空/失败状态保留规格 7 要求的「一句话 + 一个明确动作」。
struct SearchContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            resultsPane
        }
    }

    /// `.search-head { display:flex; justify-content:space-between; gap:12px }`
    private var head: some View {
        HStack(spacing: 12) {
            Text(model.searchStatus)
                .font(FMTheme.Font.bodySmall)
                .foregroundStyle(model.searchStatusIsError ? FMTheme.red : FMTheme.textSecondary)
                .lineLimit(1)
            // M3-g：自动重试 3 次仍失败 → 状态行给「重试」按钮（复用榜单状态行同款 ghost/small 样式）
            if case .failed = model.searchState {
                Button("重试") {
                    Task { await model.submitSearch() }
                }
                .fmButton(.ghost, size: .small)
            }
            Spacer(minLength: 0)
            Button {
                Task { await model.backToRank() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left")
                    Text("返回榜单")
                }
            }
            .fmButton(.ghost, size: .small)
            .fmDebugFrame("search-head-button") // 取证：头行最右元素
            .help("返回榜单")
        }
        .padding(.bottom, 10)
        .padding(.trailing, FMLayout.scrollSlot) // 与网格同一条右基准线
        .fmDebugFrame("search-head")
    }

    @ViewBuilder
    private var resultsPane: some View {
        switch model.searchState {
        case .idle:
            // 定稿：空状态只留图标 + 标题 + 一行说明（测试用的「试搜」按钮已删除）
            surface {
                stateView(
                    icon: "magnifyingglass",
                    title: "输入书名开始搜索",
                    detail: "也可以直接粘贴 10 位以上的书籍 ID，或 fanqienovel.com 的书页链接。"
                )
            }
        case .searching:
            surface {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在搜索「\(model.searchText)」…")
                        .font(FMTheme.Font.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .empty:
            surface {
                stateView(
                    icon: "books.vertical",
                    title: "没有找到相关书籍",
                    detail: "换个书名，或直接粘贴书籍 ID / 书页链接再试。",
                    actionTitle: "清空重搜"
                ) {
                    model.searchText = ""
                    model.results = []
                    model.searchState = .idle
                }
            }
        case .failed(let message):
            surface {
                stateView(
                    icon: "exclamationmark.triangle",
                    title: "😥 搜索失败",
                    detail: message,
                    actionTitle: "重试"
                ) {
                    Task { await model.submitSearch() }
                }
            }
        case .results:
            ResultsArea(items: model.results) { item in
                model.openDetail(item)
            }
        }
    }

    /// M1.7：状态容器不再自带底色（去掉比页面更深的那层）
    private func surface<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stateView(
        icon: String,
        title: String,
        detail: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(FMTheme.Font.display)
                .foregroundStyle(.secondary)
            Text(title)
                .font(FMTheme.Font.cardTitle)
                .foregroundStyle(.primary)
            Text(detail)
                .font(FMTheme.Font.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .fmButton(.primary)
                    .padding(.top, 4)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 列表模式的一行（原样式不动）；榜单模式行首加序号列（旧版 `.rank-no`，前三名橙色）。
struct BookRow: View {
    let item: SearchItem
    var rank: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let rank {
                Text("\(rank)")
                    .font(FMTheme.Font.rankNumber)
                    .foregroundStyle(rank <= 3 ? Color(hex: 0xFF9500) : FMTheme.textTertiary)
                    .frame(width: 34, alignment: .center)
                    .monospacedDigit()
            }
            CoverImage(url: item.coverURL, width: 66, height: 90)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(FMTheme.Font.cardTitle).lineLimit(2)
                Text(item.author).font(FMTheme.Font.subheadline).foregroundStyle(.secondary)
                if !item.abstract.isEmpty {
                    Text(item.abstract)
                        .font(FMTheme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if !item.score.isEmpty { chip(item.score) }
                    if !item.words.isEmpty { chip(item.words) }
                    if !item.hot.isEmpty { chip(item.hot) }
                    Spacer()
                    Text("ID \(item.bookID)")
                        .font(FMTheme.Font.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 20) // ≥18pt：给覆盖式滚动条留出浮层空间，19 位 ID 完整可读
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // 列表模式保持原样式（M1.1/M1.2 的玻璃卡片行，本轮不动）
        .fmGlass(.interactive, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // M3-b：短剧后台命中 → 红框高亮 + 右上「短剧」角标
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(item.sdInBackend ? FMTheme.red : .clear, lineWidth: 1.5)
        )
        .overlay(alignment: .topTrailing) { if item.sdInBackend { ShortdramaTag(shelved: item.sdShelved, selected: item.sdApply) } }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(FMTheme.Font.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .foregroundStyle(.secondary)
    }
}
