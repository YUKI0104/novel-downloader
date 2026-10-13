import AppKit
import SwiftUI

// ---------------------------------------------------------------------------
// 弹窗基础件：1:1 复刻旧版 Wails 的模态弹窗（只读参照）
//   index.html 113-191（lib/detail/confirm）+ style.css 5-60（变量）588-760（弹窗）978-1005（确认）
//
// 硬性口径（任务书 M1.1 第 2 节）：
//   遮罩 = 铺满整窗 rgba(0,0,0,.30) + 模糊 8px，点空白关闭，淡入 .2s
//   面板 = 实色（浅色 #ffffff / 深色 #2c2c2e）、圆角 18、边框 1px separator、shadow-lg、淡入微弹 .2s
//   关闭 = 右上 16/16 的 30×30 圆形按钮（底 fill、字次要灰、字号 14）
// 这里**不出现任何 glassEffect**：面板必须实色，字必须读得清。
// ---------------------------------------------------------------------------

/// style.css `:root` 的变量（浅色 / 深色两套）
enum FMTheme {
    /// 全局字号表（M1.12）。**以后调字号只改这里**。
    /// 规则：原来的 size 全部 +2pt，其中 ≥20pt 的标题 +4pt。
    /// 括号里是改前的值。
    /// M1.11/M1.12：详情弹窗与下载管理弹窗的**固定尺寸**（改这一处两个弹窗一起变）
    static let modalWidth: CGFloat = 950
    static let modalHeight: CGFloat = 600

    enum Font {
        static let display = SwiftUI.Font.system(size: 38, weight: .light)      // 34 → 38（空态大图标字）
        static let detailTitle = SwiftUI.Font.system(size: 26, weight: .bold)   // 22 → 26（详情书名）
        static let rankNumber = SwiftUI.Font.system(size: 20, weight: .bold)    // 18 → 20（列表序号）
        static let title = SwiftUI.Font.system(size: 19, weight: .semibold)     // 17 → 19（弹窗标题）
        static let icon = SwiftUI.Font.system(size: 18)                         // 16 → 18（顶栏图标）
        static let sectionSmall = SwiftUI.Font.system(size: 17, weight: .medium)// 15 → 17（小标题行）
        static let control = SwiftUI.Font.system(size: 16, weight: .medium)     // 14 → 16（普通按钮/胶囊/toast）
        static let body = SwiftUI.Font.system(size: 15.5)                       // 13.5 → 15.5（正文/简介）
        static let cardTitle = SwiftUI.Font.system(size: 15.5, weight: .semibold) // 13.5 → 15.5（卡片/列表书名）
        static let bodySmall = SwiftUI.Font.system(size: 15)                    // 13 → 15（状态行/小按钮/说明）
        static let button = SwiftUI.Font.system(size: 15, weight: .medium)      // 13 → 15（ghost.small 按钮）
        static let chip = SwiftUI.Font.system(size: 14.5, weight: .medium)      // 12.5 → 14.5（统计 chip）
        static let metaMono = SwiftUI.Font.system(size: 14.5, design: .monospaced) // 12.5 → 14.5（ID 行）
        static let meta = SwiftUI.Font.system(size: 14)                         // 12 → 14（作者/次要信息）
        static let caption = SwiftUI.Font.system(size: 12)                      // 语义 .caption/.caption2(10) → 12
        static let micro = SwiftUI.Font.system(size: 13.5)                      // 11.5 → 13.5（最小号）
        static let subheadline = SwiftUI.Font.system(size: 13)                   // 语义 .subheadline(11) → 13
    }


    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    static let card = dynamic(light: NSColor(hex: 0xFFFFFF), dark: NSColor(hex: 0x2C2C2E))
    static let fill = dynamic(
        light: NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.10),
        dark: NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.20)
    )
    static let separator = dynamic(
        light: NSColor(srgbRed: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.14),
        dark: NSColor(srgbRed: 84 / 255, green: 84 / 255, blue: 88 / 255, alpha: 0.42)
    )
    static let separatorStrong = dynamic(
        light: NSColor(srgbRed: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.24),
        dark: NSColor(srgbRed: 84 / 255, green: 84 / 255, blue: 88 / 255, alpha: 0.60)
    )
    static let text = dynamic(light: NSColor(hex: 0x1D1D1F), dark: NSColor(hex: 0xF5F5F7))
    static let textSecondary = dynamic(light: NSColor(hex: 0x6E6E73), dark: NSColor(hex: 0x98989D))
    static let textTertiary = dynamic(light: NSColor(hex: 0x98989D), dark: NSColor(hex: 0x6E6E73))
    static let accent = Color(hex: 0x0A84FF)
    static let accentHover = dynamic(light: NSColor(hex: 0x0071E3), dark: NSColor(hex: 0x409CFF))
    static let red = dynamic(light: NSColor(hex: 0xFF3B30), dark: NSColor(hex: 0xFF453A))
    static let redBg = dynamic(
        light: NSColor(srgbRed: 1, green: 59 / 255, blue: 48 / 255, alpha: 0.10),
        dark: NSColor(srgbRed: 1, green: 69 / 255, blue: 58 / 255, alpha: 0.16)
    )
    static let green = dynamic(light: NSColor(hex: 0x34C759), dark: NSColor(hex: 0x30D158))
    static let greenBg = dynamic(
        light: NSColor(srgbRed: 52 / 255, green: 199 / 255, blue: 89 / 255, alpha: 0.12),
        dark: NSColor(srgbRed: 48 / 255, green: 209 / 255, blue: 88 / 255, alpha: 0.16)
    )
    /// M5.1「最近查看」平台标签：七猫＝靛蓝系（番茄用上面的 red/redBg）
    static let indigo = dynamic(light: NSColor(hex: 0x4C5BD4), dark: NSColor(hex: 0x8B94F5))
    static let indigoBg = dynamic(
        light: NSColor(srgbRed: 76 / 255, green: 91 / 255, blue: 212 / 255, alpha: 0.12),
        dark: NSColor(srgbRed: 139 / 255, green: 148 / 255, blue: 245 / 255, alpha: 0.18)
    )

    static let radiusLg: CGFloat = 18
    static let radius: CGFloat = 12
    static let radiusSm: CGFloat = 8
    static let radiusBtn: CGFloat = 9

    static let shadowSm = (color: Color.black.opacity(0.06), radius: 1.5, y: 1.0)
    static let shadowMd = (color: Color.black.opacity(0.14), radius: 10.0, y: 6.0)
    static let shadowLg = (color: Color.black.opacity(0.28), radius: 32.0, y: 24.0)
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

