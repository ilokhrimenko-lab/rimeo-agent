import Foundation

final class AgentLogger {
    static let shared = AgentLogger()

    private let queue     = DispatchQueue(label: "rimeo.logger", qos: .utility)
    private var handle:    FileHandle?
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private init() {
        let url = AppConfig.shared.logFile
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: url.path)
        handle?.seekToEndOfFile()
    }

    func log(_ level: String, _ msg: String) {
        let ts   = formatter.string(from: Date())
        let line = "\(ts) [\(level)] \(msg)\n"
        queue.async {
            print(line, terminator: "")
            if let data = line.data(using: .utf8) {
                self.handle?.write(data)
            }
        }
    }

    func info(_ msg: String)    { log("INFO",  msg) }
    func warning(_ msg: String) { log("WARN",  msg) }
    func error(_ msg: String)   { log("ERROR", msg) }
    func debug(_ msg: String)   { log("DEBUG", msg) }

    func lastLines(_ n: Int) -> String {
        guard let data = try? Data(contentsOf: AppConfig.shared.logFile),
              let text = String(data: data, encoding: .utf8) else { return "" }
        let lines = text.components(separatedBy: .newlines)
        return lines.suffix(n).joined(separator: "\n")
    }
}

let logger = AgentLogger.shared
