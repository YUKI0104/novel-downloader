import AppKit

/// 全局 Esc（等价旧版 index.html 的 `window.addEventListener('keydown', … "Escape" …)`）。
///
/// M1.8 回归修复：之前 Esc 走的是 `FMModalPanel` 上隐藏按钮的 `.keyboardShortcut(.cancelAction)`，
/// 那是**第一响应者链**上的快捷键 —— 搜索框（NSTextField 的 field editor）持焦点时，
/// Esc 先被文本域当成 `cancelOperation:` 吃掉，弹窗关不掉；旧版是 window 级 keydown，
/// 不管焦点在哪都关最上层弹窗。
///
/// 这里用 AppKit 的 local event monitor：事件在派发给窗口/响应者链**之前**经过它，
/// 所以与焦点无关；只有真正关掉了一层弹窗才吞掉事件（`return nil`），
/// 没有弹窗时原样放行（不碰任何其它键、不影响搜索框里的 Esc 行为）。
@MainActor
enum GlobalEscape {
    private static var monitor: Any?

    /// 安装（重复调用只装一次）。`handle` 返回是否关掉了一层弹窗。
    static func install(_ handle: @escaping () -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 只认 Esc（keyCode 53）；长按重复、其它修饰键组合一律不进这个门
            guard event.keyCode == 53, !event.isARepeat else { return event }
            let closed = MainActor.assumeIsolated { handle() }
            return closed ? nil : event
        }
    }

    static func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
