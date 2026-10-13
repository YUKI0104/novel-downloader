import SwiftUI

/// M3-b 短剧 IP 的界面零件（对照旧版 `style.css:445-466/738-763/833-847`）。
/// 只用现有 SwiftUI 组件与 FMTheme 颜色/字号，不新创造型。
enum SDTone {
    /// 旧版 `--orange`
    static let orange = Color(hex: 0xFF9500)
}

/// 短剧命中角标（旧版 `.sd-tag`，absolute top:8 right:8）。
/// M10（用户 2026-10-11 改口径）：**不再出现「短剧」字样**，文案固定 `上架N部·申请N次`：
///   · 两段都显示（为 0 也显示）；
///   · `ip_shelved_count` / `ip_selected_count` **> 0 的片段标红、= 0 的片段灰字**；
///   · 位置仍在封面右上角、不遮封面主体与书名；放不下可两行，**不许截断**。
struct ShortdramaTag: View {
    /// `ip_shelved_count`（已上架短剧数）
    var shelved: Int = 0
    /// `ip_selected_count`（申请/被挑选次数）
    var selected: Int = 0

    /// 角标文案（自检 `sd-hit` 直接断言；固定两段，不做三态降级）。
    static func text(shelved: Int, selected: Int) -> String {
        "上架\(shelved)部·申请\(selected)次"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Image(systemName: "film")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(FMTheme.red)
            Text(Self.attributed(shelved: shelved, selected: selected))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8) // 只缩不截：放不下先缩字，再换两行
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(FMTheme.card.opacity(0.94), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(FMTheme.red.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
        .padding(8)
    }

    /// 两段各自着色：> 0 红、= 0 灰（分隔点用三级灰）。
    static func attributed(shelved: Int, selected: Int) -> AttributedString {
        var out = AttributedString()
        var first = AttributedString("上架\(shelved)部")
        first.foregroundColor = shelved > 0 ? FMTheme.red : FMTheme.textSecondary
        out += first
        var dot = AttributedString("·")
        dot.foregroundColor = FMTheme.textTertiary
        out += dot
        var second = AttributedString("申请\(selected)次")
        second.foregroundColor = selected > 0 ? FMTheme.red : FMTheme.textSecondary
        out += second
        return out
    }
}

/// 数据块里的一段「标签 值」：值 >0 时警示红、=0 时灰字（M10 高亮规则）。
struct SDField: Equatable {
    var label: String
    var value: String
    /// `申请`/`已上架`/`改编中` > 0 → 警示红
    var alert: Bool = false
    /// `= 0` 的计数值 → 灰字（不当作正向高亮）
    var muted: Bool = false
}

/// 短剧后台字段的**取数与文案口径**（M12 起**界面上不再有数据块 / 榜单标签块**）。
///
/// 用户 2026-10-11 圈删了整个榜单框（只剩一个「阅读榜」小标签的那个框）→
/// **连框带标签一起删**，详情页不再显示榜单；`rankTags` 取数逻辑保留（自检/将来复用），只不进界面。
///
/// 当前详情页用到这里的：
///   · `statusText` → 作者行的 `已完结 · 上架 YYYY-MM`
///   · `tags` → 作者行下面的后台标签胶囊
///   · `line2`/`line3` + `attributed` → 下载按钮右侧那两行（`ShortdramaSideLines`）
/// 历史：M11 删了「短剧后台」标题行 / 「在后台打开」/ 「评价 N 人」；M12 删了两行数据所在的块与榜单框。
enum ShortdramaStrip {

    // MARK: - 行内容（自检 `sd-fields` 复用同一份口径）

    /// 不换行空格：把「标签 + 值」粘成一个原子单元，换行只发生在 `·` 分隔处。
    private static let nbsp = "\u{00A0}"

    /// M11：`已完结 · 上架 YYYY-MM`（渲染在作者行里）。
    /// 两项都空 → 返回空串（界面回退显示番茄自己的题材标签）。
    static func statusText(_ hit: ShortdramaClient.ShortdramaIP) -> String {
        var parts: [String] = []
        if !hit.creationStatus.isEmpty { parts.append(hit.creationStatus) }
        if !hit.onlineMonth.isEmpty { parts.append("上架 \(hit.onlineMonth)") }
        return parts.joined(separator: " · ")
    }

    static func line2(_ hit: ShortdramaClient.ShortdramaIP) -> [SDField] {
        let rates = "中年\(nbsp)\(empty(hit.middleRate))\(nbsp)\(nbsp)·\(nbsp)\(nbsp)老年\(nbsp)\(empty(hit.oldRate))\(nbsp)\(nbsp)·\(nbsp)\(nbsp)青年\(nbsp)\(empty(hit.youngRate))"
        return [SDField(label: "读者占比", value: rates)]
    }

