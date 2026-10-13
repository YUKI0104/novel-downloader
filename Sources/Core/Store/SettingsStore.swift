import Foundation

/// 与旧版 Wails 版完全一致的 settings.json（键名不动，老文件直接能读）。
/// 对照 `app.go: Settings / loadSettings / saveSettings`。
struct FMSettings: Codable, Sendable, Equatable {
    var downloadDir: String
    var format: String
    var fanqieBin: String
    var shortdramaIgnored: Bool
    var shortdramaPrompted: Bool

    static var `default`: FMSettings {
        FMSettings(
            downloadDir: FMAppPaths.home.appending(path: "Downloads").path,
            format: "txt",
            fanqieBin: "",
            shortdramaIgnored: false,
            shortdramaPrompted: false
        )
    }

    /// 键缺失时用默认值（旧文件/手改文件都能读）。未知键忽略，但写入时键集合与旧版一致。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = FMSettings.default
        if let v = try? c.decodeIfPresent(String.self, forKey: .downloadDir) { downloadDir = v } else { downloadDir = fallback.downloadDir }
        if let v = try? c.decodeIfPresent(String.self, forKey: .format) { format = Self.normalizedFormat(v) } else { format = fallback.format }
        if let v = try? c.decodeIfPresent(String.self, forKey: .fanqieBin) { fanqieBin = v } else { fanqieBin = fallback.fanqieBin }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .shortdramaIgnored) { shortdramaIgnored = v } else { shortdramaIgnored = fallback.shortdramaIgnored }
        if let v = try? c.decodeIfPresent(Bool.self, forKey: .shortdramaPrompted) { shortdramaPrompted = v } else { shortdramaPrompted = fallback.shortdramaPrompted }
    }

    init(
        downloadDir: String,
        format: String,
        fanqieBin: String,
        shortdramaIgnored: Bool,
        shortdramaPrompted: Bool
    ) {
        self.downloadDir = downloadDir
        self.format = format
        self.fanqieBin = fanqieBin
        self.shortdramaIgnored = shortdramaIgnored
        self.shortdramaPrompted = shortdramaPrompted
    }

    enum CodingKeys: String, CodingKey {
        case downloadDir, format, fanqieBin, shortdramaIgnored, shortdramaPrompted
    }

    /// M11：设置页已删「保存格式」——两个平台一律 TXT。
    /// 旧 `settings.json` 里如果存过 `epub`，载入/写入时一律归一为 `txt`
    /// （不用「选了但没入口」的悬挂状态；七猫 EPUB 写出能力仍在 `QimaoClient` 里，只给开发探针用）。
    static func normalizedFormat(_ raw: String) -> String {
        raw.lowercased() == "epub" ? "txt" : (raw.isEmpty ? "txt" : raw.lowercased())
    }
}

/// 设置的唯一写盘入口（规格第 3 节）。
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published private(set) var settings: FMSettings

    private let fileURL = FMAppPaths.settingsFile

    private init() {
        settings = Self.load(from: FMAppPaths.settingsFile)
    }

    /// 下载目录（旧版默认 ~/Downloads）。
    var downloadDir: URL {
        URL(fileURLWithPath: (settings.downloadDir as NSString).expandingTildeInPath)
    }

    /// 保存格式：**永远 `txt`**（M11：两个平台默认只下 TXT，入口已删）。
    var format: String { FMSettings.normalizedFormat(settings.format) }

    /// 唯一写入路径。
    func update(_ mutate: (inout FMSettings) -> Void) {
        var next = settings
        mutate(&next)
        next.format = FMSettings.normalizedFormat(next.format) // M11：只允许 TXT
        guard next != settings else { return }
        settings = next
        persist()
    }

    func save() { persist() }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: FMAppPaths.legacySupport, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try encoder.encode(settings).write(to: fileURL, options: .atomic)
            fmLog("设置已保存：\(fileURL.path)")
        } catch {
            fmLog("设置保存失败：\(error.localizedDescription)")
        }
    }

    static func load(from url: URL) -> FMSettings {
        guard let data = try? Data(contentsOf: url) else { return .default }
        if let decoded = try? JSONDecoder().decode(FMSettings.self, from: data) { return decoded }
        fmLog("设置文件无法解析，使用默认值：\(url.path)")
        return .default
    }
}
