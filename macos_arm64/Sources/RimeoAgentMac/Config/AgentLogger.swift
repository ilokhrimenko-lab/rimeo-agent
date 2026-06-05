import Foundation

final class AgentLogger {
    static let shared = AgentLogger()

    private let queue     = DispatchQueue(label: "rimeo.logger", qos: .utility)
    private let maxLines  = 500
    private var lines:     [String] = []
    private let logURL:    URL
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private init() {
        logURL = AppConfig.shared.logFile
        // Seed the in-memory ring from the existing file's tail, then the file is
        // rewritten on every log line so it never exceeds `maxLines` (keeps the
        // macOS Console from choking on a multi-MB file).
        if let data = try? Data(contentsOf: logURL),
           let text = String(data: data, encoding: .utf8) {
            lines = Array(text.components(separatedBy: "\n").filter { !$0.isEmpty }.suffix(maxLines))
        }
    }

    func log(_ level: String, _ msg: String) {
        let ts   = formatter.string(from: Date())
        let line = "\(ts) [\(level)] \(msg)"
        queue.async {
            print(line)
            self.lines.append(line)
            if self.lines.count > self.maxLines {
                self.lines.removeFirst(self.lines.count - self.maxLines)
            }
            let text = self.lines.joined(separator: "\n") + "\n"
            try? text.write(to: self.logURL, atomically: true, encoding: .utf8)
        }
    }

    func info(_ msg: String)    { log("INFO",  msg) }
    func warning(_ msg: String) { log("WARN",  msg) }
    func error(_ msg: String)   { log("ERROR", msg) }
    func debug(_ msg: String)   { log("DEBUG", msg) }

    func lastLines(_ n: Int) -> String {
        queue.sync { lines.suffix(n).joined(separator: "\n") }
    }
}

let logger = AgentLogger.shared