    static func line3(_ hit: ShortdramaClient.ShortdramaIP) -> [SDField] {
        let selected = num(hit.selectedCnt)
        let shelved = num(hit.shelvedCnt)
        let adapting = num(hit.adaptingCnt)
        return [
            SDField(label: "申请", value: "\(selected)\(nbsp)次", alert: selected > 0, muted: selected == 0),
            SDField(label: "已上架", value: "\(shelved)\(nbsp)部", alert: shelved > 0, muted: shelved == 0),
            SDField(label: "改编中", value: "\(adapting)\(nbsp)个", alert: adapting > 0, muted: adapting == 0),
        ]
    }

    /// M11：榜单**以标签形式**呈现（当前榜 + 历史峰值榜，去重、保持原序）。
    /// **M12：取数逻辑保留，界面不再渲染**（用户圈删了整个榜单框）。
    static func rankTags(_ hit: ShortdramaClient.ShortdramaIP) -> [String] {
        var out: [String] = []
        for rank in hit.currentRankings + hit.historicalRankings where !rank.isEmpty && !out.contains(rank) {
            out.append(rank)
        }
        return out
    }

    /// 标签胶囊取数（M11 起渲染在详情页作者行下面）：等级（`精品IP`，强调色）+ 性别 + 内容标签。
    static func tags(_ hit: ShortdramaClient.ShortdramaIP) -> [(text: String, accent: Bool)] {
        var out: [(String, Bool)] = []
        if hit.tierLevel != "未知", !hit.tierLevel.isEmpty {
            out.append((hit.tierLevel, true))
        }
        if hit.gender != "未知", !hit.gender.isEmpty {
            out.append((hit.gender, false))
        }
        for c in hit.categories {
            out.append((c, false))
        }
        return out
    }

    /// 一行数据的纯文案（自检取证用，与界面同源）。分隔符统一 `·`（不再用 `｜`）。
    static func lineText(_ fields: [SDField]) -> String {
        fields
            .map { $0.label.isEmpty ? $0.value : "\($0.label) \($0.value)" }
            .joined(separator: "  ·  ")
            .replacingOccurrences(of: nbsp, with: " ")
    }

    static func attributed(_ fields: [SDField]) -> AttributedString {
        var out = AttributedString()
        for (index, field) in fields.enumerated() {
            if index > 0 {
                var sep = AttributedString("  ·  ")
                sep.foregroundColor = FMTheme.textTertiary
                out += sep
            }
            if !field.label.isEmpty {
                var label = AttributedString(field.label + nbsp)
                label.foregroundColor = FMTheme.textSecondary
                out += label
            }
            var value = AttributedString(field.value)
            value.foregroundColor = field.alert ? FMTheme.red : (field.muted ? FMTheme.textSecondary : FMTheme.text)
            out += value
        }
        return out
    }

