import AppKit
import SwiftUI

/// 窗口背景层（Q8 乙：整窗玻璃化）。
///
/// 做法与教训：把 NSWindow 变非不透明（`WindowConfigurator`），背景用
/// `NSVisualEffectView(.underWindowBackground, .behindWindow)`——它**采样窗口背后的桌面**，
/// 是真正的「窗口玻璃」。
/// 注意：这里**不能**再铺一层整窗 `glassEffect`。macOS 26 会把 GlassEffectContainer 里的玻璃
/// 放到单独图层，整窗那块玻璃会盖在普通内容（列表/空状态文字）之上，
/// 结果是「玻璃风格控件清晰、正文糊成一团」——直接违反规格 7 的可读性红线。
/// 玻璃只留在控件层（顶栏、按钮、浮层、状态胶囊），内容层坐不透明材质面。
struct WindowBackdrop: View {
    var body: some View {
        VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// 把承载它的 NSWindow 配置成玻璃窗口：透明底、隐藏标题栏、可拖拽、固定 1000×820。
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { Self.fix(window: view.window) }
        return view
    }

    /// ⚠️ 这里**必须**什么都不做：在 updateNSView 里动窗口（改 styleMask/setFrame）
    /// 会触发 SwiftUI 重新布局 → 再次 update → 死循环，启动期会卡死在 SwiftUI body 求值里。
    /// 尺寸固定靠「初始 fix() + didResize 兜底 clamp」两处，足够。
    func updateNSView(_ nsView: NSView, context: Context) {}

    private static var clampInstalled = false
    private static var clamping = false

    /// 窗口固定成 1000×820（用户要求：软件尺寸不能改）。
    ///
    /// SwiftUI 的 `.windowResizability(.contentSize)` 会在我们配置完之后**再把**
    /// `.resizable` 加回来、把 min/max 重置（实测 max=NaN、resizable=true），
    /// 所以只在启动时设一次是不够的：这里用「事件兜底 + 0.5s 巡检」两条腿保证它一直是固定尺寸。
    /// 位置仍可拖动（`isMovableByWindowBackground`）；红叉退出行为（M1.9）不受影响。
    @MainActor
    static func fix(window: NSWindow?) {
        guard let window else { return }

        if !clampInstalled {
            clampInstalled = true
            // 1) 一被缩放就立刻掰回来（用户拖角/拖边都会触发）
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: nil, queue: .main
            ) { _ in
                // 必须异步一拍再动窗口：观察者可能在 SwiftUI 更新 AttributeGraph 的过程中被调用，
                // 同拍改窗口会和 SwiftUI 的图更新抢锁 → 启动期直接卡死（实测过）。
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let w = MainWindowRegistry.shared.window else { return }
                        enforce(w)
                    }
                }
            }
            // 2) 窗口被激活/取消缩放时再兜一次（都不在 SwiftUI 布局期，安全）
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didDeminiaturizeNotification, NSApplication.didBecomeActiveNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let w = MainWindowRegistry.shared.window else { return }
                            enforce(w)
                        }
                    }
                }
            }
            // 3) 1s 巡检纠偏。**不能**用 RunLoop 定时器：实测 .common 模式的重复定时器会在启动期
            //    与 SwiftUI 的 AttributeGraph 更新抢锁，把主线程卡死在 sceneList 求值里（4/4 复现）。
            //    用 MainActor 上的 Task.sleep 循环：只在主线程空闲时跑，天然不会和 SwiftUI 抢锁。
            Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let w = MainWindowRegistry.shared.window else { continue }
                    enforce(w)
                }
            }
        }

        let firstTime = MainWindowRegistry.shared.window == nil
        MainWindowRegistry.shared.window = window
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
        window.appearance = nil // 深浅色跟随系统
        enforce(window)

        if firstTime {
            let zoom = window.standardWindowButton(.zoomButton)
            fmLog("窗口固定 \(Int(FMLayout.windowWidth))×\(Int(FMLayout.windowHeight))：min=\(Int(window.minSize.width))×\(Int(window.minSize.height)) max=\(Int(window.maxSize.width))×\(Int(window.maxSize.height)) resizable=\(window.styleMask.contains(.resizable)) 绿按钮.isEnabled=\(zoom?.isEnabled ?? false) 可拖动=\(window.isMovableByWindowBackground)")
        }
    }

    /// 幂等地把窗口拉回 1000×820：尺寸 + min==max + 去掉 .resizable + 绿按钮禁用。
    /// 只在真的需要时写窗口，避免无谓地触发 SwiftUI 布局。
    @MainActor
    static func enforce(_ window: NSWindow) {
        guard !clamping else { return }
        let fixed = NSSize(width: FMLayout.windowWidth, height: FMLayout.windowHeight)
        let needs = window.frame.size != fixed
            || window.minSize != fixed
            || window.maxSize != fixed
            || window.styleMask.contains(.resizable)
            || (window.standardWindowButton(.zoomButton)?.isEnabled ?? false)

        window.minSize = fixed
        window.maxSize = fixed
        window.styleMask.remove(.resizable)
        window.standardWindowButton(.zoomButton)?.isEnabled = false

        guard needs else { return }
        if window.frame.size != fixed {
            let was = window.frame.size
            var frame = window.frame
            frame.origin.y += frame.height - fixed.height // 顶部不动，向下收
            frame.size = fixed
            clamping = true
            window.setFrame(frame, display: true)
            clamping = false
            fmLog("窗口尺寸被改动（\(Int(was.width))x\(Int(was.height))）→ 已强制回到 \(Int(fixed.width))×\(Int(fixed.height))")
        }
    }
}

/// 主窗口引用（M1.9）：关窗路径只对主窗口做「关窗即完全退出」，辅助窗口关掉不影响。
@MainActor
final class MainWindowRegistry {
    static let shared = MainWindowRegistry()
    weak var window: NSWindow?
    private init() {}
}

/// 内容层材质面（规格 7 的可读性红线）：列表/正文坐在这一层上，保证字读得清。
struct FMContentSurface: ViewModifier {
    var cornerRadius: CGFloat = 22
    var opacity: Double = 0.96

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(Color(nsColor: .textBackgroundColor).opacity(opacity), in: shape)
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .clipShape(shape)
    }
}

extension View {
    func fmContentSurface(cornerRadius: CGFloat = 22, opacity: Double = 0.96) -> some View {
        modifier(FMContentSurface(cornerRadius: cornerRadius, opacity: opacity))
    }
}
