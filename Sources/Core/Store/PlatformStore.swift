import Foundation

/// 平台（番茄 / 七猫）。M2-b 起共用的 SearchItem/BookInfo 都带 platform。
enum Platform: String, CaseIterable, Sendable, Hashable {
    case fanqie
    case qimao

    var displayName: String {
        switch self {
        case .fanqie: "番茄小说"
        case .qimao: "七猫小说"
        }
    }

    var shortName: String {
        switch self {
        case .fanqie: "番茄"
        case .qimao: "七猫"
        }
    }

    /// 书页链接（旧版 frontend/src/main.js:750 的 bookUrl 分支）
    func bookLink(bookID: String) -> URL {
        switch self {
        case .fanqie: URL(string: "https://fanqienovel.com/page/\(bookID)")!
        case .qimao: URL(string: "https://www.qimao.com/shuku/\(bookID)/")!
        }
    }
}

/// 当前平台（UserDefaults 键 `novelPlatform`，与 `novelViewMode` 同一套「界面偏好」写法）。
///
/// **七猫入口默认开放**（M2-c）：不设任何环境变量时，顶栏就是「番茄小说 | 七猫小说」两个 chip，
/// 首次打开/没有记录时默认选中番茄（老用户打开还是熟悉的样子）；用户上次选的是七猫则下次仍是七猫。
/// 兜底开关：应急时设 `FQM_DISABLE_QIMAO=1` 退回只有番茄的单平台形态。
@MainActor
final class PlatformStore: ObservableObject {
    static let shared = PlatformStore()

    /// 七猫入口开关（默认开；`FQM_DISABLE_QIMAO=1` 才关）
    static let qimaoEnabled = ProcessInfo.processInfo.environment["FQM_DISABLE_QIMAO"] != "1"

    private static let key = "novelPlatform"

    @Published private(set) var platform: Platform

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? ""
        // 没有记录 / 记录不认识 → 番茄（首次打开必须是番茄）
        let saved = Platform(rawValue: raw) ?? .fanqie
        // 兜底开关关着时一律番茄（即使上次存过七猫）
        platform = (saved == .qimao && !Self.qimaoEnabled) ? .fanqie : saved
    }

    func set(_ next: Platform) {
        guard next != .qimao || Self.qimaoEnabled else {
            fmLog("平台切换被忽略：七猫入口被 FQM_DISABLE_QIMAO=1 关闭")
            return
        }
        guard next != platform else { return }
        platform = next
        UserDefaults.standard.set(next.rawValue, forKey: Self.key)
        fmLog("平台切换：\(next.displayName)")
    }
}
