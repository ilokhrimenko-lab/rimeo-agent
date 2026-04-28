import Foundation
import AVFoundation
import Accelerate

// Native Swift analysis engine: AVFoundation + Accelerate (MFCC, RMS, ZCR, Groove, Happiness)
// No librosa/CLAP dependency — pure Apple frameworks

struct TrackFeatures: Codable {
    var track_id:      String
    var segment_start: Double
    var segment_end:   Double
    var analyzed_at:   Int

    var energy:     Double
    var brightness: Double
    var zcr:        Double
    var timbre:     [Double]   // 13 MFCC coefficients
    var groove:     Double
    var happiness:  Double
}

final class AnalysisEngine {
    static let shared = AnalysisEngine()

    // In-memory analysis store (mirrors analysis_data.json)
    private let storeLock = NSLock()
    private var store: [String: TrackFeatures] = [:]
    private let runLock = NSLock()
    private var cancelRequested = false

    private init() {
        store = loadStore()
    }

    func loadStore() -> [String: TrackFeatures] {
        guard let data = try? Data(contentsOf: AppConfig.shared.analysisFile),
              let decoded = try? JSONDecoder().decode([String: TrackFeatures].self, from: data)
        else { return [:] }
        return decoded
    }

    func saveStore(_ s: [String: TrackFeatures]? = nil) {
        storeLock.lock()
        let toSave = s ?? store
        storeLock.unlock()
        guard let data = try? JSONEncoder().encode(toSave) else {
            logger.error("Analysis store encode failed")
            return
        }
        do {
            try data.write(to: AppConfig.shared.analysisFile, options: .atomic)
        } catch {
            logger.error("Analysis store save failed: \(error.localizedDescription)")
        }
    }

    func getFeatures(_ id: String) -> TrackFeatures? {
        storeLock.lock(); defer { storeLock.unlock() }
        return store[id]
    }

    func setFeatures(_ id: String, _ feat: TrackFeatures) {
        storeLock.lock(); store[id] = feat; storeLock.unlock()
    }

    func allIDs() -> [String] {
        storeLock.lock(); defer { storeLock.unlock() }
        return Array(store.keys)
    }

    func storeSnapshot() -> [String: TrackFeatures] {
        storeLock.lock(); defer { storeLock.unlock() }
        return store
    }

    func resetCancellation() {
        runLock.lock()
        cancelRequested = false
        runLock.unlock()
    }

    func requestCancel() {
        runLock.lock()
        cancelRequested = true
        runLock.unlock()
    }

    func shouldCancel() -> Bool {
        runLock.lock()
        defer { runLock.unlock() }
        return cancelRequested
    }

    // Analyse one track. Returns nil on failure.
    func analyzeTrack(_ track: Track) -> TrackFeatures? {
        guard !track.id.isEmpty,
              FileManager.default.fileExists(atPath: track.location) else {
            logger.warning("Analysis skipped missing file: \(track.id) \(track.location)")
            return nil
        }

        // Load waveform cache for segment selection
        let cacheURL = AppConfig.shared.cacheDir
            .appendingPathComponent("wave_\(track.id).json")
        var peaks    = [Double]()
        var duration = 0.0

        if let data = try? Data(contentsOf: cacheURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            peaks    = (json["peaks"]    as? [Double]) ?? []
            duration = (json["duration"] as? Double)   ?? 0
        }
        if duration <= 0 {
            duration = AudioService.shared.probeDuration(track.location)
        }
        guard duration > 0 else {
            logger.warning("Analysis skipped unreadable duration: \(track.id) \(track.location)")
            return nil
        }

        let (segStart, segEnd) = findAnalysisSegment(peaks: peaks, duration: duration)
        let segDur = segEnd - segStart

        guard let tmpPath = AudioService.shared.extractSegment(
            path: track.location, start: segStart, duration: segDur
        ) else {
            logger.warning("Analysis segment extraction failed: \(track.id) \(track.location)")
            return nil
        }
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        guard let feats = computeFeatures(wavPath: tmpPath) else {
            logger.warning("Analysis feature extraction failed: \(track.id) \(track.location)")
            return nil
        }

        return TrackFeatures(
            track_id:      track.id,
            segment_start: segStart,
            segment_end:   segEnd,
            analyzed_at:   Int(Date().timeIntervalSince1970),
            energy:        feats.energy,
            brightness:    feats.brightness,
            zcr:           feats.zcr,
            timbre:        feats.timbre,
            groove:        feats.groove,
            happiness:     feats.happiness
        )
    }

