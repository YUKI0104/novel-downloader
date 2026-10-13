import CoreGraphics

/// 主页面横向基准线（M1.3 任务书第 1 条）。
///
/// 主页面所有内容必须对齐到同一个框：
///   · 最左 = 顶栏最左元素（「番茄小说」胶囊外框）的左边缘
///   · 最右 = 顶栏最右元素（设置齿轮）的右边缘
/// 顶栏与结果区共用这一份 inset，谁也不再各自加 padding。
enum FMLayout {
    /// 窗口固定尺寸（用户要求：宽度 1000 不可更改；高度 M7 曾由 800 → 860，
    /// M7.1 再收回 860 → 820，因为加高到 860 后第二行卡片下沿只到 ≈780，
    /// 窗口底部留白约 80pt 显得空。收回到 820 后底留白 ≈40pt；
    /// 卡片尺寸/封面/行距/网格顶/左右留白一律不动）
    static let windowWidth: CGFloat = 1000
    static let windowHeight: CGFloat = 820

    /// 内容左留白。M1.9x：与右侧留白**必须相等**（右侧 = trailingInset 18 + scrollSlot 12 = 30），
    /// 所以这里也用 30；滚动槽仍在右留白里（滚动条不压内容）。
    static let leadingInset: CGFloat = 30
    /// 只给滚动指示器的窄槽（约 12pt，颜色 = 页面底色，浮层滚动条落这里，不压卡片）
    static let scrollSlot: CGFloat = 12
    /// 外层（顶栏 + 结果区）距窗口右边的页面边距（= leadingInset − scrollSlot，保证左右留白都 30）
    static let trailingInset: CGFloat = leadingInset - scrollSlot
    /// 顶栏最右元素 / 结果区最右卡片的右边缘距窗口右边 = 页面边 18 + 滚动槽 12
    /// （两者用同一个值 → 「顶栏最右元素右边缘 == 结果区最右元素右边缘」）
    static let rightLine: CGFloat = trailingInset + scrollSlot

    /// 顶栏与内容区之间的竖向间距（M1.7：14 → 10，去掉那条空带）
    static let verticalSpacing: CGFloat = 10
    /// M1.7：顶栏上面那条空带去掉（窗口安全区（红黄绿按钮条）已经让出位置，这里不再额外垫 26pt）
    static let topInset: CGFloat = 0
    static let bottomInset: CGFloat = 18

    /// 旧版 `.results.album` 的网格数值（style.css:786-830）
    static let albumMinItemWidth: CGFloat = 150
    /// 列间距（卡片宽度由它决定，**不许动**）
    static let albumGap: CGFloat = 14
    /// 行间距（M1.13：14 → 10，给"一屏两行"腾高度）
    static let albumRowGap: CGFloat = 10
    /// 封面高（M1.13：210 → 195，给"一屏两行"腾高度；下限 185）
    static let albumCoverHeight: CGFloat = 195

    // MARK: - 竖向留白（M1.13 一屏两行：按任务书的缩让顺序取值）
    /// 状态行 ↔ 网格之间的留白（改前 = 状态行下边距 12 + 结果区上边距 14 = 26）
    static let statusBottomGap: CGFloat = 4      // 状态行下边距
    static let resultsTopGap: CGFloat = 6        // 结果区上边距 → 合计 10（目标 8~10）
    static let resultsBottomGap: CGFloat = 14    // 结果区下边距（最后一屏之后，不影响一屏放两行）
    /// 卡片内部竖向（封面↔标题↔meta 与卡片上下内边距，M1.13 收紧）
    static let cardTopPadding: CGFloat = 6
    static let cardTitleMetaGap: CGFloat = 2
    /// M6：作者行 ↔「评分·字数」行 的行间距。改前 = 0（两行紧贴，看起来像被挤/截断）；
    /// 14pt 正文行高 17，加 6pt 后两行占 40pt（≥ 任务书要求的 meta 两行合计 40pt）。
    static let cardMetaLineGap: CGFloat = 6
    static let cardBottomPadding: CGFloat = 8
}
