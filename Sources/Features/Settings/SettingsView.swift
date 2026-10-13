import AppKit
import SwiftUI

/// 设置浮层（旧版设置页字段）：下载目录 / 短剧模式 / 番茄内核 / 诊断日志。
/// 不新增「更新内核」按钮：静默自动已覆盖。
///
/// M11（用户批注）：
///   · 删「保存格式」整行——两个平台默认只下 TXT（选项入口不再存在，链路上也一律按 TXT 处理）；
///   · 删「番茄内核」里的版本行 / 内核路径行 / 当前使用行，只留区块标题 +「立即检查更新」；
///   · 路径 / 说明类文字统一改用二级字号（`FMTheme.Font.meta`，14）。
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var shortdrama = ShortdramaStore.shared
    @StateObject private var settingsStore = SettingsStore.shared
    @State private var showKeychainSheet = false

    var body: some View {
        // 设置也用同一套实色模态面板（旧版没有设置弹窗，这里沿用弹窗外壳，不再用玻璃面板）
        FMModalPanel(width: 960, minHeight: 0) {
            withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = nil }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                Text("设置")
                    .font(FMTheme.Font.title)
                    .foregroundStyle(FMTheme.text)
                    .padding(.bottom, 16)

                VStack(alignment: .leading, spacing: 16) {
                    downloadDirRow
                    shortdramaRow
                    kernelRow
                    diagnosticRow
                }
            }
            .padding(28)
            .padding(.trailing, 30)
        }
        .sheet(isPresented: $showKeychainSheet) {
            ShortdramaKeychainSheet(onAuthorized: { Task { await shortdrama.refreshStatus() } })
        }
    }

    /// M3-b：短剧模式开关（开关 = 启用短剧 IP，持久化沿用旧键 `shortdramaIgnored`）。
    /// M3-d：开关显示 = 实际是否启用（`!ignored && prompted`）；打开时给使用教程 + 非模态登录态反馈。
    private var shortdramaRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("短剧模式", detail: "显示红果短剧后台的 IP 数据") {
                if shortdrama.needsFullDiskAccess {
                    Button("系统设置") { shortdrama.openFullDiskAccessSettings() }
                        .fmButton(.ghost, size: .small)
                        .fmDebugFrame("settings-open-fda")
                } else if shortdrama.keychainNeedsFix {
                    Button("钥匙串授权…") { showKeychainSheet = true }
                        .fmButton(.ghost, size: .small)
                }
                Button("检测登录态") {
                    Task {
                        let ok = await shortdrama.refreshStatus()
                        if !ok { shortdrama.showTutorial = true }
                    }
                }
                .fmButton(.ghost, size: .small)
                Button("使用教程") { shortdrama.showTutorial = true }
                    .fmButton(.ghost, size: .small)
                Toggle("", isOn: Binding(
                    // M3-d：显示必须等于实际是否启用，否则 prompted=false 时会看着像开着
                    get: { shortdrama.isEnabled },
                    set: { on in
                        // 旧版 SetShortdramaIgnored 同时把 shortdramaPrompted 置 true
                        shortdrama.setIgnored(!on)
                        if on {
                            Task {
                                await shortdrama.refreshStatus()
                                shortdrama.showTutorial = true // 打开就给教程引导去 Safari 登录
                            }
                        } else {
                            shortdrama.clearDetail()
                            // 旧版 switchPlatform：关掉短剧模式时，若在改编书单频道则回综合热榜
                            if model.mainView == .adapt { model.mainView = .rank }
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .fmDebugFrame("settings-shortdrama-toggle")
            }
            if !shortdrama.statusText.isEmpty {
                Text(shortdrama.statusText)
                    .font(FMTheme.Font.meta) // M11：说明类文字 = 二级字号
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 88)
                    .fmDebugFrame("settings-shortdrama-status")
            }
        }
    }

    private var downloadDirRow: some View {
        row("下载目录", detail: model.settings.settings.downloadDir) {
            Button("选择…") { pickDirectory() }.fmButton(.ghost)
            Button("打开") { model.revealDownloadDirectory() }.fmButton(.ghost)
        }
    }

    /// 规格 6.5：只留区块标题 +「立即检查更新」。
    /// M11：版本/检查状态行、内核路径行（输入框+选择+应用）、当前使用行按用户批注**删除**；
    /// 内核仍由 `KernelManager` 自动定位/自动更新，设置里的 `fanqieBin` 键保留给旧配置文件读取。
    private var kernelRow: some View {
        row("番茄内核", detail: nil) {
            Button("检测更新") {
                Task { await model.kernel.checkForUpdate() }
            }
            .fmButton(.ghost)
            .disabled(model.kernel.update == .checking)
        }
        .fmDebugFrame("settings-kernel-row")
    }

    private var diagnosticRow: some View {
        row("诊断日志", detail: FMLog.shared.path) {
            Button("导出") { model.exportDiagnostics() }.fmButton(.ghost)
        }
    }

    private func row<Actions: View>(
        _ title: String,
        detail: String?,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(FMTheme.Font.subheadline.weight(.semibold))
                .frame(width: 76, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if let detail {
                    // M11：路径/说明类文字 = 二级字号（`FMTheme.Font.meta` = 14）
                    Text(detail)
                        .font(FMTheme.Font.meta)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .fmDebugFrame("settings-detail-\(title)")
                }
            }
            Spacer()
            HStack(spacing: 8) { actions() }
        }
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择下载目录"
        panel.directoryURL = model.settings.downloadDir
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.update { $0.downloadDir = url.path }
        }
    }
}

