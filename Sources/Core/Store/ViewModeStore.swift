import Foundation

/// 结果区呈现方式：封面（相册）网格 / 列表。
/// 对应旧版 `frontend/src/main.js:104-121` 的 `albumMode`（localStorage 键 `novelViewMode`）。
enum FMViewMode: String, CaseIterable, Sendable {
    case album
    case list
}

/// 显示模式的唯一读写入口（写 UserDefaults，键与旧版 localStorage 同名，重启后仍生效）。
///
/// 旧版默认是列表（`localStorage.getItem('novelViewMode') === 'album'`，没有记录就是 list）；
/// M1.3 用户明确要求「以封面的形式呈现」，所以**首次（无记录）默认 = 相册/封面模式**，
/// 用户手动切过之后按记住的来。
@MainActor
final class ViewModeStore: ObservableObject {
    static let shared = ViewModeStore()

    private static let defaultsKey = "novelViewMode"

    @Published private(set) var mode: FMViewMode

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey)
        mode = raw == FMViewMode.list.rawValue ? .list : .album
        fmLog("显示模式：\(mode.rawValue)（UserDefaults novelViewMode=\(raw ?? "未设置→默认封面")）")
    }

    var isAlbum: Bool { mode == .album }

    /// 旧版 `#btn-view-toggle` 点击：切换 + 记住。
    func toggle() {
        set(isAlbum ? .list : .album)
    }

    func set(_ newMode: FMViewMode) {
        guard newMode != mode else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Self.defaultsKey)
        fmLog("显示模式切换为 \(newMode.rawValue)（已写入 UserDefaults novelViewMode）")
    }

    /// 相册模式下按钮显示「列表」图标（点它切到列表），反之亦然（旧版 applyViewMode）。
    var toggleIconName: String { isAlbum ? "list.bullet" : "square.grid.2x2" }
    var toggleTooltip: String { isAlbum ? "切换为列表模式" : "切换为相册模式" }
}
