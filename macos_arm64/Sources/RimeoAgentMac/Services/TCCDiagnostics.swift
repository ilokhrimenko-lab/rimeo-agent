import Foundation

enum TCCDiagnostics {
    private static let queue = DispatchQueue(label: "rimeo.tcc.diagnostics", qos: .utility)
    private static var didLogIdentity = false

    static func logIdentityOnce() {
        queue.async {
            guard !didLogIdentity else { return }
            didLogIdentity = true

            let bundle = Bundle.main
            let bundleID = bundle.bundleIdentifier ?? "(none)"
            let bundlePath = bundle.bundlePath
            let executablePath = bundle.executablePath ?? CommandLine.arguments.first ?? "(unknown)"
            let fullDiskAccess = hasFullDiskAccess()

            logger.info("TCC identity: bundle_id=\(bundleID), bundle_path=\(bundlePath), executable=\(executablePath), full_disk_access=\(fullDiskAccess)")

            let signature = codeSignatureSummary(for: bundlePath)
            logger.info("TCC signing: \(signature)")

            logger.info("TCC note: Full Disk Access and Files & Folders prompts (Downloads/Desktop/Documents) are separate macOS privacy surfaces; unsigned or ad-hoc rebuilt apps can get a new TCC identity.")
        }
    }

    static func logPathAccess(_ operation: String, path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let location = protectedLocation(for: normalized)

        logger.info("TCC path access: operation=\(operation), location=\(location), path=\(normalized)")
    }

    static func logPathResult(_ operation: String, path: String, exists: Bool, readable: Bool) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let location = protectedLocation(for: normalized)

        logger.info("TCC path result: operation=\(operation), location=\(location), exists=\(exists), readable=\(readable), path=\(normalized)")
    }

    static func hasFullDiskAccess() -> Bool {
        let tccDB = "/Library/Application Support/com.apple.TCC/TCC.db"
        if let fh = FileHandle(forReadingAtPath: tccDB) {
            fh.closeFile()
            return true
        }
        return false
    }

    private static func protectedLocation(for path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let checks: [(String, String)] = [
            ("downloads", "\(home)/Downloads"),
            ("documents", "\(home)/Documents"),
            ("desktop", "\(home)/Desktop"),
            ("music", "\(home)/Music"),
            ("external_volume", "/Volumes/"),
        ]

        for (label, prefix) in checks where path == prefix || path.hasPrefix(prefix + "/") {
            return label
        }
        return "other"
    }

    private static func codeSignatureSummary(for appPath: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["-dv", "--verbose=4", appPath]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return "codesign failed to run: \(error.localizedDescription)"
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        let interesting = text
            .components(separatedBy: .newlines)
            .filter {
                $0.hasPrefix("Identifier=") ||
                $0.hasPrefix("Signature=") ||
                $0.hasPrefix("TeamIdentifier=") ||
                $0.hasPrefix("Info.plist=") ||
                $0.hasPrefix("Sealed Resources=") ||
                $0.hasPrefix("Internal requirements=")
            }

        if interesting.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return interesting.joined(separator: ", ")
    }
}
