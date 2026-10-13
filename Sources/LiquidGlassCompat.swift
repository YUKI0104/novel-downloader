import SwiftUI

// ---------------------------------------------------------------------------
// Liquid Glass 兼容层（规格第 7 节）
//
// 真 Liquid Glass API（glassEffect / GlassEffectContainer / .buttonStyle(.glass)…）
// 只在 macOS 26+ 可用，而工程最低支持 macOS 14，所以把全部 `#available` 判断
// 收在这一个文件里：调用点统一写 fmGlass / FMGlassContainer / fmButtonStyle，
// 读起来仍然是同一套玻璃语义。
//
// macOS 26+：真玻璃（glassEffect + GlassEffectContainer + matchedGeometry 形变）
// macOS 14/15：回退到系统材质（.ultraThinMaterial / .bordered），视觉语义一致但不折射
// ---------------------------------------------------------------------------

enum FMGlassKind {
    /// 默认玻璃
    case regular
    /// 更通透的玻璃
    case clear
    /// 会随指针/按压产生交互反馈的玻璃
    case interactive
    /// 带 tint 的玻璃（番茄红强调、危险动作橙/红）
    case tinted(Color)
    /// 不渲染玻璃本体，只保留 glassEffectID 的形变身份（matchedGeometry 用）
    case identity
}

enum FMGlassTransitionKind {
    case matchedGeometry
    case materialize
    case identity
}

/// 一组玻璃控件的外壳：组内控件共享采样与形变，不各闪各的。
struct FMGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// 给控件加一层玻璃（规格 7.1：玻璃只用在控件层）。
    @ViewBuilder
    func fmGlass<S: Shape>(_ kind: FMGlassKind = .regular, in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(kind.coreGlass, in: shape)
        } else {
            switch kind {
            case .identity:
                self
            case .clear:
                self.background(.ultraThinMaterial, in: shape)
            case .interactive, .regular:
                self.background(.thinMaterial, in: shape)
            case .tinted(let color):
                self.background(.thinMaterial, in: shape)
                    .background(color.opacity(0.18), in: shape)
            }
        }
    }

    /// 玻璃形变身份：同一个 namespace 里同名 ID 的两块玻璃会互相衔接、形变。
    @ViewBuilder
    func fmGlassID(_ id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self
        }
    }

    /// 玻璃进出场方式（Q9 甲：搜索 → 详情用 .matchedGeometry）。
    @ViewBuilder
    func fmGlassTransition(_ kind: FMGlassTransitionKind) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffectTransition(kind.coreTransition)
        } else {
            self
        }
    }

    /// 把相邻的玻璃合并成同一块（顶栏的平台切换 + 搜索框用同一个 id 融成一个胶囊）。
    @ViewBuilder
    func fmGlassUnion(id: (some Hashable & Sendable)?, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffectUnion(id: id, namespace: namespace)
        } else {
            self
        }
    }

    /// 按钮分级：主操作用 prominent，次级动作用 glass（规格 7.3）。
    @ViewBuilder
    func fmButtonStyle(prominent: Bool = false, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            if let tint {
                if prominent {
                    self.buttonStyle(.glassProminent).tint(tint)
                } else {
                    self.buttonStyle(.glass).tint(tint)
                }
            } else if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if let tint {
                if prominent {
                    self.buttonStyle(.borderedProminent).tint(tint)
                } else {
                    self.buttonStyle(.bordered).tint(tint)
                }
            } else if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }
}

@available(macOS 26.0, *)
private extension FMGlassKind {
    var coreGlass: Glass {
        switch self {
        case .regular: .regular
        case .clear: .clear
        case .interactive: .regular.interactive()
        case .tinted(let color): .regular.tint(color)
        case .identity: .identity
        }
    }
}

@available(macOS 26.0, *)
private extension FMGlassTransitionKind {
    var coreTransition: GlassEffectTransition {
        switch self {
        case .matchedGeometry: .matchedGeometry
        case .materialize: .materialize
        case .identity: .identity
        }
    }
}
