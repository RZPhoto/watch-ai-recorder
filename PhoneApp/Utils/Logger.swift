import Foundation

/// 简易日志：追加写入沙盒 Documents/app.log
/// 无 Mac 环境下无法用调试器，日志文件是主要的排障手段。
enum AppLogger {
    private static let queue = DispatchQueue(label: "app.logger")
    private static var logURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("app.log")
    }

    static func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        queue.sync {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: logURL)
            }
        }
    }

    static func readAll() -> String {
        queue.sync {
            (try? String(contentsOf: logURL, encoding: .utf8)) ?? "（日志为空）"
        }
    }

    static func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: logURL)
        }
    }
}
