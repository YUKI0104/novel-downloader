import AppKit
import Foundation

/// App 生命周期钩子：三条退出路径都要收干净内核（规格 5.4 / M1 任务书 1.2）。
///
/// C 的 `FanQieMaoApp.swift` 必须这样挂上（两行，别删）：
/// ```swift
/// @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
/// ```
/// 即使 C 忘了挂，`KernelManager` 自己也会监听 `willTerminateNotification` 兜底。
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    override init() {
        super.init()
        // 滚动指示器走覆盖式（浮在内容上、不占布局宽度）——旧版是 WKWebView 自带的覆盖式滚动条，观感一致。
        // `NSScroller.preferredScrollerStyle` 是只读的，要改只能改它读的那个偏好键；
        // 写进本 App 的注册域（register 不落盘、不动系统设置），只影响番茄猫自己。
        UserDefaults.standard.register(defaults: ["AppleShowScrollBars": "WhenScrolling"])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FMAppPaths.ensureDirectories()
        fmLog("番茄猫启动（pid \(ProcessInfo.processInfo.processIdentifier)）")
        fmLog("滚动指示器样式 preferred=\(NSScroller.preferredScrollerStyle == .overlay ? "overlay" : "legacy")  AppleShowScrollBars=\(UserDefaults.standard.string(forKey: "AppleShowScrollBars") ?? "未设置")")
        installSignalHandlers()
    }

    /// 关掉唯一窗口即退出 —— M1.9：红叉 = 完全退出进程（与旧版一致）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 自检开关：把它关掉就能单独验证「关窗兜底退出」那条路（模拟这个回调不触发的时序）
        if ProcessInfo.processInfo.environment["FQM_DISABLE_LASTWINDOW_TERMINATE"] != nil {
            fmLog("自检：禁用 applicationShouldTerminateAfterLastWindowClosed（只走关窗兜底）")
            return false
        }
        fmLog("最后窗口已关闭 → 要求退出（applicationShouldTerminateAfterLastWindowClosed）")
        return true
    }

    /// Cmd+Q / 正常退出路径。
    func applicationWillTerminate(_ notification: Notification) {
        fmLog("applicationWillTerminate：回收内核")
        KernelManager.shared.stopSync(reason: "applicationWillTerminate")
    }

    /// 额外保险：`kill <pid>`（SIGTERM/SIGINT/SIGHUP）也走正常退出流程回收内核。
    /// 只剩 `kill -9` 会留孤儿 —— 那种情况下次启动会接管，并在退出时收干净。
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                fmLog("收到信号 \(sig)，走正常退出流程")
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }

        // 关窗路径（不依赖 delegate 是否挂上）：
        //   1) 先回收内核；
        //   2) M1.9 修复「红叉关窗后只剩无窗口后台进程」——原来进程退出只靠
        //      applicationShouldTerminateAfterLastWindowClosed，该回调在「关窗通知已到、
        //      SwiftUI 仍持有（隐藏）窗口」这类时序下不触发，于是进程活着、没有窗口、内核也没了，
        //      用户看到的就是「软件不见了但没退出」。这里在最后一个可见窗口关掉后主动 terminate，
        //      与 Cmd+Q 走同一条收尾路径（applicationWillTerminate → 内核整组回收 → 进程退出）。
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { note in
            nonisolated(unsafe) let note = note // 观察者跑在 main 队列；Notification 本身不是 Sendable，这里显式声明「只在主线程用」
            MainActor.assumeIsolated {
                let closing = note.object as? NSWindow
                KernelManager.shared.stopSync(reason: "关窗")
                // 只认主窗口：辅助窗口（临时面板等）关掉不该退出 app
                guard let closing, closing === MainWindowRegistry.shared.window else { return }
                self.quitAfterMainWindowClosed(attempt: 0)
            }
        }
    }

    /// 主窗口关掉后完全退出进程（红叉 / Cmd+W 语义，与旧版一致）。
    ///
    /// 窗口销毁/状态收敛是异步的，所以延时清点：只要还有可见窗口就再等一拍（最多 6 拍）。
    /// 这样「启动后 1 秒就点红叉」这类时序也不会留下无窗口后台进程。
    private func quitAfterMainWindowClosed(attempt: Int) {
        guard attempt < 6 else {
            let visible = NSApp.windows.filter { $0.isVisible }
            fmLog("主窗口已关但仍有 \(visible.count) 个可见窗口，放弃自动退出：\(visible.map { "\(type(of: $0))\"\($0.title)\"" }.joined(separator: ", "))")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                let visible = NSApp.windows.filter { $0.isVisible }
                guard visible.isEmpty else {
                    fmLog("主窗口关闭中…还剩 \(visible.count) 个可见窗口（\(visible.map { "\(type(of: $0))\"\($0.title)\"" }.joined(separator: ", "))），第 \(attempt + 1) 次等待")
                    self.quitAfterMainWindowClosed(attempt: attempt + 1)
                    return
                }
                fmLog("主窗口已关闭 → 完全退出进程（pid \(ProcessInfo.processInfo.processIdentifier)）")
                NSApp.terminate(nil)
            }
        }
    }
}