// MARK: - 按钮（.btn / .btn.primary / .btn.ghost / .btn.danger / .small / .big）

struct FMButtonStyle: ButtonStyle {
    enum Kind { case primary, ghost, danger }
    /// `square` = M5 顶栏图标按钮：固定 34×34、纯图标（与齿轮/下载/最近查看同款）。
    enum Size { case normal, small, big, icon, square }

    var kind: Kind = .ghost
    var size: Size = .normal

    func makeBody(configuration: Configuration) -> some View {
        let (foreground, background, border): (Color, Color, Color) = {
            switch kind {
            case .primary: (Color.white, FMTheme.accent, Color.clear)
            case .ghost: (FMTheme.text, FMTheme.card, FMTheme.separatorStrong)
            case .danger: (FMTheme.red, FMTheme.card, FMTheme.separatorStrong)
            }
        }()
        let padding: (h: CGFloat, v: CGFloat) = switch size {
        case .normal: (18, 9)
        case .small: (12, 6)
        case .big: (34, 0)
        case .icon: (0, 9) // 旧版 .btn-view { width:40px; padding:0 }
        case .square: (0, 0)
        }
        let font: Font = switch size {
        case .normal: FMTheme.Font.control
        case .small: FMTheme.Font.button
        case .big: .system(size: 18, weight: .semibold) // 16 → 18（大按钮）
        case .icon, .square: FMTheme.Font.control
        }
        // M5：方形图标按钮固定 34×34（顶栏三个图标按钮同尺寸）
        let square: CGFloat? = size == .square ? 34 : nil

        return configuration.label
            .font(font)
            .foregroundStyle(foreground)
            .frame(width: square, height: square)
            .padding(.horizontal, padding.h)
            .frame(height: size == .big ? 48 : nil)
            .padding(.vertical, size == .big ? 0 : padding.v)
            .background(
                (configuration.isPressed && kind != .primary
                    ? FMTheme.fillHoverColor
                    : background),
                in: RoundedRectangle(cornerRadius: size == .big ? FMTheme.radius : FMTheme.radiusBtn)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size == .big ? FMTheme.radius : FMTheme.radiusBtn)
                    .strokeBorder(border, lineWidth: border == .clear ? 0 : 1)
            )
            .shadow(color: FMTheme.shadowSm.color, radius: FMTheme.shadowSm.radius, y: FMTheme.shadowSm.y)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension FMTheme {
    /// hover/按下的填充色（rgba(120,120,128,.18)）
    static var fillHoverColor: Color {
        dynamic(
            light: NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.18),
            dark: NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: 0.30)
        )
    }
}

