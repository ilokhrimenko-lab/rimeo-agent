import Foundation
import Darwin

final class AppConfig {
    static let shared = AppConfig()

    let appName = "Rimeo Desktop Agent"
    let version: String
    let buildNumber: String
    let releaseTag: String
    let displayVersion: String
    let port: UInt16 = 8000
    let rimeoAppURL = "https://rimeo.app"
    let githubRepo  = "your-org/rimeo"

    let baseDir:      URL
    let cacheDir:     URL
    let dataFile:     URL
    let logFile:      URL
    let analysisFile: URL

    private(set) var agentID:  String
    private(set) var xmlPath:  String = ""
    private(set) var dbPath:   String

    private let queue = DispatchQueue(label: "rimeo.config", qos: .utility)

    private init() {
        let buildInfo = Self.loadBuildInfo()
        version = buildInfo.version
        buildNumber = buildInfo.buildNumber
        releaseTag = buildInfo.releaseTag
        displayVersion = Self.makeDisplayVersion(version: buildInfo.version, buildNumber: buildInfo.buildNumber)

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        baseDir      = appSupport.appendingPathComponent("RimeoAgent")
        cacheDir     = baseDir.appendingPathComponent("cache")
        dataFile     = baseDir.appendingPathComponent("rimo_data.json")
        logFile      = baseDir.appendingPathComponent("agent.log")
        analysisFile = baseDir.appendingPathComponent("analysis_data.json")
        dbPath       = Self.detectDBPath()

        try? FileManager.default.createDirectory(at: baseDir,  withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        // Persistent agent ID
        let idFile = baseDir.appendingPathComponent("agent_id")
        if let s = try? String(contentsOf: idFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            agentID = s
        } else {
            agentID = UUID().uuidString
            try? agentID.write(to: idFile, atomically: true, encoding: .utf8)
        }

        // Load paths from .env
        let envFile = baseDir.appendingPathComponent(".env")
        if let content = try? String(contentsOf: envFile, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) {
                let kv = line.components(separatedBy: "=")
                guard kv.count >= 2 else { continue }
                let key = kv[0].trimmingCharacters(in: .whitespaces)
                let value = kv.dropFirst().joined(separator: "=")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if key == "RIMEO_XML_PATH" {
                    xmlPath = value
                } else if key == "RIMEO_DB_PATH", !value.isEmpty {
                    dbPath = value
                }
            }
        }
    }

    func setXMLPath(_ path: String) {
        queue.sync { xmlPath = path }
        updateEnvVar(key: "RIMEO_XML_PATH", value: path)
    }

    func setDBPath(_ path: String) {
        queue.sync { dbPath = path }
        updateEnvVar(key: "RIMEO_DB_PATH", value: path)
    }

    func localAgentURL() -> String {
        "http://\(getLocalIP()):\(port)"
    }

    var xmlExists: Bool {
        !xmlPath.isEmpty && FileManager.default.fileExists(atPath: xmlPath)
    }

    var dbExists: Bool {
        !dbPath.isEmpty && FileManager.default.fileExists(atPath: dbPath)
    }

    var hasAnyLibrarySource: Bool {
        xmlExists || dbExists
    }

    func applyCloudHeaders(to request: inout URLRequest, contentType: String? = nil) {
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    func getLocalIP() -> String {
        let sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return "127.0.0.1" }
        defer { Darwin.close(sock) }

        var dst = sockaddr_in()
        dst.sin_family  = sa_family_t(AF_INET)
        dst.sin_port    = 80
        dst.sin_addr.s_addr = 0x08080808   // 8.8.8.8

        let ok = withUnsafePointer(to: &dst) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard ok else { return "127.0.0.1" }

        var local = sockaddr_in()
        var len   = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var inAddr = local.sin_addr
        inet_ntop(AF_INET, &inAddr, &buf, socklen_t(INET_ADDRSTRLEN))
        let ip = String(cString: buf)
        return ip.isEmpty ? "127.0.0.1" : ip
    }

    private static func makeDisplayVersion(version: String, buildNumber: String) -> String {
        let trimmed = buildNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "dev" else { return version }
        return "\(version) (build \(trimmed))"
    }

    private static func detectDBPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Pioneer/rekordbox/master.db"
    }

    private static func loadBuildInfo() -> (version: String, buildNumber: String, releaseTag: String) {
        let fallback = ("1.0", "dev", "v1.0-dev")
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let execDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()

        let searchRoots = [
            cwd,
            cwd.deletingLastPathComponent(),
            execDir,
            execDir.deletingLastPathComponent(),
            execDir.deletingLastPathComponent().deletingLastPathComponent(),
            Bundle.main.resourceURL,
        ]
        .compactMap { $0 }

        for root in searchRoots {
            let candidate = root.appendingPathComponent("build_info.py")
            guard let text = try? String(contentsOf: candidate, encoding: .utf8) else { continue }
            let version = match(in: text, pattern: #"VERSION\s*=\s*"([^"]+)""#) ?? fallback.0
            let build = match(in: text, pattern: #"BUILD_NUMBER\s*=\s*"([^"]+)""#) ?? fallback.1
            let tag = match(in: text, pattern: #"RELEASE_TAG\s*=\s*"([^"]+)""#) ?? fallback.2
            return (version, build, tag)
        }

        return fallback
    }

    private static func match(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[valueRange])
    }

    private func updateEnvVar(key: String, value: String) {
        let envFile = baseDir.appendingPathComponent(".env")
        let existing = (try? String(contentsOf: envFile, encoding: .utf8)
            .components(separatedBy: .newlines)) ?? []
        var lines = existing.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key)=") && !$0.isEmpty }
        lines.append("\(key)=\(value)")
        try? (lines.joined(separator: "\n") + "\n")
            .write(to: envFile, atomically: true, encoding: .utf8)
    }
}
