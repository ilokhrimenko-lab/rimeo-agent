import CryptoKit
import Foundation

struct ComponentInfo: Decodable, Identifiable, Equatable {
    let id: String
    let url: String
    let sha256: String
    let size: Int
}

struct RuntimeManifest: Decodable {
    let version: String
    let components: [ComponentInfo]
}

enum ComponentGateState {
    case checking
    case required([ComponentInfo])
    case downloading(Double, String)
    case restartRequired
    case error(String)
    case clear
}

final class ComponentManager {
    static let shared = ComponentManager()

    private let requiredIDs: Set<String> = ["tunnel-runtime", "ffmpeg", "ffprobe"]
    private let allowedIDs: Set<String> = ["tunnel-runtime", "ffmpeg", "ffprobe"]
    private let manifestPath = "/api/agent/runtime?platform=macos-arm64"

    let componentsDir: URL

    private init() {
        componentsDir = AppConfig.shared.baseDir.appendingPathComponent("components")
    }

    func componentURL(id: String) -> URL {
        componentsDir.appendingPathComponent(id, isDirectory: false)
    }

    func bundledComponentURL(id: String) -> URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(id)")
    }

    func checkMissing() async throws -> [ComponentInfo] {
        let manifest = try await fetchManifest()
        let manifestByID = Dictionary(uniqueKeysWithValues: manifest.components.map { ($0.id, $0) })
        let missingManifestIDs = requiredIDs.filter { manifestByID[$0] == nil }.sorted()
        guard missingManifestIDs.isEmpty else {
            throw ComponentError.invalidManifest
        }

        return requiredIDs
            .sorted()
            .compactMap { id in
                isAvailable(id: id) ? nil : manifestByID[id]
            }
    }

    func download(components: [ComponentInfo], progress: @escaping (Double, String) -> Void) async throws {
        guard !components.isEmpty else { return }
        try FileManager.default.createDirectory(at: componentsDir, withIntermediateDirectories: true)

        for (index, component) in components.enumerated() {
            guard allowedIDs.contains(component.id), let url = URL(string: component.url) else {
                throw ComponentError.invalidManifest
            }

            let baseProgress = Double(index) / Double(components.count)
            let span = 1.0 / Double(components.count)
            progress(baseProgress, "Installing update…")

            let tmpURL = try await downloadFile(from: url) { fileProgress in
                progress(baseProgress + span * fileProgress, "Installing update…")
            }

            try verify(component: component, tmpURL: tmpURL)
            try install(component: component, tmpURL: tmpURL)
            progress(Double(index + 1) / Double(components.count), "Installing update…")
        }
    }

    func isAvailable(id: String) -> Bool {
        if FileManager.default.isExecutableFile(atPath: bundledComponentURL(id: id).path) {
            return true
        }
        if FileManager.default.isExecutableFile(atPath: componentURL(id: id).path) {
            return true
        }
        return false
    }

    private func fetchManifest() async throws -> RuntimeManifest {
        guard let url = URL(string: AppConfig.shared.rimeoAppURL + manifestPath) else {
            throw ComponentError.invalidManifest
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("RimeoAgentMac/\(AppConfig.shared.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await data(for: request)
        do {
            return try JSONDecoder().decode(RuntimeManifest.self, from: data)
        } catch {
            logger.error("Runtime manifest decode failed: \(error)")
            throw ComponentError.invalidManifest
        }
    }

    private func data(for request: URLRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let data else {
                    continuation.resume(throwing: ComponentError.manifestUnavailable)
                    return
                }
                continuation.resume(returning: data)
            }.resume()
        }
    }

    private func downloadFile(from url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let delegate = ComponentDownloadDelegate(progress: progress, continuation: continuation)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            delegate.session = session
            let task = session.downloadTask(with: url)
            delegate.task = task
            task.resume()
        }
    }

    private func verify(component: ComponentInfo, tmpURL: URL) throws {
        let data = try Data(contentsOf: tmpURL)
        let digest = SHA256.hash(data: data)
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual.lowercased() == component.sha256.lowercased() else {
            logger.error("Runtime component checksum mismatch: id=\(component.id)")
            throw ComponentError.checksumMismatch
        }
    }

    private func install(component: ComponentInfo, tmpURL: URL) throws {
        let destination = componentURL(id: component.id)
        try FileManager.default.createDirectory(at: componentsDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tmpURL, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        logger.info("Runtime component installed: id=\(component.id), path=\(destination.path)")
    }
}

enum ComponentError: LocalizedError {
    case manifestUnavailable
    case invalidManifest
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .manifestUnavailable:
            return "Could not fetch the update. Check your internet connection and try again."
        case .invalidManifest:
            return "Could not prepare the update. Try again later."
        case .checksumMismatch:
            return "Could not verify the update. Try again."
        }
    }
}

private final class ComponentDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    var session: URLSession?
    var task: URLSessionDownloadTask?

    private let progress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var didComplete = false

    init(progress: @escaping (Double) -> Void, continuation: CheckedContinuation<URL, Error>) {
        self.progress = progress
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1.0, max(0.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard !didComplete else { return }
        do {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("rimeo_component_\(UUID().uuidString)")
            try FileManager.default.moveItem(at: location, to: tmpURL)
            didComplete = true
            continuation?.resume(returning: tmpURL)
            continuation = nil
            session.finishTasksAndInvalidate()
        } catch {
            didComplete = true
            continuation?.resume(throwing: error)
            continuation = nil
            session.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !didComplete, let error else { return }
        didComplete = true
        continuation?.resume(throwing: error)
        continuation = nil
        session.invalidateAndCancel()
    }
}

func findSystemExecutable(_ name: String) -> String? {
    let paths = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/bin",
        "/bin",
        "/opt/homebrew/opt/ffmpeg/bin",
        "\(NSHomeDirectory())/.local/bin",
    ]

    for dir in paths {
        let full = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: full) {
            return full
        }
    }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    proc.arguments = [name]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    try? proc.run()
    proc.waitUntilExit()

    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return out.isEmpty ? nil : out
}