extension View {
    func fmButton(_ kind: FMButtonStyle.Kind = .ghost, size: FMButtonStyle.Size = .normal) -> some View {
        buttonStyle(FMButtonStyle(kind: kind, size: size))
    }
}

// MARK: - chip（.chip / .chip.green / .chip.gold / .chip.stat）

struct FMChip: View {
    var text: String
    var tone: Tone = .plain
    var stat = false

    enum Tone { case plain, green, gold, red, accent }

    var body: some View {
        Text(text)
            .font(stat ? FMTheme.Font.chip : FMTheme.Font.meta)
            .foregroundStyle(foreground)
            .padding(.horizontal, stat ? 10 : 9)
            .padding(.vertical, stat ? 3 : 2)
            .background(background, in: RoundedRectangle(cornerRadius: 7))
            .fixedSize()
    }

    private var foreground: Color {
        switch tone {
        case .plain: FMTheme.textSecondary
        case .green: FMTheme.green
        case .gold: Color(hex: 0xFF9500)
        case .red: FMTheme.red
        case .accent: FMTheme.accent   // M11：短剧后台等级标签（精品IP）用强调色
        }
    }

    private var background: Color {
        switch tone {
        case .plain: FMTheme.fill
        case .green: FMTheme.greenBg
        case .gold: Color(hex: 0xFF9500).opacity(0.16)
        case .red: FMTheme.redBg
        case .accent: FMTheme.accent.opacity(0.14)
        }
    }
}

// MARK: - 遮罩 + 面板 + 关闭按钮

/// 遮罩：铺满整窗 rgba(0,0,0,.30) + 8px 模糊；点空白关闭。
struct FMModalScrim: View {
    var onTap: () -> Void

    var body: some View {
        Color.black.opacity(0.30)
            .background(.ultraThinMaterial) // 材质自带模糊，对应旧版 backdrop-filter blur(8px)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }
}

/// 面板外壳：实色卡片 + 圆角 18 + 1px 边框 + shadow-lg；右上 30×30 圆形关闭按钮。
struct FMModalPanel<Content: View>: View {
    /// 旧版 CSS 是 `width: min(960px, 100vw - 40px)`：这里是**定宽**，窄窗由外层 padding(20) 兜住
    var width: CGFloat = 960
    /// 固定高度：给了就是**死高度**（详情弹窗 950×600 用）；不给则按 minHeight + 内容自适应（下载/确认弹窗不变）
    var fixedHeight: CGFloat? = nil
    var minHeight: CGFloat = 480
    var maxHeightExtra: CGFloat? = nil // 下载面板需要撑高时给 .infinity
    var cornerRadius: CGFloat = FMTheme.radiusLg
    var showsCloseButton = true
    var onClose: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: width, alignment: .top)
            .frame(height: fixedHeight, alignment: .top)   // nil = 不限制（自适应）
            .frame(maxHeight: maxHeightExtra)
            .frame(minHeight: minHeight)
            .background(FMTheme.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(FMTheme.separator, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: FMTheme.shadowLg.color, radius: FMTheme.shadowLg.radius, y: FMTheme.shadowLg.y)
            .fmDebugFrame("modal-panel") // 取证：面板自身 frame（宽度/高度/居中留白）
            .fmMeasure(FMPanelHeightKey.self)
            .onPreferenceChange(FMPanelHeightKey.self) { FMMetrics.report("panel", $0) }
            .overlay(alignment: .topTrailing) {
                if showsCloseButton {
                    Button {
                        onClose()
                    } label: {
                        Text("✕")
                            .font(FMTheme.Font.control)
                            .foregroundStyle(FMTheme.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(FMTheme.fill, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction) // Esc
                    .fmDebugFrame("modal-close-button") // 取证：✕ 按钮中心（M1.8 关闭路径矩阵用）
                    .padding(16)
                    .help("关闭")
                }
            }
    }
}

// MARK: - 通用确认弹窗（旧版 #confirm-backdrop）

struct FMConfirmDialog: View {
    var title: String
    var message: String
    var cancelTitle: String = "取消"
    var onCancel: () -> Void
    var actions: [Action]

    struct Action: Identifiable {
        let id = UUID()
        var title: String
        var kind: FMButtonStyle.Kind
        var handler: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(FMTheme.Font.title)
                .foregroundStyle(FMTheme.text)
            Text(message)
                .font(FMTheme.Font.body)
                .lineSpacing(4.5) // 行高 1.7
                .foregroundStyle(FMTheme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(FMTheme.fill, in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 12)
                .padding(.bottom, 18)
            HStack(spacing: 8) {
                Spacer()
                ForEach(actions) { action in
                    Button(action.title) { action.handler() }
                        .fmButton(action.kind)
                }
                Button(cancelTitle, action: onCancel)
                    .fmButton(.ghost)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
    }
}

// MARK: - 进度条（.progress / .progress-bar / .progress-text）

struct FMProgressBar: View {
    var fraction: Double
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(FMTheme.fill)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(FMTheme.accent)
                        .frame(width: max(0, min(1, fraction)) * proxy.size.width)
                }
            }
            .frame(height: 6)
            Text(text)
                .font(FMTheme.Font.caption)
                .foregroundStyle(FMTheme.textSecondary)
        }
    }
}

