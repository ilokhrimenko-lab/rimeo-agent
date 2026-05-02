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
        let home = NSHomeDirectory()

        // User-level TCC-protected files: require FDA on all macOS versions regardless of path changes.
        let userProtectedFiles: [String] = [
            "\(home)/Library/Safari/History.db",
            "\(home)/Library/Messages/chat.db",
            "\(home)/Library/Mail/V10/MailData/Envelope Index",
            "\(home)/Library/Mail/V9/MailData/Envelope Index",
        ]
        for path in userProtectedFiles {
            if let fh = FileHandle(forReadingAtPath: path) {
                fh.closeFile()
                logger.info("FDA check: granted via \(path)")
                return true
            }
            logger.info("FDA check: \(path) not accessible")
        }

        // System paths: may vary across macOS versions.
        let systemFiles: [String] = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            "/private/var/db/dslocal/nodes/Default/users.plist",
            "/private/etc/sudoers",
        ]
        for path in systemFiles {
            if let fh = FileHandle(forReadingAtPath: path) {
                fh.closeFile()
                logger.info("FDA check: granted via \(path)")
                return true
            }
            logger.info("FDA check: \(path) not accessible")
        }

        // Directory listing fallbacks.
        let dirCandidates: [String] = [
            "/private/var/db/dslocal/nodes/Default",
            "/private/var/root",
        ]
        for dirPath in dirCandidates {
            if (try? FileManager.default.contentsOfDirectory(atPath: dirPath)) != nil {
                logger.info("FDA check: granted via dir listing \(dirPath)")
                return true
            }
            logger.info("FDA check: dir listing failed \(dirPath)")
        }
        logger.info("FDA check: not granted (all paths failed)")
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

        for (label, prefix) in checks where path == prefix || path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/") {
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
