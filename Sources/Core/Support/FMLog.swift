import Foundation

/// 应用级日志：写到 `~/Library/Application Support/FanQieMao/logs/app.log`，
/// 「导出诊断日志」用它 + 内核日志。
final class FMLog: @unchecked Sendable {
    static let shared = FMLog()

    private let queue = DispatchQueue(label: "com.yuki.fanqiemao.log")
    private let fileURL: URL
    private let stamp: ISO8601DateFormatter

    private init() {
        let dir = FMAppPaths.appSupport.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("app.log")
        stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
    }

    var path: String { fileURL.path }

    func write(_ message: String) {
        let line = "[\(stamp.string(from: Date()))] \(message)\n"
        // 同步写一份到 stderr：Tools/跑.sh 与自检脚本据此即时取证（不依赖日志队列排空）
        FileHandle.standardError.write(Data(line.utf8))
        queue.async { [fileURL] in
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}

func fmLog(_ message: String) {
    FMLog.shared.write(message)
}