/// 顶栏内核状态玻璃胶囊（规格 7.6）：启动中 / 更新中 / 就绪 + 版本。
/// 失败时可点开看原因并重试（一句话 + 一个明确动作）。
struct KernelStatusPill: View {
    @ObservedObject var manager: KernelManager
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            if case .failed = manager.phase {
                withAnimation(.snappy(duration: 0.25)) { model.activeOverlay = .kernelIssue }
            }
        } label: {
            HStack(spacing: 7) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(text).font(FMTheme.Font.caption).monospacedDigit()
                if manager.phase.isBusy { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .help(KernelUpdater.shared.statusLine(version: manager.version))
        .fmGlass(.clear, in: Capsule())
    }

    private var text: String {
        if let version = manager.version, manager.phase.isReady {
            return "内核 v\(version)"
        }
        return manager.phase.displayText
    }

    private var dotColor: Color {
        switch manager.phase {
        case .ready: .green
        case .starting, .updating: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }
}

/// 内核起不来时的一张小玻璃卡：一句话说明 + 一个明确动作。
struct KernelIssueOverlay: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        FMModalPanel(width: 520, minHeight: 0) {
            withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = nil }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color(hex: 0xFF9500))
                    Text("内核未就绪")
                        .font(FMTheme.Font.title)
                        .foregroundStyle(FMTheme.text)
                    Spacer(minLength: 0)
                }
                Text(model.kernel.lastFailureMessage ?? "内核没有启动成功。")
                    .font(FMTheme.Font.body)
                    .foregroundStyle(FMTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("可以重试启动；如果一直失败，点「打开日志目录」看内核日志。")
                    .font(FMTheme.Font.metaMono)
                    .foregroundStyle(FMTheme.textSecondary)
                HStack(spacing: 8) {
                    Button("重试启动") {
                        Task {
                            withAnimation(.easeOut(duration: 0.18)) { model.activeOverlay = nil }
                            await model.kernel.restart()
                        }
                    }
                    .fmButton(.primary)
                    Button("打开日志目录") { model.openLogs() }.fmButton(.ghost)
                    Spacer(minLength: 0)
                }
            }
            .padding(24)
            .padding(.trailing, 26)
        }
    }
}
