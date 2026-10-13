import AppKit
import SwiftUI

/// 主页默认榜单区（对照旧版 index.html:68-99 的 `#rank-default` + main.js:128-266 + style.css:474-520）
///
///   · 频道行：综合热榜（默认 active）/ 男频 / 女频；「改编书单」属 M3 短剧线，这轮不放
///   · 频道=综合热榜：隐藏榜单类型/题材两个下拉，直接取 https://fanqienovel.com/rank
///   · 频道=男频/女频：显示「阅读榜/新书榜」与题材下拉，切任一项都重取
///   · 状态位文案：加载榜单… / TOP 10 · 综合热榜 · 番茄 / 暂无数据 / 加载榜单失败: <原因>
struct RankView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var platformStore = PlatformStore.shared
    @StateObject private var settingsStore = SettingsStore.shared

    /// M2-b：七猫榜单走 is_girl + rank_type（官网接口），频道按钮仍是 综合热榜/男频/女频
    private var isQimao: Bool { platformStore.platform == .qimao }

    /// M3-b：短剧模式关闭时，七猫「改编书单」入口隐藏（旧版 main.js:166-180）
    private var shortdramaEnabled: Bool { !settingsStore.settings.shortdramaIgnored }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            channelRow
            statusLine
            ResultsArea(items: model.rankBooks, ranked: true) { item in
                model.openDetail(item)
            }
        }
    }

    /// `.rank-row`：频道按钮 + 榜单类型/题材下拉同一行，gap 8，下边距 14
    private var channelRow: some View {
        HStack(spacing: 8) {
            if isQimao {
                // 七猫：只有 男生榜 / 女生榜（is_girl 0/1）。番茄的「综合热榜」和男频在七猫是同一种，去掉
                channelButton("男生榜", channel: "男频")
                channelButton("女生榜", channel: "女频")
            } else {
                channelButton("综合热榜", channel: "hot")
                channelButton("男频", channel: "男频")
                channelButton("女频", channel: "女频")
            }

            if isQimao {
                // 七猫：榜单类型 5 种（旧版 main.js:135 qimaoType；没有题材下拉）
                Picker("", selection: Binding(
                    get: { model.qimaoRankType },
                    set: { value in Task { await model.selectRankType(value) } }
                )) {
                    Text("大热榜").tag("1")
                    Text("新书榜").tag("2")
                    Text("完结榜").tag("3")
                    Text("收藏榜").tag("4")
                    Text("更新榜").tag("6")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)
            } else if model.rankChannel != "hot" {
                Picker("", selection: Binding(
                    get: { model.rankType },
                    set: { value in Task { await model.selectRankType(value) } }
                )) {
                    Text("阅读榜").tag("1")
                    Text("新书榜").tag("2")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)

                Picker("", selection: Binding(
                    get: { model.rankGenreIndex },
                    set: { value in Task { await model.selectRankGenre(value) } }
                )) {
                    ForEach(Array((model.currentRankGroup?.genres ?? []).enumerated()), id: \.offset) { index, genre in
                        Text(genre.name).tag(index)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 120)
            }
            if isQimao && shortdramaEnabled {
                Button("改编书单") {
                    model.mainView = .adapt
                    Task { await model.loadAdaptIfNeeded() }
                }
                .fmButton(.ghost)
                .help("官方剧本改编书单")
                .fmDebugFrame("adapt-entry")
            }
            Spacer(minLength: 0)
            // M13：刷新榜单按钮（用户红框位：分段行右侧、☰（显示方式切换）左侧的空位）
            refreshRankButton
            // M1.13：显示方式切换按钮搬到频道行最右端（右边缘 = 页面右边线 970，
            // 靠频道行已有的 .padding(.trailing, scrollSlot) 兜住）
            ViewModeToggleButton()
        }
        .padding(.bottom, 14)
        .padding(.trailing, FMLayout.scrollSlot) // 与网格同一条右基准线
        .fmDebugFrame("rank-channel-row")
    }

    /// `.rank-gender`（旧版频道按钮：36 高、圆角 10、active 蓝底白字）
    private func channelButton(_ title: String, channel: String) -> some View {
        let active = model.rankChannel == channel
        return Button {
            Task { await model.selectRankChannel(channel) }
        } label: {
            Text(title)
                .font(FMTheme.Font.bodySmall.weight(.semibold))
                .foregroundStyle(active ? Color.white : FMTheme.textSecondary)
                .padding(.horizontal, 18)
                .frame(height: 38) // M1.12：跟着字号抬一点
                .background(active ? FMTheme.accent : FMTheme.card, in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(active ? FMTheme.accent : FMTheme.separatorStrong, lineWidth: 1)
                )
                .shadow(color: FMTheme.shadowSm.color, radius: FMTheme.shadowSm.radius, y: FMTheme.shadowSm.y)
        }
        .buttonStyle(.plain)
        .fmDebugFrame("rank-channel-\(channel)")
    }

    /// M13：榜单刷新按钮（位置 = 分段行右侧、☰ 左侧的空位；搜索页不渲染本行，也就不会出现）。
    /// 样式与顶栏既有图标按钮**同款**：`.fmButton(.ghost, size: .square)` → 34×34 / 同圆角 / 同 hover。
    /// 点击 = 重拉当前频道榜单（保持 TOP10）；请求中图标淡出换成系统转圈 + 按钮禁用（防连点并发）。
    private var refreshRankButton: some View {
        Button {
            Task { await model.refreshRank() }
        } label: {
            // 图标与加载指示叠在同一占位里：加载中图标淡出、系统转圈淡入，
            // 占位尺寸恒定（Image 始终在），布局不因状态变化而抖动。
            ZStack {
                Image(systemName: Self.refreshSymbolName ?? Self.refreshSymbolFallback)
                    .font(FMTheme.Font.icon)
                    .opacity(model.rankIsLoading ? 0 : 1)
                if model.rankIsLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                }
            }
        }
        .fmButton(.ghost, size: .square)
        .help("刷新榜单")
        .disabled(model.rankIsLoading)
        .opacity(model.rankIsLoading ? 0.65 : 1)
        .fmDebugFrame("rank-refresh-button") // 取证：位置/尺寸/间距（34×34，右边界 ≤970）
        .fmDebugValue("rank-refresh-loading", model.rankIsLoading ? "loading" : "idle")
        .fmDebugValue("rank-refresh-symbol", Self.refreshSymbolName ?? Self.refreshSymbolFallback)
    }

    /// M13：刷新图标 SF Symbol 探活 —— `arrow.clockwise` 优先，不可用再回退 `arrow.triangle.2.circlepath`。
    /// （本机踩过「不存在的 symbol 渲染成空白按钮」的坑，所以先探活再上屏。）
    static let refreshSymbolName: String? = {
        for name in ["arrow.clockwise", "arrow.triangle.2.circlepath"]
        where NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil {
            return name
        }
        return nil
    }()
    /// 两个候选都不可用时的兜底符号（`arrow.clockwise` 在 macOS 11+ 恒在，这里只做防御性兜底）
    static let refreshSymbolFallback = "arrow.clockwise"

    /// `.status { min-height:20px; margin:6px 0 12px; font-size:13px }`（失败为红字）
    @ViewBuilder
    private var statusLine: some View {
        if !model.rankStatus.isEmpty {
            HStack(spacing: 10) {
                Text(model.rankStatus)
                    .font(FMTheme.Font.bodySmall)
                    .foregroundStyle(model.rankStatusIsError ? FMTheme.red : FMTheme.textSecondary)
                    .lineLimit(2)
                if model.rankStatusIsError {
                    Button("重试") {
                        Task { await model.reloadRank() }
                    }
                    .fmButton(.ghost, size: .small) // 旧版 .btn.ghost.small
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 22, alignment: .leading)
            .fmDebugFrame("rank-status-text") // 取证：状态行文字区（不含底部留白）
            .padding(.bottom, FMLayout.statusBottomGap)
            .padding(.trailing, FMLayout.scrollSlot) // 与网格同一条右基准线
            .fmDebugFrame("rank-status")
        }
    }
}
