import SwiftUI

/// 相册（封面网格）卡片 —— 1:1 复刻旧版 `style.css:786-830` 的 `.results.album .result-item`
///
///   · 卡片：竖向、padding 0、overflow hidden、圆角 12、1px 边框、shadow-sm
///   · 封面：整宽 × 高 210、圆角 0、object-fit cover
///   · 信息区：padding 10/12/12；标题 13.5px 最多两行；meta 一行 12px
///   · 相册模式隐藏简介与箭头
///   · 榜单序号（M2 榜单区用）：**封面右下角**角标（M11 按用户批注从左上移过来），
///     黑 55% 底 + 白字 + 圆角 8 + padding 2/9；短剧后台角标在封面右上角，两者不相交。
struct AlbumCard: View {
    /// 标题两行的高度（13.5pt 行高约 16.1 → 2 行 32.2）
    static let titleHeight: CGFloat = 42   // M1.12：标题两行（15.5pt 中文行高≈21 → 2 行 42）
    /// meta 两行的高度（14pt 行高≈17 → 作者 17 + 行间 6 + 评分 17 = 40；
    /// M6：40 → 42，留 2pt 余量，保证两行完整不被压（封面/卡片高度同步 +2）。
    static let metaHeight: CGFloat = 42    // M1.12：meta 两行——字号放大后一行放不下作者+评分+字数

    let item: SearchItem
    /// 榜单名次（只有榜单结果区会传，M2）
    var rank: Int?
    /// 取证用的 frame 名（首个/末个）
    var debugFrameName: String = ""
    /// 取证用：封面 frame 名
    var debugCoverName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            cover
            info
        }
        .background(FMTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: FMTheme.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: FMTheme.radius, style: .continuous)
                .strokeBorder(item.sdInBackend ? FMTheme.red : FMTheme.separator, lineWidth: item.sdInBackend ? 1.5 : 1)
        )
        .shadow(
            color: item.sdInBackend ? FMTheme.red.opacity(0.14) : FMTheme.shadowSm.color,
            radius: item.sdInBackend ? 6 : FMTheme.shadowSm.radius,
            y: item.sdInBackend ? 4 : FMTheme.shadowSm.y
        )
        .overlay(alignment: .topTrailing) {
            if item.sdInBackend {
                ShortdramaTag(shelved: item.sdShelved, selected: item.sdApply)
                    .fmDebugFrame(debugFrameName.isEmpty ? "" : "\(debugFrameName)-sd-badge")
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: FMTheme.radius, style: .continuous))
        .fmDebugFrame(debugFrameName)
    }

    /// `.results.album .card-cover { width:100%; height:210px; border-radius:0 }`
    /// M11：榜单序号坐在封面右下角（不遮书名、不与右上角标重叠）。
    private var cover: some View {
        CoverImage(url: item.coverURL, cornerRadius: 0, mode: .fill)
            .frame(maxWidth: .infinity)
            .frame(height: FMLayout.albumCoverHeight)
            .clipped()
            // M11：榜单序号坐封面右下角（留白 8pt）
            .overlay(alignment: .bottomTrailing) { rankBadge.padding(8) }
            .fmDebugFrame(debugCoverName.isEmpty ? "album-cover" : debugCoverName)
    }

    /// `.results.album .ri-main { padding:10px 12px 12px }` + 标题 13.5/两行 + meta 12
    private var info: some View {
        VStack(alignment: .leading, spacing: FMLayout.cardTitleMetaGap) {
            Text(item.title)
                .font(FMTheme.Font.cardTitle)
                .foregroundStyle(FMTheme.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                // M1.7：标题区固定两行高（单行也占两行位置）→ 同排卡片高矮一致
                .frame(height: Self.titleHeight, alignment: .topLeading)
                .fmDebugFrame(debugFrameName.isEmpty ? "" : "\(debugFrameName)-title")
            // M2-b fix5：两行分工 —— 第 1 行作者（超长可省略），第 2 行「评分 · 字数」永不截断
            // M6：两行之间补 6pt 行距（改前 spacing 0 → 两行紧贴，视觉上像被截断）
            VStack(alignment: .leading, spacing: FMLayout.cardMetaLineGap) {
                Text(item.author)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fmDebugFrame(debugFrameName.isEmpty ? "" : "\(debugFrameName)-author")
                Text([item.score, item.words].filter { !$0.isEmpty }.joined(separator: " · "))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75) // 只缩不截：评分/字数一定看得见
                    .fmDebugFrame(debugFrameName.isEmpty ? "" : "\(debugFrameName)-meta")
            }
            .font(FMTheme.Font.meta)
            .foregroundStyle(FMTheme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: Self.metaHeight, alignment: .topLeading)
            .fmDebugFrame(debugFrameName.isEmpty ? "" : "\(debugFrameName)-info")
        }
        .padding(.top, FMLayout.cardTopPadding)
        .padding(.horizontal, 12)
        .padding(.bottom, FMLayout.cardBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `.results.album .rank-no`：黑 55% + 白字 + 圆角 8 + padding 2/9；M11 起贴在封面**右下角**（外留白 8pt）。
    @ViewBuilder
    private var rankBadge: some View {
        if let rank {
            Text("\(rank)")
                .font(FMTheme.Font.bodySmall)
                .foregroundStyle(rank <= 3 ? Color(hex: 0xFF9500) : .white) // 旧版 .rank-no.top
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .fmDebugFrame(debugFrameName.isEmpty ? "" : "\(debugFrameName)-rank")
        }
    }
}
