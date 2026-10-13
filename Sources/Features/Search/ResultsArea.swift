import SwiftUI

/// 结果区（搜索结果 / 榜单 / 改编书单共用）：内容材质面 + 网格或列表。
/// 横向 padding 由 RootView 的 FMLayout 下发，这里不加左右 padding（最左/最右元素对齐顶栏）。
struct ResultsArea: View {
    var items: [SearchItem]
    /// 榜单模式：显示序号（相册=封面左上角角标，列表=行首序号列），前三名橙色
    var ranked: Bool = false
    var onTap: (SearchItem) -> Void

    @StateObject private var viewMode = ViewModeStore.shared

    var body: some View {
        ScrollView {
            if viewMode.isAlbum {
                albumGrid
            } else {
                listRows
            }
        }
        .padding(.top, FMLayout.resultsTopGap)
        .padding(.bottom, FMLayout.resultsBottomGap)
        // M1.7：内容容器不再有自己的底色（原来那层比页面更深，加载/空态就是一块色差方块）；
        // 卡片本身是实色，直接坐在页面底色上。
        .contentMargins(0, for: .scrollContent)
        .fmDebugFrame("results-scroll")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 旧版 `.results.album { repeat(auto-fill, minmax(150px,1fr)); gap:14px }`
    private var albumGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: FMLayout.albumMinItemWidth), spacing: FMLayout.albumGap)],
            spacing: FMLayout.albumRowGap
        ) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                AlbumCard(
                    item: item,
                    rank: ranked ? index + 1 : nil,
                    debugFrameName: index < 10 ? "card-\(index + 1)" : (index == 0 ? "results-first-card" : ""),
                    debugCoverName: index < 10 ? "cover-\(index + 1)" : ""
                )
                .onTapGesture { onTap(item) }
            }
        }
        .fmDebugFrame("results-left")   // 先量（量的是卡片区自身右边缘），再让出滚动槽
        .fmDebugFrame("results-right")
        .padding(.trailing, FMLayout.scrollSlot)
    }

    /// 列表模式：保持原样式；榜单时行首加序号列（旧版 `.rank-no`，前三名橙色）
    private var listRows: some View {
        LazyVStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                BookRow(item: item, rank: ranked ? index + 1 : nil)
                    .fmDebugFrame(index == 0 ? "results-first-card" : "")
                    .onTapGesture { onTap(item) }
            }
        }
        .fmDebugFrame("results-left")
        .fmDebugFrame("results-right")
        .padding(.trailing, FMLayout.scrollSlot)
    }
}