    // --- Segment selection (port of analyzer.py) ---
    func findAnalysisSegment(peaks: [Double], duration: Double) -> (Double, Double) {
        let seg = 60.0
        guard !peaks.isEmpty, duration > 0 else {
            let s = duration * 0.40
            return (s.rounded(toPlaces: 1), min(s + seg, duration).rounded(toPlaces: 1))
        }

        let n       = peaks.count
        let searchLo = Int(Double(n) * 0.35)
        let searchHi = Int(Double(n) * 0.65)
        let win      = max(1, min(Int(Double(n) * seg / duration), searchHi - searchLo))

        var bestIdx   = searchLo
        var bestScore = -1.0

        for i in searchLo ..< max(searchLo + 1, searchHi - win + 1) {
            let slice = peaks[i ..< min(i + win, peaks.count)]
            let avg   = slice.reduce(0, +) / Double(slice.count)
            if avg > bestScore { bestScore = avg; bestIdx = i }
        }

        let start = (duration * Double(bestIdx) / Double(n)).rounded(toPlaces: 1)
        let end   = min(start + seg, duration).rounded(toPlaces: 1)
        return (start, end)
    }

    // --- Feature extraction via AVFoundation + Accelerate ---
    private struct Features {
        var energy, brightness, zcr, groove, happiness: Double
        var timbre: [Double]
    }

