import Foundation

// Handles waveform generation, artwork extraction, AIFF→WAV conversion
final class AudioService {
    static let shared = AudioService()
    private let convLocks = NSMapTable<NSString, NSLock>(keyOptions: .strongMemory,
                                                         valueOptions: .strongMemory)
    private let lockGuard = NSLock()

    private func convLock(for id: String) -> NSLock {
        lockGuard.lock(); defer { lockGuard.unlock() }
        let key = id as NSString
        if let existing = convLocks.object(forKey: key) { return existing }
        let lock = NSLock()
        convLocks.setObject(lock, forKey: key)
        return lock
    }

    // Returns path to a WAV file (from cache or freshly converted)
    func ensureWAV(path: String, trackID: String) throws -> String {
        let cached = AppConfig.shared.cacheDir.appendingPathComponent("conv_\(trackID).wav")
        if FileManager.default.fileExists(atPath: cached.path) {
            logger.info("AIFF conversion cache hit: track=\(trackID), wav=\(cached.path)")
            return cached.path
        }

        let lock = convLock(for: trackID)
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: cached.path) {
            logger.info("AIFF conversion cache hit after lock: track=\(trackID), wav=\(cached.path)")
            return cached.path
        }

        logger.info("Converting AIFF → WAV: \(trackID)")
        TCCDiagnostics.logPathAccess("convert-aiff", path: path)
        let exists = FileManager.default.fileExists(atPath: path)
        let readable = FileManager.default.isReadableFile(atPath: path)
        TCCDiagnostics.logPathResult("convert-aiff", path: path, exists: exists, readable: readable)
        logger.info("AIFF conversion input: track=\(trackID), exists=\(exists), readable=\(readable), path=\(path)")
        if let ffmpegPath = findBinary("ffmpeg") {
            logger.info("AIFF conversion ffmpeg: track=\(trackID), binary=\(ffmpegPath)")
        } else {
            logger.warning("AIFF conversion ffmpeg missing: track=\(trackID)")
        }
        let result = runFFmpeg(["-i", path, "-f", "wav", cached.path, "-y"], timeout: 120)
        guard result.success, FileManager.default.fileExists(atPath: cached.path) else {
            logger.warning("AIFF conversion failed: track=\(trackID), stderr=\(result.stderr)")
            throw AudioError.conversionFailed(result.stderr)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: cached.path))?[.size] as? Int ?? 0
        logger.info("AIFF conversion complete: track=\(trackID), wav=\(cached.path), bytes=\(size)")
        return cached.path
    }

    // Generate waveform JSON: {duration, peaks}
    func waveform(path: String, trackID: String) -> [String: Any] {
        let cacheURL = AppConfig.shared.cacheDir.appendingPathComponent("wave_\(trackID).json")
        if let data = try? Data(contentsOf: cacheURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return json
        }

        let exists = FileManager.default.fileExists(atPath: path)
        let readable = FileManager.default.isReadableFile(atPath: path)
        TCCDiagnostics.logPathResult("waveform", path: path, exists: exists, readable: readable)
        guard exists else {
            return ["duration": 0.0, "peaks": [Double]()]
        }

        // Probe duration
        let probeResult = runFFmpeg(
            ["-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            binary: "ffprobe",
            timeout: 12
        )
        let duration = Double(probeResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0.0

        // Downsample to 8000 peaks via s8 raw PCM
        let cmd = ["-v", "error", "-i", path, "-ac", "1",
                   "-filter:a", "aresample=100", "-f", "s8", "-"]
        let result = runFFmpeg(cmd, timeout: 60)
        guard result.success, !result.rawOutput.isEmpty else {
            logger.warning("Waveform failed: track=\(trackID), stderr=\(result.stderr)")
            return ["duration": duration, "peaks": [Double]()]
        }

        let bytes  = result.rawOutput
        let samples = bytes.map { b -> Double in
            let signed = b < 128 ? Int(b) : Int(b) - 256
            return Double(abs(signed)) / 128.0
        }
        let step  = max(1, samples.count / 8000)
        var peaks = [Double]()
        var i = 0
        while i < samples.count {
            let chunk = samples[i..<min(i + step, samples.count)]
            let avg   = chunk.reduce(0, +) / Double(chunk.count)
            peaks.append(min(1.0, (avg * 2.5 * 1000).rounded() / 1000))
            i += step
        }

        let out: [String: Any] = ["duration": duration, "peaks": peaks]
        if let data = try? JSONSerialization.data(withJSONObject: out) {
            try? data.write(to: cacheURL)
        }
        return out
    }

    // Extract artwork JPEG → cache, returns path or nil
    func artwork(path: String, trackID: String) -> String? {
        let cacheURL = AppConfig.shared.cacheDir.appendingPathComponent("art_\(trackID).jpg")
        if FileManager.default.fileExists(atPath: cacheURL.path) { return cacheURL.path }
        let exists = FileManager.default.fileExists(atPath: path)
        let readable = FileManager.default.isReadableFile(atPath: path)
        TCCDiagnostics.logPathResult("artwork", path: path, exists: exists, readable: readable)
        guard exists else { return nil }

        // WAV/AIFF and many plain audio files do not contain embedded artwork streams.
        // Probe first so we do not treat a "no stream" case as an extraction failure.
        let probe = runFFmpeg(
            [
                "-v", "error",
                "-select_streams", "v:0",
                "-show_entries", "stream=index",
                "-of", "csv=p=0",
                path
            ],
            binary: "ffprobe",
            timeout: 12
        )
        let hasArtworkStream = !probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasArtworkStream {
            logger.info("Artwork stream missing: track=\(trackID)")
            return nil
        }

        let result = runFFmpeg([
            "-v", "error",
            "-i", path,
            "-map", "0:v:0",
            "-an",
            "-vcodec", "mjpeg",
            "-vframes", "1",
            "-s", "512x512",
            cacheURL.path,
            "-y"
        ], timeout: 45)
        let ok = result.success && FileManager.default.fileExists(atPath: cacheURL.path)
        if !ok {
            logger.warning("Artwork extraction failed: track=\(trackID), stderr=\(result.stderr)")
        }
        return ok ? cacheURL.path : nil
    }

    // Probe duration only
    func probeDuration(_ path: String) -> Double {
        TCCDiagnostics.logPathAccess("probe-duration", path: path)
        let r = runFFmpeg(
            ["-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            binary: "ffprobe",
            timeout: 12
        )
        return Double(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 300.0
    }

    // Extract audio segment to temp WAV at 22050 Hz mono
    func extractSegment(path: String, start: Double, duration: Double) -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rimeo_seg_\(UUID().uuidString).wav")
        TCCDiagnostics.logPathAccess("extract-segment", path: path)
        let result = runFFmpeg([
            "-v", "error",
            "-ss", String(start), "-t", String(duration),
            "-i", path,
            "-ac", "1", "-ar", "22050",
            "-f", "wav", "-y", tmp.path
        ], timeout: 45)
        guard result.success, FileManager.default.fileExists(atPath: tmp.path) else {
            logger.warning("Segment extraction failed: stderr=\(result.stderr)")
            return nil
        }
        return tmp.path
    }
}

// MARK: - FFmpeg runner

struct RunResult {
    let success:   Bool
    let stdout:    String
    let stderr:    String
    let rawOutput: [UInt8]
}

func runFFmpeg(_ args: [String], binary: String = "ffmpeg", timeout: TimeInterval = 120) -> RunResult {
    guard let bin = findBinary(binary) else {
        logger.warning("Audio command failed: \(binary) not found")
        return RunResult(success: false, stdout: "", stderr: "\(binary) not found", rawOutput: [])
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: bin)
    proc.arguments     = args

    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError  = errPipe

    let outputQueue = DispatchQueue(label: "rimeo.\(binary).output", qos: .utility, attributes: .concurrent)
    let outGroup = DispatchGroup()
    var rawOut = Data()
    var rawErr = Data()

    outGroup.enter()
    outputQueue.async {
        rawOut = outPipe.fileHandleForReading.readDataToEndOfFile()
        outGroup.leave()
    }

    outGroup.enter()
    outputQueue.async {
        rawErr = errPipe.fileHandleForReading.readDataToEndOfFile()
        outGroup.leave()
    }

    do {
        try proc.run()
    } catch {
        return RunResult(success: false, stdout: "", stderr: "\(error)", rawOutput: [])
    }

    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        proc.waitUntilExit()
        finished.signal()
    }

    if finished.wait(timeout: .now() + timeout) == .timedOut {
        proc.terminate()
        _ = finished.wait(timeout: .now() + 5)
        outPipe.fileHandleForReading.closeFile()
        errPipe.fileHandleForReading.closeFile()
        _ = outGroup.wait(timeout: .now() + 5)
        return RunResult(success: false, stdout: "", stderr: "\(binary) timed out", rawOutput: [])
    }

    _ = outGroup.wait(timeout: .now() + 5)
    let stdout = String(data: rawOut, encoding: .utf8) ?? ""
    let stderr = String(data: rawErr, encoding: .utf8) ?? ""
    let raw    = [UInt8](rawOut)

    return RunResult(success: proc.terminationStatus == 0, stdout: stdout, stderr: stderr, rawOutput: raw)
}

func findBinary(_ name: String) -> String? {
    let bundled = Bundle.main.bundleURL
        .appendingPathComponent("Contents/MacOS/\(name)").path
    if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }

    let component = ComponentManager.shared.componentURL(id: name).path
    if FileManager.default.isExecutableFile(atPath: component) { return component }

    return findSystemExecutable(name)
}

enum AudioError: Error {
    case conversionFailed(String)
    case fileNotFound
}
