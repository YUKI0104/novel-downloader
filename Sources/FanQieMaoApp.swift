import SwiftUI

@main
struct FanQieMaoApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("番茄猫", id: "main") {
            RootView()
                .environmentObject(model)
                .background(WindowConfigurator())
                .task {
                    await model.launch()
                    // M1.8：全局 Esc（旧版 window 级 keydown）——与第一响应者/搜索框焦点无关
                    GlobalEscape.install { model.closeTopmostByEscape() }
                    KernelSelfTest.install(model: model)
                }
        }
        // 「软件尺寸保持这个大小，不能更改」：窗口固定 1000×820（min == max），绿色缩放按钮禁用
        .defaultSize(width: FMLayout.windowWidth, height: FMLayout.windowHeight)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
