import SwiftUI

/// 顶栏（规格 7.2 / 旧版 index.html 的 `.search-bar` 一行）：
/// 平台胶囊 + 搜索框 + 封面/列表切换 + 内核状态胶囊 + 下载 / 设置。
///
/// 横向 padding 由 RootView 统一下发（`FMLayout.leadingInset/trailingInset`），
/// 这样结果区与顶栏最左/最右元素天然落在同一条基准线上（M1.3 第 1 条）。
struct TopBar: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var platformStore = PlatformStore.shared

    var body: some View {
        HStack(spacing: 10) {
            platformSwitch
            searchField
            // M1.13：显示方式切换按钮已搬到榜单频道行最右端 —— 这里原来那块位置留空（用户要求不补别的东西）
            Spacer(minLength: 8)
            // M5：内核状态灰字 → 🕘最近查看 → ⬇下载 → ⚙设置，三个图标按钮 34×34、间距 12
            HStack(spacing: 12) {
                KernelStatusPill(manager: model.kernel)
                    .fmDebugFrame("topbar-kernel")
                historyButton
                downloadsButton
                settingsButton
            }
        }
        .padding(.vertical, 10)
        .padding(.trailing, FMLayout.scrollSlot) // 让出右侧滚动槽，齿轮右边缘落在 rightLine
        .fmDebugFrame("topbar")
    }

    /// M2-c：番茄 | 七猫 平台切换。**默认两个 chip 都在**（默认选中番茄），
    /// 只有兜底开关 `FQM_DISABLE_QIMAO=1` 时才退回单番茄胶囊。
    private var platformSwitch: some View {
        HStack(spacing: 4) {
            platformChip(.fanqie)
            if PlatformStore.qimaoEnabled {
                platformChip(.qimao)
            }
        }
        .padding(4)
        .fmGlass(.regular, in: Capsule())
        .fmDebugFrame("topbar-left")
    }

    private func platformChip(_ target: Platform) -> some View {
        let selected = platformStore.platform == target
        return Button {
            guard !selected else { return }
            platformStore.set(target)
            Task { await model.platformChanged() }
        } label: {
            Text(target.displayName)
                .font(FMTheme.Font.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help(target.displayName)
        .fmDebugFrame("platform-chip-\(target.rawValue)")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("输入书名或关键词…", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(FMTheme.Font.body)
                .onSubmit { Task { await model.submitSearch() } }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            if model.searchState == .searching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minWidth: 300, maxWidth: 460)
        .fmGlass(.regular, in: Capsule())
        .fmDebugFrame("topbar-search")
    }

    /// 旧版 `#btn-view-toggle`：位置在搜索框右侧、ghost 按钮、图标 grid/list 互换、有 tooltip。
    /// M5：去掉「下载」文字，只留图标（34×34，与设置齿轮完全同款）。
    private var downloadsButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = .downloads }
        } label: {
            Image(systemName: "arrow.down.circle")
        }
        .fmButton(.ghost, size: .square)
        .help("下载")
        // 进行中的下载数仍以右上角小角标显示（不占按钮布局，按钮本身仍是 34×34 纯图标）
        .overlay(alignment: .topTrailing) {
            if model.downloads.activeCount > 0 {
                Text("\(model.downloads.activeCount)")
                    .font(FMTheme.Font.caption.monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.accentColor, in: Capsule())
                    .offset(x: 5, y: -5)
            }
        }
        .fmDebugFrame("topbar-downloads")
    }

    /// M5：最近查看入口（纯图标 34×34，与下载/设置同款）。
    private var historyButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = .history }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .fmButton(.ghost, size: .square)
        .help("最近查看")
        .fmDebugFrame("topbar-history")
    }

    private var settingsButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = .settings }
        } label: {
            Image(systemName: "gearshape")
        }
        .fmButton(.ghost, size: .square)
        .help("设置")
        .fmDebugFrame("topbar-right")
    }
}

/// 显示方式切换按钮（封面/列表）—— M1.13 从顶栏搬到榜单频道行最右端，外观与功能不变。
struct ViewModeToggleButton: View {
    @StateObject private var viewMode = ViewModeStore.shared

    var body: some View {
        Button {
            viewMode.toggle()
        } label: {
            Image(systemName: viewMode.toggleIconName)
                .font(FMTheme.Font.icon)
                .frame(width: 40) // 旧版 .btn-view { width:40px; padding:0 }
        }
        .fmButton(.ghost, size: .icon)
        .help(viewMode.toggleTooltip)
        .accessibilityLabel(viewMode.toggleTooltip)
        .fmDebugFrame("viewmode-toggle")
    }
}