// MARK: - 尺寸测量（M1.2：面板按内容定高、封面高度 = 右列高度）

/// 调试用：`FQM_DEBUG_METRICS=1` 时把量到的尺寸打到 stdout（取证用，不影响界面）
enum FMMetrics {
    static let enabled = ProcessInfo.processInfo.environment["FQM_DEBUG_METRICS"] != nil
    private static let verbose = ProcessInfo.processInfo.environment["FQM_DEBUG_METRICS"] == "verbose"

    /// 最后一次量到的值（供取证时一次性打出结论）
    nonisolated(unsafe) private(set) static var last: [String: CGFloat] = [:]

    static func report(_ name: String, _ value: CGFloat) {
        last[name] = value
        guard enabled, verbose else { return }
        print("FQM_METRICS \(name)=\(String(format: "%.1f", value))")
        fflush(stdout)
    }

    /// `cover=360.0 info=360.0 panel=468.0 descText=212.0 list=94.0`
    static func summary() -> String {
        ["cover", "info", "panel", "descText", "list"]
            .compactMap { key in last[key].map { "\(key)=\(String(format: "%.1f", $0))" } }
            .joined(separator: " ")
    }
}

/// 取证用：把控件/卡片的 frame（.global）打出来，验证左右基准线对齐（M1.3）
enum FMFrameMetrics {
    nonisolated(unsafe) private(set) static var last: [String: CGRect] = [:]
    private static let verbose = ProcessInfo.processInfo.environment["FQM_DEBUG_METRICS"] == "verbose"

    static func report(_ name: String, _ rect: CGRect) {
        guard !name.isEmpty else { return }
        last[name] = rect
        guard FMMetrics.enabled, verbose else { return }
        print("FQM_FRAME \(name) minX=\(fmt(rect.minX)) maxX=\(fmt(rect.maxX)) w=\(fmt(rect.width)) h=\(fmt(rect.height))")
        fflush(stdout)
    }

    static func reportSize(_ name: String, _ size: CGSize) {
        lastSize[name] = size
        guard FMMetrics.enabled, verbose else { return }
        print("FQM_SIZE \(name) w=\(fmt(size.width)) h=\(fmt(size.height))")
        fflush(stdout)
    }

    nonisolated(unsafe) private(set) static var lastSize: [String: CGSize] = [:]
    /// 取证用：随状态变化的**文案**（如详情页下载按钮当前显示「下载/下载中…/打开」）。
    /// frame 只能证明「有个控件在这儿」，值上报才能证明「屏幕上真的显示了这几个字」。
    nonisolated(unsafe) private(set) static var lastValue: [String: String] = [:]