    private static func num(_ raw: String) -> Int { Int(raw) ?? 0 }
    private static func empty(_ raw: String) -> String { raw.isEmpty ? "—" : raw }
}

/// M12：从后台数据块移出、紧贴下载按钮右侧的两行。
///
///   · 两行**叠放**：上行顶对齐、下行底对齐，整块高度 = 下载按钮高（`height`，默认 48）；
///   · 着色沿用块内规则：字段名灰 / 值白、`申请·已上架·改编中 > 0` 红、`0` 灰；
///   · **不断词、不截断**：拿到右侧剩余宽度，宽度不够时按比例缩字（`minimumScaleFactor`），
///     而不是去挤按钮（按钮 `fixedSize` + 更高 `layoutPriority`）。
struct ShortdramaSideLines: View {
    let hit: ShortdramaClient.ShortdramaIP
    /// 与下载按钮同高（`BookDetailView.downloadButtonHeight`）
    var height: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            line(ShortdramaStrip.line2(hit))
                .fmDebugFrame("detail-sd-line1")
            Spacer(minLength: 0)
            line(ShortdramaStrip.line3(hit))
                .fmDebugFrame("detail-sd-line2")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height, alignment: .leading)
        .fmDebugFrame("detail-sd-lines")
    }

    /// 单行：一行一个 `Text`（不换行、不省略号；放不下只缩字到 0.8）。
    /// 用 `maxWidth: .infinity` 吃掉「按钮右侧→右边界」的剩余宽度，把右边的控件顶到行尾。
    private func line(_ fields: [SDField]) -> some View {
        Text(ShortdramaStrip.attributed(fields))
            .font(FMTheme.Font.meta)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 极简流式布局（MacOS 13+ `Layout`）：一行放不下就换行，**绝不压缩/截断**标签。
struct FMFlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// 短剧数据没加载出来时的提示行（旧版 `#m-sd-hint`：橙底提示 + 「忽略」按钮）。
/// 钥匙串被拦时把按钮换成「钥匙串授权…」（用户点了才执行授权）。
struct ShortdramaHintRow: View {
    let hint: String
    var needsKeychainFix = false
    var needsFullDiskAccess = false
    var onIgnore: (() -> Void)?
    var onAuthorize: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 14))
                .foregroundStyle(SDTone.orange)
            Text(hint)
                .font(FMTheme.Font.meta)
                .foregroundStyle(SDTone.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if needsFullDiskAccess, let onOpenSettings {
                Button("打开系统设置", action: onOpenSettings).fmButton(.ghost, size: .small)
            } else if needsKeychainFix, let onAuthorize {
                Button("钥匙串授权…", action: onAuthorize).fmButton(.ghost, size: .small)
            } else if let onIgnore {
                Button("忽略", action: onIgnore).fmButton(.ghost, size: .small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(SDTone.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// 钥匙串授权 sheet（旧版 `#kc-backdrop` 的等价物）：
/// **只有用户点了「钥匙串授权…」才打开**，在里面点「授权」才真正调用 `security` 修分区列表。
struct ShortdramaKeychainSheet: View {
    /// 授权成功后回调（用来重试原先失败的查询）
    var onAuthorized: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var errorText: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("钥匙串授权")
                .font(FMTheme.Font.title)
                .foregroundStyle(FMTheme.text)
            Text("macOS 拦截了读取浏览器登录态的钥匙串访问。输入 Mac 开机密码，把 security 工具加入授权列表，之后不再弹窗。密码只用于本次命令，不保存。")
                .font(FMTheme.Font.bodySmall)
                .foregroundStyle(FMTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Mac 开机密码", text: $password)
                .textFieldStyle(.roundedBorder)
            if let errorText {
                Text(errorText)
                    .font(FMTheme.Font.caption)
                    .foregroundStyle(FMTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("手动方式：去系统弹窗点「总是允许」") {
                    onAuthorized()
                    dismiss()
                }
                .fmButton(.ghost, size: .small)
                Spacer(minLength: 0)
                Button("取消") { dismiss() }.fmButton(.ghost)
                Button("授权") {
                    Task {
                        busy = true
                        errorText = await ShortdramaStore.shared.authorizeKeychain(password: password)
                        busy = false
                        if errorText == nil {
                            onAuthorized()
                            dismiss()
                        }
                    }
                }
                .fmButton(.primary)
                .disabled(password.isEmpty || busy)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

/// M3-d：短剧模式使用教程（用户打开开关 / 检测登录态失败时显示）。
/// 编号步骤 + 中文，用现有 FMTheme 字体；Safari 为主角，Chromium 只在末尾一行小字。
struct ShortdramaTutorialContent: View {
    var needsFullDiskAccess: Bool
    var onOpenSettings: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("怎么用短剧模式")
                .font(FMTheme.Font.title)
                .foregroundStyle(FMTheme.text)

            step(1, "在 Safari 里打开 www.shortdramas.com 并登录。")
            step(2, "回到「番茄猫」，点设置页的「检测登录态」。")
            step(3, "如果提示权限不足：点「打开系统设置」，在 隐私与安全性 → 完全磁盘访问权限 里打开「番茄猫」，然后回软件重试（必要时退出软件重开）。")
            step(4, "检测通过后：番茄搜索/榜单里命中的书会带红框和「短剧」角标，番茄详情里会显示 IP 数据条。")

            Text("（也支持 Chrome / Edge 等 Chromium 浏览器）")
                .font(FMTheme.Font.caption)
                .foregroundStyle(FMTheme.textSecondary)

            HStack(spacing: 8) {
                if needsFullDiskAccess {
                    Button("打开系统设置", action: onOpenSettings)
                        .fmButton(.primary)
                        .fmDebugFrame("sd-tutorial-open-settings")
                }
                Spacer(minLength: 0)
                Button("知道了", action: onClose)
                    .fmButton(.ghost)
            }
        }
        .padding(24)
        .frame(width: 470)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(FMTheme.Font.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(FMTheme.accent, in: Circle())
            Text(text)
                .font(FMTheme.Font.bodySmall)
                .foregroundStyle(FMTheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