    private func computeFeatures(wavPath: String) -> Features? {
        guard let samples = loadMonoSamples(wavPath: wavPath), samples.count > 512 else { return nil }

        let sr   = 22050.0
        let n    = samples.count

        // RMS energy
        var rmsVal: Float = 0
        var fSamples = samples
        vDSP_rmsqv(&fSamples, 1, &rmsVal, vDSP_Length(n))
        let energy = Double(rmsVal)

        // FFT power spectrum (full signal averaged into one frame)
        let log2n  = vDSP_Length(log2(Double(n.nextPowerOf2)))
        let fftLen = Int(1) << Int(log2n)
        var padded = [Float](fSamples.prefix(fftLen))
        if padded.count < fftLen { padded += [Float](repeating: 0, count: fftLen - padded.count) }

        // Apply Hann window
        var window     = [Float](repeating: 0, count: fftLen)
        var windowed   = [Float](repeating: 0, count: fftLen)
        vDSP_hann_window(&window, vDSP_Length(fftLen), Int32(vDSP_HANN_NORM))
        vDSP_vmul(&padded, 1, &window, 1, &windowed, 1, vDSP_Length(fftLen))
        padded = windowed

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var splitReal = [Float](repeating: 0, count: fftLen / 2)
        var splitImag = [Float](repeating: 0, count: fftLen / 2)

        splitReal.withUnsafeMutableBufferPointer { realBuf in
            splitImag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                padded.withUnsafeBytes { rawBuf in
                    rawBuf.withMemoryRebound(to: DSPComplex.self) { cBuf in
                        vDSP_ctoz(cBuf.baseAddress!, 2, &split, 1, vDSP_Length(fftLen / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }

        var power = [Float](repeating: 0, count: fftLen / 2)
        splitReal.withUnsafeMutableBufferPointer { realBuf in
            splitImag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(fftLen / 2))
            }
        }

        // Spectral centroid → brightness (0–1 over 0–4000 Hz range)
        let freqBinWidth = Float(sr) / Float(fftLen)
        var weightedSum: Float = 0; var totalPower: Float = 0
        for i in 0 ..< power.count {
            let freq = Float(i) * freqBinWidth
            weightedSum += freq * power[i]
            totalPower  += power[i]
        }
        let centroid   = totalPower > 0 ? Double(weightedSum / totalPower) : 0
        let brightness = min(1.0, centroid / 4000.0)

        // Zero-crossing rate
        var crossings = 0
        for i in 1 ..< n {
            if (samples[i - 1] >= 0) != (samples[i] >= 0) { crossings += 1 }
        }
        let zcr = Double(crossings) / Double(n)

        // MFCC via mel filter bank + DCT
        let timbre = computeMFCC(power: power, sr: sr, fftLen: fftLen)

        // Groove: beat interval regularity
        let groove = computeGroove(samples: samples, sr: sr)

        // Happiness: chroma → major/minor ratio
        let happiness = computeHappiness(power: power, sr: sr, fftLen: fftLen)

        return Features(energy: energy, brightness: brightness, zcr: zcr,
                        groove: groove, happiness: happiness, timbre: timbre)
    }

    // MARK: - MFCC

    private func computeMFCC(power: [Float], sr: Double, fftLen: Int) -> [Double] {
        let nFilters = 40
        let nCoeffs  = 13
        let fLow     = 20.0
        let fHigh    = min(sr / 2, 8000.0)

        func hzToMel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
        func melToHz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }

        let melLow  = hzToMel(fLow)
        let melHigh = hzToMel(fHigh)
        let melPts  = (0 ... nFilters + 1).map { i -> Double in
            melLow + (melHigh - melLow) * Double(i) / Double(nFilters + 1)
        }
        let freqPts = melPts.map { melToHz($0) }
        let binWidth = sr / Double(fftLen)

        // Mel filter bank energies
        var melEnergies = [Double](repeating: 0, count: nFilters)
        for m in 0 ..< nFilters {
            let f0 = freqPts[m]; let f1 = freqPts[m + 1]; let f2 = freqPts[m + 2]
            for k in 0 ..< power.count {
                let freq = Double(k) * binWidth
                var weight = 0.0
                if freq >= f0 && freq <= f1 {
                    weight = (freq - f0) / (f1 - f0)
                } else if freq > f1 && freq <= f2 {
                    weight = (f2 - freq) / (f2 - f1)
                }
                melEnergies[m] += weight * Double(power[k])
            }
            melEnergies[m] = log(max(melEnergies[m], 1e-10))
        }

        // DCT-II
        var mfcc = [Double](repeating: 0, count: nCoeffs)
        for n in 0 ..< nCoeffs {
            var sum = 0.0
            for m in 0 ..< nFilters {
                sum += melEnergies[m] * cos(Double.pi * Double(n) * (Double(m) + 0.5) / Double(nFilters))
            }
            mfcc[n] = round(sum * 10000) / 10000
        }
        return mfcc
    }

    // MARK: - Groove (simplified onset-based)

    private func computeGroove(samples: [Float], sr: Double) -> Double {
        // Onset strength as spectral flux, then find peaks
        let frameLen = 512
        let hopLen   = 256
        guard samples.count > frameLen * 4 else { return 0.5 }

        var prevFrame = [Float](repeating: 0, count: frameLen / 2)
        var onsets    = [Double]()
        var pos       = 0
        while pos + frameLen < samples.count {
            var frame = Array(samples[pos ..< pos + frameLen])
            // Simple onset strength: sum of positive spectral diff
            var flux: Float = 0
            for i in 0 ..< frameLen / 2 {
                let diff = abs(frame[i]) - prevFrame[i]
                if diff > 0 { flux += diff }
            }
            if flux > 0.01 { onsets.append(Double(pos) / sr) }
            prevFrame = Array(frame.prefix(frameLen / 2))
            pos += hopLen
        }

        guard onsets.count > 3 else { return 0.5 }

        // Beat interval regularity
        let intervals = (1 ..< onsets.count).map { onsets[$0] - onsets[$0 - 1] }
        let mean   = intervals.reduce(0, +) / Double(intervals.count)
        let stddev = sqrt(intervals.map { pow($0 - mean, 2) }.reduce(0, +) / Double(intervals.count))
        let groove = max(0.0, min(1.0, 1.0 - stddev / (mean + 1e-6)))
        return (groove * 10000).rounded() / 10000
    }

    // MARK: - Happiness (chroma → major/minor)

    private func computeHappiness(power: [Float], sr: Double, fftLen: Int) -> Double {
        var chroma = [Double](repeating: 0, count: 12)
        let binWidth = sr / Double(fftLen)
        let A4_hz    = 440.0

        for k in 1 ..< power.count {
            let freq = Double(k) * binWidth
            guard freq > 20 else { continue }
            let midi    = 69.0 + 12.0 * log2(freq / A4_hz)
            let pitchCl = ((Int(midi.rounded()) % 12) + 12) % 12
            chroma[pitchCl] += Double(power[k])
        }
        // Normalize
        let maxC = chroma.max() ?? 1.0
        if maxC > 0 { for i in 0..<12 { chroma[i] /= maxC } }

        let majorIntervals = [0, 2, 4, 5, 7, 9, 11]
        let minorIntervals = [0, 2, 3, 5, 7, 8, 10]
        var bestMajor = 0.0; var bestMinor = 0.0
        for root in 0 ..< 12 {
            let maj = majorIntervals.reduce(0.0) { $0 + chroma[($1 + root) % 12] }
            let min = minorIntervals.reduce(0.0) { $0 + chroma[($1 + root) % 12] }
            bestMajor = max(bestMajor, maj)
            bestMinor = max(bestMinor, min)
        }
        let total = bestMajor + bestMinor + 1e-8
        return ((bestMajor / total) * 10000).rounded() / 10000
    }

    // MARK: - Audio loading

    private func loadMonoSamples(wavPath: String) -> [Float]? {
        let url = URL(fileURLWithPath: wavPath)
        guard let audioFile = try? AVAudioFile(forReading: url) else { return nil }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 22050,
                                   channels: 1,
                                   interleaved: false)!
        let capacity = AVAudioFrameCount(min(audioFile.length, 22050 * 70))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        do {
            try audioFile.read(into: buffer)
        } catch {
            return nil
        }

        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
    }
}

// MARK: - Helpers

private extension Int {
    var nextPowerOf2: Int {
        guard self > 0 else { return 1 }
        var n = self - 1
        n |= n >> 1; n |= n >> 2; n |= n >> 4; n |= n >> 8; n |= n >> 16
        return n + 1
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