    static func reportValue(_ name: String, _ value: String) {
        lastValue[name] = value
        guard FMMetrics.enabled, verbose else { return }
        print("FQM_VALUE \(name)=\(value)")
        fflush(stdout)
    }

    /// 取证用：清空已量到的 frame/尺寸/文案。判定「某个控件不存在」时必先清一次，
    /// 否则会读到上一次渲染留下的旧值（视图消失不会上报变化）。
    static func clear() {
        last.removeAll()
        lastSize.removeAll()
        lastValue.removeAll()
    }

    static func fmt(_ value: CGFloat) -> String { String(format: "%.1f", value) }

    /// `左：顶栏 78.0 / 结果 78.0（Δ0.0）　右：结果 1166.0 / 顶栏 1166.0（Δ0.0）`
    static func alignment(_ leftName: String, _ rightName: String) -> String {
        let barLeft = last["topbar-left"]?.minX
        let barRight = last["topbar-right"]?.maxX
        let resLeft = last[leftName]?.minX
        let resRight = last[rightName]?.maxX
        func delta(_ a: CGFloat?, _ b: CGFloat?) -> String {
            guard let a, let b else { return "?" }
            return fmt(abs(a - b))
        }
        return "左 顶栏=\(barLeft.map(fmt) ?? "?") 结果=\(resLeft.map(fmt) ?? "?") Δ=\(delta(barLeft, resLeft))"
            + " ｜ 右 结果=\(resRight.map(fmt) ?? "?") 顶栏=\(barRight.map(fmt) ?? "?") Δ=\(delta(resRight, barRight))"
    }
}

extension View {
    /// 上报自身 frame 到 FMFrameMetrics（只在 FQM_DEBUG_METRICS 下打日志）
    /// 取证：报告 .global frame（对齐用）+ 附加报告「尺寸不受过渡动画缩放影响」的 .local bounds。
    /// 弹窗做入场动画（scale 0.96→1）时 .global 会被缩放影响，量尺寸要用 `name#size`。
    func fmDebugFrame(_ name: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        FMFrameMetrics.report(name, proxy.frame(in: .global))
                        FMFrameMetrics.reportSize(name + "#size", proxy.size)
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, rect in FMFrameMetrics.report(name, rect) }
                    .onChange(of: proxy.size) { _, size in FMFrameMetrics.reportSize(name + "#size", size) }
            }
        )
    }

    /// 取证用：上报一段**随状态变化的文案**（首帧 + 每次变化），供自检断言渲染内容。
    func fmDebugValue(_ name: String, _ value: String) -> some View {
        onAppear { FMFrameMetrics.reportValue(name, value) }
            .onChange(of: value) { _, newValue in FMFrameMetrics.reportValue(name, newValue) }
    }
}

protocol FMHeightPreference: PreferenceKey where Value == CGFloat {}

extension FMHeightPreference {
    static var defaultValue: CGFloat { 0 }
    /// 取 max：测量是「先窄后宽」地收敛的（封面宽度随信息高度增大 → 信息列变窄 → 文字更高），
    /// 单向增长所以 max 能稳定收敛；用 last-wins 会被重排过程中的瞬时 0 覆盖成 0。
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// 右列信息高度（ID 行→统计 chip→简介块→下载按钮行）
struct FMInfoHeightKey: FMHeightPreference {}
/// 简介文字本身的自然高度
struct FMDescHeightKey: FMHeightPreference {}
/// 下载列表自然高度
struct FMListHeightKey: FMHeightPreference {}
/// 面板总高
struct FMPanelHeightKey: FMHeightPreference {}

extension View {
    /// 把自身高度上报给指定 PreferenceKey
    func fmMeasure<K: PreferenceKey>(_ key: K.Type) -> some View where K.Value == CGFloat {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: K.self, value: proxy.size.height)
            }
        )
    }
}

// MARK: - 弹窗进出场动画（fadeIn .2s / popIn .22s cubic-bezier(.2,.9,.3,1.1)）

extension AnyTransition {
    static var fmModalScrim: AnyTransition {
        .opacity.animation(.easeOut(duration: 0.20))
    }

    static var fmModalPanel: AnyTransition {
        .scale(scale: 0.96, anchor: .center)
            .combined(with: .opacity)
            .animation(.spring(response: 0.26, dampingFraction: 0.78))
    }
}
